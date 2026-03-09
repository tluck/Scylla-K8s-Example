#!/usr/bin/env python3
"""
High-performance Alternator load generator. Fixed for DynamoDB compatibility.
Generates 1M+ records with UserID using a TIMESTAMP.
"""

import time
import random
import argparse
import logging
from ssl import SSLContext, TLSVersion, CERT_REQUIRED, PROTOCOL_TLS_CLIENT
from botocore.exceptions import ClientError
from alternator import AlternatorConfig, AlternatorClient, AlternatorResource, create_resource, close_resource
from cassandra.cluster import Cluster, ExecutionProfile, EXEC_PROFILE_DEFAULT
from cassandra.concurrent import execute_concurrent_with_args
from cassandra import ConsistencyLevel
from cassandra.policies import DCAwareRoundRobinPolicy, TokenAwarePolicy, WhiteListRoundRobinPolicy, RoundRobinPolicy, HostFilterPolicy, DefaultLoadBalancingPolicy
from cassandra.auth import PlainTextAuthProvider
from cassandra.connection import UnixSocketEndPoint
from cassandra.query import SimpleStatement, ordered_dict_factory, TraceUnavailable

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
    parser.add_argument('-d', '--delete', action="store_true", help='Delete table before inserting')
    parser.add_argument('-k', '--keyspace', default="alternator_userid", help='Keyspace name')
    parser.add_argument("-i", "--user-id-start", type=int, default=1, help="First numeric user id")
    parser.add_argument("-n", "--num-inserts", type=int, default=1_000_000, help="Number of users to insert")
    parser.add_argument("-t", "--timestamp", type=int, help="Fixed timestamp value (in milliseconds)")
    parser.add_argument("--skew", type=int, default=0, help="Skew timestamp by this many milliseconds")
    parser.add_argument('--dc', default='dc1', help='Local datacenter name for ScyllaDB')
    return parser.parse_args()

def generate_data(start_id: int, num_records: int, skew: int=0):
    NAMES = ['Alice','Bob','Charlie','David','Eva','Frank','Grace','Henry','Ivy','Jack',
         'Katie','Leo','Mia','Noah','Olivia','Paul','Quinn','Riley','Sophia','Tom',
         'Uma','Victor','Wendy','Xander','Yara','Zoe','Aaron','Bella','Carlos','Dana']
    users = []
    now_ms = int(time.time() * 1000)+skew
    end_id = start_id + num_records
    for i in range(start_id, end_id):
        user = {
            "UserID": f"user{i}",                    # ✅ Plain string
            "LastUpdated": now_ms,                   # ✅ Plain integer
            "Name": random.choice(NAMES),            # ✅ Plain string
            "Score": random.randint(0, 100)          # ✅ Plain integer
        }
        users.append(user)
    return users

def encode_alternator_blob(value):
    if isinstance(value, str):
        return b'\x00' + value.encode('utf-8')
    elif isinstance(value, int):
        # 1. Create correct LE bytes
        num_bytes = value.to_bytes(7, byteorder='little')
        # 2. PRE-REVERSE to match driver's delivery order
        driver_expected_bytes = num_bytes[::-1]
        # 3. Add header
        return b'\x03\x00\x00\x00' + driver_expected_bytes
    return None

def _build_cluster_and_session(hosts, port, username, password, dc):

    policy = TokenAwarePolicy(DCAwareRoundRobinPolicy(local_dc=dc))
    profile = ExecutionProfile(
        load_balancing_policy=policy,
        request_timeout=30,
    )
    shard_aware_opts = {"disable": False}  # shard-aware for cluster
    pv = 4
    md = True

    # TLS setup
    if port == "9142":
        ssl_context = SSLContext(PROTOCOL_TLS_CLIENT)
        ssl_context.minimum_version = TLSVersion.TLSv1_2
        ssl_context.maximum_version = TLSVersion.TLSv1_3
        ssl_context.load_verify_locations('./config/ca.crt')
        ssl_context.verify_mode = CERT_REQUIRED
        ssl_context.load_cert_chain(certfile='./config/tls.crt', keyfile='./config/tls.key')
        ssl_options = {'server_hostname': hosts[0]}  # Add SNI
    else:
        ssl_context = None
        ssl_options = None

    # Common cluster params
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

    logging.info(f"Connecting: hosts={hosts}, port={port}, auth={username}")
    # session = cluster.connect()
    # logging.info("Session created successfully")
    # return cluster, session
    return cluster

