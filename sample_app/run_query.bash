#!/usr/bin/env bash

nodes="node-0.gce-us-west-1.3c28723ec835659dd9f4.clusters.scylla.cloud,node-1.gce-us-west-1.3c28723ec835659dd9f4.clusters.scylla.cloud,node-2.gce-us-west-1.3c28723ec835659dd9f4.clusters.scylla.cloud"
dc='GCE_US_WEST_1'
username='scylla'
password='ucbZ6D8hfSQx7Ik'

./query.py  -u $username -p $password -s "$nodes" --dc "$dc"

