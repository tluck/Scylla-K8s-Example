#!/usr/bin/env bash

java -cp target/alternator-loader-1.0-SNAPSHOT.jar AlternatorUserIdLoader \
  -u ${USERNAME:-cassandra} \
  -p ${PASSWORD:-cassandra} \
  --dc ${DC:-dc1} \
  -s ${CONTACT_POINTS:-scylla-client} \
  --keyspace alternator_userid \
  --num-inserts 10000 \
  --user-id-start 1
