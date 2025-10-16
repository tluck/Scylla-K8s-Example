#!/usr/bin/env python3
# -*- coding: latin-1 -*-

import time
import logging
import random
import sys
import argparse
from asyncio import sleep
from datetime import datetime, timedelta
from cassandra.cluster import Cluster
from cassandra import ConsistencyLevel
from cassandra.concurrent import execute_concurrent_with_args
from cassandra.auth import PlainTextAuthProvider
from cassandra.cluster import Cluster, ExecutionProfile, EXEC_PROFILE_DEFAULT
from cassandra.policies import DCAwareRoundRobinPolicy, TokenAwarePolicy, RoundRobinPolicy

parser = argparse.ArgumentParser(description='ScyllaDB table query script')
parser.add_argument('-s', '--hosts', default="127.0.0.1", help='Comma-separated ScyllaDB node Names or IPs')
parser.add_argument('-u', '--username', default="cassandra", help='Cassandra username')
parser.add_argument('-p', '--password', default="cassandra", help='Cassandra password')
parser.add_argument('-k', '--keyspace', default="mykeyspace", help='Keyspace name')
parser.add_argument('-t', '--table', default="myTable", help='Table name')
parser.add_argument('-r', '--row_count', type=int, action="store", dest="row_count", default=100000)
parser.add_argument('--cl', dest="consistency_level", default="QUORUM", help="Consistency Level (ONE, TWO, QUORUM, ALL, LOCAL_QUORUM, EACH_QUORUM)")
parser.add_argument('--dc', dest='local_datacenter', default='dc1', help='Local datacenter name for ScyllaDB')
parser.add_argument('--minutes', type=int, default=60, help='How long to run (minutes)')
parser.add_argument('--interval', type=float, default=1.0, help='Delay between queries (seconds)')
# parser.add_argument('--dc', dest='local_dc', default='GCE_US_WEST_1', help='Local datacenter name for ScyllaDB')
opts = parser.parse_args()

hosts = [h.strip() for h in opts.hosts.split(',') if h.strip()]
username = opts.username
password = opts.password
row_count = int(opts.row_count)
local_datacenter = opts.local_datacenter
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
logger.info(f"Local DC: {opts.local_datacenter}")
logger.info(f"Using consistency level: {opts.consistency_level}") 
logger.info(f"Row count to insert: {opts.row_count}") 

class TableQueryRunner:
    def __init__(self, hosts, keyspace, table, username, password):
        self.hosts = hosts
        self.keyspace = keyspace
        self.table = table
        self.query_count = 0
        self.error_count = 0
        try:
            if hosts == ['127.0.0.1']:
                profile = ExecutionProfile(load_balancing_policy=RoundRobinPolicy(), request_timeout=30)
                self.cluster = Cluster(hosts, 
                    auth_provider=PlainTextAuthProvider(username=username, password=password),
                    execution_profiles={EXEC_PROFILE_DEFAULT: profile},
                    protocol_version=4, connect_timeout=30, control_connection_timeout=30 )
            else:
                profile = ExecutionProfile(load_balancing_policy=TokenAwarePolicy(DCAwareRoundRobinPolicy(local_dc=local_datacenter)))
                self.cluster = Cluster(
                    contact_points= hosts,
                    auth_provider = PlainTextAuthProvider(username=username, password=password),
                    protocol_version=4,
                    connect_timeout=30,
                    control_connection_timeout=30)

            self.session = self.cluster.connect()
            self.session.set_keyspace(self.keyspace)
            logger.info(f"Connected to cluster: {self.hosts}")
            logger.info(f"Using keyspace: {self.keyspace}, table: {self.table}")
            logger.info(f"Authentication successful for user: {username}, password: {'*' * len(password)}")
        except Exception as e:
            logger.error(f"Failed to connect to cluster: {e}")
            sys.exit(1)

    def prepare_queries(self):
        self.queries = [
            f"SELECT * FROM {self.table} where id=? LIMIT 10"
        ]
        self.prepared_queries = []
        for query in self.queries:
            try:
                prepared = self.session.prepare(query)
                # Convert string to ConsistencyLevel enum
                prepared.consistency_level = getattr(ConsistencyLevel, consistency_level)
                self.prepared_queries.append(prepared)
                logger.info(f"Prepared query: {query}")
            except Exception as e:
                logger.warning(f"Failed to prepare query '{query}': {e}")

    def execute_query(self):
        if not self.prepared_queries:
            logger.error("No prepared queries available")
            return False
        try:
            # query = random.choice(self.prepared_queries)
            id=random.randint(1, row_count)
            query = self.prepared_queries[0]
            result = self.session.execute(query, (id,))
            rows = list(result)
            self.query_count += 1
            logger.info("Query #%d executed successfully, returned %d rows", self.query_count, len(rows))
            if rows:
                logger.info("Row sample: %s, %s", rows[0].id, rows[0].ssn)
            else:
                logger.info("Row sample: No rows returned")
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
