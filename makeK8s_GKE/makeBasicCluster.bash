#!/usr/bin/env bash

context=$(kubectl config current-context 2>/dev/null)
[[ ${context} == *docker-desktop* ]] && kubectl config unset current-context
[[ -e init.conf ]] && source init.conf
[[ ${context} != "" ]] && kubectl config use-context ${context}

verb=create
[[ $1 == "-d" ]] && verb=delete; shift

export clusterName="${1:-tjl-scylla}"
export PROJECT_ID="cx-sa-lab"
export region="${gcpRegion:-us-west1}"
export zone="${region}-a"

# the actual names for clusters and zones are set in init.conf
# domain="${clusterDomain:-sdb.com}"
machineType0="e2-standard-8" # general operator and other services
machineType1="n2-standard-8" # SSD based machines for ScyllaDB
machineType2="c4a-standard-8" # arm64 application nodes
# e2-standard-2 2 core x  8 GB
# e2-standard-4 4 core x 16 GB
# e2-standard-8 8 core x 32 GB
imageType='UBUNTU_CONTAINERD' # 'COS_CONTAINERD'
rootDiskSize="100GB"

# Note: the next variable is set with variable names to be used with !name
if [[ ${singleZone} == true ]]; then
    gkeLocation="zone"
else
    gkeLocation="region"
fi

if [[ ${gkeLocation} == "region" ]]; then
    # 1 = 3 total nodes, 2 = 6 total nodes (2 per zone)x(3 zones)
    nodesPer0=1
    nodesPer1=2
    nodesPer2=1 
else
    # 3 total nodes per zone
    nodesPer0=3
    nodesPer1=6
    nodesPer2=1
fi

if [[ $verb == "create" ]]; then
set -x
# create a cluster with a default node pool for the operator and other services
gcloud container clusters ${verb} ${clusterName} --${gkeLocation}="${!gkeLocation}" \
  --tier "standard" \
  --cluster-version="latest" \
  --num-nodes=${nodesPer0} \
  --machine-type="${machineType0}" \
  --image-type=${imageType} \
  --disk-size=${rootDiskSize} \
  --system-config-from-file=systemconfig.yaml \
  --labels="owner=sa_demo_scylladb_com" \
  --node-labels="scylla.scylladb.com/node-type=${nodeSelector0},owner=sa_demo_scylladb_com" \
  --no-enable-autoupgrade \
  --no-enable-autorepair
# create a dedicated node pool for ScyllaDB (SSD and CPU optimized)
gcloud container node-pools create "dedicated-pool" \
  --cluster ${clusterName} --${gkeLocation}="${!gkeLocation}" \
  --num-nodes=${nodesPer1} \
  --machine-type="${machineType1}" \
  --image-type=${imageType} \
  --disk-type='pd-ssd' \
  --disk-size=${rootDiskSize} \
  --local-nvme-ssd-block count=1 \
  --system-config-from-file=systemconfig.yaml \
  --labels="owner=sa_demo_scylladb_com" \
  --node-labels="scylla.scylladb.com/node-type=${nodeSelector1},owner=sa_demo_scylladb_com" \
  --node-taints='scylla-operator.scylladb.com/dedicated=scyllaclusters:NoSchedule' \
  --no-enable-autoupgrade \
  --no-enable-autorepair
# create an application node
gcloud container node-pools create "application-pool" \
  --cluster ${clusterName} --${gkeLocation}="${!gkeLocation}" \
  --num-nodes=${nodesPer2} \
  --node-locations=${zone} \
  --machine-type="${machineType2}" \
  --image-type=${imageType} \
  --disk-size=${rootDiskSize} \
  --labels="owner=sa_demo_scylladb_com" \
  --system-config-from-file=systemconfig.yaml \
  --node-labels="scylla.scylladb.com/node-type=${nodeSelector2},owner=sa_demo_scylladb_com" \
  --no-enable-autoupgrade \
  --no-enable-autorepair
set +x

#    --cluster-dns="clouddns" \
#    --cluster-dns-scope="vpc" \
#    --cluster-dns-domain="${domain}" \
#    --node-labels="expire-on=${expire},owner=sa_demo,purpose=opportunity"

gcloud container clusters get-credentials ${clusterName} --${gkeLocation}="${!gkeLocation}" --project="${PROJECT_ID}"
sleep 5

# remove taint for arm64 nodes to allow scheduling
# kubectl taint nodes -l kubernetes.io/arch=arm64 scylla-operator.scylladb.com/dedicated:NoSchedule-

# fix for xfs
# kubectl apply -f ubuntu-xfs-installer.yaml
if [[ ${imageType} == 'UBUNTU_CONTAINERD' ]]; then
  # run the ubuntu-fix.bash script
  # this will install xfsprogs on all nodes
  # and remove the ubuntu-xfs-installer DaemonSet
  #kubectl apply -f ubuntu-xfs-installer.yaml
  ./ubuntu-fix.bash
fi

else

# verb=delete
gcloud container node-pools delete  "application-pool" --cluster ${clusterName} --${gkeLocation}="${!gkeLocation}" --quiet
gcloud container node-pools delete  "dedicated-pool"   --cluster ${clusterName} --${gkeLocation}="${!gkeLocation}" --quiet
gcloud container clusters    delete ${clusterName} --${gkeLocation}="${!gkeLocation}" --quiet

fi
