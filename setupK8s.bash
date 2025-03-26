#!/usr/bin/env bash

date
[[ -e init.conf ]] && source init.conf

if [[ ${1} == '-d' ]]; then

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
helm uninstall cert-manager     --namespace cert-manager
# kubectl delete ns cert-manager

else

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
printf "Label nodes for Scylla deployment\n"
# label nodes for Scylla
./labelNodes.bash

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
printf "Installing the storageclass\n"

# Install the storageclass scylladb-local-xfs
# kubectl apply -f sc.yaml 
kubectl apply -f=- <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: scylladb-local-xfs
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"  # Mark as default
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
# Install the cert-manager
printf "Installing the cert manager\n"
helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set crds.enabled=true

# # setup the issuer for scylla #scylla-cert-issuer.yaml
# kubectl apply -f=- <<EOF
# apiVersion: cert-manager.io/v1
# kind: ClusterIssuer
# metadata:
#   name: selfsigned-issuer
#   namespace: ${scyllaNamespace}
# spec:
#   selfSigned: {}
# EOF

fi

printf "\n%s\n" '-----------------------------------------------------------------------------------------------'
[[ ${backupEnabled} == true ]] && ./deployMinio.bash ${1}
date
