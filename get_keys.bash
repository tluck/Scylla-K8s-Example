#!/bin/bash

for secret in $( kubectl -n region1 get secrets -o name)
do 
 kubectl -n region1 get $secret -o jsonpath="{.data['tls\.crt']}"  | base64 -d > ${secret}.crt
 kubectl -n region1 get $secret -o jsonpath="{.data['tls\.key']}"  | base64 -d > ${secret}.key
done


