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
else
  printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
  printf "Using Password Auth for ScyllaDB\n"

cat <<EOF > "${SCYLLADB_CONFIG}/credentials"
[PlainTextAuthProvider]
username = cassandra
password = cassandra
EOF
    chmod 600 "${SCYLLADB_CONFIG}/credentials"
    passAuth=""
fi

SCYLLADB_DISCOVERY_EP="$( kubectl -n ${scyllaNamespace} get service/${clusterName}-client -o='jsonpath={.spec.clusterIP}' )"
#kubectl -n ${scyllaNamespace} get configmap/${clusterName}-local-serving-ca -o='jsonpath={.data.ca-bundle\.crt}' > "${SCYLLADB_CONFIG}/ca.crt"
#kubectl -n ${scyllaNamespace} get secret/${clusterName}-local-user-admin -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/tls.crt"
#kubectl -n ${scyllaNamespace} get secret/${clusterName}-local-user-admin -o='jsonpath={.data.tls\.key}' | base64 -d > "${SCYLLADB_CONFIG}/tls.key"
kubectl -n ${scyllaNamespace} get secret/scylla-server-certs -o='jsonpath={.data.ca\.crt}'  | base64 -d > "${SCYLLADB_CONFIG}/ca.crt"
kubectl -n ${scyllaNamespace} get secret/scylla-server-certs -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/tls.crt"
kubectl -n ${scyllaNamespace} get secret/scylla-server-certs -o='jsonpath={.data.tls\.key}' | base64 -d > "${SCYLLADB_CONFIG}/tls.key"

cat <<EOF > "${SCYLLADB_CONFIG}/cqlshrc"
${passAuth}[authentication]
${passAuth}credentials = ${SCYLLADB_CONFIG}/credentials

[connection]
# hostname = 127.0.0.1
# hostname = ${SCYLLADB_DISCOVERY_EP}
hostname = scylla-client
port = 9142
ssl = true
factory = cqlshlib.ssl.ssl_transport_factory

[ssl]
validate=true
certfile=${SCYLLADB_CONFIG}/ca.crt
usercert=${SCYLLADB_CONFIG}/tls.crt
userkey=${SCYLLADB_CONFIG}/tls.key
EOF

cqlsh --cqlshrc="${SCYLLADB_CONFIG}/cqlshrc"
