#!/usr/bin/env bash

nodes=${NODE_LIST:-scylla-client}
dc=${DC:-dc1}
username=${USERNAME:-cassandra}
password=${PASSWORD:-cassandra}

./loader.py -r $1 -u $username -p $password -s "$nodes" --dc "$dc"

