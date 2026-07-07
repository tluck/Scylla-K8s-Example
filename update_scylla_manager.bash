#!/usr/bin/env bash

[[ -e init.conf ]] && source init.conf

if [[ -e gcs-service-account.json && ${context} == *gke* ]]; then
  location="gcs:${gcsBucketName}"
else
  location="s3:${s3BucketName}"
fi

[[ $1 == '-n' ]] && native=true || native=false

items=$(kubectl -n ${clusterNamespace} get ScyllaDBManagerClusterRegistration -o name 2>/dev/null)
[[ -n "${items}" ]] && kubectl -n ${clusterNamespace} delete ${items}

# check status
upcount=0
loop=0
while [[ ${upcount} -lt 3 ]]; do
sleep 5
upcount=$( kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool status -c ${clusterNamespace}/${clusterName} | grep UN |wc -l)
loop=$((loop + 1))
if [[ ${loop} -gt 24 ]]; then
  printf "\nCluster is not up after 24 attempts, exiting\n"
  exit 1
fi
done
printf "\nCluster status for cluster: ${clusterNamespace}/${clusterName}\n"
kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool status -c ${clusterNamespace}/${clusterName}

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
    --username ${authSuperuserName} --password ${authSuperuserPassword}
fi

# create (or update) a weekly tablet repair task for the cluster - this repairs all tablet keyspaces
# idempotent: re-running fails with "task name weekly is already used", so update the task if it exists
if kubectl -n ${scyllaManagerNamespace} exec service/scylla-manager -c scylla-manager -- sctool tasks --cluster ${clusterNamespace}/${clusterName} 2>/dev/null | grep -q "tablet_repair/weekly"; then
  printf "\nUpdating the existing weekly tablet repair task to run at 2 AM every Sunday\n"
  kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool repair tablet update --cluster ${clusterNamespace}/${clusterName} --cron "0 2 * * 0" tablet_repair/weekly
else
  printf "\nCreating a weekly tablet repair task that runs at 2 AM every Sunday\n"
  kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool repair tablet --name 'weekly' --cluster ${clusterNamespace}/${clusterName} --cron "0 2 * * 0"
fi

# update the existing repair task with new credentials and properties
printf "\nUpdating the existing repair task for vnodes only and intensity 0\n"
kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool repair update -c ${clusterNamespace}/${clusterName} --keyspace-replication=vnodes --intensity=0 --parallel=0 repair/weekly

# dump out the tasks for the cluster
kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool tasks --cluster ${clusterNamespace}/${clusterName} --show-properties
