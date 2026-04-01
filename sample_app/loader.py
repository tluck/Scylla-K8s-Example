#!/usr/bin/env python3
import logging
import ssl
import time
import datetime
import random
import sys
import argparse
import os
from math import ceil
from faker import Faker
from multiprocessing import get_context, cpu_count
from cassandra.cluster import Cluster, ExecutionProfile, EXEC_PROFILE_DEFAULT
from cassandra.concurrent import execute_concurrent_with_args
from cassandra import ConsistencyLevel
from cassandra.policies import DCAwareRoundRobinPolicy, TokenAwarePolicy, WhiteListRoundRobinPolicy, RoundRobinPolicy, HostFilterPolicy, DefaultLoadBalancingPolicy
from cassandra.auth import PlainTextAuthProvider
from cassandra.connection import UnixSocketEndPoint
from cassandra.query import SimpleStatement, ordered_dict_factory, TraceUnavailable
from ssl import SSLContext, TLSVersion, CERT_REQUIRED, PROTOCOL_TLS_CLIENT

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
    parser.add_argument('-s', '--hosts', default="127.0.0.1:9042", help='Comma-separated ScyllaDB node Names or IPs')
    parser.add_argument('-l', '--local_only', action="store_true", help='Use local-only mode')
    parser.add_argument('-m', '--mtls', action="store_true", help='Use mtls for authentication (overrides username/password)')
    parser.add_argument('-e', '--tls', action="store_true", help='Use tls for connection with username/password)')
    parser.add_argument('-u', '--username', default="cassandra", help='ScyllaDB username')
    parser.add_argument('-p', '--password', default="cassandra", help='ScyllaDB password')
    parser.add_argument('-k', '--keyspace', default="myKeyspace", help='Keyspace name')
    parser.add_argument('-t', '--table', default="myTable", help='Table name')
    parser.add_argument('-d', '--drop', action="store_true", help='Drop table if exists')
    parser.add_argument('-r', '--row_count', type=int, default=100000, help='Number of rows to insert')
    parser.add_argument('-b', '--batch_size', type=int, default=2000, help='Batch size for inserts')
    parser.add_argument('--cl', default="LOCAL_QUORUM", help="Consistency Level (ONE, TWO, QUORUM, etc.)")
    parser.add_argument('--dc', default='dc1', help='Local datacenter name for ScyllaDB')
    parser.add_argument('-w', '--workers', type=int, default=0, help='Number of worker processes (0 = cpu_count())')
    parser.add_argument('-o', '--offset', type=int, default=0, help='Offset for ID generation to avoid collisions across runs')
    parser.add_argument( '--buckets', type=int, default=256, help='Number of partition buckets (id %% buckets). More buckets = less hotspot risk per partition.',
    )
    return parser.parse_args()

def str_time_prop(start, end, fmt, prop):
    stime = time.mktime(time.strptime(start, fmt))
    etime = time.mktime(time.strptime(end, fmt))
    ptime = stime + prop * (etime - stime)
    return time.strftime(fmt, time.localtime(ptime))

def random_date(start, end, prop):
    return str_time_prop(start, end, DATE_FORMAT, prop)

def create_schema(session, keyspace, table, tablets, compression):
    create_ks = f"""
        CREATE KEYSPACE IF NOT EXISTS {keyspace}
        WITH replication = {{'class' : 'NetworkTopologyStrategy', 'replication_factor' : 3}}
        AND tablets = {{'enabled': {tablets} }};
    """
    # Single table: bucket spreads partitions; id is unique clustering key
    create_table = f"""CREATE TABLE IF NOT EXISTS {keyspace}.{table}
        (bucket int, id int, ssn text, imei text, os text, phonenum text, balance float, pdate date, message text, PRIMARY KEY (bucket, id))
        WITH compression = {{ {compression} }}
        ;"""
    session.execute(create_ks)
    session.execute(create_table)

def generate_row(fake, row_id, num_buckets):
    bucket = row_id % num_buckets
    if bucket < 0:
        bucket += num_buckets

    ssn = '-'.join([str(random.randint(100,999)), str(random.randint(10,99)), str(random.randint(1000,9999))])
    imei = str(random.randint(100000000000000,999999999999999))
    os_name = random.choice(['Android','iOS','Windows','Samsung','Nokia'])
    phone = '-'.join([str(random.randint(200,999)), str(random.randint(100,999)), str(random.randint(1000,9999))])
    bal = round(random.uniform(10.5, 999.5), 2)
    dat = random_date("2019-01-01", "2019-04-01", random.random())
    base_string = f"IMEI:{imei}|OS:{os_name}|Phone:{phone}"
    message = []
    for _ in range(1):
        if len(base_string) < 200:
            sentences = []
            while sum(len(s) for s in sentences) < 200 - len(base_string):
                sentences.append(fake.sentence())
            padding = ' '.join(sentences)[:200 - len(base_string)]
            message.append(base_string + padding)
        else:
            message.append(base_string[:200])
    
    return (bucket, row_id, ssn, imei, os_name, phone, bal, dat, *message)


