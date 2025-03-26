#!/usr/bin/env bash

source init.conf

pkill -f "kubectl.*port-forward"

printf "Port-forward service/${clusterName}-grafana 3000:3000\n"
kubectl -n ${scyllaNamespace} port-forward service/${clusterName}-grafana 3000:3000 > /dev/null 2>&1 &

printf "Port-forward service/${clusterName}-client  9042:9042\n"
kubectl -n ${scyllaNamespace} port-forward service/${clusterName}-client  9042:9042 > /dev/null 2>&1 &

printf "Port-forward service/${clusterName}-client  9142:9142\n"
kubectl -n ${scyllaNamespace} port-forward service/${clusterName}-client  9142:9142 > /dev/null 2>&1 &
