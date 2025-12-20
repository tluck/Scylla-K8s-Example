#!/bin/bash

namespace=${1:-scylla-dc1}

for secret in $( kubectl -n ${namespace} get secrets -o name)
do 
 kubectl -n ${namespace} get $secret -o jsonpath="{.data['tls\.crt']}"  | base64 -d > ${secret}.crt
 kubectl -n ${namespace} get $secret -o jsonpath="{.data['tls\.key']}"  | base64 -d > ${secret}.key
done


