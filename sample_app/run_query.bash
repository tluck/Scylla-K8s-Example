#!/usr/bin/env bash

nodes=${NODE_LIST:-scylla-client}
dc=${DC:-dc1}
username=${USERNAME:-cassandra}
password=${PASSWORD:-cassandra}
if [[ $1 == -* ]] ;then
opts="$*"
fi

./query.py -u $username -p $password -s "$nodes" --dc "$dc" $opts
