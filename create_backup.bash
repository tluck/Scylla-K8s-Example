#!/usr/bin/env bash

[[ -e init.conf ]] && source init.conf

if [[ -e gcs-service-account.json && ${context} == *gke* ]]; then
  location="gcs:${gcpBucketName}"
else
  location="s3:${awsBucketName}"
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
printf "Makeing a backup to ${location}\n"
kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool backup -c scylla-dc1/scylla -L ${location}
