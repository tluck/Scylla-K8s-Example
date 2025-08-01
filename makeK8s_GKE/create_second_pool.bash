#!/usr/bin/env bash

[[ -e init.conf ]] && source init.conf

verb=create
[[ $1 == "-d" ]] && verb=delete; shift

export clusterName="${1:-tjl-scylla}"
export PROJECT_ID="cx-sa-lab"
export region="${gcpRegion:-us-west1}"
export zone="${region}-a"

# the actual names for clusters and zones are set in init.conf
domain="${clusterDomain:-sdb.com}"
nodesPerRegion=1 # 1 = 3 total nodes, 2 = 6 total nodes (2 per zone)x(3 zones)
nodesPerZone=3 # 3 total nodes per zone
machineType='n2-standard-8' #"e2-standard-8"
imageType='UBUNTU_CONTAINERD' # 'COS_CONTAINERD'
rootDiskSize=20 # 100 GB
#expire="2025-12-31"

# e2-standard-2 2 core x  8 GB
# e2-standard-4 4 core x 16 GB
# e2-standard-8 8 core x 32 GB

# Note: the next variable is set with variable names to be used with !name
gkeLocation="zone"

gcloud container node-pools create "second-pool" \
  --cluster ${clusterName} \
  --${gkeLocation}="${!gkeLocation}" \
  --num-nodes=${nodesPerZone} \
  --machine-type "${machineType}" \
  --image-type=${imageType} \
  --disk-type='pd-ssd' \
  --disk-size=${rootDiskSize} \
  --local-nvme-ssd-block count=1 \
  --system-config-from-file=systemconfig.yaml \
  --no-enable-autoupgrade \
  --no-enable-autorepair

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
