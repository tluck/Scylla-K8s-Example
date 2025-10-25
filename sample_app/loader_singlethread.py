#!/usr/bin/env python3

import logging
import time
import datetime
import random
import sys
import argparse
from faker import Faker
from cassandra.cluster import Cluster, ExecutionProfile, EXEC_PROFILE_DEFAULT
from cassandra.concurrent import execute_concurrent_with_args
from cassandra import ConsistencyLevel
from cassandra.auth import PlainTextAuthProvider
from cassandra.policies import DCAwareRoundRobinPolicy, TokenAwarePolicy

# Constants
COMPRESSION = "'sstable_compression': 'ZstdWithDictsCompressor'"
TABLETS = "true"
DATE_FORMAT = '%Y-%m-%d'
LOG_FORMAT = '%(asctime)s - %(levelname)s - %(message)s'

# Logging Setup
logging.basicConfig(level=logging.INFO, format=LOG_FORMAT)
logger = logging.getLogger(__name__)

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('-s', '--hosts', default="127.0.0.1", help='Comma-separated ScyllaDB node Names or IPs')
    parser.add_argument('-u', '--username', default="cassandra", help='Cassandra username')
    parser.add_argument('-p', '--password', default="cassandra", help='Cassandra password')
    parser.add_argument('-k', '--keyspace', default="mykeyspace", help='Keyspace name')
    parser.add_argument('-d', '--drop', action="store_true", help='Drop keyspace if exists')
    parser.add_argument('-t', '--table', default="myTable", help='Table name')
    parser.add_argument('-r', '--row_count', type=int, default=100000, help='Number of rows to insert')
    parser.add_argument('-b', '--batch_size', type=int, default=2000, help='Batch size for inserts')
    parser.add_argument('--cl', default="LOCAL_QUORUM", help="Consistency Level (ONE, TWO, QUORUM, etc.)")
    parser.add_argument('--dc', default='dc1', help='Local datacenter name for ScyllaDB')

    return parser.parse_args()

def str_time_prop(start, end, fmt, prop):
    """Return a time at a proportion of a range of two formatted times."""
    stime = time.mktime(time.strptime(start, fmt))
    etime = time.mktime(time.strptime(end, fmt))
    ptime = stime + prop * (etime - stime)
    return time.strftime(fmt, time.localtime(ptime))

def random_date(start, end, prop):
    return str_time_prop(start, end, DATE_FORMAT, prop)

def create_schema(session, keyspace, table, tablets, compression):
    logger.info("Creating keyspace and table (if not exists).")
    create_ks = f"""
        CREATE KEYSPACE IF NOT EXISTS {keyspace}
        WITH replication = {{'class' : 'org.apache.cassandra.locator.NetworkTopologyStrategy', 'replication_factor' : 3}}
        AND tablets = {{'enabled': {tablets} }};
    """
    create_table = f"""CREATE TABLE IF NOT EXISTS {keyspace}.{table}
        (id int PRIMARY KEY, ssn text, imei text, os text, phonenum text, balance float, pdate date, v1 text, v2 text, v3 text, v4 text, v5 text)
        WITH compression = {{ {compression} }}
        ;"""
    session.execute(create_ks)
    session.execute(create_table)

def generate_row(fake, i):
    ssn = '-'.join([str(random.randint(100,999)), str(random.randint(10,99)), str(random.randint(1000,9999))])
    imei = str(random.randint(100000000000000,999999999999999))
    os = random.choice(['Android','iOS','Windows','Samsung','Nokia'])
    phone = '-'.join([str(random.randint(200,999)), str(random.randint(100,999)), str(random.randint(1000,9999))])
    bal = round(random.uniform(10.5, 999.5), 2)
    dat = random_date("2019-01-01", "2019-04-01", random.random())
    base_string = f"IMEI:{imei}|OS:{os}|Phone:{phone}"
    v = []
    for _ in range(5):
        if len(base_string) < 200:
            sentences = []
            while sum(len(s) for s in sentences) < 200 - len(base_string):
                sentences.append(fake.sentence())
            padding = ' '.join(sentences)[:200 - len(base_string)]
            v.append(base_string + padding)
        else:
            v.append(base_string[:200])
    return (i, ssn, imei, os, phone, bal, dat, *v)

