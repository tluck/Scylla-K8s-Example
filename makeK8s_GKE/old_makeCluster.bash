#!/bin/bash

#gcloud container clusters create 'my-k8s-cluster' \
#--zone='us-west1-a' \
#--cluster-version="latest" \
#--machine-type='n2-standard-8' \
#--num-nodes='3' \
#--disk-type='pd-ssd' --disk-size='20' \
#--local-nvme-ssd-block='count=1' \
#--node-labels='scylla.scylladb.com/node-type=scylla' \
#--node-taints='scylla-operator.scylladb.com/dedicated=scyllaclusters:NoSchedule'
#--no-enable-autoupgrade \
#--no-enable-autorepairo

## --image-type='UBUNTU_CONTAINERD' \

## option 2nd nodd group:
#gcloud container node-pools create 'scyllaclusters' --cluster='my-k8s-cluster' \
#--zone='us-west1-a' \
#--node-version="latest" \
#--machine-type='n2-standard-16' \
#--num-nodes='4' \
#--disk-type='pd-ssd' --disk-size='20' \
#--local-nvme-ssd-block='count=4' \
#--system-config-from-file='systemconfig.yaml' \
#--no-enable-autoupgrade \
#--no-enable-autorepair \
#--node-labels='scylla.scylladb.com/node-type=scylla' \
#--node-taints='scylla-operator.scylladb.com/dedicated=scyllaclusters:NoSchedule'

##--image-type='UBUNTU_CONTAINERD' \


gcloud beta container --project "cx-sa-lab" clusters create "tjl-cluster-1" --zone "us-west1-a" --tier "standard" --no-enable-basic-auth --cluster-version "1.32.2-gke.1182003" --release-channel "regular" --machine-type "n2-standard-2" --image-type "COS_CONTAINERD" --disk-type "pd-balanced" --disk-size "100" --metadata disable-legacy-endpoints=true --scopes "https://www.googleapis.com/auth/cloud-platform" --spot --num-nodes "3" --logging=SYSTEM,WORKLOAD --monitoring=SYSTEM,STORAGE,POD,DEPLOYMENT,STATEFULSET,DAEMONSET,HPA,JOBSET,CADVISOR,KUBELET,DCGM --enable-ip-alias --network "projects/cx-sa-lab/global/networks/default" --subnetwork "projects/cx-sa-lab/regions/us-west1/subnetworks/default" --no-enable-intra-node-visibility --default-max-pods-per-node "110" --enable-ip-access --security-posture=standard --workload-vulnerability-scanning=disabled --no-enable-google-cloud-access --addons HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver --enable-autoupgrade --enable-autorepair --max-surge-upgrade 1 --max-unavailable-upgrade 0 --binauthz-evaluation-mode=DISABLED --enable-managed-prometheus --enable-shielded-nodes --shielded-integrity-monitoring --no-shielded-secure-boot --node-locations "us-west1-a"

gcloud container clusters get-credentials tjl-cluster-1 --zone us-west1-a --project cx-sa-lab

