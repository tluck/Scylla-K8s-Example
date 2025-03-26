#!/usr/bin/env bash

[[ -e init.conf ]] && source init.conf

nodes=( $( kubectl get nodes -o json | jq -r '.items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] != "" )' | jq -r '.metadata.name' ))
num=${#nodes[*]}
n=0
while [ $n -lt $num ]; do 
    printf "Running: kubectl label node ${nodes[$n]} "scylla.scylladb.com/node-type=scylla" --overwrite=true\n"
    kubectl label nodes ${nodes[$n]} "scylla.scylladb.com/node-type=scylla" --overwrite=true
    n=$((n+1))
done

kubectl get nodes --show-labels
