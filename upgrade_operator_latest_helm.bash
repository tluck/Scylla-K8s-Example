#!/usr/bin/env bash

source init.conf

operatorTag=${1:-latest}

cat templateOperator.yaml | sed \
  -e "s|REPOSITORY|${operatorRepository}|g" \
  -e "s|IMAGETAG|${operatorTag}|g" \
  -e "s|NODESELECTOR|${nodeSelector1}|g" \
  > scylla-operator.yaml

#[[ ${operatorTag} == "latest" ]] && repo=scylla-latest || repo=scylla

find scylla-latest/scylla-operator/crds/ -name '*.yaml' -exec printf -- '-f=%s ' {} + | xargs kubectl apply --server-side --force-conflicts

helm upgrade scylla-operator scylla-latest/scylla-operator --namespace scylla-operator -f scylla-operator.yaml --version ${operatorTag}
