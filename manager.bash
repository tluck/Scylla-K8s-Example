#!/usr/bin/env bash

set -euo pipefail

script_dir=$(dirname "$0")
[[ -e "${script_dir}/init.conf" ]] && source "${script_dir}/init.conf"

usage() {
    echo "Usage: $0 [-h] [command ...]"
    echo "  Run a command inside the scylla-manager pod."
    echo
    echo "Options:"
    echo "  -h        Display this help message."
    echo
    echo "Examples:"
    echo "  $0                             # interactive shell in the manager pod"
    echo "  $0 sctool status               # run sctool status"
    echo "  $0 'sctool task list | head'   # quote to use shell syntax"
}

[[ "${1:-}" == "-h" ]] && { usage; exit 0; }

ns="${scyllaManagerNamespace:-scylla-manager}"

if [[ $# -eq 0 ]]; then
    kubectl -n "${ns}" exec -it service/scylla-manager -c scylla-manager -- bash
else
    kubectl -n "${ns}" exec -it service/scylla-manager -c scylla-manager -- bash -c "$*"
fi
