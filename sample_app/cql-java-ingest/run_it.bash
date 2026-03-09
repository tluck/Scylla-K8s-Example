#!/usr/bin/env bash

mode=${1:-concurrent}
ver=5.0

java -jar target/scylla-loader-${ver}.jar \
  -k mercado \
  -t userid \
  -u ${USERNAME:-cassandra} \
  -p ${PASSWORD:-cassandra} \
  --dc ${DC:-dc1} \
  -s ${CONTACT_POINTS:-scylla-client} \
  -w 4 \
  -r 1000000 \
  --batch_mode ${mode} \
  --batch_size 1000 \
  -c 200 \
  -d -v
