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
kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool status

# update credentials
if [[ ${mTLS} == true ]]; then
  printf "\nUpdating the cluster with TLS creds\n"
  kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool cluster update -c ${scyllaNamespace}/${clusterName} \
    --ssl-user-cert-file /var/run/secrets/${clusterName}-client-certs/tls.crt \
    --ssl-user-key-file  /var/run/secrets/${clusterName}-client-certs/tls.key \
    --force-non-ssl-session-port=false --force-tls-disabled=false
else
  printf "\nUpdating the cluster with Username creds\n"
  kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool cluster update -c ${scyllaNamespace}/${clusterName} \
    --username cassandra --password cassandra
fi

# make a backup
printf "\nMaking a backup of cluster: ${scyllaNamespace}/${clusterName} to ${location}\n"
if [[ $native == true ]]; then
  printf "... using native method\n"
  kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool backup -c ${scyllaNamespace}/${clusterName} -L ${location} --method native
else
  printf "... using rclone method\n"
  kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool backup -c ${scyllaNamespace}/${clusterName} -L ${location}
fi
