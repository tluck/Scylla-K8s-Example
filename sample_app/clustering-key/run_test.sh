#!/bin/bash

# Build and run the Rust clustering key IN query test

echo "Building Rust clustering test..."
cargo build --release

if [ $? -eq 0 ]; then
    echo "Build successful! Running test..."
    echo "Usage: ./target/release/large-clustering-in [OPTIONS]"
    echo ""
    echo "Example runs:"
    echo "  # Basic test (10 seconds, 50 concurrency, 50 keys per IN query)"
    echo "  ./target/release/large-clustering-in"
    echo ""
    echo "  # High performance test"
    echo "  ./target/release/large-clustering-in --duration 30 --concurrency 200 --num-rows 10000"
    echo ""
    echo "  # Quick test"
    echo "  ./target/release/large-clustering-in --duration 5 --concurrency 20 --num-rows 1000"
    echo ""
    echo "Available options:"
    ./target/release/large-clustering-in --help
else
    echo "Build failed. Please install Rust and try again:"
    echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
fi
