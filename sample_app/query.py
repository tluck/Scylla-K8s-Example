#!/usr/bin/env python3
# -*- coding: latin-1 -*-

import time
import logging
import random
import sys
import argparse
from asyncio import sleep
from datetime import datetime, timedelta
from cassandra import ConsistencyLevel
from scylla_conn import add_connection_args, build_cluster_and_session, log_auth, resolve_connection

parser = argparse.ArgumentParser(description='ScyllaDB table query script')
add_connection_args(parser)
parser.add_argument('-k', '--keyspace', default="mykeyspace", help='Keyspace name')
parser.add_argument('-t', '--table', default="myTable", help='Table name')
parser.add_argument('-r', '--row_count', type=int, action="store", dest="row_count", default=100000)
parser.add_argument('-o', '--offset', type=int, default=0, help='ID offset (must match loader)')
parser.add_argument('--cl', dest="consistency_level", default="LOCAL_QUORUM", help="Consistency Level (ONE, TWO, QUORUM, ALL, LOCAL_QUORUM, EACH_QUORUM)")
parser.add_argument('--minutes', type=int, default=60, help='How long to run (minutes)')
parser.add_argument('--interval', type=float, default=1.0, help='Delay between queries (seconds)')
parser.add_argument('--buckets', type=int, default=256, help='Partition bucket count (must match loader: id %% buckets)',)
opts = parser.parse_args()

password = opts.password
row_count = int(opts.row_count)
id_offset = int(opts.offset)
num_buckets = int(opts.buckets)
dc = opts.dc
consistency_level = opts.consistency_level
## Define KS + Table
keyspace = opts.keyspace
table = opts.table
 
# Logging Setup
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

hosts, port, username = resolve_connection(opts, logger)

logger.info(f"Using keyspace: {opts.keyspace}, table: {opts.table}")
logger.info(f"Local DC: {opts.dc}")
logger.info(f"Using consistency level: {opts.consistency_level}") 
logger.info(f"Row count to query: {opts.row_count}, id offset: {id_offset}, buckets: {num_buckets}")

class TableQueryRunner:
    def __init__(self, hosts, port, keyspace, table, username, password):
        self.hosts = hosts
        self.keyspace = keyspace
        self.table = table
        self.query_count = 0
        self.error_count = 0
        try:
            self.cluster, self.session = build_cluster_and_session(
                hosts, port, username, password, dc, opts.local_only, opts.rack
            )
            self.session.set_keyspace(self.keyspace)
            logger.info(f"Connected to cluster: {self.hosts}")
            logger.info(f"Using keyspace: {self.keyspace}, table: {self.table}")
            log_auth(username, password, logger)
        except Exception as e:
            logger.error(f"Failed to connect to cluster: {e}")
            sys.exit(1)

    def prepare_queries(self):
        q = f"SELECT * FROM {self.keyspace}.{self.table} WHERE bucket = ? AND id = ?"
        try:
            prepared = self.session.prepare(q)
            prepared.consistency_level = getattr(ConsistencyLevel, consistency_level)
            self.main_query = prepared
            logger.info(f"Prepared query: {q}")
        except Exception as e:
            logger.warning(f"Failed to prepare query: {e}")
            self.main_query = None

    def execute_query(self):
        if not self.main_query:
            logger.error("No prepared query available")
            return False

        try:
            rid = id_offset + random.randint(1, row_count)
            b = rid % num_buckets
            logger.info(f"Querying bucket={b} id={rid}")

            main_result = self.session.execute(self.main_query, (b, rid))
            main_rows = list(main_result)

            self.query_count += 1
            logger.info(f"Query #{self.query_count} bucket={b} id={rid} -> {len(main_rows)} rows")
            
            if main_rows:
                row = main_rows[0]
                logger.info(f"Sample: id={row.id}, ssn={row.ssn}, balance={row.balance}")
            else:
                logger.info("No rows returned from main table")
            
            return True
            
        except Exception as e:
            self.error_count += 1
            logger.error(f"Query #{self.query_count + 1} failed: {e}")
            return False

    def run_for_duration(self, duration_minutes=10, query_interval_seconds=1):
        logger.info(f"Starting query runner for {duration_minutes} minutes...")
        start_time = datetime.now()
        end_time = start_time + timedelta(minutes=duration_minutes)
        self.prepare_queries()
        while datetime.now() < end_time:
            self.execute_query()
            if self.query_count % 50 == 0 and self.query_count != 0:
                elapsed = datetime.now() - start_time
                logger.info(f"Progress: {self.query_count} queries, {self.error_count} errors, elapsed: {elapsed}")
            time.sleep(query_interval_seconds)
        total_time = datetime.now() - start_time
        success_rate = ((self.query_count - self.error_count) / self.query_count * 100) if self.query_count else 0
        logger.info("=== Final Statistics ===")
        logger.info(f"Total runtime: {total_time}")
        logger.info(f"Total queries: {self.query_count}")
        logger.info(f"Successful queries: {self.query_count - self.error_count}")
        logger.info(f"Failed queries: {self.error_count}")
        logger.info(f"Success rate: {success_rate:.2f}%")
        logger.info(f"Average queries per second: {self.query_count / total_time.total_seconds():.2f}")

    def close(self):
        if self.cluster:
            self.cluster.shutdown()
            logger.info("Database connection closed")

def main():
    if num_buckets < 1:
        logger.error("--buckets must be >= 1")
        sys.exit(1)
    runner = TableQueryRunner(hosts, port, keyspace, table, username, password)
    try:
        runner.run_for_duration(duration_minutes=opts.minutes,
                                query_interval_seconds=opts.interval)
    except KeyboardInterrupt:
        logger.info("Script interrupted by user")
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
    finally:
        runner.close()

if __name__ == "__main__":
    main()
