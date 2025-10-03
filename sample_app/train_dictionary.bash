#!/usr/bin/env bash

curl -X POST "http://<node-address>:10000/storage_service/retrain_dict?keyspace=<keyspace>&cf=<table>"

curl -X GET "http://<node-address>:10000/storage_service/estimate_compression_ratios?keyspace=<keyspace>&cf=<table>"
