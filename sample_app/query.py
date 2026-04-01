#!/usr/bin/env python3
# -*- coding: latin-1 -*-

import time
import logging
import random
import sys
import argparse
from asyncio import sleep
from datetime import datetime, timedelta
from cassandra.cluster import Cluster, ExecutionProfile, EXEC_PROFILE_DEFAULT
from cassandra.auth import PlainTextAuthProvider
from cassandra import ConsistencyLevel
from cassandra.policies import DCAwareRoundRobinPolicy, TokenAwarePolicy, WhiteListRoundRobinPolicy

parser = argparse.ArgumentParser(description='ScyllaDB table query script')
parser.add_argument('-s', '--hosts', default="127.0.0.1", help='Comma-separated ScyllaDB node Names or IPs')
parser.add_argument('-u', '--username', default="cassandra", help='ScyllaDB username')
parser.add_argument('-p', '--password', default="cassandra", help='ScyllaDB password')
parser.add_argument('-k', '--keyspace', default="mykeyspace", help='Keyspace name')
parser.add_argument('-t', '--table', default="myTable", help='Table name')
parser.add_argument('-r', '--row_count', type=int, action="store", dest="row_count", default=100000)
parser.add_argument('-o', '--offset', type=int, default=0, help='ID offset (must match loader)')
parser.add_argument('-l', '--local_only', action="store_true", help='Use local-only mode')
parser.add_argument('--cl', dest="consistency_level", default="LOCAL_QUORUM", help="Consistency Level (ONE, TWO, QUORUM, ALL, LOCAL_QUORUM, EACH_QUORUM)")
parser.add_argument('--dc', default='dc1', help='Local datacenter name for ScyllaDB')
parser.add_argument('--minutes', type=int, default=60, help='How long to run (minutes)')
parser.add_argument('--interval', type=float, default=1.0, help='Delay between queries (seconds)')
parser.add_argument('--buckets', type=int, default=256, help='Partition bucket count (must match loader: id %% buckets)',)
opts = parser.parse_args()

hosts = [h.strip() for h in opts.hosts.split(',') if h.strip()]
username = opts.username
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

logger.info(f"Connecting to cluster: {hosts} with user {opts.username}")
logger.info(f"Using keyspace: {opts.keyspace}, table: {opts.table}")
logger.info(f"Local DC: {opts.dc}")
logger.info(f"Using consistency level: {opts.consistency_level}") 
logger.info(f"Row count to query: {opts.row_count}, id offset: {id_offset}, buckets: {num_buckets}")

class TableQueryRunner:
    def __init__(self, hosts, keyspace, table, username, password):
        self.hosts = hosts
        self.keyspace = keyspace
        self.table = table
        self.query_count = 0
        self.error_count = 0
        try:
            is_local_only = (hosts and hosts[0] in ('127.0.0.1', 'localhost')) or opts.local_only
            if is_local_only:
                # For a single node connection, shard-awareness should be disabled.
                # This prevents the driver from trying to connect to other discovered nodes.
                logger.info(f"Using WhiteListRoundRobinPolicy with hosts: {hosts}")
                policy = WhiteListRoundRobinPolicy(hosts)
            else:
                logger.info(f"Using TokenAwarePolicy with local_dc: {dc}")
                policy = TokenAwarePolicy(DCAwareRoundRobinPolicy(local_dc=dc))

            profile = ExecutionProfile(load_balancing_policy=policy, request_timeout=30)
                
            self.cluster = Cluster(
                contact_points= hosts,
                shard_aware_options=dict(disable=is_local_only),
                auth_provider=PlainTextAuthProvider(username=username, password=password),
                execution_profiles={EXEC_PROFILE_DEFAULT: profile},
                protocol_version=4,
                connect_timeout=30,
                control_connection_timeout=30
            )

            self.session = self.cluster.connect()
            self.session.set_keyspace(self.keyspace)
            logger.info(f"Connected to cluster: {self.hosts}")
            logger.info(f"Using keyspace: {self.keyspace}, table: {self.table}")
            logger.info(f"Authentication successful for user: {username}, password: {'*' * len(password)}")
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
    runner = TableQueryRunner(hosts, keyspace, table, username, password)
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
