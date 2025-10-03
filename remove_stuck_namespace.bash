#!/bin/bash

namespace=${1:-scylla-manager}

kubectl get namespace $namespace -o json | jq '.spec.finalizers=[]' | kubectl replace --raw "/api/v1/namespaces/$namespace/finalize" -f -

