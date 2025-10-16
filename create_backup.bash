#!/usr/bin/env bash

[[ -e init.conf ]] && source init.conf

if [[ -e gcs-service-account.json && ${context} == *gke* ]]; then
  location="gcs:${gcsBucketName}"
else
  location="s3:${s3BucketName}"
fi

# check status
kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool status

# update credentials
if [[ ${mTLS} == true ]]; then
  printf "Updating the cluster with TLS creds\n"
  kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool cluster update -c ${scyllaNamespace}/${clusterName} \
    --ssl-user-cert-file /var/run/secrets/scylla-manager/client-certs/tls.crt \
    --ssl-user-key-file /var/run/secrets/scylla-manager/client-certs/tls.key  \
    --force-non-ssl-session-port=false --force-tls-disabled=false
else
  printf "Updating the cluster with Username creds\n"
  kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool cluster update -c ${scyllaNamespace}/${clusterName} \
    --username cassandra --password cassandra
fi

# make a backup
printf "Making a backup of cluster: ${scyllaNamespace}/${clusterName} to ${location}\n"
kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool backup -c ${scyllaNamespace}/${clusterName} -L ${location}
