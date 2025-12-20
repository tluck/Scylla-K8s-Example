#!/usr/bin/env bash

# curl -X POST "http://<node-address>:10000/storage_service/retrain_dict?keyspace=<keyspace>&cf=<table>"
# curl -X GET "http://<node-address>:10000/storage_service/estimate_compression_ratios?keyspace=<keyspace>&cf=<table>"

keyspace=mykeyspace
table=comp_w_zstd_dict

printf "Retraining $keyspace.$table\n"
curl -sq -X POST "http://scylla-client:10000/storage_service/retrain_dict?keyspace=${keyspace}&cf=${table}"
printf "Getting compression stats for $keyspace.$table\n"
curl -sq -X GET "http://scylla-client:10000/storage_service/estimate_compression_ratios?keyspace=${keyspace}&cf=${table}" | jq '.[] | select(.chunk_length_in_kb == 16 and (.dict == "past" or .dict == "none") and .level == 3)'
