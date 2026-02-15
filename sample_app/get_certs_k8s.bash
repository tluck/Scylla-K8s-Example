#!/usr/bin/env bash

[[ -e ../init.conf ]] && source ../init.conf

clusterName=${clusterName:-scylla}
clusterNamespace=${clusterNamespace:-scylla-dc1}
SCYLLADB_CONFIG="config" 
[[ ! -e $SCYLLADB_CONFIG ]] && mkdir $SCYLLADB_CONFIG

if [[ -d /var/run/secrets/kubernetes.io/serviceaccount ]]; then

    APISERVER="https://kubernetes.default.svc"
    SERVICEACCOUNT="/var/run/secrets/kubernetes.io/serviceaccount"
    NAMESPACE=$(cat "${SERVICEACCOUNT}/namespace")
    TOKEN=$(cat "${SERVICEACCOUNT}/token")
    CACERT="${SERVICEACCOUNT}/ca.crt"

    if [[ ${mTLS} == true ]]; then
    curl --silent --cacert "${CACERT}" -H "Authorization: Bearer ${TOKEN}" "${APISERVER}/api/v1/namespaces/${NAMESPACE}/secrets/${clusterName}-client-certs" | jq -r '.data."tls.crt"'  | base64 -d > ${SCYLLADB_CONFIG}/tls.crt
    curl --silent --cacert "${CACERT}" -H "Authorization: Bearer ${TOKEN}" "${APISERVER}/api/v1/namespaces/${NAMESPACE}/secrets/${clusterName}-client-certs" | jq -r '.data."tls.key"'  | base64 -d > ${SCYLLADB_CONFIG}/tls.key
    else
    curl --silent --cacert "${CACERT}" -H "Authorization: Bearer ${TOKEN}" "${APISERVER}/api/v1/namespaces/${NAMESPACE}/secrets/${clusterName}-local-user-admin" | jq -r '.data."tls.crt"' | base64 -d > ${SCYLLADB_CONFIG}/tls.crt
    curl --silent --cacert "${CACERT}" -H "Authorization: Bearer ${TOKEN}" "${APISERVER}/api/v1/namespaces/${NAMESPACE}/secrets/${clusterName}-local-user-admin" | jq -r '.data."tls.key"' | base64 -d > ${SCYLLADB_CONFIG}/tls.key
    fi
    curl --silent --cacert "${CACERT}" -H "Authorization: Bearer ${TOKEN}" "${APISERVER}/api/v1/namespaces/${NAMESPACE}/secrets/${clusterName}-local-serving-ca"    | jq -r '.data."tls.crt"' | base64 -d > ${SCYLLADB_CONFIG}/ca.crt
else
    if [[ ${customCerts} == true ]]; then
    kubectl -n ${clusterNamespace} get secret/${clusterName}-client-certs -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/tls.crt"
    kubectl -n ${clusterNamespace} get secret/${clusterName}-client-certs -o='jsonpath={.data.tls\.key}' | base64 -d > "${SCYLLADB_CONFIG}/tls.key"
    kubectl -n ${clusterNamespace} get secret/${clusterName}-server-certs -o='jsonpath={.data.ca\.crt}'  | base64 -d > "${SCYLLADB_CONFIG}/ca.crt"
    else
    # these 2 certs are signed with serving-ca
    #kubectl -n ${clusterNamespace} get secret/${clusterName}-local-serving-certs    -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/tls.crt"
    #kubectl -n ${clusterNamespace} get secret/${clusterName}-local-serving-certs    -o='jsonpath={.data.tls\.key}' | base64 -d > "${SCYLLADB_CONFIG}/tls.key"
    # these 2 certs are signed with client-ca - which is the default for client_encryption
    if [[ ${mTLS} == true ]]; then
        kubectl -n ${clusterNamespace} get secret/${clusterName}-client-certs      -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/tls.crt"
        kubectl -n ${clusterNamespace} get secret/${clusterName}-client-certs      -o='jsonpath={.data.tls\.key}' | base64 -d > "${SCYLLADB_CONFIG}/tls.key"  
    else
        kubectl -n ${clusterNamespace} get secret/${clusterName}-local-user-admin  -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/tls.crt"
        kubectl -n ${clusterNamespace} get secret/${clusterName}-local-user-admin  -o='jsonpath={.data.tls\.key}' | base64 -d > "${SCYLLADB_CONFIG}/tls.key"
    fi
    # this CA is for the client_config certs local-serving-certs
    kubectl -n ${clusterNamespace} get configmap/${clusterName}-local-serving-ca -o='jsonpath={.data.ca-bundle\.crt}'         > "${SCYLLADB_CONFIG}/ca.crt"
    fi
fi
