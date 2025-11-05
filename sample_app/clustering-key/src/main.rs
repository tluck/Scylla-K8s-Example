use anyhow::Result;
use clap::Parser;
use futures::future::join_all;
use rand::seq::SliceRandom;
use rand::Rng;
use scylla::prepared_statement::PreparedStatement;
use scylla::{Session, SessionBuilder};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Semaphore;

#[derive(Parser, Debug)]
#[command(name = "large-clustering-in")]
#[command(about = "ScyllaDB Clustering Key IN Query Test")]
struct Args {
    #[arg(long, default_value = "127.0.0.1")]
    hosts: String,

    #[arg(long, default_value_t = 9042)]
    port: u16,

    #[arg(long, default_value = "test_clustering_in")]
    keyspace: String,

    #[arg(long)]
    username: Option<String>,

    #[arg(long)]
    password: Option<String>,

    #[arg(long, default_value_t = 1000)]
    num_rows: u32,

    #[arg(long, default_value_t = 100)]
    row_size: usize,

    #[arg(long, default_value_t = 50)]
    in_query_size: usize,

    #[arg(long, default_value_t = 50)]
    concurrency: usize,

    #[arg(long, default_value_t = 10)]
    duration: u64,

    #[arg(long)]
    cleanup: bool,

    #[arg(long)]
    query_only: bool,
}

#[derive(Debug, Clone)]
struct QueryResult {
    query_id: usize,
    rows_retrieved: usize,
    data_size_bytes: usize,
    query_time: Duration,
    success: bool,
    error: Option<String>,
}

struct ClusteringKeyINTester {
    session: Arc<Session>,
    keyspace: String,
    prepared_in_statement: Option<PreparedStatement>,
    hosts: Vec<String>,
}

impl ClusteringKeyINTester {
    async fn new(args: &Args) -> Result<Self> {
        let hosts: Vec<String> = args.hosts.split(',').map(|h| h.trim().to_string()).collect();
        
        println!("Connecting to ScyllaDB at {}:{}...", args.hosts, args.port);

        let mut session_builder = SessionBuilder::new().known_nodes(&hosts);
        
        if let (Some(username), Some(password)) = (&args.username, &args.password) {
            session_builder = session_builder.user(username, password);
        }

        let session = Arc::new(session_builder.build().await?);
        println!("Connected to ScyllaDB successfully");

        Ok(Self {
            session,
            keyspace: args.keyspace.clone(),
            prepared_in_statement: None, // Will be set later
            hosts,
        })
    }