def chunked_ids(start_id, end_id, batch_size):
    i = start_id
    while i <= end_id:
        j = min(i + batch_size - 1, end_id)
        yield (i, j)
        i = j + 1

def _init_worker_rng(worker_index):
    # Unique seeds per worker for stdlib random and Faker to avoid duplicates
    seed = int.from_bytes(os.urandom(8), 'little') ^ int(time.time_ns()) ^ worker_index
    random.seed(seed)
    Faker.seed(seed)

def _build_cluster_and_session(hosts, port, username, password, dc, local_only):
    is_local_only = (hosts and hosts[0] in ('127.0.0.1', 'localhost')) or local_only

    if is_local_only:
        logging.info("Local-only mode: HostFilterPolicy + no discovery")
        policy = HostFilterPolicy(
            child_policy=RoundRobinPolicy(),
            predicate=lambda host: host.address == hosts[0]
        )
        profile = ExecutionProfile(
            load_balancing_policy=policy,
            request_timeout=30,
            consistency_level=ConsistencyLevel.ONE
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

    logging.info(f"Connecting: hosts={hosts}, port={port}, auth={username}, local_only={is_local_only}")
    session = cluster.connect()
    logging.info("Session created successfully")
    return cluster, session


def _worker_insert_range(
    worker_index,
    hosts,
    port,
    username,
    password,
    keyspace,
    table,
    dc,
    local_only,
    consistency_level,
    start_id,
    end_id,
    batch_size,
    offset,
    num_buckets,
):
    # Per-process RNG
    _init_worker_rng(worker_index)
    fake = Faker()
    cluster, session = _build_cluster_and_session(hosts, port, username, password, dc, local_only)
    try:
        # Prepare statement per worker
        cql = f"""INSERT INTO {keyspace}.{table} (bucket, id, ssn, imei, os, phonenum, balance, pdate, message) VALUES (?,?,?,?,?,?,?,?, ?)"""
        prepared = session.prepare(cql)
        prepared.consistency_level = getattr(ConsistencyLevel, consistency_level)

        total = 0
        total_failed = 0
        for (s_id, e_id) in chunked_ids(start_id, end_id, batch_size):
            batch = [generate_row(fake, i + offset, num_buckets) for i in range(s_id, e_id + 1)]
            results = execute_concurrent_with_args(session, prepared, batch, concurrency=100)

            failed = sum(1 for (success, _) in results if not success)
            total += len(batch)
            total_failed += failed
            if worker_index == 0:
                # Reduce log chatter by letting only worker 0 log per-batch
                logger.info(f'Worker {worker_index} inserted {len(batch)} rows (failed={failed}), id [{s_id}-{e_id}]')
        return (worker_index, total, total_failed)
    finally:
        try:
            session.shutdown()
        except Exception:
            pass
        try:
            cluster.shutdown()
        except Exception:
            pass

def insert_data_parallel(
    hosts,
    port,
    username,
    password,
    keyspace,
    table,
    tablets,
    compression,
    dc,
    local_only,
    consistency_level,
    row_count,
    batch_size,
    workers,
    offset,
    num_buckets,
):
    # One control session in parent to create schema (safe and simple)
    ctrl_cluster, ctrl_session = _build_cluster_and_session(hosts, port, username, password, dc, local_only)
    try:
        create_schema(ctrl_session, keyspace, table, tablets, compression)
    finally:
        try:
            ctrl_session.shutdown()
        except Exception:
            pass
        try:
            ctrl_cluster.shutdown()
        except Exception:
            pass

    # Partition id space evenly among workers
    procs = workers if workers > 0 else cpu_count()
    procs = max(1, procs)
    span = ceil(row_count / procs)

    logger.info(
        f"Starting {procs} workers, total rows={row_count}, buckets={num_buckets}, "
        f"per-worker target≈{span}, batch_size={batch_size}"
    )

    ctx = get_context("spawn")
    with ctx.Pool(processes=procs) as pool:
        jobs = []
        for w in range(procs):
            start_id = w * span + 1
            end_id = min((w + 1) * span, row_count) 
            if start_id > end_id:
                continue
            jobs.append(pool.apply_async(
                _worker_insert_range,
                kwds=dict(
                    worker_index=w,
                    hosts=hosts,
                    port=port,
                    username=username,
                    password=password,
                    keyspace=keyspace,
                    table=table,
                    dc=dc,
                    local_only=local_only,
                    consistency_level=consistency_level,
                    start_id=start_id,
                    end_id=end_id,
                    batch_size=batch_size,
                    offset=offset,
                    num_buckets=num_buckets,
                )
            ))
        pool.close()
        pool.join()

    total_rows = 0
    total_failed = 0
    for j in jobs:
        w_idx, cnt, failed = j.get()
        total_rows += cnt
        total_failed += failed
        logger.info(f"Worker {w_idx} complete: rows={cnt}, failed={failed}")

    logger.info(f"All workers done: inserted={total_rows}, failures={total_failed}")

def main():
    opts = parse_args()
    hosts = [h.strip().split(':')[0] for h in opts.hosts.split(',') if h.strip()]
    parts = opts.hosts.strip().split(':')
    port=parts[1] if len(parts) > 1 else "9042"

    # Pre-flight check for required TLS configuration files
    username = opts.username
    if opts.mtls or opts.tls:
        config_dir = './config'
        required_files = [
            os.path.join(config_dir, 'ca.crt'),
            os.path.join(config_dir, 'tls.crt'),
            os.path.join(config_dir, 'tls.key')
        ]

        # Check if the config path exists and is a directory (or a symlink to one)
        if not os.path.lexists(config_dir) or not os.path.isdir(config_dir):
            logger.error(f"TLS config directory not found or is not a directory: '{config_dir}'")
            logger.error("Please ensure './config' exists and is a directory or a symbolic link to a directory.")
            sys.exit(1)

        for f_path in required_files:
            if not os.path.isfile(f_path):
                logger.error(f"Required TLS file not found: {f_path}")
                sys.exit(1)
        if opts.mtls:
            logger.info(f"Connecting to cluster: {hosts} with mTLS authentication")
            username = "mtls"  # Special username to trigger mTLS in _build_cluster_and_session
        else:
            logger.info(f"Connecting to cluster: {hosts} with username/password authentication with TLS: {username}")
        port = "9142"  # Default mTLS port, adjust if your cluster uses a different one
    else:
        logger.info(f"Connecting to cluster: {hosts}:{port} with username/password authentication: {username}")

    logger.info(f"Using keyspace: {opts.keyspace}, table: {opts.table}")
    logger.info(f"Local DC: {opts.dc}")
    logger.info(f"Using consistency level: {opts.cl}")
    logger.info(f"Row count to insert: {opts.row_count}, partition buckets: {opts.buckets}")
    if opts.buckets < 1:
        logger.error("--buckets must be >= 1")
        sys.exit(1)
    logger.info(f"Workers: {opts.workers or cpu_count()}")
    if opts.local_only:
        logger.info(f"Local-only mode forced: {opts.local_only}")

    try:
        if opts.drop:
            # Use ephemeral parent session to drop keyspace to avoid races
            cluster, session = _build_cluster_and_session(hosts, port, username, opts.password, opts.dc, opts.local_only)
            try:
                logger.info(f"Dropping table {opts.keyspace}.{opts.table} if exists.")
                session.execute(f"DROP TABLE IF EXISTS {opts.keyspace}.{opts.table};")
            finally:
                try:
                    session.shutdown()
                except Exception:
                    pass
                try:
                    cluster.shutdown()
                except Exception:
                    pass

        start_time = datetime.datetime.now()
        insert_data_parallel(
            hosts=hosts,
            port=port,
            username=username,
            password=opts.password,
            keyspace=opts.keyspace,
            table=opts.table,
            tablets=TABLETS,
            compression=COMPRESSION,
            dc=opts.dc,
            local_only=opts.local_only,
            consistency_level=opts.cl,
            row_count=opts.row_count,
            batch_size=opts.batch_size,
            workers=opts.workers,
            offset=opts.offset,
            num_buckets=opts.buckets,
        )
        elapsed = datetime.datetime.now() - start_time
        logger.info(f"Total insertion time: {elapsed}")
    except Exception as e:
        logger.error(f"Error in main execution: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
