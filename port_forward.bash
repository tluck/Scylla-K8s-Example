#!/usr/bin/env bash

source init.conf

pkill -f "kubectl.*port-forward"

sleep 3

if [[ ${backupEnabled} == true ]]; then
  printf "Port-forward service/minio 9000:9000\n"
  kubectl -n minio port-forward service/minio 9000:9000 > /dev/null 2>&1 &
fi

printf "Port-forward service/${clusterName}-grafana 3000:3000\n"
kubectl -n ${scyllaNamespace} port-forward service/${clusterName}-grafana 3000:3000 > /dev/null 2>&1 &

printf "Port-forward service/${clusterName}-client  9042:9042\n"
kubectl -n ${scyllaNamespace} port-forward service/${clusterName}-client  9042:9042 > /dev/null 2>&1 &

printf "Port-forward service/${clusterName}-client  9142:9142\n"
kubectl -n ${scyllaNamespace} port-forward service/${clusterName}-client  9142:9142 > /dev/null 2>&1 &

printf "Port-forward service/${clusterName}-client  19042:19042\n"
kubectl -n ${scyllaNamespace} port-forward service/${clusterName}-client  19042:19042 > /dev/null 2>&1 &

printf "Port-forward service/${clusterName}-client  19142:19142\n"
kubectl -n ${scyllaNamespace} port-forward service/${clusterName}-client  19142:19142 > /dev/null 2>&1 &

# 
if [[ ${enableAlternator} == true ]]; then
printf "Port-forward service/${clusterName}-client  8000:8000\n"
kubectl -n ${scyllaNamespace} port-forward service/${clusterName}-client  8000:8000 > /dev/null 2>&1 &

printf "Port-forward service/${clusterName}-client  8043:8043\n"
kubectl -n ${scyllaNamespace} port-forward service/${clusterName}-client  8043:8043 > /dev/null 2>&1 &
fi

username=$( kubectl -n ${scyllaNamespace} get secret/scylla-grafana-admin-credentials --template '{{ index .data "username" }}' | base64 -d )
password=$( kubectl -n ${scyllaNamespace} get secret/scylla-grafana-admin-credentials --template '{{ index .data "password" }}' | base64 -d )
printf  "\nGrafana credentials: \n\thttps://localhost:3000 \n\tUsername: ${username} \n\tPassword: ${password} \n\n"
