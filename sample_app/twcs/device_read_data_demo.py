#!/usr/bin/env python3
"""
device_read_data_demo.py
========================
Creates a scaled-down version of shifteos2.device_read_data using
x-MINUTE TWCS windows (instead of 18 days) so you can observe window
behaviour, compaction, and SSTable expiry on a laptop or test cluster
in minutes rather than weeks.

Scale mapping
-------------
  Production          This demo
  18-day window   ->  x-minute window
  450-day TTL     ->  2-hour TTL  (= 16 x x-min windows worth of data)
  ~10k writes/s   ->  configurable batch writes
  gc_grace 1hr    ->  60 seconds  (safe for no-delete workload)

Requirements
------------
    pip install cassandra-driver

Usage
-----
    # 1. Start a local ScyllaDB (Docker example):
    #    docker run -d --name scylla -p 9042:9042 scylladb/scylla

    # 2. Run with defaults (creates keyspace + table, seeds data):
    python device_read_data_demo.py

    # 3. Connect to a specific cluster with auth / DC / consistency:
    python device_read_data_demo.py -s node1,node2 -u user -p pass --dc dc1 --cl QUORUM

    # 4. Local port-forward (single host, no discovery):
    python device_read_data_demo.py -s 127.0.0.1:9042 -l

    # 5. TLS / mTLS (expects ./config/{ca,tls}.crt + tls.key, forces port 9142):
    python device_read_data_demo.py -s node1 -e -u user -p pass   # TLS + user/pass
    python device_read_data_demo.py -s node1 -m                   # mTLS

    # 6. Seed only (table already exists):
    python device_read_data_demo.py --seed-only

    # 7. Watch SSTable windows after seeding:
    python device_read_data_demo.py --status

    # 8. Print the TWCS-safe compaction guide:
    python device_read_data_demo.py --compact-guide
"""

import argparse
import datetime
import logging
import os
import random
import subprocess
import sys
import time
import uuid
from typing import Optional

from cassandra.cluster import Cluster, ExecutionProfile, EXEC_PROFILE_DEFAULT
from cassandra.concurrent import execute_concurrent_with_args
from cassandra import ConsistencyLevel
from cassandra.policies import DCAwareRoundRobinPolicy, TokenAwarePolicy, WhiteListRoundRobinPolicy, RoundRobinPolicy, HostFilterPolicy, DefaultLoadBalancingPolicy
from cassandra.auth import PlainTextAuthProvider
from cassandra.connection import UnixSocketEndPoint
from cassandra.query import SimpleStatement, ordered_dict_factory, TraceUnavailable
from ssl import SSLContext, TLSVersion, CERT_REQUIRED, PROTOCOL_TLS_CLIENT

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

SCYLLA_HOSTS   = ["scylla-client-headless"]
SCYLLA_PORT    = 9042
KEYSPACE       = "demo"          # use 'shifteos2' to match production name
TABLE          = "device_read_data"

# Scaled-down TTL and window to observe TWCS behaviour quickly
DEMO_TTL_SECONDS    = 43200     # 1 hours  (prod = 38_880_000 / 450 days)
DEMO_WINDOW_MINUTES = 10        # 5 min    (prod = 18 days)
DEMO_GC_GRACE       = 60        # 60 s     (prod = 3600; safe, no deletes)

# Seed parameters
NUM_DEVICES        = 10          # number of distinct fkdrwid UUIDs
READINGS_PER_FLUSH = 500         # rows per INSERT batch
NUM_FLUSHES        = 100000      # how many windows to seed
WRITES_PER_SECOND  = 50          # rate limiter

# ---------------------------------------------------------------------------
# DDL — built at runtime so --keyspace / --table overrides take effect
# ---------------------------------------------------------------------------
def create_keyspace_cql(keyspace):
    return f"""
CREATE KEYSPACE IF NOT EXISTS {keyspace}
WITH replication = {{'class' : 'NetworkTopologyStrategy', 'replication_factor': 3}};
"""


def drop_table_cql(keyspace, table):
    return f"DROP TABLE IF EXISTS {keyspace}.{table};"


