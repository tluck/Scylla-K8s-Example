#!/usr/bin/env bash

[[ -e init.conf ]] && source init.conf

#ng=<nodegroup_name> # replace with your node group name, e.g., "scylla-nodes"
##nodes=( $( kubectl get nodes -o json | jq -r --arg ng "$ng" '.items[] | select(.metadata.labels["eks.amazonaws.com/nodegroup"] == $ng | select(.metadata.labels["node-role.kubernetes.io/control-plane"] != "" )' | jq -r '.metadata.name'  ) )
nodes=( $( kubectl get nodes -o json | jq -r '.items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] != "" )' | jq -r '.metadata.name' ))
num=${#nodes[*]}
n=0
while [ $n -lt $num ]; do 
    printf "Running: kubectl label node ${nodes[$n]} "scylla.scylladb.com/node-type=scylla" --overwrite=true\n"
    # nodes that can run scylla
    kubectl label nodes ${nodes[$n]} "scylla.scylladb.com/node-type=scylla" --overwrite=true
    # to keep non-scylly stuff off the nodes
    # kubectl taint nodes ${nodes[$n]} "scylla-operator.scylladb.com/dedicated=scyllaclusters:NoSchedule"
    n=$((n+1))
done

kubectl get nodes --show-labels
