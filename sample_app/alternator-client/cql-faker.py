#!/usr/bin/env python3
"""
High-performance ScyllaDB CQL load generator.
Generates 1M+ records with userid using TIMESTAMP.
"""

import time
import random
import argparse
import logging
from ssl import SSLContext, TLSVersion, CERT_REQUIRED, PROTOCOL_TLS_CLIENT
from cassandra.cluster import Cluster, ExecutionProfile, EXEC_PROFILE_DEFAULT
from cassandra import ConsistencyLevel
from cassandra.policies import DCAwareRoundRobinPolicy, TokenAwarePolicy
from cassandra.auth import PlainTextAuthProvider

# Constants
COMPRESSION = "'sstable_compression': 'ZstdWithDictsCompressor'"
TABLETS = "true"

# Logging Setup
DATE_FORMAT = '%Y-%m-%d'
LOG_FORMAT = '%(asctime)s - %(levelname)s - %(message)s'
logging.basicConfig(level=logging.INFO, format=LOG_FORMAT)
logger = logging.getLogger(__name__)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('-s', '--hosts', default="scylla-client.scylla-dc1.svc", help='Comma-separated ScyllaDB node IPs')
    parser.add_argument('-u', '--username', default="cassandra", help='ScyllaDB username')
    parser.add_argument('-p', '--password', default="cassandra", help='ScyllaDB password')
    parser.add_argument('-d', '--drop', action="store_true", help='Drop table before inserting')
    parser.add_argument('-k', '--keyspace', default="cql_userid", help='Keyspace name')
    parser.add_argument("-i", "--user-id-start", type=int, default=1, help="First numeric user id")
    parser.add_argument("-n", "--num-inserts", type=int, default=1_000_000, help="Number of users to insert")
    parser.add_argument("-t", "--timestamp", type=int, help="Fixed timestamp value (in milliseconds)")
    parser.add_argument("--skew", type=int, default=0, help="Skew timestamp by this many milliseconds")
    parser.add_argument('--dc', default='dc1', help='Local datacenter name for ScyllaDB')
    return parser.parse_args()


def generate_data(start_id: int, num_records: int, skew: int = 0):
    NAMES = ['Alice','Bob','Charlie','David','Eva','Frank','Grace','Henry','Ivy','Jack',
             'Katie','Leo','Mia','Noah','Olivia','Paul','Quinn','Riley','Sophia','Tom',
             'Uma','Victor','Wendy','Xander','Yara','Zoe','Aaron','Bella','Carlos','Dana']
    now_ms = int(time.time() * 1000) + skew
    users = []
    for i in range(start_id, start_id + num_records):
        users.append({
            "userid": f"user{i}",
            "LastUpdated": now_ms,
            "Name": random.choice(NAMES),
            "Score": random.randint(0, 100)
        })
    return users


def _build_cluster_and_session(hosts, port, username, password, dc):
    policy = TokenAwarePolicy(DCAwareRoundRobinPolicy(local_dc=dc))
    profile = ExecutionProfile(load_balancing_policy=policy, request_timeout=30)

    # TLS setup for port 9142 (example)
    ssl_context = None
    ssl_options = None
    if str(port) == "9142":
        ssl_context = SSLContext(PROTOCOL_TLS_CLIENT)
        ssl_context.minimum_version = TLSVersion.TLSv1_2
        ssl_context.maximum_version = TLSVersion.TLSv1_3
        ssl_context.load_verify_locations('./config/ca.crt')
        ssl_context.verify_mode = CERT_REQUIRED
        ssl_context.load_cert_chain(certfile='./config/tls.crt', keyfile='./config/tls.key')
        ssl_options = {'server_hostname': hosts[0]}

    common_kwargs = dict(
        contact_points=hosts,
        port=int(port),
        execution_profiles={EXEC_PROFILE_DEFAULT: profile},
        protocol_version=4,
        connect_timeout=30,
        control_connection_timeout=5,
        schema_metadata_enabled=True,
        token_metadata_enabled=True,
        ssl_context=ssl_context,
        ssl_options=ssl_options,
    )

    if username != "mtls":
        common_kwargs['auth_provider'] = PlainTextAuthProvider(username=username, password=password)

    cluster = Cluster(**common_kwargs)
    session = cluster.connect()
    logging.info(f"Connected: hosts={hosts}, port={port}, user={username}")
    return cluster, session


