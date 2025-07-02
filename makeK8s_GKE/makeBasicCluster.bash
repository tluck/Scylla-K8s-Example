#!/bin/bash

source init.conf

verb=create
[[ $1 == "-d" ]] && verb=delete; shift

export clusterName="${1:-tjl-scylla}"

# the actual names for clusters and zones are set in init.conf
# domain="${clusterDomain:-sdb.com}"
nodesPerRegion=1 # 1 = 3 total nodes, 2 = 6 total nodes (2 per zone)x(3 zones)
nodesPerZone=3 # 3 total nodes per zone
machineType0="n2-standard-8" # SSD based machines for ScyllaDB
machineType1="e2-standard-4" # general operator and other services
# e2-standard-2 2 core x  8 GB
# e2-standard-4 4 core x 16 GB
# e2-standard-8 8 core x 32 GB
imageType='UBUNTU_CONTAINERD' # 'COS_CONTAINERD'
rootDiskSize=20 # 100 GB

export PROJECT_ID="cx-sa-lab"
export region="us-west1"
export zone="us-west1-a"

# Note: the next variable is set with variable names to be used with !name
gkeLocation="zone" # or "region"

if [[ $verb == "create" ]]; then
set -x
# create a cluster with a default node pool for the operator and other services
gcloud container clusters ${verb} ${clusterName} --${gkeLocation}="${!gkeLocation}" \
  --tier "standard" \
  --cluster-version="latest" \
  --num-nodes=${nodesPerZone} \
  --machine-type "${machineType1}" \
  --image-type=${imageType} \
  --disk-size=${rootDiskSize} \
  --system-config-from-file=systemconfig.yaml \
  --node-labels="scylla.scylladb.com/node-type=${nodeSelector1}" \
  --no-enable-autoupgrade \
  --no-enable-autorepair
# create a dedicated node pool for ScyllaDB (SSD and CPU optimized)
gcloud container node-pools create "dedicated-pool" \
  --cluster ${clusterName} \
  --${gkeLocation}="${!gkeLocation}" \
  --num-nodes=${nodesPerZone} \
  --machine-type "${machineType0}" \
  --image-type=${imageType} \
  --disk-type='pd-ssd' \
  --disk-size=${rootDiskSize} \
  --local-nvme-ssd-block count=1 \
  --system-config-from-file=systemconfig.yaml \
  --node-labels="scylla.scylladb.com/node-type=${nodeSelector0}" \
  --no-enable-autoupgrade \
  --no-enable-autorepair
set +x
#  --node-taints='scylla-operator.scylladb.com/dedicated=scyllaclusters:NoSchedule' \

#    --cluster-dns="clouddns" \
#    --cluster-dns-scope="vpc" \
#    --cluster-dns-domain="${domain}" \
#    --node-labels="expire-on=${expire},owner=thomas_luckenbach,purpose=opportunity"

gcloud container clusters get-credentials ${clusterName} --${gkeLocation}="${!gkeLocation}" --project="${PROJECT_ID}"

sleep 5

# fix for xfs
# kubectl apply -f ubuntu-xfs-installer.yaml
if [[ ${imageType} == 'UBUNTU_CONTAINERD' ]]; then
  # run the ubuntu-fix.bash script
  # this will install xfsprogs on all nodes
  # and remove the ubuntu-xfs-installer DaemonSet
  #kubectl apply -f ubuntu-xfs-installer.yaml
  ./ubuntu-fix.bash
  ./ubuntu-fix.bash
fi


else

gcloud container clusters ${verb} ${clusterName} --${gkeLocation}="${!gkeLocation}" --quiet

fi
