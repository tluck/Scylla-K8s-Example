#!/usr/bin/env bash

set -euo pipefail

script_dir=$(dirname "$0")
[[ -e "${script_dir}/init.conf" ]] && source "${script_dir}/init.conf"

usage() {
    echo "Usage: $0 [-h] [-p] [host] [port]"
    echo "  A cqlsh wrapper script for TLS connections."
    echo
    echo "Options:"
    echo "  -p        Connect to the first cluster pod's IP instead of a service."
    echo "  -h        Display this help message."
    echo
    echo "Arguments:"
    echo "  [host]    The target host to connect to (default: ${clusterName}-client.${clusterNamespace}.svc)."
    echo "  [port]    The target port (default: 9142)."
}

use_pod_ip=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p) use_pod_ip=true; shift ;;
        -h) usage; exit 0 ;;
        *) break ;; # Stop parsing options, remaining are positional args
    esac
done

cql_user="${CQL_USER:-cassandra}"
cql_pass="${CQL_PASSWORD:-cassandra}"

# SCYLLADB_CONFIG=$(mktemp -d)
SCYLLADB_CONFIG="${script_dir}/config"
[[ -d "${SCYLLADB_CONFIG}" ]] || mkdir -p "${SCYLLADB_CONFIG}"
#trap 'rm -rf -- "$SCYLLADB_CONFIG"' EXIT

hostname="${1:-${clusterName}-client.${clusterNamespace}.svc}"
port="${2:-9142}"

if [[ "${use_pod_ip}" == true ]]; then
  pod_ip=$(kubectl -n "${clusterNamespace}" get pod -l "scylla/cluster=${clusterName}" -o='jsonpath={.items[0].status.podIP}')
  hostname="${pod_ip}"
  printf "Connecting to pod IP %s:%s\n" "${hostname}" "${port}"
else
  printf "Connecting to service endpoint %s:%s\n" "${hostname}" "${port}"
fi

pass_auth_section=""

if [[ "${mTLS:-false}" == true ]]; then
  echo "Using mTLS authentication."
  pass_auth_section="#" # Comment out password auth section in cqlshrc

  kubectl -n "${clusterNamespace}" get secret/"${clusterName}-client-certs" -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/tls.crt"
  kubectl -n "${clusterNamespace}" get secret/"${clusterName}-client-certs" -o='jsonpath={.data.tls\.key}' | base64 -d > "${SCYLLADB_CONFIG}/tls.key"
  if [[ "${customCerts:-false}" == true ]]; then
    kubectl -n "${clusterNamespace}" get secret/"${clusterName}-server-certs" -o='jsonpath={.data.ca\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/ca.crt"
  else
    # kubectl -n "${clusterNamespace}" get cm/"${clusterName}-local-serving-ca" -o='jsonpath={.data.ca-bundle\.crt}' > "${SCYLLADB_CONFIG}/ca.crt"
    kubectl -n "${clusterNamespace}" get secret/"${clusterName}-local-serving-ca" -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/ca.crt"
  fi
else
  echo "Using password authentication."
  cat <<EOF > "${SCYLLADB_CONFIG}/credentials"
[PlainTextAuthProvider]
username = ${cql_user}
password = ${cql_pass}
EOF
  chmod 600 "${SCYLLADB_CONFIG}/credentials"

  kubectl -n ${clusterNamespace} get secret/${clusterName}-local-user-admin -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/tls.crt"
  kubectl -n ${clusterNamespace} get secret/${clusterName}-local-user-admin -o='jsonpath={.data.tls\.key}' | base64 -d > "${SCYLLADB_CONFIG}/tls.key"
  if [[ "${customCerts:-false}" == true ]]; then
    kubectl -n "${clusterNamespace}" get secret/"${clusterName}-server-certs" -o='jsonpath={.data.ca\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/ca.crt"
  else
    kubectl -n "${clusterNamespace}" get secret/"${clusterName}-local-serving-ca" -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/ca.crt"
  fi
fi

cat <<EOF > "${SCYLLADB_CONFIG}/cqlshrc"
${pass_auth_section}[authentication]
${pass_auth_section}credentials = ${SCYLLADB_CONFIG}/credentials

[connection]
hostname = ${hostname}
port = ${port}
ssl = true
factory = cqlshlib.ssl.ssl_transport_factory

[ssl]
validate = true
certfile = ${SCYLLADB_CONFIG}/ca.crt
usercert = ${SCYLLADB_CONFIG}/tls.crt
userkey = ${SCYLLADB_CONFIG}/tls.key
EOF

cqlsh --cqlshrc="${SCYLLADB_CONFIG}/cqlshrc"
