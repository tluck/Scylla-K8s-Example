#!/usr/bin/env bash

mTLS=false
[[ -e init.conf ]] && source init.conf

#SCYLLADB_CONFIG="$( mktemp -d )" 
SCYLLADB_CONFIG="config" 
[[ ! -e $SCYLLADB_CONFIG ]] && mkdir $SCYLLADB_CONFIG

if [[ ${mTLS} == true ]]; then
  printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
  printf "Using mTLS for ScyllaDB\n"
  passAuth="# "
  tls=""
else
  printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
  printf "Using Password Auth for ScyllaDB\n"
  tls="#"

cat <<EOF > "${SCYLLADB_CONFIG}/credentials"
[PlainTextAuthProvider]
username = cassandra
password = cassandra
EOF
    chmod 600 "${SCYLLADB_CONFIG}/credentials"
    passAuth=""
fi
if [[ ${1} == '-p' ]]; then
  shift
  usepod=true
#fi  
#if [[ ${usepod} == true ]]; then
  podIPs=( $( kubectl -n ${scyllaNamespace} get pod -l scylla/cluster=${clusterName} -o='jsonpath={.items[*].status.podIP}' ) )
  hostname=${podIPs[0]}
  port=9142
  printf "Using the podIP ${hostname}:${port} for the client connection\n"
else
  hostname=${1:-${clusterName}-client}
  port=${2:-9142}
  printf "Using service endpoint ${hostname}:${port} for the client connection\n"
fi  


SCYLLADB_DISCOVERY_EP="$( kubectl -n ${scyllaNamespace} get service/${clusterName}-client -o='jsonpath={.spec.clusterIP}' )"
if [[ ${customCerts} == true ]]; then
  kubectl -n ${scyllaNamespace} get secret/${clusterName}-client-certs -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/tls.crt"
  kubectl -n ${scyllaNamespace} get secret/${clusterName}-client-certs -o='jsonpath={.data.tls\.key}' | base64 -d > "${SCYLLADB_CONFIG}/tls.key"
  kubectl -n ${scyllaNamespace} get secret/${clusterName}-server-certs -o='jsonpath={.data.ca\.crt}'  | base64 -d > "${SCYLLADB_CONFIG}/ca.crt"
else
  # these 2 certs are signed with serving-ca
  #kubectl -n ${scyllaNamespace} get secret/${clusterName}-local-serving-certs    -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/tls.crt"
  #kubectl -n ${scyllaNamespace} get secret/${clusterName}-local-serving-certs    -o='jsonpath={.data.tls\.key}' | base64 -d > "${SCYLLADB_CONFIG}/tls.key"
  # these 2 certs are signed with client-ca - which is the default for client_encryption
  if [[ ${mTLS} == true ]]; then
    kubectl -n ${scyllaNamespace} get secret/${clusterName}-client-certs      -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/tls.crt"
    kubectl -n ${scyllaNamespace} get secret/${clusterName}-client-certs      -o='jsonpath={.data.tls\.key}' | base64 -d > "${SCYLLADB_CONFIG}/tls.key"  
  else
    kubectl -n ${scyllaNamespace} get secret/${clusterName}-local-user-admin  -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/tls.crt"
    kubectl -n ${scyllaNamespace} get secret/${clusterName}-local-user-admin  -o='jsonpath={.data.tls\.key}' | base64 -d > "${SCYLLADB_CONFIG}/tls.key"
  fi
  # this CA is for the client_config certs local-serving-certs
  kubectl -n ${scyllaNamespace} get configmap/${clusterName}-local-serving-ca -o='jsonpath={.data.ca-bundle\.crt}'       > "${SCYLLADB_CONFIG}/ca.crt"
fi

cat <<EOF > "${SCYLLADB_CONFIG}/cqlshrc"
${passAuth}[authentication]
${passAuth}credentials = ${SCYLLADB_CONFIG}/credentials

[connection]
# hostname = 127.0.0.1
# hostname = ${SCYLLADB_DISCOVERY_EP}
hostname = ${hostname}
port = ${port}
ssl = true
factory = cqlshlib.ssl.ssl_transport_factory

[ssl]
validate=true
certfile=${SCYLLADB_CONFIG}/ca.crt
# for cert auth
usercert=${SCYLLADB_CONFIG}/tls.crt
userkey=${SCYLLADB_CONFIG}/tls.key
EOF

cqlsh --cqlshrc="${SCYLLADB_CONFIG}/cqlshrc"