def create_schema(session, keyspace, table, tablets, compression, drop=False):
    if drop:
        session.execute(f"DROP TABLE IF EXISTS {keyspace}.{table};")

    create_ks = f"""
        CREATE KEYSPACE IF NOT EXISTS {keyspace}
        WITH replication = {{'class' : 'org.apache.cassandra.locator.NetworkTopologyStrategy', 'replication_factor' : 3}}
        AND tablets = {{'enabled': {tablets} }};
    """

    create_table = f"""
        CREATE TABLE IF NOT EXISTS {keyspace}.{table} (
            userid text PRIMARY KEY,
            attrs map<text, text>
        ) WITH compression = {{ {compression} }};
    """

    session.execute(create_ks)
    session.set_keyspace(keyspace)
    session.execute(create_table)
    logging.info(f"Schema ready: {keyspace}.{table}")


def main():
    opts = parse_args()
    TABLE_NAME = "userid"
    batch_size = 1000
    HOSTS = [h.strip().split(':')[0] for h in opts.hosts.split(',') if h.strip()]
    port = int(opts.hosts.split(':')[1]) if ':' in opts.hosts else 9042

    print(f"Connecting to {HOSTS} | Inserting {opts.num_inserts:,} users from ID {opts.user_id_start}")

    cluster, session = _build_cluster_and_session(HOSTS, port, opts.username, opts.password, opts.dc)
    create_schema(session, opts.keyspace, TABLE_NAME, tablets=TABLETS, compression=COMPRESSION, drop=opts.drop)

    insert_stmt = session.prepare(f"""
        INSERT INTO {TABLE_NAME} (userid, attrs) VALUES (?, ?) USING TIMESTAMP ?
    """)

    total_inserted = 0
    start_time = time.time()
    next_id = opts.user_id_start
    skew = opts.skew

    for i in range(0, opts.num_inserts, batch_size):
        users = generate_data(next_id, batch_size, skew)
        next_id += batch_size
        timestamp = opts.timestamp + skew if opts.timestamp else int(time.time() * 1000) + skew

        for user in users:
            attrs = {
                'Name': user['Name'],
                'Score': str(user['Score']),
                'LastUpdated': str(user['LastUpdated'])
            }
            session.execute(insert_stmt, (user['userid'], attrs, timestamp))

        total_inserted += len(users)
        if total_inserted % (10 * batch_size) == 0:
            elapsed = time.time() - start_time
            rate = total_inserted / elapsed if elapsed > 0 else 0
            print(f"Progress: {total_inserted:,}/{opts.num_inserts:,} ({rate:,.0f} inserts/sec)")

    elapsed = time.time() - start_time
    rate = total_inserted / elapsed if elapsed > 0 else 0
    print(f"\n✅ Inserted {total_inserted:,} in {elapsed:.1f}s ({rate:,.0f}/sec)")


    # Verify (scan first 10)
    print("\nVerification scan:")
    query_stmt = session.prepare(f"""
        SELECT * FROM {TABLE_NAME} WHERE userid = ?
    """)
    for i in range(opts.user_id_start, opts.user_id_start + 10):
        result = session.execute(query_stmt, (f"user{i}",))
        for row in result:
            print(f"Verified: {row.userid} -> {row.attrs}")
            
    session.shutdown()
    cluster.shutdown()
    print("Cluster connection closed.")


if __name__ == "__main__":
    main()
