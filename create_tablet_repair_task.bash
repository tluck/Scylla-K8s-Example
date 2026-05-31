#!/usr/bin/env bash
[[ -e init.conf ]] && source init.conf
# check status
printf "\nCluster status for cluster: ${clusterNamespace}/${clusterName}\n"

kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool status

# create a repair task for the cluster - this will be a weekly repair of all keyspaces in the cluster
kubectl -n ${clusterNamespace} apply -f - <<EOF
apiVersion: scylla.scylladb.com/v1alpha1
kind: ScyllaDBManagerTask
metadata:
  name: extra-repair
spec:
  type: Repair
  scyllaDBClusterRef:
    # legacy ScyllaCluster deployments surface as a ScyllaDBDatacenter; the ref
    # only accepts ScyllaDBCluster (multi-DC) or ScyllaDBDatacenter (single-DC)
    kind: ScyllaDBDatacenter
    name: "${clusterName}"
  repair:
    cron: "0 0 * * 0"
    dc: 
      - "${dataCenterName}"
    keyspace:
      - "*"
EOF

kubectl -n ${scyllaManagerNamespace} exec -it service/scylla-manager -c scylla-manager -- sctool tasks --cluster ${clusterNamespace}/${clusterName}
