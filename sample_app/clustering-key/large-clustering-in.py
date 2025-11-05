#!/usr/bin/python3

import sys
import argparse
import time
import random
import asyncio
import requests
from cassandra.cluster import Cluster
from cassandra.auth import PlainTextAuthProvider
from cassandra.policies import DCAwareRoundRobinPolicy

class ClusteringKeyINTester:
    def __init__(self, hosts=['127.0.0.1'], port=9042, keyspace='test_clustering_in', 
                 username=None, password=None):
        self.hosts = hosts
        self.port = port
        self.keyspace = keyspace
        self.cluster = None
        self.session = None
        self.prepared_in_statement = None  # Single prepared statement for IN queries
        
        # Setup authentication if provided
        auth_provider = None
        if username and password:
            auth_provider = PlainTextAuthProvider(username=username, password=password)
        
        # Create cluster connection
        self.cluster = Cluster(
            contact_points=self.hosts,
            port=self.port,
            auth_provider=auth_provider,
            load_balancing_policy=DCAwareRoundRobinPolicy()
        )
        
        try:
            self.session = self.cluster.connect()
            print(f"Connected to ScyllaDB at {self.hosts}:{self.port}")
        except Exception as e:
            print(f"Failed to connect to ScyllaDB: {e}")
            sys.exit(1)
    
    def prepare_statements(self):
        """Prepare statements after keyspace is set"""
        select_query = """
        SELECT partition_id, clustering_key, row_data 
        FROM clustering_test 
        WHERE partition_id = ? AND clustering_key IN ?
        """
        self.prepared_in_statement = self.session.prepare(select_query)
    
    def create_keyspace(self):
        """Create keyspace if it doesn't exist"""
        create_keyspace_query = f"""
        CREATE KEYSPACE IF NOT EXISTS {self.keyspace}
        WITH replication = {{
            'class': 'NetworkTopologyStrategy',
            'dc1': 3
        }}
        """
        try:
            self.session.execute(create_keyspace_query)
            print(f"Keyspace '{self.keyspace}' created or already exists")
        except Exception as e:
            print(f"Error creating keyspace: {e}")
            sys.exit(1)
    
    def use_keyspace(self):
        """Switch to the target keyspace"""
        try:
            self.session.set_keyspace(self.keyspace)
            print(f"Using keyspace '{self.keyspace}'")
        except Exception as e:
            print(f"Error using keyspace: {e}")
            sys.exit(1)
    
    def create_table(self):
        """Create table with clustering key for IN queries"""
        create_table_query = """
        CREATE TABLE IF NOT EXISTS clustering_test (
            partition_id INT,
            clustering_key INT,
            row_data TEXT,
            PRIMARY KEY (partition_id, clustering_key)
        )
        """
        try:
            self.session.execute(create_table_query)
            print("Table 'clustering_test' created or already exists")
        except Exception as e:
            print(f"Error creating table: {e}")
            sys.exit(1)
    
    def generate_row_data(self, size_bytes=100):
        """Generate random row data of specified size"""
        # Create data to fill the specified size
        chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return ''.join(random.choice(chars) for _ in range(size_bytes))
    
    def insert_rows(self, num_rows=1000, row_size=100):
        """Insert specified number of rows into a single partition"""
        insert_query = """
        INSERT INTO clustering_test (partition_id, clustering_key, row_data)
        VALUES (?, ?, ?)
        """
        prepared_stmt = self.session.prepare(insert_query)
        
        print(f"Inserting {num_rows} rows of {row_size} bytes each into partition 1...")
        
        start_time = time.time()
        partition_id = 1  # Use a single partition
        
        for i in range(num_rows):
            clustering_key = i
            row_data = self.generate_row_data(row_size)
            
            try:
                self.session.execute(prepared_stmt, (partition_id, clustering_key, row_data))
                if (i + 1) % 100 == 0:
                    print(f"  Inserted {i+1}/{num_rows} rows")
            except Exception as e:
                print(f"  Error inserting row {i+1}: {e}")
                continue
        
        end_time = time.time()
        total_time = end_time - start_time
        total_size_mb = (num_rows * row_size) / (1024 * 1024)
        
        print(f"\nInsertion completed:")
        print(f"  Total time: {total_time:.2f} seconds")
        print(f"  Total data: {total_size_mb:.2f} MB")
        print(f"  Throughput: {num_rows/total_time:.0f} rows/s")
        
        return list(range(num_rows))  # Return available clustering keys
    
    def flush_memtables(self):
        """Flush memtables via ScyllaDB REST API"""
        # Try each host to find one that responds
        for host in self.hosts:
            try:
                url = f"http://{host}:10000/storage_service/keyspace_flush/{self.keyspace}"
                print(f"Flushing memtables for keyspace '{self.keyspace}' on {host}:10000...")
                
                response = requests.post(url, timeout=30)
                if response.status_code == 200:
                    print("  Memtable flush completed successfully")
                    return
                else:
                    print(f"  Flush request returned status {response.status_code}: {response.text}")
            except requests.exceptions.RequestException as e:
                print(f"  Failed to flush on {host}:10000: {e}")
                continue
        
        print("  Warning: Could not flush memtables on any host")
    
    async def perform_in_query(self, clustering_keys, query_id=0):
        """Perform a single IN query with the specified clustering keys"""
        start_time = time.time()
        
        try:
            # Execute with partition_id=1 and clustering_keys as a list
            rows = self.session.execute(self.prepared_in_statement, (1, clustering_keys))
            row_count = 0
            total_data_size = 0
            
            for row in rows:
                row_count += 1
                total_data_size += len(row.row_data)
            
            end_time = time.time()
            query_time = end_time - start_time
            
            return {
                'query_id': query_id,
                'rows_retrieved': row_count,
                'data_size_bytes': total_data_size,
                'query_time': query_time,
                'success': True
            }
            
        except Exception as e:
            end_time = time.time()
            query_time = end_time - start_time
            
            return {
                'query_id': query_id,
                'rows_retrieved': 0,
                'data_size_bytes': 0,
                'query_time': query_time,
                'success': False,
                'error': str(e)
            }
    
    async def run_concurrent_in_queries(self, available_keys, in_query_size=50, concurrency=50, duration_seconds=10):
        """Run concurrent IN queries for a specified duration"""
        print(f"\nRunning concurrent IN queries for {duration_seconds} seconds:")
        print(f"  IN query size: {in_query_size} clustering keys")
        print(f"  Concurrency level: {concurrency}")
        
        start_time = time.time()
        end_time = start_time + duration_seconds
        
        # Create semaphore to limit concurrency
        semaphore = asyncio.Semaphore(concurrency)
        
        # Counter for query IDs
        query_counter = 0
        results = []
        active_tasks = set()
        
        async def run_single_query():
            nonlocal query_counter
            async with semaphore:
                # Randomly select clustering keys for the IN query
                query_keys = random.sample(available_keys, min(in_query_size, len(available_keys)))
                current_query_id = query_counter
                query_counter += 1
                return await self.perform_in_query(query_keys, current_query_id)
        
        # Keep launching queries until time is up
        while time.time() < end_time:
            # Clean up completed tasks
            if active_tasks:
                done_tasks = [task for task in active_tasks if task.done()]
                for task in done_tasks:
                    active_tasks.remove(task)
                    try:
                        result = await task
                        results.append(result)
                    except Exception as e:
                        print(f"  Query {query_counter}: Exception - {e}")
                        results.append({
                            'query_id': query_counter,
                            'rows_retrieved': 0,
                            'data_size_bytes': 0,
                            'query_time': 0,
                            'success': False,
                            'error': str(e)
                        })
            
            # Launch new queries if we have capacity and time remaining
            while len(active_tasks) < concurrency * 2 and time.time() < end_time:
                task = asyncio.create_task(run_single_query())
                active_tasks.add(task)
            
            # Small sleep to prevent busy waiting
            await asyncio.sleep(0.01)
        
        # Wait for remaining tasks to complete
        if active_tasks:
            remaining_results = await asyncio.gather(*active_tasks, return_exceptions=True)
            for i, result in enumerate(remaining_results):
                if isinstance(result, Exception):
                    print(f"  Query: Exception - {result}")
                    results.append({
                        'query_id': query_counter + i,
                        'rows_retrieved': 0,
                        'data_size_bytes': 0,
                        'query_time': 0,
                        'success': False,
                        'error': str(result)
                    })
                else:
                    results.append(result)
        
        actual_end_time = time.time()
        total_time = actual_end_time - start_time
        
        # Calculate statistics
        successful_queries = [r for r in results if r['success']]
        failed_queries = [r for r in results if not r['success']]
        
        if successful_queries:
            total_rows = sum(r['rows_retrieved'] for r in successful_queries)
            total_data_mb = sum(r['data_size_bytes'] for r in successful_queries) / (1024 * 1024)
            avg_query_time = sum(r['query_time'] for r in successful_queries) / len(successful_queries)
            min_query_time = min(r['query_time'] for r in successful_queries)
            max_query_time = max(r['query_time'] for r in successful_queries)
        else:
            total_rows = total_data_mb = avg_query_time = min_query_time = max_query_time = 0
        
        print(f"\nQuery execution completed:")
        print(f"  Actual runtime: {total_time:.2f} seconds")
        print(f"  Total queries executed: {len(results)}")
        print(f"  Successful queries: {len(successful_queries)}")
        print(f"  Failed queries: {len(failed_queries)}")
        print(f"  Total rows retrieved: {total_rows}")
        print(f"  Total data retrieved: {total_data_mb:.2f} MB")
        print(f"  Query throughput: {len(successful_queries)/total_time:.1f} queries/s")
        if successful_queries:
            print(f"  Average query time: {avg_query_time:.3f} seconds")
            print(f"  Min query time: {min_query_time:.3f} seconds")
            print(f"  Max query time: {max_query_time:.3f} seconds")
        
        if failed_queries:
            print(f"\nFailed queries:")
            for failed in failed_queries[:5]:  # Show first 5 failures
                print(f"  Query {failed['query_id']}: {failed.get('error', 'Unknown error')}")
        
        return results
    
    def cleanup_table(self):
        """Drop the clustering test table"""
        try:
            self.session.execute("DROP TABLE IF EXISTS clustering_test")
            print("Table 'clustering_test' dropped")
        except Exception as e:
            print(f"Error dropping table: {e}")
    
    def close(self):
        """Close the database connection"""
        if self.cluster:
            self.cluster.shutdown()
            print("Database connection closed")

