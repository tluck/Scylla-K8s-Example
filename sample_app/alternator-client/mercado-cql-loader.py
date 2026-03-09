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
from cassandra.policies import DCAwareRoundRobinPolicy, TokenAwarePolicy, HostFilterPolicy, RoundRobinPolicy
from cassandra.auth import PlainTextAuthProvider
from cassandra.query import SimpleStatement
from ssl import SSLContext, TLSVersion, CERT_REQUIRED, PROTOCOL_TLS_CLIENT

# OPTIMIZED CONSTANTS
COMPRESSION = "'sstable_compression': 'ZstdWithDictsCompressor'"
TABLETS = "true"
_TIME_CONSTANTS = {
    'HOUR_MS': 3600000,
    'WEEK_MS': 604800000,
    'MONTH_TTL': 2592000,
    'YEAR_TTL': 31536000
}
_YEARS = ['5', '6']

# FAST LOGGING WITH PID
LOG_FORMAT = '%(asctime)s [%(process)d] %(levelname)s %(message)s'
logging.basicConfig(level=logging.INFO, format=LOG_FORMAT)
logger = logging.getLogger(__name__)

def parse_args():
    parser = argparse.ArgumentParser(description="High-performance ScyllaDB data loader")
    parser.add_argument('-s', '--hosts', default="127.0.0.1:9042", help='Comma-separated ScyllaDB nodes')
    parser.add_argument('-l', '--loopback', action="store_true", help='Force loopback mode')
    parser.add_argument('-m', '--mtls', action="store_true", help='Use mTLS (overrides user/pass)')
    parser.add_argument('-e', '--tls', action="store_true", help='Use TLS + user/pass')
    parser.add_argument('-u', '--username', default="cassandra")
    parser.add_argument('-p', '--password', default="cassandra")
    parser.add_argument('-k', '--keyspace', default="mercado")
    parser.add_argument('-t', '--table', default="userid")
    parser.add_argument('--dc', default='dc1', help='Local datacenter for DCAwareRoundRobinPolicy')
    parser.add_argument('-d', '--drop', action="store_true", help='Drop table before loading')
    parser.add_argument('-r', '--row_count', type=int, default=10000, help='Total rows to insert')
    parser.add_argument('-b', '--batch_size', type=int, default=1000)
    parser.add_argument('-w', '--workers', type=int, default=0, help='Workers (0=auto)')
    parser.add_argument('-o', '--offset', type=int, default=0)
    parser.add_argument('-v', '--verify', action="store_true", help='Verify first 10 rows after load')
    parser.add_argument('--cl', default="LOCAL_QUORUM", help='Consistency level')
    parser.add_argument('--batch_mode', choices=['concurrent', 'logged', 'unlogged', 'none'], default='concurrent')
    parser.add_argument('-c', '--concurrency', type=int, default=100, help='Concurrency for concurrent batch mode')
    return parser.parse_args()

def create_schema(session, keyspace, table):
    session.execute(f"""
        CREATE KEYSPACE IF NOT EXISTS {keyspace}
        WITH replication = {{'class': 'NetworkTopologyStrategy', 'replication_factor': 3}}
        AND tablets = {{'enabled': {TABLETS}}};
    """)
    session.execute(f"""
        CREATE TABLE IF NOT EXISTS {keyspace}.{table} (
            userid text PRIMARY KEY,
            attrs map<text, text>
        ) WITH compression = {{{COMPRESSION}}};
    """)

def generate_row_fast(worker_seed, i, now_ms):
    """Self-contained row generation - no global Faker dependency"""
    random.seed(worker_seed ^ i ^ now_ms)  # Deterministic per row
    
    base_time = now_ms - random.randint(0, _TIME_CONSTANTS['HOUR_MS'])
    uuid_str = str(random.getrandbits(128))  # Fast UUID replacement
    chunk_hash = uuid_str[:32]
    
    month = random.randint(1, 12)
    day = random.randint(1, 31)
    year_suffix = random.choice(_YEARS)
    chunk_path = f"dmd/{month:02d}/{day:02d}/202{year_suffix}/{chunk_hash}"
    
    attrs = {
        'chunk_path': chunk_path,
        'compression_version': str(random.randint(1, 5)),
        'start_byte_range': str(random.randint(400000, 1500000)),
        'end_byte_range': str(random.randint(500000, 2000000)),
        'last_updated_millis': str(base_time + random.randint(0, _TIME_CONSTANTS['WEEK_MS'])),
        'ttl': str(random.randint(_TIME_CONSTANTS['MONTH_TTL'], _TIME_CONSTANTS['YEAR_TTL']))
    }
    
    return (f"user{i}", attrs, now_ms)

