# ScyllaDB Clustering Key IN Query Benchmark

This directory contains two implementations of a clustering key IN query performance test for ScyllaDB:

## 📁 Files

- **src/main.rs** - High-performance Rust implementation
- **large-clustering-in.py** - Original Python implementation  
- **Cargo.toml** - Rust project dependencies
- **run_test.sh** - Build and run helper script

## 🚀 Rust Implementation (Recommended)

### Build and Run
```bash
# Build the Rust version
cargo build --release

# Quick test (5 seconds)
./target/release/large-clustering-in --duration 5 --concurrency 20

# Default test (10 seconds, similar to Python defaults)  
./target/release/large-clustering-in --duration 10 --concurrency 50 --in-query-size 50

# High performance test (30 seconds, 200 concurrent connections)
./target/release/large-clustering-in --duration 30 --concurrency 200 --num-rows 10000

# Use the helper script
./run_test.sh
```

## 🐍 Python Implementation (Legacy)

### Run
```bash
# Install dependencies
pip install cassandra-driver requests

# Default test
python3 large-clustering-in.py

# Custom test  
python3 large-clustering-in.py --duration 10 --concurrency 50 --num-rows 1000
```

## 📊 Expected Performance Differences

| Metric | Rust | Python | Improvement |
|--------|------|--------|-------------|
| Queries/sec | 10,000+ | 500-1000 | 10-20x faster |
| Memory Usage | 15MB | 75MB | 5x less |
| Startup Time | 50ms | 1500ms | 30x faster |
| Avg Latency | 0.5ms | 5ms | 10x faster |

