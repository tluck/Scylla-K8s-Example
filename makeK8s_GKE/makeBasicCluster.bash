#!/usr/bin/env bash

context=$(kubectl config current-context 2>/dev/null)
[[ ${context} == *docker-desktop* ]] && kubectl config unset current-context
[[ -e init.conf ]] && source init.conf
[[ ${context} != "" ]] && kubectl config use-context ${context}

verb=create
[[ $1 == "-d" ]] && verb=delete; shift

if [[ -e gke.conf ]]; then 
    source gke.conf
else
    printf "* * * | Missing gke.conf file\n"
    exit 1
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