def create_table_cql(keyspace, table):
    return f"""
CREATE TABLE IF NOT EXISTS {keyspace}.{table} (
    fkdrwid  uuid,
    ddate    text,
    odate    timestamp,
    bval     text,
    val      text,
    PRIMARY KEY ((fkdrwid, ddate), odate)
) WITH CLUSTERING ORDER BY (odate DESC)
    AND bloom_filter_fp_chance = 0.1
    AND caching = {{'keys': 'ALL', 'rows_per_partition': '100'}}
    AND comment = 'Demo: x-min windows mirror prod 18-day TWCS behaviour'
    AND compaction = {{
        'class'                 : 'TimeWindowCompactionStrategy',
        'compaction_window_size': '{DEMO_WINDOW_MINUTES}',
        'compaction_window_unit': 'MINUTES',
        'min_threshold'         : '4',
        'max_threshold'         : '32'
    }}
    AND compression = {{'sstable_compression': 'LZ4Compressor'}}
    AND crc_check_chance = 1
    AND default_time_to_live = {DEMO_TTL_SECONDS}
    AND gc_grace_seconds     = {DEMO_GC_GRACE}
    AND max_index_interval   = 2048
    AND memtable_flush_period_in_ms = 0
    AND min_index_interval   = 128
    AND speculative_retry    = '99.0PERCENTILE'
    AND tombstone_gc         = {{'mode': 'timeout', 'propagation_delay_in_seconds': '60'}};
"""


def insert_cql(keyspace, table):
    return f"""
INSERT INTO {keyspace}.{table} (fkdrwid, ddate, odate, bval, val)
VALUES (?, ?, ?, ?, ?)
USING TTL {DEMO_TTL_SECONDS};
"""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def build_session(hosts, port, username, password, dc, local_only, consistency_level):
    """
    Build a cluster + session. Mirrors loader.py's connection logic:
      * local-only mode (HostFilterPolicy, no discovery) for port-forward use
      * TokenAware/DCAware for real clusters
      * TLS on port 9142 via ./config/{ca,tls}.crt + tls.key
      * mTLS when username == 'mtls' (no PlainTextAuthProvider)
    """
    is_local_only = (hosts and hosts[0] in ('127.0.0.1', 'localhost')) or local_only

    cl = getattr(ConsistencyLevel, consistency_level)

    if is_local_only:
        logging.info("Local-only mode: HostFilterPolicy + no discovery")
        policy = HostFilterPolicy(
            child_policy=RoundRobinPolicy(),
            predicate=lambda host: host.address == hosts[0]
        )
        profile = ExecutionProfile(
            load_balancing_policy=policy,
            request_timeout=30,
            consistency_level=cl,
        )
        shard_aware_opts = {"disable": True}
        pv = 3
        md = False
    else:
        logging.info(f"Using TokenAwarePolicy with local_dc: {dc}")
        policy = TokenAwarePolicy(DCAwareRoundRobinPolicy(local_dc=dc))
        profile = ExecutionProfile(
            load_balancing_policy=policy,
            request_timeout=30,
            consistency_level=cl,
        )
        shard_aware_opts = {"disable": False}  # shard-aware for cluster
        pv = 4
        md = True

    # TLS setup (port 9142 implies TLS/mTLS)
    if str(port) == "9142":
        ssl_context = SSLContext(PROTOCOL_TLS_CLIENT)
        ssl_context.minimum_version = TLSVersion.TLSv1_2
        ssl_context.maximum_version = TLSVersion.TLSv1_3
        ssl_context.load_verify_locations('./config/ca.crt')
        ssl_context.verify_mode = CERT_REQUIRED
        ssl_context.load_cert_chain(certfile='./config/tls.crt', keyfile='./config/tls.key')
        ssl_options = {'server_hostname': hosts[0]}  # SNI
    else:
        ssl_context = None
        ssl_options = None

    common_kwargs = {
        'contact_points': hosts,
        'port': int(port),
        'ssl_context': ssl_context,
        'ssl_options': ssl_options,
        'execution_profiles': {EXEC_PROFILE_DEFAULT: profile},
        'shard_aware_options': shard_aware_opts,
        'protocol_version': pv,
        'connect_timeout': 30,
        'control_connection_timeout': 1,
        'schema_metadata_enabled': md,
        'token_metadata_enabled': md,
    }

    if username == "mtls":
        cluster = Cluster(**common_kwargs)
    else:
        common_kwargs['auth_provider'] = PlainTextAuthProvider(username=username, password=password)
        cluster = Cluster(**common_kwargs)

    logging.info(f"Connecting: hosts={hosts}, port={port}, auth={username}, local_only={is_local_only}")
    session = cluster.connect()
    logging.info("Session created successfully")
    return session


