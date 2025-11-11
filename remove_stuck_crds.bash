#!/bin/bash

# Usage: ./remove_stuck_crds.bash <resource> <namespace>
# Example: ./remove_stuck_crds.bash scyllaclusters/my-cluster default

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <resource> <namespace>"
    echo "Example: $0 scyllaclusters/my-cluster default"
    exit 1
fi

resource=$1
ns=$2

# Extract resource type and name if in format type/name
if [[ "$resource" == *"/"* ]]; then
    resource_type=${resource%/*}
    resource_name=${resource#*/}
else
    resource_type=$resource
    resource_name=""
fi

# Remove finalizers from the resource(s)
if [ -n "$resource_name" ]; then
    echo "Removing finalizers from $resource in namespace $ns..."
    kubectl -n "$ns" patch "$resource" -p '{"metadata":{"finalizers":[]}}' --type=merge
    echo "Deleting $resource..."
    kubectl -n "$ns" delete "$resource"
else
    echo "Removing finalizers from all $resource_type in namespace $ns..."
    resources=$(kubectl -n "$ns" get "$resource_type" -o name)
    for r in $resources; do
        echo "Patching $r..."
        kubectl -n "$ns" patch "$r" -p '{"metadata":{"finalizers":[]}}' --type=merge
    done
    echo "Deleting all $resource_type..."
    kubectl -n "$ns" delete "$resource_type" --all
fi

