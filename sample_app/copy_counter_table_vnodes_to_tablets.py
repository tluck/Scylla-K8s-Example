#!/usr/bin/env python3
"""
Demo: create a small counter table in a vnodes-based keyspace, then copy
it into a new keyspace that has tablets enabled.

Requires ScyllaDB 2026.1 or later — tablets only gained counter support
in that release. On older versions, CREATE TABLE with a counter column
in a tablets-enabled keyspace will be rejected.

On 2026.3+ prefer convert_to_tablets_kubectl.bash, which migrates a counter
table in place (verified: exact values preserved, increments keep working)
and needs no copy. This copy path is for 2026.1/2026.2 clusters, where counters
work on tablets but the in-place migration is not trusted yet — and as a
demo of counter semantics: counters cannot be INSERTed, only incremented,
so the copy is only correct into an empty destination.

Connects with username/password authentication (defaults: scylla /
scylla), so the cluster needs `enableAuth=true` in init.conf.

Install driver:  pip install scylla-driver
                  (or: pip install cassandra-driver)
"""

from cassandra.auth import PlainTextAuthProvider
from cassandra.cluster import Cluster

# in k8s use scylla-client
CONTACT_POINTS = ["scylla-client"] # ["127.0.0.1"]
USERNAME = "scylla"
PASSWORD = "scylla"
SOURCE_KS = "vnodes_ks"
DEST_KS = "tablets_ks"
TABLE = "page_views"

# Sample counter data: page_id -> number of views to increment by
SAMPLE_DATA = {
    "home": 42,
    "pricing": 17,
    "docs": 8,
    "blog": 5,
    "signup": 23,
}


def print_table(session, keyspace):
    print(f"\n{keyspace}.{TABLE}:")
    for row in session.execute(f"SELECT page_id, views FROM {keyspace}.{TABLE}"):
        print(f"  {row.page_id:10s} {row.views}")


def main():
    cluster = Cluster(
        CONTACT_POINTS,
        auth_provider=PlainTextAuthProvider(username=USERNAME, password=PASSWORD),
    )
    session = cluster.connect()

    # 1. Source keyspace: vnodes-based. Tablets are the default in recent
    #    ScyllaDB versions, so tablets must be explicitly disabled to get
    #    vnodes-based replication.
    session.execute(f"""
        CREATE KEYSPACE IF NOT EXISTS {SOURCE_KS}
        WITH replication = {{'class': 'NetworkTopologyStrategy', 'replication_factor': 3}}
        AND tablets = {{'enabled': false}}
    """)

    # 2. Counter table. A table with a counter column can only contain the
    #    primary key plus counter columns — no other regular columns.
    session.execute(f"""
        CREATE TABLE IF NOT EXISTS {SOURCE_KS}.{TABLE} (
            page_id text PRIMARY KEY,
            views counter
        )
    """)

    # 3. Seed data. Counters can't be INSERTed — only incremented via UPDATE.
    for page_id, views in SAMPLE_DATA.items():
        session.execute(
            f"UPDATE {SOURCE_KS}.{TABLE} SET views = views + %s WHERE page_id = %s",
            (views, page_id),
        )
    print_table(session, SOURCE_KS)

    # 4. Destination keyspace: tablets enabled.
    session.execute(f"""
        CREATE KEYSPACE IF NOT EXISTS {DEST_KS}
        WITH replication = {{'class': 'NetworkTopologyStrategy', 'replication_factor': 3}}
        AND tablets = {{'enabled': true}}
    """)

    # 5. Same table shape in the tablets keyspace.
    session.execute(f"""
        CREATE TABLE IF NOT EXISTS {DEST_KS}.{TABLE} (
            page_id text PRIMARY KEY,
            views counter
        )
    """)

    # 6. Copy row by row. This only produces correct values because the
    #    destination table starts empty — each partition's counter begins
    #    implicitly at 0, so a single increment lands exactly on the
    #    source value. Do NOT run this against a destination that already
    #    has data for these partition keys, since it would add to it
    #    rather than overwrite it.
    rows = session.execute(f"SELECT page_id, views FROM {SOURCE_KS}.{TABLE}")
    for row in rows:
        session.execute(
            f"UPDATE {DEST_KS}.{TABLE} SET views = views + %s WHERE page_id = %s",
            (row.views, row.page_id),
        )
    print_table(session, DEST_KS)

    cluster.shutdown()


if __name__ == "__main__":
    main()
