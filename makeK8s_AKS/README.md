# Deploy a cluster on AKS

`makeBasicCluster.bash` uses the Azure CLI to create a small AKS cluster for internal testing, following the same pattern as `makeK8s_GKE`.

## Prerequisites

1. Install the Azure CLI. Ref: https://learn.microsoft.com/cli/azure/install-azure-cli
2. Log in with `az login`, and select the subscription with `az account set --subscription <name>`.
3. Make sure the region has vCPU quota for each VM family: `az vm list-usage -l westus3 -o table`.

## Create a cluster

Run `./makeBasicCluster.bash [clusterName]`. It takes around 10-15 minutes.

The script creates the resource group `<clusterName>-rg` and a cluster with three node pools.
Each pool's `scylla.scylladb.com/node-type` label comes from `nodeSelector0/1/2` in `init.conf`:

| Pool | VM size | Nodes | Label | Taint |
| --- | --- | --- | --- | --- |
| `system` | `Standard_D4s_v5` | 3 | `scylla-operator` | none |
| `scylla` | `Standard_L8as_v4` (local NVMe) | 3 | `scylla` | `dedicated=scyllaclusters:NoSchedule` |
| `app` | `Standard_D8ps_v6` (arm64) | 1 | `application` | `dedicated=application:NoSchedule` |

With `singleZone=false`, the `system` and `scylla` pools span zones 1, 2, and 3, so each Scylla rack lands in its own zone.
The `app` pool is pinned to `zone` (1).

The kube context is `aks_<region>_<clusterName>`.

## Backups

At the end, `makeBasicCluster.bash` runs `createStorageAccount.bash`, which creates the storage account `azStorageAccount` and the blob container `azBlobContainer` (both set in `init.conf`) in the cluster's resource group.
ScyllaDB Manager backs up to `azure:<azBlobContainer>`.
`deployScylla.bash` reads the account key with `az storage account keys list` at deploy time and writes it into the agent config secret; no key file is stored locally.

Account/key access is used because role-based access requires `Microsoft.Authorization/roleAssignments/write`, which the Contributor role does not include.

The storage account lives in the cluster's resource group, so `-d` deletes the backups along with the cluster.

## Destroying the cluster

Run `./makeBasicCluster.bash -d [clusterName]`. It deletes the cluster and the resource group (including the backup storage account), then removes the kubeconfig entries.

## Customization

- Region: `azRegion` in `init.conf`.
- VM sizes, OS image, disk size, and node counts: `aks.conf`.
- `Standard_L8as_v4` supports only the NVMe disk controller, so the OS disk is also a `/dev/nvme*` device.
  The ScyllaDB NodeConfig must select the local disks by NVMe model, not by device name alone.