def chunked_ids(start_id, end_id, batch_size):
    """Generator for ID chunks"""
    i = start_id
    while i <= end_id:
        j = min(i + batch_size - 1, end_id)
        yield (i, j)
        i = j + 1

def _build_cluster_and_session(hosts, port, username, password, dc, loopback):
    local_loopback = (hosts and hosts[0] in ('127.0.0.1', 'localhost')) or loopback
    
    if local_loopback:
        policy = HostFilterPolicy(RoundRobinPolicy(), lambda h: h.address == hosts[0])
        profile = ExecutionProfile(load_balancing_policy=policy, request_timeout=30, consistency_level=ConsistencyLevel.ONE)
        shard_opts = {"disable": True}
        pv, md = 3, False
    else:
        policy = TokenAwarePolicy(DCAwareRoundRobinPolicy(local_dc=dc))
        profile = ExecutionProfile(load_balancing_policy=policy, request_timeout=30)
        shard_opts = {"disable": False}
        pv, md = 4, True

    ssl_context = ssl_options = None
    if port == "9142":  # TLS port
        ssl_context = SSLContext(PROTOCOL_TLS_CLIENT)
        ssl_context.minimum_version = TLSVersion.TLSv1_2
        ssl_context.maximum_version = TLSVersion.TLSv1_3
        ssl_context.load_verify_locations('./config/ca.crt')
        ssl_context.verify_mode = CERT_REQUIRED
        ssl_context.load_cert_chain('./config/tls.crt', './config/tls.key')
        ssl_options = {'server_hostname': hosts[0]}

    kwargs = {
        'contact_points': hosts, 'port': int(port), 'ssl_context': ssl_context,
        'ssl_options': ssl_options, 'execution_profiles': {EXEC_PROFILE_DEFAULT: profile},
        'shard_aware_options': shard_opts, 'protocol_version': pv,
        'connect_timeout': 30, 'control_connection_timeout': 1,
        'schema_metadata_enabled': md, 'token_metadata_enabled': md
    }
    
    if username != "mtls":
        kwargs['auth_provider'] = PlainTextAuthProvider(username, password)
    
    cluster = Cluster(**kwargs)
    session = cluster.connect()
    return cluster, session

def _worker_insert_range(args):
    """Worker function - completely self-contained"""
    (worker_index, worker_seed, hosts, port, username, password, keyspace, table, dc, loopback,
     consistency_level, start_id, end_id, batch_size, offset, batch_mode, concurrency) = args
    
    now_ms = int(time.time() * 1000)
    cluster, session = _build_cluster_and_session(hosts, port, username, password, dc, loopback)
    
    try:
        prepared = session.prepare(f"INSERT INTO {keyspace}.{table} (userid, attrs) VALUES (?, ?) USING TIMESTAMP ?")
        prepared.consistency_level = getattr(ConsistencyLevel, consistency_level)
        
        total = total_failed = 0
        
        if batch_mode == 'none':
            for i in range(start_id, end_id + 1):
                try:
                    future = session.execute_async(prepared, generate_row_fast(worker_seed, i + offset, now_ms))
                    future.result()
                    total += 1
                except Exception:
                    total_failed += 1
        
        elif batch_mode == 'concurrent':
            for s_id, e_id in chunked_ids(start_id, end_id, batch_size):
                batch = [generate_row_fast(worker_seed, i + offset, now_ms) for i in range(s_id, e_id + 1)]
                results = execute_concurrent_with_args(session, prepared, batch, concurrency=concurrency)
                failed = sum(1 for success, _ in results if not success)
                total += len(batch)
                total_failed += failed
                if worker_index == 0 and s_id % (batch_size * 10) == 0:
                    logger.info(f"W{worker_index}: {total} rows [{s_id}-{e_id}] ({failed} failed)")
        
        elif batch_mode in ('logged', 'unlogged'):
            # Limit batch size for native batches
            effective_batch_size = min(20, batch_size)
            batch_type = 'UNLOGGED ' if batch_mode == 'unlogged' else ''
            
            for s_id, e_id in chunked_ids(start_id, end_id, effective_batch_size):
                batch_rows = [generate_row_fast(worker_seed, i + offset, now_ms) for i in range(s_id, e_id + 1)]
                
                batch_stmts = []
                for userid, attrs, ts in batch_rows:
                    # Safe map construction
                    map_items = [f"'{k}': '{v}'" for k, v in attrs.items()]
                    map_literal = '{' + ', '.join(map_items) + '}'
                    batch_stmts.append(f"INSERT INTO {keyspace}.{table} (userid, attrs) VALUES ('{userid}', {map_literal}) USING TIMESTAMP {ts}")
                
                batch_cql = f"BEGIN {batch_type}BATCH\n" + ";\n".join(batch_stmts) + ";\nAPPLY BATCH"
                session.execute(SimpleStatement(batch_cql))
                total += len(batch_rows)
        
        return (worker_index, total, total_failed)
    
    finally:
        session.shutdown()
        cluster.shutdown()

