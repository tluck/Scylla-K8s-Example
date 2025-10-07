#!/usr/bin/env python3

import logging
from threading import local
import time
import datetime
import random
import sys
import argparse
from venv import logger
from faker import Faker
from cassandra.cluster import Cluster
from cassandra import ConsistencyLevel
from cassandra.concurrent import execute_concurrent_with_args
from cassandra.auth import PlainTextAuthProvider
from cassandra.cluster import Cluster, ExecutionProfile, EXEC_PROFILE_DEFAULT
from cassandra.policies import DCAwareRoundRobinPolicy, TokenAwarePolicy, RoundRobinPolicy

## Script args and Help
parser = argparse.ArgumentParser(add_help=True)
parser.add_argument('-s', '--hosts', default="127.0.0.1", help='Comma-separated ScyllaDB node Names or IPs')
parser.add_argument('-u', '--username', default="cassandra", help='Cassandra username')
parser.add_argument('-p', '--password', default="cassandra", help='Cassandra password')
parser.add_argument('-k', '--keyspace', default="mykeyspace", help='Keyspace name')
parser.add_argument('-t', '--table', default="myTable", help='Table name')
parser.add_argument('-r', '--row_count', type=int, action="store", dest="row_count", default=10000)
parser.add_argument('-d', '--drop', action="store_true", help='Drop keyspace if exists')
parser.add_argument('--cl', dest="consistency_level", default="QUORUM", help="Consistency Level (ONE, TWO, QUORUM, ALL, LOCAL_QUORUM, EACH_QUORUM)")
parser.add_argument('--dc', dest='local_dc', default='dc1', help='Local datacenter name for ScyllaDB')
opts = parser.parse_args()

hosts = [h.strip() for h in opts.hosts.split(',') if h.strip()]
username = opts.username
password = opts.password
row_count = int(opts.row_count)
local_datacenter = opts.local_dc
consistency_level = opts.consistency_level
## Define KS + Table
keyspace = opts.keyspace
table = opts.table
tablets = "true"
drop_keyspace = opts.drop
compression = "'sstable_compression': 'ZstdWithDictsCompressor'"

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

logger.info(f"Connected to cluster: {hosts}")
logger.info(f"Using keyspace: {keyspace}, table: {table}")
logger.info(f"Authentication successful for user: {username}, password: {'*' * len(password)}")
logger.info(f"Local DC: {local_datacenter}")
logger.info(f"Row count to insert: {row_count}") 
logger.info(f"Using consistency level: {consistency_level}") 

def strTimeProp(start, end, format, prop):
    stime = time.mktime(time.strptime(start, format))
    etime = time.mktime(time.strptime(end, format))
    ptime = stime + prop * (etime - stime)
    return time.strftime(format, time.localtime(ptime))

def randomDate(start, end, prop):
    return strTimeProp(start, end, '%Y-%m-%d', prop)

