#!/usr/bin/env python3
"""
Demo: create a keyspace with tablets disabled (vnodes-based) holding

  * a sample table            -> sensor_readings
  * a secondary index on it   -> sensor_readings_region_idx (on region)
  * a materialized view on it -> sensor_readings_by_region
  * optionally (-c), a second counter table -> device_event_counts

Tablets must be disabled for this shape on older releases: counter tables,
secondary indexes and materialized views all gained tablets support only in
later ScyllaDB versions, so a vnodes keyspace is the portable baseline. This
is the same kind of source keyspace used by
copy_counter_table_vnodes_to_tablets.py.

The counter table is off by default because counters do not convert to
tablets: a keyspace holding one cannot be migrated in place with
convert_to_tablets_kubectl.bash, it has to be copied into a tablets keyspace
instead.
Without -c, this keyspace migrates as is.

Connects with username/password authentication (defaults: scylla /
scylla), so the cluster needs `enableAuth=true` in init.conf.

Install driver:  pip install scylla-driver
                  (or: pip install cassandra-driver)
"""

import argparse
import time
from datetime import datetime, timedelta, timezone

from cassandra.auth import PlainTextAuthProvider
from cassandra.cluster import Cluster

# in k8s use scylla-client
CONTACT_POINTS = ["scylla-client"] # ["127.0.0.1"]
USERNAME = "scylla"
PASSWORD = "scylla"
KEYSPACE = "vnodes_ks"
# one replica per rack - a tablets keyspace has to be RF-rack-valid
REPLICATION_FACTOR = 3
TABLE = "sensor_readings"
INDEX = "sensor_readings_region_idx"
VIEW = "sensor_readings_by_region"
COUNTER_TABLE = "device_event_counts"

# Sample readings: device_id, region, temperature
SAMPLE_DATA = [
    ("dev-001", "us-east", 21.5),
    ("dev-002", "us-east", 23.1),
    ("dev-003", "us-west", 19.8),
    ("dev-004", "eu-central", 25.4),
    ("dev-005", "eu-central", 24.0),
]

# Readings written per device — three timestamps each, one minute apart
READINGS_PER_DEVICE = 3


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument(
        "-c", "--counters", action="store_true",
        help="also create and populate the counter table - note that this makes "
             "the keyspace unmigratable to tablets",
    )
    return parser.parse_args()


def retry(fn, attempts=12, delay=5):
    """Run fn until it stops raising.

    A SELECT against a brand-new index or materialized view can fail until the
    index/view is built and visible on the coordinator, so the first few
    attempts are expected to fail on a fresh keyspace.
    """
    for attempt in range(1, attempts + 1):
        try:
            return fn()
        except Exception as e:
            if attempt == attempts:
                raise
            print(f"  attempt {attempt}/{attempts} failed ({e}); retrying in {delay}s")
            time.sleep(delay)


