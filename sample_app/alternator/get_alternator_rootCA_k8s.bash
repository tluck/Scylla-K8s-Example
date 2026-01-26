#!/usr/bin/env bash

source ../init.conf
SCYLLADB_CONFIG="config" 
[[ ! -e $SCYLLADB_CONFIG ]] && mkdir $SCYLLADB_CONFIG

kubectl -n ${clusterNamespace} get secret ${clusterName}-alternator-local-serving-ca -o='jsonpath={.data.tls\.crt}' | base64 -d > "${SCYLLADB_CONFIG}/ca.crt"