def chunked(iterable, batch_size):
    """Yield successive chunk_size-sized chunks from iterable."""
    for i in range(0, len(iterable), batch_size):
        yield iterable[i:i + batch_size]

def insert_data(session, keyspace, table, tablets, compression, consistency_level, row_count, batch_size):
    create_schema(session, keyspace, table, tablets, compression)
    cql = f"""INSERT INTO {keyspace}.{table} (id, ssn, imei, os, phonenum, balance, pdate, v1, v2, v3, v4, v5) VALUES (?,?,?,?,?,?,?, ?,?,?,?,?)"""
    prepared = session.prepare(cql)
    prepared.consistency_level = getattr(ConsistencyLevel, consistency_level)
    fake = Faker()

    logger.info(f'Inserting {row_count} rows with batch size={batch_size}')

    total_failed = 0
    for batch_num in range(1, (row_count // batch_size) + 2):
        start_idx = (batch_num - 1) * batch_size + 1
        end_idx = min(batch_num * batch_size, row_count)
        if start_idx > row_count:
            break
        batch = [generate_row(fake, i) for i in range(start_idx, end_idx + 1)]
        results = execute_concurrent_with_args(session, prepared, batch, concurrency=100)
        failed = sum(1 for (success, _) in results if not success)
        now = datetime.datetime.now()
        logger.info('Batch %d: %d rows, %d failures at %s' % (batch_num, len(batch), failed, now.strftime('%Y-%m-%d %H:%M:%S')))
        total_failed += failed

    logger.info(f'All batches done, total insertion failures: {total_failed}')

def main():
    opts = parse_args()
    hosts = [h.strip() for h in opts.hosts.split(',') if h.strip()]
    logger.info(f"Connecting to cluster: {hosts} with user {opts.username}")
    logger.info(f"Using keyspace: {opts.keyspace}, table: {opts.table}")
    logger.info(f"Local DC: {opts.dc}")
    logger.info(f"Using consistency level: {opts.cl}") 
    logger.info(f"Row count to insert: {opts.row_count}") 
    try:
        if hosts[0] == '127.0.0.1':
            profile = ExecutionProfile(load_balancing_policy=DCAwareRoundRobinPolicy(local_dc=opts.dc), request_timeout=30)
            cluster = Cluster(hosts,
                auth_provider=PlainTextAuthProvider(username=opts.username, password=opts.password),
                execution_profiles={EXEC_PROFILE_DEFAULT: profile},
                protocol_version=4,
                connect_timeout=30,
                control_connection_timeout=30)
        else:
            profile = ExecutionProfile(load_balancing_policy=TokenAwarePolicy(DCAwareRoundRobinPolicy(local_dc=opts.dc)))
            cluster = Cluster(
                contact_points=hosts,
                auth_provider=PlainTextAuthProvider(username=opts.username, password=opts.password),
                execution_profiles={EXEC_PROFILE_DEFAULT: profile},
                protocol_version=4,
                connect_timeout=30,
                control_connection_timeout=30)

        with cluster.connect() as session:
            logger.info(f"Authentication successful for user: {opts.username}, password: {'*' * len(opts.password)}")
            if opts.drop:
                logger.info(f"Dropping keyspace {opts.keyspace} if exists.")
                session.execute(f"DROP KEYSPACE IF EXISTS {opts.keyspace};")
            start_time = datetime.datetime.now()
            insert_data(
                session,
                opts.keyspace,
                opts.table,
                TABLETS,
                COMPRESSION,
                opts.cl,
                opts.row_count,
                opts.batch_size
            )
            elapsed = datetime.datetime.now() - start_time
            logger.info(f"Total insertion time: {elapsed}")
    except Exception as e:
        logger.error(f"Error in main execution: {e}")
        sys.exit(1)
    finally:
        cluster.shutdown()
        logger.info("Database connection closed.")

if __name__ == "__main__":
    main()

