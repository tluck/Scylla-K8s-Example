#!/usr/bin/env bash

set -euo pipefail

# Follow symlinks (e.g. ~/bin/client.bash) so init.conf is found next to the real script
script_path="$0"
while [[ -L "${script_path}" ]]; do
    link=$(readlink "${script_path}")
    [[ "${link}" == /* ]] && script_path="${link}" || script_path="$(dirname "${script_path}")/${link}"
done
script_dir=$(dirname "${script_path}")
[[ -e "${script_dir}/init.conf" ]] && source "${script_dir}/init.conf"

# Allow overriding from environment, with defaults
cql_user="${authSuperuserName:-cassandra}"
cql_pass="${authSuperuserPassword:-cassandra}"

usage() {
    echo "Usage: $0 [-h] [-r] [host] [cqlsh options...]"
    echo "  A cqlsh wrapper script."
    echo
    echo "Options:"
    echo "  -r        Connect via 'kubectl exec' into the client service."
    echo "  -h        Display this help message."
    echo "  [host]    The target host to connect to (default: scylla-client)."
    echo
    echo "Anything else is passed through to cqlsh, so one-off statements work:"
    echo "  $0 -r -e \"SELECT * FROM system.local\""
    echo "  $0 -r -k mykeyspace -f /tmp/schema.cql"
    echo "  $0 -r -- --debug        # everything after -- goes to cqlsh verbatim"
    echo "Passthrough options come after the script's own, so they win over the"
    echo "credentials and timeouts set here."
}

use_kubectl=false
host="scylla-client"
host_set=false
cqlsh_args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -r) use_kubectl=true; shift ;;
        -h) usage; exit 0 ;;
        --) shift; cqlsh_args+=("$@"); break ;;
        # cqlsh options that take a value - keep the value with its flag
        -e|--execute|-f|--file|-k|--keyspace|-u|--username|-p|--password|\
        --connect-timeout|--request-timeout|--cqlshrc|--encoding|--cqlversion)
            if [[ $# -lt 2 ]]; then
                echo "error: $1 requires an argument" >&2
                exit 1
            fi
            cqlsh_args+=("$1" "$2"); shift 2 ;;
        -*) cqlsh_args+=("$1"); shift ;;
        *)  if [[ "${host_set}" == false ]]; then
                host="$1"; host_set=true
            else
                cqlsh_args+=("$1")
            fi
            shift ;;
    esac
done

# A TTY is right for an interactive shell, but it mangles the output of
# -e/-f runs, so only allocate one when no cqlsh arguments were given.
kubectl_exec_flags=(-i -t)
[[ ${#cqlsh_args[@]} -gt 0 ]] && kubectl_exec_flags=(-i)

if [[ "${use_kubectl}" == true ]]; then
    echo "Connecting via kubectl to service/${clusterName}-client in namespace ${clusterNamespace}..."
    kubectl -n "${clusterNamespace}" exec "${kubectl_exec_flags[@]}" "service/${clusterName}-client" -c scylla -- \
        cqlsh -u "${cql_user}" -p "${cql_pass}" --connect-timeout=30 --request-timeout=30 \
        ${cqlsh_args[@]+"${cqlsh_args[@]}"}
else
    echo "Connecting to host: ${host}..."
    cqlsh -u "${cql_user}" -p "${cql_pass}" --connect-timeout=30 --request-timeout=30 \
        ${cqlsh_args[@]+"${cqlsh_args[@]}"} "${host}"
fi
