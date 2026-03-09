#!/usr/bin/env python3 
import argparse
from cassandra.cluster import Cluster
from cassandra.auth import PlainTextAuthProvider

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('-s', '--hosts', default="scylla-client.scylla-dc1.svc", help='Comma-separated ScyllaDB node IPs')
    parser.add_argument('-u', '--username', default="cassandra", help='ScyllaDB username')
    parser.add_argument('-p', '--password', default="cassandra", help='ScyllaDB password')
    parser.add_argument('-q', '--query', required=True, help='UserID to lookup (e.g. "user826614")')
    return parser.parse_args()

# Command line argument parsing
args = parse_args()

# Connect to your Scylla cluster
cluster = Cluster(
    contact_points=[args.hosts],
    port=9042,
    auth_provider=PlainTextAuthProvider(username=args.username, password=args.password)
)
session = cluster.connect('alternator_userid')

def decode_alternator_blob(blob_bytes):
    if not blob_bytes or blob_bytes[0] != 0x03:
        if blob_bytes and blob_bytes[0] == 0x00:
            return blob_bytes[1:].decode('utf-8')
        return None
    
    # Cassandra delivers REVERSED bytes - reverse back to logical order
    value_bytes = blob_bytes[4:11][::-1]  # Reverse: 8dca7e31→00 01 99 31 7e ca 8d
    return int.from_bytes(value_bytes, 'little')

# Get single row using command line argument
userid = args.query
first_row = session.execute('SELECT "UserID", ":attrs" FROM userid WHERE "UserID" = %s', [userid]).one()

if not first_row:
    print(f"No user found: {userid}")
    cluster.shutdown()
    exit(1)

print("=== RAW ROW INSPECTION ===")
print("UserID:", first_row.UserID)
print("attrs:", first_row.attrs)
print("Type of attrs:", type(first_row.attrs))
print()

print("=== ATTRS MAP CONTENTS ===")
attrs = first_row.attrs
print("Keys:", list(attrs.keys()))
print("Raw values:")
for k, v in attrs.items():
    print(f"  {k}: {v.hex()} (raw bytes: {v})")
print()

print("=== DECODED VALUES ===")
for k, v in attrs.items():
    decoded = decode_alternator_blob(v)
    print(f"  {k}: {decoded}")

cluster.shutdown()
