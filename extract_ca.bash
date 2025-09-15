#!/bin/bash

source init.conf

if [[ ${dataCenterName} == 'dc1' ]]; then
kubectl -n cert-manager get secret cert-manager-webhook-ca -o jsonpath="{.data['ca\.crt']}"  | base64 -d > ca.crt
kubectl -n cert-manager get secret cert-manager-webhook-ca -o jsonpath="{.data['tls\.crt']}" | base64 -d > tls.crt
kubectl -n cert-manager get secret cert-manager-webhook-ca -o jsonpath="{.data['tls\.key']}" | base64 -d > tls.key
fi

kubectl -n cert-manager create secret generic my-ca-secret \
  --from-file=tls.crt=tls.crt \
  --from-file=tls.key=tls.key \
  --from-file=ca.crt=ca.crt \
  -o yaml --dry-run=client | kubectl apply -f -