def main():
    opts = parse_args()

    cluster = Cluster(
        CONTACT_POINTS,
        auth_provider=PlainTextAuthProvider(username=USERNAME, password=PASSWORD),
    )
    session = cluster.connect()

    # 1. Keyspace with tablets explicitly disabled. Tablets are the default in
    #    recent ScyllaDB versions, so they must be turned off to get
    #    vnodes-based replication.
    print(f"Dropping keyspace {KEYSPACE} (tablets disabled)")
    session.execute(f"""DROP KEYSPACE IF EXISTS {KEYSPACE}""")
    print(f"Creating keyspace {KEYSPACE} (tablets disabled)")
    session.execute(f"""
        CREATE KEYSPACE IF NOT EXISTS {KEYSPACE}
        WITH replication = {{'class': 'NetworkTopologyStrategy', 'replication_factor': {REPLICATION_FACTOR}}}
        AND tablets = {{'enabled': false}}
    """)

    # 2. Sample table: one partition per device, readings clustered newest first.
    print(f"Creating table {KEYSPACE}.{TABLE}")
    session.execute(f"""
        CREATE TABLE IF NOT EXISTS {KEYSPACE}.{TABLE} (
            device_id text,
            reading_time timestamp,
            region text,
            temperature double,
            PRIMARY KEY (device_id, reading_time)
        ) WITH CLUSTERING ORDER BY (reading_time DESC)
    """)

    # 3. Secondary index on a non-key column. Good for low-cardinality lookups
    #    where the partition key isn't known.
    print(f"Creating index {INDEX} on {TABLE}(region)")
    session.execute(
        f"CREATE INDEX IF NOT EXISTS {INDEX} ON {KEYSPACE}.{TABLE} (region)"
    )

    # 4. Materialized view keyed by region. Every base primary key column must
    #    appear in the view's primary key, and view key columns can't be null.
    print(f"Creating materialized view {KEYSPACE}.{VIEW}")
    session.execute(f"""
        CREATE MATERIALIZED VIEW IF NOT EXISTS {KEYSPACE}.{VIEW} AS
            SELECT region, device_id, reading_time, temperature
            FROM {KEYSPACE}.{TABLE}
            WHERE region IS NOT NULL
              AND device_id IS NOT NULL
              AND reading_time IS NOT NULL
            PRIMARY KEY ((region), device_id, reading_time)
            WITH CLUSTERING ORDER BY (device_id ASC, reading_time DESC)
    """)

    # 5. Optional second table with counters. A table with a counter column can
    #    only contain the primary key plus counter columns — no other regular
    #    columns — and counters can't be INSERTed, only incremented. Left out
    #    by default: a counter table blocks a vnodes-to-tablets migration.
    bump = None
    if opts.counters:
        print(f"Creating counter table {KEYSPACE}.{COUNTER_TABLE}")
        session.execute(f"""
            CREATE TABLE IF NOT EXISTS {KEYSPACE}.{COUNTER_TABLE} (
                device_id text PRIMARY KEY,
                readings counter,
                errors counter
            )
        """)

    # 6. Seed readings, and count them in the counter table as we go.
    insert = session.prepare(
        f"INSERT INTO {KEYSPACE}.{TABLE} "
        f"(device_id, reading_time, region, temperature) VALUES (?, ?, ?, ?)"
    )
    if opts.counters:
        bump = session.prepare(
            f"UPDATE {KEYSPACE}.{COUNTER_TABLE} SET readings = readings + ? "
            f"WHERE device_id = ?"
        )
    now = datetime.now(timezone.utc)
    print(f"Writing {READINGS_PER_DEVICE} readings for each of {len(SAMPLE_DATA)} devices")
    for device_id, region, temperature in SAMPLE_DATA:
        for i in range(READINGS_PER_DEVICE):
            session.execute(
                insert,
                (device_id, now - timedelta(minutes=i), region, temperature + i * 0.3),
            )
        if bump is not None:
            session.execute(bump, (READINGS_PER_DEVICE, device_id))

    if opts.counters:
        # One error on the first device, so both counters have a value. A
        # counter that was never incremented reads back as null, not 0.
        session.execute(
            f"UPDATE {KEYSPACE}.{COUNTER_TABLE} SET errors = errors + 1 WHERE device_id = %s",
            (SAMPLE_DATA[0][0],),
        )

    # 7. Read the data back three ways: base table, index, and view.
    print(f"\nBase table — latest reading per device (partition key lookup):")
    for device_id, _region, _temperature in SAMPLE_DATA:
        row = session.execute(
            f"SELECT device_id, reading_time, region, temperature "
            f"FROM {KEYSPACE}.{TABLE} WHERE device_id = %s LIMIT 1",
            (device_id,),
        ).one()
        print(f"  {row.device_id:10s} {row.region:12s} {row.temperature:5.1f} {row.reading_time}")

    region = SAMPLE_DATA[0][1]
    print(f"\nSecondary index — rows in region '{region}':")
    rows = retry(lambda: list(session.execute(
        f"SELECT device_id, reading_time, temperature FROM {KEYSPACE}.{TABLE} "
        f"WHERE region = %s",
        (region,),
    )))
    for row in rows:
        print(f"  {row.device_id:10s} {row.temperature:5.1f} {row.reading_time}")

    print(f"\nMaterialized view — rows in region '{region}' from {VIEW}:")
    rows = retry(lambda: list(session.execute(
        f"SELECT device_id, reading_time, temperature FROM {KEYSPACE}.{VIEW} "
        f"WHERE region = %s",
        (region,),
    )))
    for row in rows:
        print(f"  {row.device_id:10s} {row.temperature:5.1f} {row.reading_time}")

    if opts.counters:
        print(f"\nCounter table {COUNTER_TABLE}:")
        for row in session.execute(
            f"SELECT device_id, readings, errors FROM {KEYSPACE}.{COUNTER_TABLE}"
        ):
            print(f"  {row.device_id:10s} readings={row.readings} errors={row.errors or 0}")
    else:
        print(f"\nNo counter table (pass -c to add {COUNTER_TABLE});"
              f" {KEYSPACE} can be migrated to tablets as is")

    cluster.shutdown()


if __name__ == "__main__":
    main()
