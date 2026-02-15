#!/usr/bin/env bash

[[ -e ../init.conf ]] && source ../init.conf

clusterName=${clusterName:-scylla}
clusterNamespace=${clusterNamespace:-scylla-dc1}
SCYLLADB_CONFIG="config" 
[[ ! -e $SCYLLADB_CONFIG ]] && mkdir $SCYLLADB_CONFIG

SECRET_NAME="${clusterName}-alternator-local-serving-ca"  # Replace with the secret from your list

if [[ -d /var/run/secrets/kubernetes.io/serviceaccount ]]; then

    APISERVER="https://kubernetes.default.svc"
    SERVICEACCOUNT="/var/run/secrets/kubernetes.io/serviceaccount"
    NAMESPACE=$(cat "${SERVICEACCOUNT}/namespace")
    TOKEN=$(cat "${SERVICEACCOUNT}/token")
    CACERT="${SERVICEACCOUNT}/ca.crt"

    curl --silent \
    --cacert "${CACERT}" \
    -H "Authorization: Bearer ${TOKEN}" \
    "${APISERVER}/api/v1/namespaces/${NAMESPACE}/secrets/${SECRET_NAME}" \
    | jq -r '.data."tls.crt"' \
    | base64 -d > ${SCYLLADB_CONFIG}/ca.crt
else
    kubectl -n ${clusterNamespace} get secret ${SECRET_NAME} -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/ca.crt"
fi
