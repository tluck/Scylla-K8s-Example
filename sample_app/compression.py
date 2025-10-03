#!/usr/bin/env python3
# -*- coding: latin-1 -*-

import csv
import sys
from xml.etree.ElementPath import ops
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
parser.add_argument('-k', '--keyspace', default="compression", help='Keyspace name')
parser.add_argument('-d', '--drop', action="store_true", help='Drop keyspace if exists')
parser.add_argument('-r', '--row_count', type=int, action="store", dest="row_count", default=100000)
opts = parser.parse_args()

hosts = [h.strip() for h in opts.hosts.split(',') if h.strip()]
username = opts.username
password = opts.password
row_count = int(opts.row_count)
## Define KS + Table
keyspace = opts.keyspace
tablets = "true"
drop_keyspace = opts.drop
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
        (id int, ssn text, imei text, os text, phonenum text, balance float, pdate date, v1 text, v2 text, v3 text, v4 text, v5 text,
        PRIMARY KEY (id))
        WITH compression = {{ {compression} }}
        ;"""
    session.execute(create_ks)
    session.execute(create_t1)

    # Prepare and insert data, as before...
    # (rest of your function unchanged)
    # ...
    print("## Preparing CQL statement")
    cql = f"""INSERT INTO {keyspace}.{table} (id, ssn, imei, os, phonenum, balance, pdate, v1, v2, v3, v4, v5) VALUES (?,?,?,?,?,?,?, ?,?,?,?,?) using TIMESTAMP ?"""
    cql_prepared = session.prepare(cql)
    cql_prepared.consistency_level = ConsistencyLevel.ONE
    print("")

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
            print("inserted records:", i, now.strftime("%Y-%m-%d %H:%M:%S"))
        i += 1
        session.execute(cql_prepared, (i, ssn, imei, os, phone, bal, dat, v[0], v[1], v[2], v[3], v[4]))
    now = datetime.datetime.now()
    print("inserted records:", i, now.strftime("%Y-%m-%d %H:%M:%S"))

if __name__ == "__main__":
    table = [ "actions_w_none",
              "actions_w_zstd", 
              "actions_w_zstd_dict", 
              "actions_w_lz4c" 
            ]
    compression = [ "",
                    "'sstable_compression': 'ZstdCompressor', 'chunk_length_in_kb': 64",
                    "'sstable_compression': 'ZstdWithDictsCompressor', 'chunk_length_in_kb': 64",
                    "'sstable_compression': 'org.apache.cassandra.io.compress.LZ4Compressor', 'chunk_length_in_kb': 64"
                  ]

    cluster = Cluster(hosts, auth_provider=PlainTextAuthProvider(username, password))
    session = cluster.connect()
    numtable= len(table) 
    if drop_keyspace:
        session.execute(f"""DROP KEYSPACE if exists {keyspace};""")
    for i in range(numtable):
        print("")
        print(f"## Inserting data into {keyspace}.{table[i]}")
        t = table[i]
        c = compression[i]
        insert_data(session, row_count, t, c)
    session.shutdown()       # or, preferably, cluster.shutdown()
    now = datetime.datetime.now()
    print(now.strftime("%Y-%m-%d %H:%M:%S"))