def insert_data_parallel(hosts, port, username, password, keyspace, table, dc, loopback, 
                        consistency_level, row_count, batch_size, workers, offset, batch_mode, concurrency):
    # Create schema first
    ctrl_cluster, ctrl_session = _build_cluster_and_session(hosts, port, username, password, dc, loopback)
    try:
        create_schema(ctrl_session, keyspace, table)
    finally:
        ctrl_session.shutdown()
        ctrl_cluster.shutdown()

    procs = min(workers or cpu_count(), 64)
    span = ceil(row_count / procs)
    
    logger.info(f"[{procs} workers] {row_count:,} rows | batch={batch_size:,}")
    
    ctx = get_context("spawn")
    with ctx.Pool(procs) as pool:
        args_list = []
        for w in range(procs):
            start_id = w * span + 1
            end_id = min((w + 1) * span, row_count)
            if start_id <= end_id:
                # Unique seed per worker
                worker_seed = int.from_bytes(os.urandom(8), 'little') ^ w ^ int(time.time())
                args_list.append((
                    w, worker_seed, hosts, port, username, password, keyspace, table, dc, loopback,
                    consistency_level, start_id, end_id, batch_size, offset, batch_mode, concurrency
                ))
        
        jobs = [pool.apply_async(_worker_insert_range, args=(args,)) for args in args_list]
        pool.close()
        pool.join()

    total_rows = total_failed = 0
    for job in jobs:
        w, rows, failed = job.get()
        total_rows += rows
        total_failed += failed
        logger.info(f"W{w}: {rows:,} rows ({failed} failed)")
    
    logger.info(f"COMPLETE: {total_rows:,} inserted | {total_failed} failed")
    return total_rows, total_failed

def main():
    opts = parse_args()
    
    # Parse hosts/port cleanly
    host_parts = [h.strip().split(':') for h in opts.hosts.split(',') if h.strip()]
    hosts = [hp[0] for hp in host_parts]
    port = host_parts[0][1] if len(host_parts[0]) > 1 else "9042"
    
    # TLS validation
    username = "mtls" if opts.mtls else opts.username
    if opts.tls or opts.mtls:
        certs = ['./config/ca.crt', './config/tls.crt', './config/tls.key']
        for cert in certs:
            if not os.path.isfile(cert):
                logger.error(f"Missing TLS cert: {cert}")
                sys.exit(1)
        port = "9142"
        logger.info(f"TLS mode: {'mTLS' if opts.mtls else 'TLS'}")
    
    logger.info(f"Loading {opts.row_count:,} rows -> {opts.keyspace}.{opts.table}")
    if opts.batch_mode == 'concurrent': 
        logger.info(f"Workers: {opts.workers or cpu_count()} | Batch: {opts.batch_size:,} | Mode: {opts.batch_mode} | Concurrency: {opts.concurrency}")
    else:
        logger.info(f"Workers: {opts.workers or cpu_count()} | Batch: {opts.batch_size:,} | Mode: {opts.batch_mode}")
    
    if opts.drop:
        cluster, session = _build_cluster_and_session(hosts, port, username, opts.password, opts.dc, opts.loopback)
        session.execute(f"DROP TABLE IF EXISTS {opts.keyspace}.{opts.table}")
        session.shutdown()
        cluster.shutdown()

    start = datetime.datetime.now()
    total_rows, total_failed = insert_data_parallel(
        hosts, port, username, opts.password, opts.keyspace, opts.table, opts.dc, opts.loopback,
        opts.cl, opts.row_count, opts.batch_size, opts.workers, opts.offset, opts.batch_mode, opts.concurrency
    )
    
    elapsed = datetime.datetime.now() - start
    rate = total_rows / max(elapsed.total_seconds(), 1)
    logger.info(f"FINISHED: {total_rows:,} rows in {elapsed} ({rate:,.0f} rows/sec)")
    
    if opts.verify and total_rows > 0:
        cluster, session = _build_cluster_and_session(hosts, port, username, opts.password, opts.dc, opts.loopback)
        try:
            prepared = session.prepare(f"SELECT * FROM {opts.keyspace}.{opts.table} WHERE userid = ?")
            verified = sum(1 for i in range(1, min(11, total_rows + 1)) 
                          if session.execute(prepared, [f"user{i}"]).one())
            logger.info(f"VERIFIED: {verified}/10 rows OK")
        finally:
            session.shutdown()
            cluster.shutdown()

if __name__ == "__main__":
    main()
