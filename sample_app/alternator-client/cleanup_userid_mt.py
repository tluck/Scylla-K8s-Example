#!/usr/bin/env python3
"""
ScyllaDB Alternator cleanup (parallel token-range):
Keeps only the latest row per UserID.
Streams and deletes across multiple concurrent token ranges.
"""

from cassandra.cluster import Cluster, PlainTextAuthProvider
from cassandra.query import SimpleStatement
from concurrent.futures import ThreadPoolExecutor, as_completed
import time
import argparse

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('-s', '--hosts', default="scylla-client.scylla-dc1.svc")
    parser.add_argument('-u', '--username', default="cassandra")
    parser.add_argument('-p', '--password', default="cassandra")
    parser.add_argument('--batch_size', type=int, default=1000)
    parser.add_argument('--token-step', type=int, default=2**64 // 64,
                        help='Token range width per thread')
    parser.add_argument('--parallelism', type=int, default=8,
                        help='Number of parallel ranges to process')
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
    start = -2**63
    while start < 2**63:
        end = min(start + args.token_step, 2**63 - 1)
        yield (start, end)
        start = end + 1

def cleanup_range(start_token, end_token):
    session = connect_scylla()
    total_deleted = 0
    try:
        max_stmt = session.prepare(f'SELECT MAX("LastUpdated") FROM {TABLE} WHERE "UserID" = ?')
        delete_stmt = session.prepare(f'DELETE FROM {TABLE} WHERE "UserID" = ? AND "LastUpdated" < ?')
        range_stmt = SimpleStatement(
            f'SELECT "UserID" FROM {TABLE} WHERE TOKEN("UserID") > %s AND TOKEN("UserID") <= %s',
            fetch_size=args.batch_size
        )

        result = session.execute(range_stmt, (start_token, end_token))
        for row in result:
            user_id = row[0]
            try:
                max_ts = session.execute(max_stmt, [user_id]).one()[0]
                if not max_ts:
                    continue
                session.execute(delete_stmt, [user_id, max_ts])
                total_deleted += 1
            except Exception as e:
                print(f"⚠️ range {start_token}:{end_token} user {user_id}: {e}")
    finally:
        session.cluster.shutdown()
        session.shutdown()
    print(f"✓ Range {start_token}–{end_token}: deleted {total_deleted}")
    return total_deleted

def main():
    start_time = time.time()
    ranges = list(get_token_ranges())
    deleted_total = 0

    print(f"Starting cleanup across {len(ranges)} ranges with {args.parallelism} workers...")

    with ThreadPoolExecutor(max_workers=args.parallelism) as executor:
        futures = {executor.submit(cleanup_range, s, e): (s, e) for s, e in ranges}
        for future in as_completed(futures):
            deleted_total += future.result()

    elapsed = time.time() - start_time
    print(f"\n✅ Finished. Deleted ~{deleted_total:,} old rows in {elapsed:.1f}s")

if __name__ == "__main__":
    main()

