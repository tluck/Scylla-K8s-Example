#!/usr/bin/env python3
"""
ScyllaDB Alternator CQL cleanup (streaming):
Keep only the latest row per UserID using token-range partition scan.
Efficient for millions of partitions, avoids ALLOW FILTERING.
"""

from cassandra.cluster import Cluster, PlainTextAuthProvider
from cassandra.query import SimpleStatement
import time
import argparse

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('-s', '--hosts', default="scylla-client.scylla-dc1.svc")
    parser.add_argument('-u', '--username', default="cassandra")
    parser.add_argument('-p', '--password', default="cassandra")
    parser.add_argument('--batch_size', type=int, default=1000)
    parser.add_argument('--token-step', type=int, default=2**64 // 32, help='Number of tokens per range')
    return parser.parse_args()

args = parse_args()
KEYSPACE = "alternator_userid"
TABLE = "userid"

def connect_scylla():
    cluster = Cluster(
        contact_points=[args.hosts],
        port=9042,
        auth_provider=PlainTextAuthProvider(username=args.username, password=args.password)
    )
    return cluster.connect(KEYSPACE)

def get_token_ranges():
    """Yield non-overlapping token ranges across Murmur3 token space (-2^63 to 2^63-1)."""
    start = -2**63
    while start < 2**63:
        end = min(start + args.token_step, 2**63 - 1)
        yield (start, end)
        start = end + 1

def cleanup_range(session, start_token, end_token):
    max_stmt = session.prepare(f'SELECT MAX("LastUpdated") FROM {TABLE} WHERE "UserID" = ?')
    delete_stmt = session.prepare(f'DELETE FROM {TABLE} WHERE "UserID" = ? AND "LastUpdated" < ?')
    total_deleted = 0

    # stream partition keys in the token range
    range_stmt = SimpleStatement(
        f'SELECT "UserID" FROM {TABLE} WHERE TOKEN("UserID") > %s AND TOKEN("UserID") <= %s',
        fetch_size=args.batch_size
    )
    result = session.execute(range_stmt, (start_token, end_token))

    for row in result:
        user_id = row[0]
        try:
            max_row = session.execute(max_stmt, [user_id]).one()
            if not max_row or not max_row[0]:
                continue
            max_ts = max_row[0]
            session.execute(delete_stmt, [user_id, max_ts])
            total_deleted += 1
        except Exception as e:
            print(f"⚠️ {user_id}: {e}")

    print(f"Range {start_token}–{end_token}: processed {total_deleted} partitions")
    return total_deleted

def main():
    session = connect_scylla()
    total_deleted = 0
    start_time = time.time()

    try:
        for start_token, end_token in get_token_ranges():
            deleted = cleanup_range(session, start_token, end_token)
            total_deleted += deleted
            time.sleep(0.05)  # let compactions breathe
    finally:
        session.cluster.shutdown()
        session.shutdown()

    elapsed = time.time() - start_time
    print(f"\n✅ DONE: deleted {total_deleted:,} old rows in {elapsed:.1f}s")

if __name__ == "__main__":
    main()
