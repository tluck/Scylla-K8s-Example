#!/usr/bin/env bash

# run from this directory - init.conf and aks.conf are relative
cd "$(dirname "$0")" || exit 1

source init.conf
source aks.conf

# ScyllaDB Manager backs up to azure:${azBlobContainer} with account/key access;
# deployScylla.bash reads the key at deploy time and puts it in the agent config secret.
# (Role-based access would need Microsoft.Authorization/roleAssignments/write, which
# Contributor does not have.)
if [[ -z ${azStorageAccount} || -z ${azBlobContainer} ]]; then
  printf "* * * Error: azStorageAccount and azBlobContainer must be set in init.conf\n" >&2
  exit 1
fi

if az storage account show -n ${azStorageAccount} -o none 2>/dev/null; then
  echo "Storage account ${azStorageAccount} already exists"
else
  if [[ $(az storage account check-name -n ${azStorageAccount} --query nameAvailable -o tsv) != true ]]; then
    printf "* * * Error: storage account name %s is taken - change azStorageAccount in init.conf\n" "${azStorageAccount}" >&2
    exit 1
  fi
  echo "Creating storage account ${azStorageAccount} in ${resourceGroup}"
  az storage account create -g ${resourceGroup} -n ${azStorageAccount} -l ${region} \
    --sku Standard_LRS \
    --kind StorageV2 \
    --https-only true \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --tags ${tags} \
    -o none || { printf "* * * Error: storage account create failed\n" >&2; exit 1; }
fi

# container-rm uses the management plane, so no blob data role is needed
if [[ $(az storage container-rm exists --storage-account ${azStorageAccount} -n ${azBlobContainer} --query exists -o tsv) == true ]]; then
  echo "Container ${azBlobContainer} already exists"
else
  echo "Creating container ${azBlobContainer}"
  az storage container-rm create --storage-account ${azStorageAccount} -n ${azBlobContainer} -o none \
    || { printf "* * * Error: container create failed\n" >&2; exit 1; }
fi
