#!/usr/bin/env bash

set -euo pipefail

script_dir=$(dirname "$0")
[[ -e "${script_dir}/init.conf" ]] && source "${script_dir}/init.conf"
clusterName="${clusterName:-scylla}"
clusterNamespace="${clusterNamespace:-scylla-dc1}"

usage() {
    echo "Usage: $0 [-h] [-p] [host] [port]"
    echo "  A cqlsh wrapper script for TLS connections."
    echo
    echo "Options:"
    echo "  -p        Connect to the first cluster pod's IP instead of a service."
    echo "           Without kubectl, set SCYLLADB_POD_IP (see below)."
    echo "  -h        Display this help message."
    echo
    echo "Arguments:"
    echo "  [host]    The target host to connect to (default: ${clusterName}-client.${clusterNamespace}.svc)."
    echo "  [port]    The target port (default: 9142)."
    echo
    echo "In-cluster / no kubectl:"
    echo "  Mount client TLS material as files and set SCYLLADB_TLS_MOUNT to that directory."
    echo "  Default files: tls.crt, tls.key, ca.crt (override with SCYLLADB_TLS_CERT, SCYLLADB_TLS_KEY, SCYLLADB_CA_CERT)."
    echo "  With -p and no kubectl: set SCYLLADB_POD_IP to the target pod IP."
}

use_pod_ip=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p) use_pod_ip=true; shift ;;
        -h) usage; exit 0 ;;
        *) break ;; # Stop parsing options, remaining are positional args
    esac
done

cql_user="${authSuperuserName:-cassandra}"
cql_pass="${authSuperuserPassword:-cassandra}"

# kubectl binary (override in minimal images or CI). Unused when SCYLLADB_TLS_MOUNT is set.
KUBECTL="${KUBECTL:-kubectl}"

# If SCYLLADB_TLS_MOUNT is set, TLS files are read from disk (e.g. Secret volume) and kubectl is not used.
use_mounted_certs() {
  [[ -n "${SCYLLADB_TLS_MOUNT:-}" ]]
}

copy_tls_from_mount() {
  local src_cert="${SCYLLADB_TLS_CERT:-${SCYLLADB_TLS_MOUNT}/tls.crt}"
  local src_key="${SCYLLADB_TLS_KEY:-${SCYLLADB_TLS_MOUNT}/tls.key}"
  local src_ca="${SCYLLADB_CA_CERT:-${SCYLLADB_TLS_MOUNT}/ca.crt}"
  local f
  for f in "${src_cert}" "${src_key}" "${src_ca}"; do
    if [[ ! -r "${f}" ]]; then
      echo "error: TLS mount file missing or unreadable: ${f}" >&2
      exit 1
    fi
  done
  cp "${src_cert}" "${SCYLLADB_CONFIG}/tls.crt"
  cp "${src_key}" "${SCYLLADB_CONFIG}/tls.key"
  cp "${src_ca}" "${SCYLLADB_CONFIG}/ca.crt"
  chmod 600 "${SCYLLADB_CONFIG}/tls.key"
}

# Writable TLS/cqlshrc material: default next to script; in read-only images use
# SCYLLADB_CONFIG=/tmp/scylla-cqlsh-config (or mount an emptyDir).
if [[ -z "${SCYLLADB_CONFIG:-}" ]]; then
  SCYLLADB_CONFIG="${script_dir}/config"
fi
if [[ ! -d "${SCYLLADB_CONFIG}" ]]; then
  if mkdir -p "${SCYLLADB_CONFIG}" 2>/dev/null; then
    :
  else
    SCYLLADB_CONFIG="${TMPDIR:-/tmp}/scylla-cqlsh-config.$$"
    mkdir -p "${SCYLLADB_CONFIG}"
  fi
fi
#trap 'rm -rf -- "$SCYLLADB_CONFIG"' EXIT

hostname="${1:-${clusterName}-client-external.${clusterNamespace}.svc}"
port="${2:-9142}"

if [[ "${use_pod_ip}" == true ]]; then
  if use_mounted_certs; then
    if [[ -z "${SCYLLADB_POD_IP:-}" ]]; then
      echo "error: -p requires SCYLLADB_POD_IP when SCYLLADB_TLS_MOUNT is set (no kubectl)." >&2
      exit 1
    fi
    hostname="${SCYLLADB_POD_IP}"
  else
    pod_ip=$("${KUBECTL}" -n "${clusterNamespace}" get pod -l "scylla/cluster=${clusterName}" -o='jsonpath={.items[0].status.podIP}')
    hostname="${pod_ip}"
  fi
  printf "Connecting to pod IP %s:%s\n" "${hostname}" "${port}"
else
  printf "Connecting to service endpoint %s:%s\n" "${hostname}" "${port}"
fi

if ! use_mounted_certs && ! command -v "${KUBECTL}" >/dev/null 2>&1; then
  echo "error: ${KUBECTL} not found. For pods without kubectl, mount tls.crt, tls.key, and ca.crt and set SCYLLADB_TLS_MOUNT to that directory." >&2
  exit 1
fi

pass_auth_section=""

if [[ "${mTLS:-false}" == true ]]; then
  echo "Using mTLS authentication."
  pass_auth_section="#" # Comment out password auth section in cqlshrc

  if use_mounted_certs; then
    copy_tls_from_mount
  else
    "${KUBECTL}" -n "${clusterNamespace}" get secret/"${clusterName}-client-certs" -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/tls.crt"
    "${KUBECTL}" -n "${clusterNamespace}" get secret/"${clusterName}-client-certs" -o='jsonpath={.data.tls\.key}' | base64 -d > "${SCYLLADB_CONFIG}/tls.key"
    if [[ "${customCerts:-false}" == true ]]; then
      "${KUBECTL}" -n "${clusterNamespace}" get secret/"${clusterName}-server-certs" -o='jsonpath={.data.ca\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/ca.crt"
    else
      "${KUBECTL}" -n "${clusterNamespace}" get secret/"${clusterName}-local-serving-ca" -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/ca.crt"
    fi
  fi
else
  echo "Using password authentication."
  cat <<EOF > "${SCYLLADB_CONFIG}/credentials"
[PlainTextAuthProvider]
username = ${cql_user}
password = ${cql_pass}
EOF
  chmod 600 "${SCYLLADB_CONFIG}/credentials"

  if use_mounted_certs; then
    copy_tls_from_mount
  else
    "${KUBECTL}" -n "${clusterNamespace}" get secret/"${clusterName}-local-user-admin" -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/tls.crt"
    "${KUBECTL}" -n "${clusterNamespace}" get secret/"${clusterName}-local-user-admin" -o='jsonpath={.data.tls\.key}' | base64 -d > "${SCYLLADB_CONFIG}/tls.key"
    if [[ "${customCerts:-false}" == true ]]; then
      "${KUBECTL}" -n "${clusterNamespace}" get secret/"${clusterName}-server-certs" -o='jsonpath={.data.ca\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/ca.crt"
    else
      "${KUBECTL}" -n "${clusterNamespace}" get secret/"${clusterName}-local-serving-ca" -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/ca.crt"
    fi
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
