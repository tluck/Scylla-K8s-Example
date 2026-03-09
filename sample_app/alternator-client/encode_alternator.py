#!/usr/bin/env python3 

import argparse
from cassandra.cluster import Cluster
from cassandra.auth import PlainTextAuthProvider

# Command line argument parsing
parser = argparse.ArgumentParser(description='Decode Alternator user data')
parser.add_argument('userid', help='UserID to lookup (e.g. "user826614")')
args = parser.parse_args()

def encode_alternator_blob(value):
    if isinstance(value, str):
        return b'\x00' + value.encode('utf-8')
    elif isinstance(value, int):
        # 1. Create correct LE bytes
        num_bytes = value.to_bytes(7, byteorder='little')
        # 2. PRE-REVERSE to match driver's delivery order
        driver_expected_bytes = num_bytes[::-1]
        # 3. Add header
        return b'\x03\x00\x00\x00' + driver_expected_bytes
    return None

def decode_alternator_blob(blob_bytes):
    if not blob_bytes or blob_bytes[0] != 0x03:
        if blob_bytes and blob_bytes[0] == 0x00:
            return blob_bytes[1:].decode('utf-8')
        return None
    
    # Cassandra delivers REVERSED bytes - reverse back to logical order
    value_bytes = blob_bytes[4:11][::-1]  # Reverse: 8dca7e31→00 01 99 31 7e ca 8d
    return int.from_bytes(value_bytes, 'little')

cluster = Cluster(['scylla-client'], port=9042, 
                 auth_provider=PlainTextAuthProvider(username='cassandra', password='cassandra'))
session = cluster.connect('alternator_userid')

# Create + verify
userid = args.userid
attrs = {'Name': encode_alternator_blob('Charlie'), 'Score': encode_alternator_blob('99')}

session.execute("INSERT INTO userid (\"UserID\", \":attrs\") VALUES (%(id)s, %(attrs)s)", 
                {'id': userid, 'attrs': dict(attrs)})

result = session.execute('SELECT "UserID", ":attrs" FROM userid WHERE "UserID" = %s', [userid]).one()
print(f"User: {result.UserID}")
print(f"Name: {decode_alternator_blob(result.attrs['Name'])}")
print(f"Score: {decode_alternator_blob(result.attrs['Score'])}")  # 99 ✓

cluster.shutdown()
