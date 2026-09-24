#!/usr/bin/env python3
# -*- coding: latin-1 -*-

import time
import datetime
import logging
import random
import argparse
import random
from cassandra import ConsistencyLevel
from cassandra.concurrent import execute_concurrent_with_args
from scylla_conn import add_connection_args, build_cluster_and_session, resolve_connection

## Script args and Help
parser = argparse.ArgumentParser(add_help=True)
add_connection_args(parser)
parser.add_argument('-k', '--keyspace', default="mykeyspace", help='Keyspace name')
parser.add_argument('-r', '--row_count', type=int, default=10000, help='Number of rows to insert')
opts = parser.parse_args()

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

password = opts.password
row_count = int(opts.row_count)
## Define KS + Table
keyspace = opts.keyspace
tablets = "true"

hosts, port, username = resolve_connection(opts, logger)

print ("hosts: %s" % hosts)
print ("row_count: %d" % row_count)

def strTimeProp(start, end, format, prop):
    stime = time.mktime(time.strptime(start, format))
    etime = time.mktime(time.strptime(end, format))
    ptime = stime + prop * (etime - stime)
    return time.strftime(format, time.localtime(ptime))

def randomDate(start, end, prop):
    return strTimeProp(start, end, '%Y-%m-%d', prop)

def insert_data(session, row_count, table, compression):
    print("")
    print("## Creating schema")
    now = datetime.datetime.now()
    print(now.strftime("%Y-%m-%d %H:%M:%S"))
    # You do NOT need to recreate the session or cluster here!
    
    create_ks = f"""
        CREATE KEYSPACE IF NOT EXISTS {keyspace}
        WITH replication = {{'class' : 'org.apache.cassandra.locator.NetworkTopologyStrategy', 'replication_factor' : 3}}
        AND tablets = {{'enabled': {tablets} }};
    """
    create_t1 = f"""CREATE TABLE IF NOT EXISTS {keyspace}.{table}
        (a int, b int, c int,
        PRIMARY KEY (a))
        WITH compression = {{ {compression} }}
        ;"""
    session.execute(create_ks)
    session.execute(f"""DROP TABLE if exists {keyspace}.{table};""")
    session.execute(create_t1)

    # Prepare and insert data, as before...
    # (rest of your function unchanged)
    # ...
    print("## Preparing CQL statement")
    cql = f"""INSERT INTO {keyspace}.{table} (a,b,c) VALUES (?,?,?)"""
    cql_prepared = session.prepare(cql)
    cql_prepared.consistency_level = ConsistencyLevel.ONE
    print("")

    i = 0
    while i < row_count:
        a=1
        b=i
        c=i
        i += 1
        session.execute(cql_prepared, (a,b,c))
    now = datetime.datetime.now()
    print("inserted records:", i, now.strftime("%Y-%m-%d %H:%M:%S"))

if __name__ == "__main__":
    table = [ "myTable" ]
    compression = [ "'sstable_compression': 'ZstdCompressor'" ]
    cluster, session = build_cluster_and_session(
        hosts, port, username, password, opts.dc, opts.local_only, opts.rack
    )
    numtable= len(table) 
    for i in range(numtable):
        print("")
        print(f"## Inserting data into {keyspace}.{table[i]}")
        t = table[i]
        c = compression[i]
        insert_data(session, row_count, t, c)
    cluster.shutdown()
    now = datetime.datetime.now()
    print(now.strftime("%Y-%m-%d %H:%M:%S"))

