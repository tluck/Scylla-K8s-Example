#!/usr/bin/env python3
# -*- coding: latin-1 -*-

import csv
import sys
from cassandra.cluster import Cluster
import time
import datetime
import random
import argparse
import concurrent.futures
from faker import Faker
import random
from cassandra import ConsistencyLevel
from cassandra.concurrent import execute_concurrent_with_args
from cassandra.auth import PlainTextAuthProvider

## Script args and Help
parser = argparse.ArgumentParser(add_help=True)
parser.add_argument('-s', '--hosts', default="127.0.0.1", help='Comma-separated ScyllaDB node Names or IPs')
parser.add_argument('-u', '--username', default="cassandra", help='Cassandra username')
parser.add_argument('-p', '--password', default="cassandra", help='Cassandra password')
parser.add_argument('-k', '--keyspace', default="mykeyspace", help='Keyspace name')
opts = parser.parse_args()

hosts = [h.strip() for h in opts.hosts.split(',') if h.strip()]
username = opts.username
password = opts.password
row_count = int(opts.row_count)
## Define KS + Table
keyspace = opts.keyspace
tablets = "true"

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
    cluster = Cluster(hosts, auth_provider=PlainTextAuthProvider(username, password))
    session = cluster.connect()
    numtable= len(table) 
    for i in range(numtable):
        print("")
        print(f"## Inserting data into {keyspace}.{table[i]}")
        t = table[i]
        c = compression[i]
        insert_data(session, row_count, t, c)
    session.shutdown()       # or, preferably, cluster.shutdown()
    now = datetime.datetime.now()
    print(now.strftime("%Y-%m-%d %H:%M:%S"))