def insert_data(session, row_count, table, compression):
    # print("")
    logger.info(f"## Creating schema")
    now = datetime.datetime.now()
    logger.info(now.strftime("%Y-%m-%d %H:%M:%S"))
    # You do NOT need to recreate the session or cluster here!
    
    create_ks = f"""
        CREATE KEYSPACE IF NOT EXISTS {keyspace}
        WITH replication = {{'class' : 'org.apache.cassandra.locator.NetworkTopologyStrategy', 'replication_factor' : 3}}
        AND tablets = {{'enabled': {tablets} }};
    """
    create_t1 = f"""CREATE TABLE IF NOT EXISTS {keyspace}.{table}
        (id int, ssn text, imei text, os text, phonenum text, balance float, pdate date, v1 text, v2 text, v3 text, v4 text, v5 text,
        PRIMARY KEY (id))
        WITH compression = {{ {compression} }}
        ;"""
    session.execute(create_ks)
    session.execute(create_t1)

    # Prepare and insert data, as before...
    # (rest of your function unchanged)
    # ...
    logger.info(f"## Preparing CQL statement")
    cql = f"""INSERT INTO {keyspace}.{table} (id, ssn, imei, os, phonenum, balance, pdate, v1, v2, v3, v4, v5) VALUES (?,?,?,?,?,?,?, ?,?,?,?,?) using TIMESTAMP ?"""
    cql_prepared = session.prepare(cql)
    cql_prepared.consistency_level = getattr(ConsistencyLevel, consistency_level)
    # print("")

    i = 0
    while i < row_count:
        ssn1 = [str(random.randint(100,999)), str(random.randint(10,99)), str(random.randint(1000,9999))]
        ssn = '-'.join(ssn1)
        imei = str(random.randint(100000000000000,999999999999999))
        os1 = ['Android','iOS','Windows','Samsung','Nokia']
        os = random.choice(os1)
        phone1 = [str(random.randint(200,999)), str(random.randint(100,999)), str(random.randint(1000,9999))]
        phone = '-'.join(phone1)
        bal = round(random.uniform(10.5,999.5), 2)
        dat = randomDate("2019-01-01", "2019-04-01", random.random())

        v = [None] * 5
        for j in range(5):
            base_string = f"IMEI:{imei}|OS:{os}|Phone:{phone}"

            # if len(base_string) < 200:
            #     padding = ''.join(random.choices('      ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789', k=200 - len(base_string)))
            #     final_string = base_string + padding
            # else:
            #     final_string = base_string[:200]
            # v[j] = final_string
            fake = Faker()
            if len(base_string) < 200:
                # Generate enough fake sentences to reach the desired length
                sentences = []
                while sum(len(s) for s in sentences) < 200 - len(base_string):
                    sentences.append(fake.sentence())
                padding = ' '.join(sentences)
                # Trim to exactly fit 200 characters
                padding = padding[:200 - len(base_string)]
                v[j] = base_string + padding
            else:
                v[j] = base_string[:200]

        if (i % 1000 == 0):
            now = datetime.datetime.now()
            logger.info("inserted records: %s, %s:", i, now.strftime('%Y-%m-%d %H:%M:%S'))
        i += 1
        session.execute(cql_prepared, (i, ssn, imei, os, phone, bal, dat, v[0], v[1], v[2], v[3], v[4]))
    now = datetime.datetime.now()
    logger.info("inserted records: %s, %s", i, now.strftime("%Y-%m-%d %H:%M:%S"))

if __name__ == "__main__":
    try:
        if hosts[0] == '127.0.0.1':
            profile = ExecutionProfile(load_balancing_policy=DCAwareRoundRobinPolicy(local_dc=local_datacenter), request_timeout=30)
            cluster = Cluster(hosts, 
                auth_provider=PlainTextAuthProvider(username=username, password=password),
                execution_profiles={EXEC_PROFILE_DEFAULT: profile},
                protocol_version=4, 
                connect_timeout=30, 
                control_connection_timeout=30 )
        else:
            profile = ExecutionProfile(load_balancing_policy=TokenAwarePolicy(DCAwareRoundRobinPolicy(local_dc=local_datacenter)))
            cluster = Cluster(
                contact_points=hosts,
                auth_provider=PlainTextAuthProvider(username=username, password=password),
                execution_profiles={EXEC_PROFILE_DEFAULT: profile},
                protocol_version=4,
                connect_timeout=30,
                control_connection_timeout=30)

        session = cluster.connect()
        if drop_keyspace:
            logger.info(f"Dropping keyspace {keyspace} if exists")
            session.execute(f"""DROP KEYSPACE if exists {keyspace};""")
        logger.info(f"Connected to cluster: {hosts}")
        logger.info(f"Using keyspace: {keyspace}, table: {table}")
        logger.info(f"Authentication successful for user: {username}, password: {'*' * len(password)}")
    except Exception as e:
        logger.error(f"Failed to connect to cluster: {e}")
        sys.exit(1)
    # print("")
    logger.info(f"## Inserting data into {keyspace}.{table}")
    now = datetime.datetime.now() 
    insert_data(session, row_count, table=table, compression=compression)
    now2 = datetime.datetime.now()
    logger.info(f"Data insertion completed in: {now2 - now}")

    session.shutdown()       # or, preferably, cluster.shutdown()
    if cluster:
        cluster.shutdown()
        logger.info("Database connection closed")
    now = datetime.datetime.now()
    print(now.strftime("%Y-%m-%d %H:%M:%S"))
