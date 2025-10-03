#!/bin/bash

crd=$1
ns=$2

ns=$(kubectl get $crd -A -o json | jq -r '.items[].metadata.namespace' )
kubectl get crds ${crd%/*} -A -o name
kubectl get ${crd%/*} -A -o name
kubectl -n $ns get ${crd}
kubectl -n $ns patch $crd -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl -n $ns get    $crd
kubectl -n $ns delete $crd

