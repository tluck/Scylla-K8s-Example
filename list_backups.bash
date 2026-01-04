#!/usr/bin/env bash

[[ -e init.conf ]] && source init.conf

if [[ -e gcs-service-account.json && ${context} == *gke* ]]; then
  location="gcs:${gcsBucketName}"
else
  location="s3:${s3BucketName}"
fi

[[ $1 == '-n' ]] && native=true || native=false

# check status
printf "\nCluster status for cluster: ${scyllaNamespace}/${clusterName}\n"
kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool status -c ${scyllaNamespace}/${clusterName}

# make a backup
printf "\nListing the backup tasks for cluster: ${scyllaNamespace}/${clusterName} to ${location}\n"
kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool tasks -c ${scyllaNamespace}/${clusterName} -t backup  --show-properties 
printf "\nListing the backup info for cluster: ${scyllaNamespace}/${clusterName} to ${location}\n"
kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool backup list -c ${scyllaNamespace}/${clusterName}
