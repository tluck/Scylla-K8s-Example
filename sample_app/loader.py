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
from cassandra.concurrent import execute_concurrent_with_args
from cassandra import ConsistencyLevel
from cassandra.query import SimpleStatement, ordered_dict_factory, TraceUnavailable
from scylla_conn import add_connection_args, build_cluster_and_session, resolve_connection

# Constants
COMPRESSION = "'sstable_compression': 'ZstdWithDictsCompressor'"

# Logging Setup
DATE_FORMAT = '%Y-%m-%d'
LOG_FORMAT = '%(asctime)s - %(levelname)s - %(message)s'
logging.basicConfig(level=logging.INFO, format=LOG_FORMAT)
logger = logging.getLogger(__name__)

def parse_args():
    parser = argparse.ArgumentParser()
    add_connection_args(parser)
    parser.add_argument('-k', '--keyspace', default="myKeyspace", help='Keyspace name')
    parser.add_argument('--rf', type=int, default=3, help='Replication factor for the keyspace (default 3)')
    parser.add_argument('-t', '--table', default="myTable", help='Table name')
    parser.add_argument('-d', '--drop', action="store_true", help='Drop table if exists')
    parser.add_argument('-r', '--row_count', type=int, default=100000, help='Number of rows to insert')
    parser.add_argument('-b', '--batch_size', type=int, default=2000, help='Batch size for inserts')
    parser.add_argument('--cl', default="LOCAL_QUORUM", help="Consistency Level (ONE, TWO, QUORUM, etc.)")
    parser.add_argument('-w', '--workers', type=int, default=0, help='Number of worker processes (0 = cpu_count())')
    parser.add_argument('-o', '--offset', type=int, default=0, help='Offset for ID generation to avoid collisions across runs')
    parser.add_argument('--buckets', type=int, default=256, help='Number of partition buckets (id %% buckets). More buckets = less hotspot risk per partition.')
    parser.add_argument('--tablets', action=argparse.BooleanOptionalAction, default=True, help='Enable tablets on the keyspace (use --no-tablets to disable)')
    return parser.parse_args()

def str_time_prop(start, end, fmt, prop):
    stime = time.mktime(time.strptime(start, fmt))
    etime = time.mktime(time.strptime(end, fmt))
    ptime = stime + prop * (etime - stime)
    return time.strftime(fmt, time.localtime(ptime))

def random_date(start, end, prop):
    return str_time_prop(start, end, DATE_FORMAT, prop)

def create_schema(session, keyspace, table, tablets, compression, rf):
    create_ks = f"""
        CREATE KEYSPACE IF NOT EXISTS {keyspace}
        WITH replication = {{'class' : 'NetworkTopologyStrategy', 'replication_factor' : {rf}}}
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
    rack,
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
    cluster, session = build_cluster_and_session(hosts, port, username, password, dc, local_only, rack)
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
    rf,
    dc,
    local_only,
    rack,
    consistency_level,
    row_count,
    batch_size,
    workers,
    offset,
    num_buckets,
):
    # One control session in parent to create schema (safe and simple)
    ctrl_cluster, ctrl_session = build_cluster_and_session(hosts, port, username, password, dc, local_only, rack)
    try:
        create_schema(ctrl_session, keyspace, table, tablets, compression, rf)
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
                    rack=rack,
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
    hosts, port, username = resolve_connection(opts, logger)

    logger.info(f"Using keyspace: {opts.keyspace}, table: {opts.table}, rf: {opts.rf}")
    logger.info(f"Local DC: {opts.dc}")
    logger.info(f"Using consistency level: {opts.cl}")
    tablets = "true" if opts.tablets else "false"
    logger.info(f"Row count to insert: {opts.row_count}, partition buckets: {opts.buckets}, tablets: {tablets}")
    if opts.buckets < 1:
        logger.error("--buckets must be >= 1")
        sys.exit(1)
    if opts.rf < 1:
        logger.error("--rf must be >= 1")
        sys.exit(1)
    logger.info(f"Workers: {opts.workers or cpu_count()}")
    if opts.local_only:
        logger.info(f"Local-only mode forced: {opts.local_only}")

    try:
        if opts.drop:
            # Use ephemeral parent session to drop keyspace to avoid races
            cluster, session = build_cluster_and_session(hosts, port, username, opts.password, opts.dc,
                                                         opts.local_only, opts.rack)
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
            tablets=tablets,
            compression=COMPRESSION,
            rf=opts.rf,
            dc=opts.dc,
            local_only=opts.local_only,
            rack=opts.rack,
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
