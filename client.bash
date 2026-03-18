#!/usr/bin/env bash

set -euo pipefail

script_dir=$(dirname "$0")
[[ -e "${script_dir}/init.conf" ]] && source "${script_dir}/init.conf"

# Allow overriding from environment, with defaults
cql_user="${CQL_USER:-cassandra}"
cql_pass="${CQL_PASSWORD:-cassandra}"

usage() {
    echo "Usage: $0 [-h] [-r] [host]"
    echo "  A cqlsh wrapper script."
    echo
    echo "Options:"
    echo "  -r        Connect via 'kubectl exec' into the client service."
    echo "  -h        Display this help message."
    echo "  [host]    The target host to connect to (default: scylla-client)."
}

use_kubectl=false
host="scylla-client"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -r) use_kubectl=true; shift ;;
        -h) usage; exit 0 ;;
        *) host="$1"; shift ;;
    esac
done

if [[ "${use_kubectl}" == true ]]; then
    echo "Connecting via kubectl to service/${clusterName}-client in namespace ${clusterNamespace}..."
    kubectl -n "${clusterNamespace}" exec -it "service/${clusterName}-client" -c scylla -- \
        cqlsh -u "${cql_user}" -p "${cql_pass}" --connect-timeout=30 --request-timeout=30
else
    echo "Connecting to host: ${host}..."
    cqlsh -u "${cql_user}" -p "${cql_pass}" --connect-timeout=30 --request-timeout=30 "${host}"
fi
