#!/usr/bin/env bash

context=$(kubectl config current-context 2>/dev/null)
[[ ${context} == *docker-desktop* ]] && kubectl config unset current-context
[[ -e init.conf ]] && source init.conf
[[ ${context} != "" ]] && kubectl config use-context ${context}

verb=create
[[ $1 == "-d" ]] && { verb=delete; shift; }

if [[ -e aks.conf ]]; then
    source aks.conf
else
    printf "* * * | Missing aks.conf file\n"
    exit 1
fi

if ! az account show --query name -o tsv; then
    printf "* * * | Azure credentials are missing or expired - run: az login\n"
    exit 1
fi
aksContext="aks_${region}_${clusterName}"

if [[ $verb == "create" ]]; then
# one-time per subscription
for ns in Microsoft.ContainerService Microsoft.Compute Microsoft.Network; do
  [[ $(az provider show -n ${ns} --query registrationState -o tsv) != Registered ]] && az provider register -n ${ns} --wait
done

set -x
az group create -n ${resourceGroup} -l ${region} --tags ${tags} -o none
# create a cluster with a default (system) node pool for the operator and other services
az aks create -g ${resourceGroup} -n ${clusterName} -l ${region} \
  --tier free \
  --network-plugin azure --network-plugin-mode overlay \
  --auto-upgrade-channel none \
  --node-os-upgrade-channel None \
  --nodepool-name system \
  --node-count ${nodesPer0} \
  --node-vm-size ${machineType0} \
  --zones ${zones} \
  --os-sku ${osSku} \
  --node-osdisk-type Managed \
  --node-osdisk-size ${rootDiskSize} \
  --kubelet-config kubeletconfig.json \
  --nodepool-labels "scylla.scylladb.com/node-type=${nodeSelector0}" \
  --no-ssh-key \
  --tags ${tags} \
  -o none \
  || { set +x; printf "* * * Error: az aks create failed\n" >&2; exit 1; }
# create a dedicated node pool for ScyllaDB (local NVMe SSD)
az aks nodepool add -g ${resourceGroup} --cluster-name ${clusterName} -n scylla \
  --mode User \
  --node-count ${nodesPer1} \
  --node-vm-size ${machineType1} \
  --zones ${zones} \
  --os-sku ${osSku} \
  --node-osdisk-type Managed \
  --node-osdisk-size ${rootDiskSize} \
  --kubelet-config kubeletconfig.json \
  --labels "scylla.scylladb.com/node-type=${nodeSelector1}" \
  --node-taints 'scylla-operator.scylladb.com/dedicated=scyllaclusters:NoSchedule' \
  --tags ${tags} \
  -o none
# create an application node
az aks nodepool add -g ${resourceGroup} --cluster-name ${clusterName} -n app \
  --mode User \
  --node-count ${nodesPer2} \
  --node-vm-size ${machineType2} \
  --zones ${zone} \
  --os-sku ${osSku} \
  --node-osdisk-type Managed \
  --node-osdisk-size ${rootDiskSize} \
  --kubelet-config kubeletconfig.json \
  --labels "scylla.scylladb.com/node-type=${nodeSelector2}" \
  --node-taints 'scylla-operator.scylladb.com/dedicated=application:NoSchedule' \
  --tags ${tags} \
  -o none
set +x

az aks get-credentials -g ${resourceGroup} -n ${clusterName} --context ${aksContext} --overwrite-existing
kubectl config use-context ${aksContext}
kubectl get nodes -L scylla.scylladb.com/node-type,topology.kubernetes.io/zone,kubernetes.io/arch,node.kubernetes.io/instance-type

# create the storage account and container for backups
./createStorageAccount.bash

else

# verb=delete
# no per-pool deletes: AKS drains a pool before deleting it, and the Scylla
# PodDisruptionBudget blocks that drain - the cluster delete removes the pools
az aks delete -g ${resourceGroup} -n ${clusterName} --yes
az group delete -n ${resourceGroup} --yes
# get-credentials --context names the context and the cluster entry the same
kubectl config delete-context ${aksContext}
kubectl config delete-cluster ${aksContext}
kubectl config delete-user clusterUser_${resourceGroup}_${clusterName}

fi
