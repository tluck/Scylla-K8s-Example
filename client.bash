#!/usr/bin/env bash

if [[ ${1} == '-h' ]]; then
  echo "Usage: $0 [-r] [host]"
  echo "   Default host is scylla-client"
  echo "   -r uses kubectl exec"
  exit 0
fi


if [[ ${1} == '-r' ]]; then
    script_dir=$(dirname "$0")
    [[ -e ${script_dir}/init.conf ]] && source ${script_dir}/init.conf
set -x
    kubectl -n ${clusterNamespace} exec -it service/${clusterName}-client -c scylla -- cqlsh -u cassandra -p cassandra --connect-timeout=30 --request-timeout=30
set +x
else
    host=${1:-scylla-client}
    cqlsh -u cassandra -p cassandra --connect-timeout=30 --request-timeout=30 ${host}
fi
