#!/usr/bin/env bash

[[ -e init.conf ]] && source init.conf

if [[ -e gcs-service-account.json && ${context} == *gke* ]]; then
  location="gcs:${gcsBucketName}"
else
  location="s3:${s3BucketName}"
fi

# native is only supported for S3 not GCS
[[ $1 == '-n' ]] && native=true || native=false

# check status
printf "\nCluster status for cluster: ${clusterNamespace}/${clusterName}\n"
kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool status

# update credentials
if [[ ${mTLS} == true ]]; then
  printf "\nUpdating the cluster with TLS creds\n"
  kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool cluster update -c ${clusterNamespace}/${clusterName} \
    --ssl-user-cert-file /var/run/secrets/${clusterName}-client-certs/tls.crt \
    --ssl-user-key-file  /var/run/secrets/${clusterName}-client-certs/tls.key \
    --force-non-ssl-session-port=false --force-tls-disabled=false
else
  printf "\nUpdating the cluster with Username creds\n"
  kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool cluster update -c ${clusterNamespace}/${clusterName} \
    --username cassandra --password cassandra
fi

# make a backup
printf "\nMaking a backup of cluster: ${clusterNamespace}/${clusterName} to ${location} using the backup/daily task\n"
if [[ $native == true ]]; then
  printf "... using native method\n"
  # kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool backup -c ${clusterNamespace}/${clusterName} -L ${location} --method native
  kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool backup update -c ${clusterNamespace}/${clusterName} -L ${location} --method native "backup/daily"
else
  printf "... using rclone method\n"
  # kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool backup -c ${clusterNamespace}/${clusterName} -L ${location}
  kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool backup update -c ${clusterNamespace}/${clusterName} -L ${location} --method rclone "backup/daily"
fi

  kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool start -c ${clusterNamespace}/${clusterName} "backup/daily"
  sleep 5
  kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool progress -c ${clusterNamespace}/${clusterName} "backup/daily"
  sleep 5
  kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool progress -c ${clusterNamespace}/${clusterName} "backup/daily"
  kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool backup list -c ${clusterNamespace}/${clusterName}
