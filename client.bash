#!/usr/bin/env bash

if [[ ${1} == '-h' ]]; then
  echo "Usage: $0 [host]"
  echo "Default host is 127.0.0.1"
  exit 0
fi
host=${1:-127.0.0.1}
[[ -e init.conf ]] && source init.conf

if [[ ${1} == '-r' ]]; then
  kubectl -n ${scyllaNamespace} exec -it service/${clusterName}-client -c scylla -- cqlsh -u cassandra -p cassandra --connect-timeout=30 --request-timeout=30
else
  cqlsh -u cassandra -p cassandra --connect-timeout=30 --request-timeout=30 ${host}
fi