async def main():
    parser = argparse.ArgumentParser(description='ScyllaDB Clustering Key IN Query Test')
    parser.add_argument('--hosts', default='127.0.0.1', 
                       help='Comma-separated list of ScyllaDB hosts (default: 127.0.0.1)')
    parser.add_argument('--port', type=int, default=9042,
                       help='ScyllaDB port (default: 9042)')
    parser.add_argument('--keyspace', default='test_clustering_in',
                       help='Keyspace name (default: test_clustering_in)')
    parser.add_argument('--username', help='Username for authentication')
    parser.add_argument('--password', help='Password for authentication')
    parser.add_argument('--num-rows', type=int, default=1000,
                       help='Number of rows in the partition (default: 1000)')
    parser.add_argument('--row-size', type=int, default=100,
                       help='Size of each row in bytes (default: 100)')
    parser.add_argument('--in-query-size', type=int, default=50,
                       help='Number of clustering keys in IN query (default: 50)')
    parser.add_argument('--concurrency', type=int, default=50,
                       help='Concurrency of read requests (default: 50)')
    parser.add_argument('--duration', type=int, default=10,
                       help='Duration to run queries in seconds (default: 10)')
    parser.add_argument('--cleanup', action='store_true',
                       help='Drop the table after test')
    parser.add_argument('--query-only', action='store_true',
                       help='Only run queries, do not insert new data')
    
    args = parser.parse_args()
    
    # Parse hosts
    hosts = [host.strip() for host in args.hosts.split(',')]
    
    # Create tester instance
    tester = ClusteringKeyINTester(
        hosts=hosts,
        port=args.port,
        keyspace=args.keyspace,
        username=args.username,
        password=args.password
    )
    
    try:
        # Setup database
        tester.create_keyspace()
        tester.use_keyspace()
        tester.create_table()
        
        # Prepare statements after keyspace and table are ready
        tester.prepare_statements()
        
        if not args.query_only:
            # Insert rows into partition
            available_keys = tester.insert_rows(
                num_rows=args.num_rows, 
                row_size=args.row_size
            )
            
            # Flush memtables to ensure data is written to SSTables
            tester.flush_memtables()
        else:
            # Assume keys 0 to num_rows-1 exist
            available_keys = list(range(args.num_rows))
            print(f"Using existing data with {args.num_rows} rows")
        
        # Run concurrent IN queries
        results = await tester.run_concurrent_in_queries(
            available_keys=available_keys,
            in_query_size=args.in_query_size,
            concurrency=args.concurrency,
            duration_seconds=args.duration
        )
        
        if args.cleanup:
            tester.cleanup_table()
            
    except KeyboardInterrupt:
        print("\nOperation interrupted by user")
    finally:
        tester.close()

if __name__ == "__main__":
    asyncio.run(main())

