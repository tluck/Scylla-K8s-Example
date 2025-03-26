#!/usr/bin/env bash

[[ -e init.conf ]] && source init.conf

SCYLLADB_CONFIG="$( mktemp -d )" 

cat <<EOF > "${SCYLLADB_CONFIG}/credentials"
[PlainTextAuthProvider]
username = cassandra
password = cassandra
EOF
chmod 600 "${SCYLLADB_CONFIG}/credentials"

SCYLLADB_DISCOVERY_EP="$( kubectl -n ${scyllaNamespace} get service/${clusterName}-client -o='jsonpath={.spec.clusterIP}' )"
# kubectl -n ${scyllaNamespace} get secret/${clusterName}-server-certs -o='jsonpath={.data.ca\.crt}'  | base64 -d > "${SCYLLADB_CONFIG}/serving-ca-bundle.crt"
# kubectl -n ${scyllaNamespace} get secret/${clusterName}-server-certs -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/admin.crt"
# kubectl -n ${scyllaNamespace} get secret/${clusterName}-server-certs -o='jsonpath={.data.tls\.key}' | base64 -d > "${SCYLLADB_CONFIG}/admin.key"
kubectl -n ${scyllaNamespace} get configmap/${clusterName}-local-serving-ca -o='jsonpath={.data.ca-bundle\.crt}' > "${SCYLLADB_CONFIG}/serving-ca-bundle.crt"
kubectl -n ${scyllaNamespace} get secret/${clusterName}-local-user-admin -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/admin.crt"
kubectl -n ${scyllaNamespace} get secret/${clusterName}-local-user-admin -o='jsonpath={.data.tls\.key}' | base64 -d > "${SCYLLADB_CONFIG}/admin.key"

cat <<EOF > "${SCYLLADB_CONFIG}/cqlshrc"
[authentication]
credentials = ${SCYLLADB_CONFIG}/credentials
[connection]
hostname = 127.0.0.1
# hostname = ${SCYLLADB_DISCOVERY_EP}
port = 9142
ssl=true
factory = cqlshlib.ssl.ssl_transport_factory
[ssl]
validate=true
certfile=${SCYLLADB_CONFIG}/serving-ca-bundle.crt
usercert=${SCYLLADB_CONFIG}/admin.crt
userkey=${SCYLLADB_CONFIG}/admin.key
EOF

cqlsh --cqlshrc="${SCYLLADB_CONFIG}/cqlshrc"