def main():
    args = parse_args()
    TABLE_NAME = "userid"
    NUMREADS = 10
    NUM_INSERTS = args.num_inserts
    USER_ID_START = args.user_id_start
    batch_size = 1000
    HOSTS = [h.strip() for h in args.hosts.split(',') if h.strip()]

    print(f"Connecting to {HOSTS} | Inserting {NUM_INSERTS:,} users from ID {USER_ID_START}")

    config = AlternatorConfig(
        seed_hosts=HOSTS, port=8000, scheme='http', max_pool_connections=10
    )

    # Table management
    with AlternatorClient(config) as client:
        if args.delete:
            try:
                client.delete_table(TableName=TABLE_NAME)
                print(f"✅ Deleted {TABLE_NAME}")
            except ClientError as e:
                if e.response['Error']['Code'] != 'ResourceNotFoundException':
                    raise
                print("No table to delete")

        print(f"Existing tables: {client.list_tables().get('TableNames', [])}")
        
        # ✅ composite key schema
        mode="unsafe" #"only_rmw_uses_lwt"
        print(f"Creating {TABLE_NAME} with {'RANGE' if args.range else 'HASH-only'} key and write isolation mode: {mode}")
        try:
            client.create_table(
                TableName=TABLE_NAME,
                KeySchema=[{'AttributeName': 'UserID', 'KeyType': 'HASH'}],
                AttributeDefinitions=[{'AttributeName': 'UserID', 'AttributeType': 'S'}],
                BillingMode='PAY_PER_REQUEST',
                Tags=[{"Key": "system:write_isolation", "Value": f"{mode}"}],
            )
            print(f"✅ Created {TABLE_NAME} (UserID only)")
        except ClientError as e:
            if e.response['Error']['Code'] != 'ResourceInUseException':
                raise
            print(f"Using existing {TABLE_NAME}")

    try:
        print(f"Inserting {NUM_INSERTS:,} items in {batch_size}-item batches...")

        # Connect to your Scylla cluster
        # cluster = Cluster(
        #     contact_points=[args.hosts],
        #     port=9042,
        #     auth_provider=PlainTextAuthProvider(username=args.username, password=args.password)
        # )
        cluster = _build_cluster_and_session(HOSTS, 9042, args.username, args.password, args.dc)
        session = cluster.connect(args.keyspace)
        insert_stmt = session.prepare("""
            INSERT INTO userid ("UserID", ":attrs") 
            VALUES (?, ?) USING TIMESTAMP ?
        """)

        start_time = time.time()
        total_inserted = 0
        start = USER_ID_START
        skew = args.skew
        
        for i in range(0, NUM_INSERTS, batch_size):
            # How many we *intend* to insert in this batch
            remaining = NUM_INSERTS - i
            this_batch_size = min(batch_size, remaining)
            users = generate_data(start, this_batch_size,skew=skew)
            start += this_batch_size

            if args.timestamp:
                now_ms = args.timestamp+skew
            else:
                now_ms = int(time.time() * 1000)+skew

            for user in users:
                attrs = {
                    'Name': encode_alternator_blob(user['Name']),
                    'Score': encode_alternator_blob(user['Score']),
                    'LastUpdated': encode_alternator_blob(user['LastUpdated']),
                }
                session.execute(insert_stmt, (user['UserID'], dict(attrs), now_ms))

            total_inserted += len(users)
            if total_inserted % (10 * batch_size) == 0:
                elapsed = time.time() - start_time
                rate = total_inserted / elapsed if elapsed > 0 else 0
                print(
                    f"Progress: {total_inserted:,}/{NUM_INSERTS:,} "
                    f"({rate:,.0f} inserts/sec)"
                )

        elapsed = time.time() - start_time
        rate = total_inserted / elapsed if elapsed > 0 else 0
        print(f"\n✅ Inserted {total_inserted:,} in {elapsed:.1f}s ({rate:,.0f}/sec)")
        
    finally:
        session.shutdown()
        cluster.shutdown()

    # Verify (scan first 10)
    print("\nVerification scan:")
    resource = create_resource(config)
    try:
        table = resource.Table(TABLE_NAME)
        resp = table.scan(Limit=NUMREADS)
        for item in resp['Items']:
            print(f"  {item['UserID']} | {item['Name']} | Score:{item['Score']} | {item['LastUpdated']}ms")
    finally:
        close_resource(resource)

if __name__ == "__main__":
    main()