def window_bucket(ts: datetime.datetime, window_minutes: int) -> datetime.datetime:
    """Floor a timestamp to its TWCS window boundary."""
    epoch = datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)
    window_secs = window_minutes * 60
    ts_utc = ts.astimezone(datetime.timezone.utc)
    elapsed = int((ts_utc - epoch).total_seconds())
    floored = (elapsed // window_secs) * window_secs
    return epoch + datetime.timedelta(seconds=floored)


def ddate_key(ts: datetime.datetime) -> str:
    """
    Partition key helper — mirrors production convention.
    Production uses ddate = 'YYYY-MM-DD'.
    In demo mode we use 'YYYY-MM-DD-HH-MM' so each x-min window
    gets its own partition bucket (avoids giant partitions in the test).
    Adjust to plain 'YYYY-MM-DD' if you want to match production exactly.
    """
    return ts.strftime("%Y-%m-%d-%H-%M")


def random_val() -> str:
    return f"{random.uniform(-40.0, 120.0):.4f}"


def random_bval() -> Optional[str]:
    return str(random.randint(0, 1)) if random.random() < 0.3 else None


# ---------------------------------------------------------------------------
# Schema setup
# ---------------------------------------------------------------------------
def setup_schema(session):
    print(f"[schema] Creating keyspace '{KEYSPACE}' if needed...")
    session.execute(create_keyspace_cql(KEYSPACE))
    session.set_keyspace(KEYSPACE)
    print(f"[schema] Creating table '{TABLE}' if needed...")
    session.execute(drop_table_cql(KEYSPACE, TABLE))
    session.execute(create_table_cql(KEYSPACE, TABLE))
    print("[schema] Done.")


# ---------------------------------------------------------------------------
# Data seeding
# ---------------------------------------------------------------------------
def seed_data(session):
    """
    Writes NUM_FLUSHES x READINGS_PER_FLUSH rows spread across
    NUM_FLUSHES consecutive x-minute windows so every window bucket
    gets data, simulating production ingest.
    """
    session.set_keyspace(KEYSPACE)
    prepared = session.prepare(insert_cql(KEYSPACE, TABLE))

    # Pre-generate stable device UUIDs
    devices = [uuid.uuid4() for _ in range(NUM_DEVICES)]

    now = datetime.datetime.now(datetime.timezone.utc)
    # Seed data starting from (NUM_FLUSHES * window) minutes ago so some
    # windows are already "closed" and eligible for TWCS compaction.
    start_ts = now - datetime.timedelta(minutes=DEMO_WINDOW_MINUTES * NUM_FLUSHES)

    print(
        f"\n[seed] Writing {NUM_FLUSHES} windows × {READINGS_PER_FLUSH} rows "
        f"across {NUM_DEVICES} devices..."
    )
    print(f"       Start : {start_ts.isoformat()}")
    print(f"       End   : {now.isoformat()}")
    print(f"       Window: {DEMO_WINDOW_MINUTES} min  TTL: {DEMO_TTL_SECONDS}s\n")

    total = 0
    interval = 1.0 / WRITES_PER_SECOND

    for flush_idx in range(NUM_FLUSHES):
        window_start = start_ts + datetime.timedelta(
            minutes=DEMO_WINDOW_MINUTES * flush_idx
        )
        bucket = window_bucket(window_start, DEMO_WINDOW_MINUTES)
        print(
            f"  Window {flush_idx + 1}/{NUM_FLUSHES}  "
            f"bucket={bucket.strftime('%Y-%m-%d %H:%M')} UTC"
        )

        for i in range(READINGS_PER_FLUSH):
            # Spread readings evenly within the window
            offset_secs = (DEMO_WINDOW_MINUTES * 60 / READINGS_PER_FLUSH) * i
            ts = window_start + datetime.timedelta(seconds=offset_secs)
            device = random.choice(devices)
            dd = ddate_key(ts)

            session.execute(
                prepared,
                (device, dd, ts, random_bval(), random_val()),
            )
            total += 1
            time.sleep(interval)

        print(f"    -> {READINGS_PER_FLUSH} rows written  (total {total})")

    print(f"\n[seed] Complete — {total} rows written across {NUM_FLUSHES} windows.")
    print(
        f"       Wait ~{DEMO_WINDOW_MINUTES} min for the current window to close,\n"
        f"       then run `--status` to see TWCS compact closed windows."
    )


# ---------------------------------------------------------------------------
# Status / diagnostics
# ---------------------------------------------------------------------------
def show_status(session):
    session.set_keyspace(KEYSPACE)

    print(f"\n[status] Row counts by ddate bucket in {KEYSPACE}.{TABLE}:")
    print("  (each ddate = one x-min partition in demo mode)\n")

    rows = session.execute(
        f"SELECT ddate, COUNT(*) as cnt FROM {KEYSPACE}.{TABLE} "
        f"ALLOW FILTERING"
    )
    buckets = sorted(rows, key=lambda r: r.ddate)
    for r in buckets:
        bar = "█" * min(40, r.cnt // 10)
        print(f"  {r.ddate}  {r.cnt:6d} rows  {bar}")

    print(f"\n[status] For SSTable-level visibility run on the ScyllaDB node:\n"
        f"   nodetool tablestats {KEYSPACE}.{TABLE}\n"
        f"   nodetool compactionstats\n"
    )


# ---------------------------------------------------------------------------
# TWCS-safe window compaction
# ---------------------------------------------------------------------------
def print_compact_guide():
    """
    Explains how to compact a single TWCS window without merging across
    window boundaries — the only safe manual compaction approach for TWCS.
    """
    print("""
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  How to compact a TWCS table without destroying window boundaries
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

The key insight
───────────────
nodetool compact (major compaction) merges ALL SSTables into ONE,
destroying every window boundary. For a 9 TB TWCS table this means:

  • Disk spikes to ~18 TB during compaction (2x headroom needed)
  • The single output SSTable won't expire until the NEWEST row's
    TTL elapses — i.e. ~450 days from when you ran compact, not
    from when the data was originally written
  • You lose all incremental SSTable-drop benefits of TWCS

There is NO nodetool command that compacts one TWCS window in isolation.

What you CAN do safely
──────────────────────

Option 1 — Do nothing (recommended for append-only + TTL tables)
  TWCS drops entire SSTables automatically once every row inside
  has expired. For a no-delete, TTL-only table this is free and
  requires zero manual intervention.

  Monitor progress:
    nodetool tablestats shifteos2.device_read_data | grep SSTable
    nodetool compactionstats

Option 2 — Flush + let TWCS close the current window
  If you have data stuck in memtable that hasn't been flushed into
  a sealed window SSTable yet:

    nodetool flush shifteos2 device_read_data

  TWCS will then automatically compact the newly flushed SSTables
  within their window once min_threshold (4) is reached.

Option 3 — scrub (fixes corrupt SSTables, does NOT merge windows)
    nodetool scrub shifteos2 device_read_data

Option 4 — upgradesstables (rewrites format, preserves windows)
  Use only when upgrading ScyllaDB versions or changing compression:
    nodetool upgradesstables shifteos2 device_read_data

Option 5 — If tombstone_gc was disabled (your production situation)
  After re-enabling tombstone_gc:
    1. Wait gc_grace_seconds (3600 s) for the setting to propagate
    2. Run: nodetool flush shifteos2 device_read_data
    3. TWCS background compaction will then pick up each closed window
       and purge expired tombstones within that window's SSTable
    4. Fully expired windows drop automatically — no compact needed

For the 9 TB device_read_data with tombstone_gc re-enabled
──────────────────────────────────────────────────────────
  DO NOT run: nodetool compact shifteos2 device_read_data
    -> Would spike disk to ~18 TB, lock all data for 450+ days

  DO run:
    nodetool flush shifteos2 device_read_data
    # then monitor — TWCS handles the rest automatically
    watch -n 30 'nodetool compactionstats && nodetool tablestats \\
      shifteos2.device_read_data | grep -E "SSTable|Space"'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
""")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def parse_args():
    parser = argparse.ArgumentParser(
        description="Demo: device_read_data with x-min TWCS windows"
    )
    # --- Connection options (mirrors loader.py) ---
    parser.add_argument(
        "-s", "--hosts", default=f"{SCYLLA_HOSTS[0]}:{SCYLLA_PORT}",
        help="Comma-separated ScyllaDB node Names or IPs (optionally host:port)"
    )
    parser.add_argument(
        "-l", "--local_only", action="store_true", help="Use local-only mode"
    )
    parser.add_argument(
        "-m", "--mtls", action="store_true",
        help="Use mTLS for authentication (overrides username/password)"
    )
    parser.add_argument(
        "-e", "--tls", action="store_true",
        help="Use TLS for connection with username/password"
    )
    parser.add_argument(
        "-u", "--username", default="cassandra", help="ScyllaDB username"
    )
    parser.add_argument(
        "-p", "--password", default="cassandra", help="ScyllaDB password"
    )
    parser.add_argument(
        "-k", "--keyspace", default=KEYSPACE, help=f"Keyspace name (default: {KEYSPACE})"
    )
    parser.add_argument(
        "-t", "--table", default=TABLE, help=f"Table name (default: {TABLE})"
    )
    parser.add_argument(
        "--cl", default="LOCAL_QUORUM", help="Consistency Level (ONE, TWO, QUORUM, etc.)"
    )
    parser.add_argument(
        "--dc", default="dc1", help="Local datacenter name for ScyllaDB"
    )
    # --- Demo-specific options ---
    parser.add_argument(
        "--seed-only", action="store_true", help="Skip schema creation, just insert data"
    )
    parser.add_argument(
        "--status", action="store_true", help="Show row counts per window bucket"
    )
    parser.add_argument(
        "--compact-guide", action="store_true",
        help="Print TWCS-safe compaction guide for production 9 TB table"
    )
    parser.add_argument(
        "--devices", type=int, default=NUM_DEVICES,
        help=f"Number of device UUIDs to simulate (default: {NUM_DEVICES})"
    )
    parser.add_argument(
        "--windows", type=int, default=NUM_FLUSHES,
        help=f"Number of x-min windows to seed (default: {NUM_FLUSHES})"
    )
    parser.add_argument(
        "--rows-per-window", type=int, default=READINGS_PER_FLUSH,
        help=f"Rows per window (default: {READINGS_PER_FLUSH})"
    )
    return parser.parse_args()


def main():
    global NUM_DEVICES, NUM_FLUSHES, READINGS_PER_FLUSH, SCYLLA_HOSTS, SCYLLA_PORT, KEYSPACE, TABLE
    args = parse_args()

    if args.compact_guide:
        print_compact_guide()
        return

    # Override globals from CLI args
    NUM_DEVICES        = args.devices
    NUM_FLUSHES        = args.windows
    READINGS_PER_FLUSH = args.rows_per_window
    KEYSPACE           = args.keyspace
    TABLE              = args.table

    # Parse comma-separated hosts and optional host:port (mirrors loader.py)
    hosts = [h.strip().split(':')[0] for h in args.hosts.split(',') if h.strip()]
    parts = args.hosts.strip().split(':')
    port = parts[1] if len(parts) > 1 else str(SCYLLA_PORT)

    # Pre-flight check for required TLS configuration files
    username = args.username
    if args.mtls or args.tls:
        config_dir = './config'
        required_files = [
            os.path.join(config_dir, 'ca.crt'),
            os.path.join(config_dir, 'tls.crt'),
            os.path.join(config_dir, 'tls.key'),
        ]
        if not os.path.lexists(config_dir) or not os.path.isdir(config_dir):
            logging.error(f"TLS config directory not found or is not a directory: '{config_dir}'")
            logging.error("Please ensure './config' exists and is a directory or a symbolic link to a directory.")
            sys.exit(1)
        for f_path in required_files:
            if not os.path.isfile(f_path):
                logging.error(f"Required TLS file not found: {f_path}")
                sys.exit(1)
        if args.mtls:
            logging.info(f"Connecting to cluster: {hosts} with mTLS authentication")
            username = "mtls"  # Special username to trigger mTLS in build_session
        else:
            logging.info(f"Connecting to cluster: {hosts} with username/password authentication with TLS: {username}")
        port = "9142"  # TLS/mTLS port
    else:
        logging.info(f"Connecting to cluster: {hosts}:{port} with username/password authentication: {username}")

    SCYLLA_HOSTS = hosts
    SCYLLA_PORT  = int(port)

    print(f"Connecting to ScyllaDB at {hosts}:{port}...")
    session = build_session(hosts, port, username, args.password, args.dc, args.local_only, args.cl)
    print("Connected.\n")

    if args.status:
        show_status(session)
        return

    if not args.seed_only:
        setup_schema(session)

    seed_data(session)
    show_status(session)

    print("\nNext steps:")
    print(f"  • Run `python {__file__} --compact-guide` for TWCS compaction guidance")
    print(f"  • Run `python {__file__} --status` again after {DEMO_WINDOW_MINUTES} min to see window close")
    print(f"  • Wait {DEMO_TTL_SECONDS//60} min for TTL expiry, then watch SSTables drop automatically\n")


if __name__ == "__main__":
    main()