    async fn create_keyspace(&self) -> Result<()> {
        let query = format!(
            "CREATE KEYSPACE IF NOT EXISTS {} WITH replication = {{
                'class': 'NetworkTopologyStrategy',
                'datacenter1': 1
            }}",
            self.keyspace
        );

        self.session.query(query, &[]).await?;
        println!("Keyspace '{}' created or already exists", self.keyspace);
        Ok(())
    }

    async fn use_keyspace(&self) -> Result<()> {
        self.session.use_keyspace(&self.keyspace, false).await?;
        println!("Using keyspace '{}'", self.keyspace);
        Ok(())
    }

    async fn create_table(&self) -> Result<()> {
        let query = "
            CREATE TABLE IF NOT EXISTS clustering_test (
                partition_id INT,
                clustering_key INT,
                row_data TEXT,
                PRIMARY KEY (partition_id, clustering_key)
            )
        ";

        self.session.query(query, &[]).await?;
        println!("Table 'clustering_test' created or already exists");
        Ok(())
    }

    async fn prepare_statements(&mut self) -> Result<()> {
        let query = "
            SELECT partition_id, clustering_key, row_data 
            FROM clustering_test 
            WHERE partition_id = ? AND clustering_key IN ?
        ";
        
        self.prepared_in_statement = Some(self.session.prepare(query).await?);
        println!("Prepared statements ready");
        Ok(())
    }

    fn generate_row_data(&self, size_bytes: usize) -> String {
        const CHARS: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        let mut rng = rand::thread_rng();
        
        (0..size_bytes)
            .map(|_| CHARS[rng.gen_range(0..CHARS.len())] as char)
            .collect()
    }

    async fn insert_rows(&self, num_rows: u32, row_size: usize) -> Result<Vec<i32>> {
        let insert_query = "
            INSERT INTO clustering_test (partition_id, clustering_key, row_data)
            VALUES (?, ?, ?)
        ";
        
        let prepared_insert = self.session.prepare(insert_query).await?;
        
        
        let start_time = Instant::now();
        //let partition_id = 1i32;
        
        // Use semaphore to limit concurrent inserts for better control
        let semaphore = Arc::new(Semaphore::new(100)); // Limit concurrent inserts
        let mut handles = Vec::new();
        
        let num_keys=num_rows/1000;
        println!("Inserting {} rows each into each partition ",num_keys);
        for j in 1..1001 {
          for i in 0..num_keys {
            let session = self.session.clone();
            let prepared = prepared_insert.clone();
            let permit = semaphore.clone().acquire_owned().await?;
            let row_data = self.generate_row_data(row_size);
            
            let handle = tokio::spawn(async move {
                let _permit = permit;
                let clustering_key = i as i32;
                //let partition_id: i32 = rand::thread_rng().gen_range(1..=96);
                let partition_id = j as i32;
                
                match session.execute(&prepared, (partition_id, clustering_key, row_data)).await {
                    Ok(_) => {
                        if (i + 1) % 1000 == 0 {
                            //println!("  Inserted {}/{} rows", i + 1, num_keys);
                        }
                        Ok(())
                    }
                    Err(e) => {
                        eprintln!("  Error inserting row {}: {}", i + 1, e);
                        Err(e)
                    }
                }
            });
            
            handles.push(handle);
        }
      }
        // Wait for all inserts to complete
        let results: Vec<_> = join_all(handles).await;
        let successful_inserts = results.iter().filter(|r| r.as_ref().unwrap().is_ok()).count();
        
        let total_time = start_time.elapsed();
        let total_size_mb = (num_rows as f64 * row_size as f64) / (1024.0 * 1024.0);
        
        println!("\nInsertion completed:");
        println!("  Total time: {:.2} seconds", total_time.as_secs_f64());
        println!("  Total data: {:.2} MB", total_size_mb);
        println!("  Successful inserts: {}/{}", successful_inserts, num_rows);
        println!("  Throughput: {:.0} rows/s", num_keys as f64 / total_time.as_secs_f64());
        
        Ok((0..num_rows as i32).collect())
    }

    async fn flush_memtables(&self) -> Result<()> {
        for host in &self.hosts {
            let url = format!("http://{}:10000/storage_service/keyspace_flush/{}", host, self.keyspace);
            println!("Flushing memtables for keyspace '{}' on {}:10000...", self.keyspace, host);
            
            match reqwest::Client::new()
                .post(&url)
                .timeout(Duration::from_secs(30))
                .send()
                .await
            {
                Ok(response) if response.status().is_success() => {
                    println!("  Memtable flush completed successfully");
                    return Ok(());
                }
                Ok(response) => {
                    let status = response.status();
                    let text = response.text().await.unwrap_or_default();
                    println!("  Flush request returned status {}: {}", status, text);
                }
                Err(e) => {
                    println!("  Failed to flush on {}:10000: {}", host, e);
                    continue;
                }
            }
        }
        
        println!("  Warning: Could not flush memtables on any host");
        Ok(())
    }

    async fn run_concurrent_in_queries(
        &self,
        available_keys: &[i32],
        in_query_size: usize,
        concurrency: usize,
        duration_seconds: u64,
    ) -> Result<Vec<QueryResult>> {
        println!("\nRunning concurrent IN queries for {} seconds:", duration_seconds);
        println!("  IN query size: {} clustering keys", in_query_size);
        println!("  Concurrency level: {}", concurrency);

        let prepared_stmt = self.prepared_in_statement.as_ref().unwrap();
        let start_time = Instant::now();
        let duration = Duration::from_secs(duration_seconds);
        let semaphore = Arc::new(Semaphore::new(concurrency));
        
        let mut results = Vec::new();
        let mut query_counter = 0;
        let mut handles: Vec<tokio::task::JoinHandle<QueryResult>> = Vec::new();
        
        // Keep launching queries until time is up
        while start_time.elapsed() < duration {
            // Clean up completed tasks
            let mut completed_indices = Vec::new();
            for (i, handle) in handles.iter().enumerate() {
                if handle.is_finished() {
                    completed_indices.push(i);
                }
            }
            
            // Remove completed handles from back to front to maintain indices
            for &i in completed_indices.iter().rev() {
                let handle = handles.remove(i);
                match handle.await {
                    Ok(result) => results.push(result),
                    Err(e) => {
                        eprintln!("Query task failed: {}", e);
                        results.push(QueryResult {
                            query_id: query_counter,
                            rows_retrieved: 0,
                            data_size_bytes: 0,
                            query_time: Duration::default(),
                            success: false,
                            error: Some(e.to_string()),
                        });
                    }
                }
            }
            
            // Launch new queries if we have capacity and time remaining
            while handles.len() < concurrency * 2 && start_time.elapsed() < duration {
                // Try to acquire permit without blocking
                if let Ok(permit) = semaphore.clone().try_acquire_owned() {
                    // Randomly select clustering keys for the IN query
                    let mut rng = rand::thread_rng();
                    let query_keys: Vec<i32> = available_keys
                        .choose_multiple(&mut rng, in_query_size.min(available_keys.len()))
                        .cloned()
                        .collect();
                    let partition_id: i32 = rand::thread_rng().gen_range(1..=1000);
                    
                    let current_query_id = query_counter;
                    query_counter += 1;
                    
                    let session = self.session.clone();
                    let prepared = prepared_stmt.clone();
                    
                    let handle = tokio::spawn(async move {
                        let _permit = permit;
                        let start_time = Instant::now();
                        
                        //println!("partition_id {} query_keys {:#?}", partition_id, query_keys);
                        match session.execute(&prepared, (partition_id, query_keys)).await {
                            Ok(rows) => {
                                let mut row_count = 0;
                                let mut total_data_size = 0;
                                
                                if let Some(rows) = rows.rows {
                                    for row in rows {
                                        row_count += 1;
                                        if let Some(Some(scylla::frame::response::result::CqlValue::Text(data))) = row.columns.get(2) {
                                            total_data_size += data.len();
                                        }
                                    }
                                }
                                
                                QueryResult {
                                    query_id: current_query_id,
                                    rows_retrieved: row_count,
                                    data_size_bytes: total_data_size,
                                    query_time: start_time.elapsed(),
                                    success: true,
                                    error: None,
                                }
                            }
                            Err(e) => QueryResult {
                                query_id: current_query_id,
                                rows_retrieved: 0,
                                data_size_bytes: 0,
                                query_time: start_time.elapsed(),
                                success: false,
                                error: Some(e.to_string()),
                            },
                        }
                    });
                    
                    handles.push(handle);
                } else {
                    // No permits available, wait a bit
                    tokio::time::sleep(Duration::from_millis(1)).await;
                    break;
                }
            }
            
            // Small sleep to prevent busy waiting
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        
        // Wait for remaining tasks to complete
        let remaining_results: Vec<_> = join_all(handles).await;
        for result in remaining_results {
            match result {
                Ok(query_result) => results.push(query_result),
                Err(e) => {
                    eprintln!("Query task failed: {}", e);
                    results.push(QueryResult {
                        query_id: query_counter,
                        rows_retrieved: 0,
                        data_size_bytes: 0,
                        query_time: Duration::default(),
                        success: false,
                        error: Some(e.to_string()),
                    });
                }
            }
        }
        
        let actual_end_time = start_time.elapsed();
        
        // Calculate statistics
        let successful_queries: Vec<_> = results.iter().filter(|r| r.success).collect();
        let failed_queries: Vec<_> = results.iter().filter(|r| !r.success).collect();
        
        let (total_rows, total_data_mb, avg_query_time, min_query_time, max_query_time) = if !successful_queries.is_empty() {
            let total_rows: usize = successful_queries.iter().map(|r| r.rows_retrieved).sum();
            let total_data_mb = successful_queries.iter().map(|r| r.data_size_bytes).sum::<usize>() as f64 / (1024.0 * 1024.0);
            let avg_query_time = successful_queries.iter().map(|r| r.query_time.as_secs_f64()).sum::<f64>() / successful_queries.len() as f64;
            let min_query_time = successful_queries.iter().map(|r| r.query_time.as_secs_f64()).fold(f64::INFINITY, f64::min);
            let max_query_time = successful_queries.iter().map(|r| r.query_time.as_secs_f64()).fold(0.0, f64::max);
            (total_rows, total_data_mb, avg_query_time, min_query_time, max_query_time)
        } else {
            (0, 0.0, 0.0, 0.0, 0.0)
        };
        
        println!("\nQuery execution completed:");
        println!("  Actual runtime: {:.2} seconds", actual_end_time.as_secs_f64());
        println!("  Total queries executed: {}", results.len());
        println!("  Successful queries: {}", successful_queries.len());
        println!("  Failed queries: {}", failed_queries.len());
        println!("  Total rows retrieved: {}", total_rows);
        println!("  Total data retrieved: {:.2} MB", total_data_mb);
        println!("  Query throughput: {:.1} queries/s", successful_queries.len() as f64 / actual_end_time.as_secs_f64());
        
        if !successful_queries.is_empty() {
            println!("  Average query time: {:.3} seconds", avg_query_time);
            println!("  Min query time: {:.3} seconds", min_query_time);
            println!("  Max query time: {:.3} seconds", max_query_time);
        }
        
        if !failed_queries.is_empty() {
            println!("\nFailed queries:");
            for (i, failed) in failed_queries.iter().enumerate().take(5) {
                println!("  Query {}: {}", failed.query_id, failed.error.as_ref().unwrap_or(&"Unknown error".to_string()));
            }
        }
        
        Ok(results)
    }

    async fn cleanup_table(&self) -> Result<()> {
        self.session.query("DROP TABLE IF EXISTS clustering_test", &[]).await?;
        println!("Table 'clustering_test' dropped");
        Ok(())
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    
    let mut tester = ClusteringKeyINTester::new(&args).await?;
    
    // Setup database
    tester.create_keyspace().await?;
    tester.use_keyspace().await?;
    tester.create_table().await?;
    tester.prepare_statements().await?;
    
    let available_keys = if !args.query_only {
        // Insert rows into partition
        let keys = tester.insert_rows(args.num_rows, args.row_size).await?;
        
        // Flush memtables to ensure data is written to SSTables
        tester.flush_memtables().await?;
        
        keys
    } else {
        // Assume keys 0 to num_rows-1 exist
        let keys: Vec<i32> = (0..args.num_rows as i32).collect();
        println!("Using existing data with {} rows", args.num_rows);
        keys
    };
    
    // Run concurrent IN queries
    let _results = tester
        .run_concurrent_in_queries(&available_keys, args.in_query_size, args.concurrency, args.duration)
        .await?;
    
    if args.cleanup {
        tester.cleanup_table().await?;
    }
    
    println!("Test completed successfully");
    Ok(())
}
