#!/usr/bin/env bash

[[ -e init.conf ]] && source init.conf

if [[ ${1} == '-r' ]]; then
  kubectl -n ${scyllaNamespace}  exec -it service/scylla-client -c scylla -- cqlsh -u cassandra -p cassandra --connect-timeout=30 --request-timeout=30
else
  cqlsh -u cassandra -p cassandra --connect-timeout=30 --request-timeout=30
fi
