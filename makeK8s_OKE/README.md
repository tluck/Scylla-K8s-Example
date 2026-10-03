# Deploy an OKE cluster for ScyllaDB

`makeBasicCluster.bash` provisions the OCI infrastructure needed by this repository:

- a VCN with a public control-plane subnet, private worker/pod subnet, and public load-balancer subnet;
- an OKE Enhanced Cluster with VCN-native pod networking;
- a general-purpose node pool labeled `scylla-operator`;
- a three-node Dense I/O pool labeled and tainted for ScyllaDB, spread across the three OCI fault domains;
- an optional application pool labeled and tainted for the sample applications.

The dedicated pool's cloud-init enables the kubelet static CPU manager policy. All pools disable the legacy IMDSv1 endpoint and use IMDSv2. The Dense I/O pool's local NVMe devices are prepared later by `setupK8s.bash` using `local-csi-driver/nodeconfigOKE.yaml`.

## Prerequisites

- OCI CLI configured with `oci setup config`.
- `kubectl`, `jq`, and `base64`.
- OCI permissions to create networking, OKE, and Compute resources in the target compartment.
- Dense I/O capacity for at least three nodes in the selected availability domain.

## Configure and create

```bash
cp makeK8s_OKE/oke.conf.example makeK8s_OKE/oke.conf
$EDITOR makeK8s_OKE/oke.conf
./makeK8s_OKE/makeBasicCluster.bash
```

`OCI_REGION` and `OCI_COMPARTMENT_OCID` are required. The Kubernetes version and availability domain are discovered when left empty. The script uses the OCI profile selected by `OCI_CLI_PROFILE`, waits for every OCI operation that later steps depend on, creates kubeconfig with OCI token version 2.0.0, embeds the selected OCI profile in its exec credentials, and renames the context to `${OKE_CLUSTER_NAME}-oke`. It writes to the single file named by `KUBECONFIG`, or to `${HOME}/.kube/config` when `KUBECONFIG` is unset.

To run the name/context collision checks without creating anything:

```bash
./makeK8s_OKE/makeBasicCluster.bash --preflight
```

Preflight ignores OCI list records already in `DELETED` or `TERMINATED`. It briefly retries records still in `DELETING` or `TERMINATING`, because OCI list results can lag a completed delete. A live collision is reported with its resource type, OCID, lifecycle state, and ownership tag status. Live untagged or differently tagged resources are never adopted or deleted.

For each pool, image discovery asks OKE for OL8 sources filtered by the cluster's Kubernetes version and configured architecture (`X86_64` by default). It then verifies that OKE supports the requested shape and that Compute's complete image-shape compatibility list contains that shape. Selection happens for every requested pool before the first node pool is created. `*_NODE_IMAGE_OCID` can pin a pool to a specific image; the override must be present in OKE's filtered sources and pass the same shape check. The legacy common `OKE_NODE_IMAGE_OCID` override is also accepted as a fallback for all pools.

OKE's supported shape set is narrower than Compute's general image compatibility set and differs by region. At validation time, OKE 1.36.1 in `us-sanjose-1` advertised only the fixed `VM.DenseIO2.*` and `BM.DenseIO2.52` Dense I/O shapes, while `us-phoenix-1` advertised `VM.DenseIO.E4.Flex`, `VM.DenseIO.E5.Flex`, and their bare-metal variants. Always confirm the current result with `oci ce node-pool-options get` before choosing a shape. The newest non-GPU OKE OL8 image returned for Kubernetes 1.36.1 had build 1699, which is newer than the build 1367 at which OKE OL8 images enable the required cgroups v2 by default.

Before creating the Scylla pool, the script checks OCI resource availability for the complete three-node topology. For `VM.DenseIO2.8`, it checks `dense-io2-core-count` and requires 24 available units (three nodes at eight OCPUs each). It refuses to create any Scylla nodes when that full amount is unavailable. `VM.DenseIO.E4.Flex` and `VM.DenseIO.E5.Flex` are automatically mapped to `dense-io-e4-core-count` and `dense-io-e5-core-count`; other Dense I/O families can use the same guard by setting `SCYLLA_NODE_LIMIT_NAME` and `SCYLLA_NODE_LIMIT_UNITS_PER_NODE`. Do not disable the mapping merely to bypass a real limit. `SCYLLA_NODE_AD` can place Scylla nodes in a different availability domain from the general pool, while `SCYLLA_NODE_FAULT_DOMAINS_JSON` remains constrained to three distinct OCI fault domains so configuration cannot silently reduce the intended rack topology.

Standard and Optimized x86 shapes are not drop-in replacements for this repository's Scylla pool, even when their core limits have ample room: `nodeconfigOKE.yaml` deliberately builds XFS storage from locally attached NVMe devices. Use an OKE-advertised Dense I/O shape. A validated fallback is `VM.DenseIO.E5.Flex` at 8 OCPUs and 96 GB in a region/AD where both OKE and the tenancy advertise it and at least 24 `dense-io-e5-core-count` units are available. This is also an OCI shape listed in ScyllaDB's cloud instance recommendations.

### Dense I/O limit visibility and requests

Service limit definitions and values must be queried with the root tenancy OCID, even when resource availability is checked for the deployment compartment. In the Console, use **Governance & Administration → Tenancy Management → Limits, Quotas and Usage**, select the target region, then filter for Service `Compute`, Scope `Availability Domain`, the target AD, and the deployment compartment. Select Subscription `None` for limits whose definition has an empty `supported-subscriptions` list; selecting an assigned subscription can hide or reject an otherwise valid Compute limit.

`is-eligible-for-limit-increase: true` means the limit is adjustable, but does not guarantee that every account model exposes it in the standard selector. Oracle's current default-limits documentation lists `dense-io2-core-count` as **Contact Us** for Pay As You Go or Trial accounts. Use **Help → Targeted help → Request a limit increase** with Subscription `None`, or use the limit row's **Open support request** action if the limit is omitted. An empty result from `oci limits-increase question list` only means that the limit has no additional questionnaire fields; it is not an eligibility result.

The Limits Increase API accepts the same request. For an AD-scoped limit, `scope` is the logical AD name and `value` is the requested new total. The following only shows the supported payload; do not run it until the desired total and support path are approved:

```bash
oci limits-increase limits-increase-request create \
  --compartment-id "${TENANCY_OCID}" \
  --display-name "DenseIO2 capacity for OKE ScyllaDB" \
  --justification "Three additional VM.DenseIO2.8 OKE workers require 24 OCPUs" \
  --items '[{"serviceName":"compute","limitName":"dense-io2-core-count","region":"us-sanjose-1","scope":"<logical-AD-name>","value":<new-total>}]'
```

Viewing definitions and values requires `inspect resource-availability in tenancy`; checking a deployment compartment requires `read resource-availability` there. Subscription-specific Console requests additionally require `Allow group <group_name> to READ organizations-assigned-subscription in tenancy`. That subscription policy is not required for a non-subscription Compute limit.

Every waited OKE work request is checked directly. If OCI reports `FAILED`, the script retrieves and prints both `ce work-request-error` and `ce work-request-log-entry` output before stopping. A node pool can remain displayed as `CREATING` after its create or reconcile work request has failed; that lifecycle value is not treated as success.

The public API and load-balancer CIDRs default to `0.0.0.0/0` for an immediately usable example. Restrict `API_INGRESS_CIDR` and `LOAD_BALANCER_INGRESS_CIDR` in `oke.conf` for production use.

The optional application pool is disabled by default and uses an x86 shape/image when enabled. The sample application scripts already target its `application` node label; ensure the application images support `amd64`, or extend the provisioning script with a matching OKE aarch64 image before choosing an Arm application shape.

After creation, return to the repository root:

```bash
./setupK8s.bash
./deployScylla.bash
```

The top-level scripts detect the `-oke` context. Scylla racks are pinned to `oci.oraclecloud.com/fault-domain` values `FAULT-DOMAIN-1` through `FAULT-DOMAIN-3`; monitoring, Manager, and MinIO use OKE's `oci-bv` StorageClass.

## Backups

ScyllaDB Manager's documented S3-compatible provider list does not include OCI Object Storage. This repository therefore does not inject OCI Customer Secret Keys or claim native OCI Object Storage support. When backups are enabled on OKE, `init.conf` selects the supported in-cluster MinIO path. MinIO uses a 50 GiB `oci-bv` volume, matching OCI Block Volume's minimum size.

This example retains the repository's demo MinIO credentials (`minio` / `minio123`) on a cluster-internal endpoint. Replace them in both the Tenant and Manager agent configuration before using this outside an isolated test cluster.

Use an external backup target only after independently validating it against the exact ScyllaDB Manager version and configuring the agent templates yourself.

## Teardown

Delete the ScyllaDB deployment before deleting its OKE infrastructure:

```bash
./deployScylla.bash -x
./setupK8s.bash -x
./makeK8s_OKE/makeBasicCluster.bash -d
```

The provisioning script tags the VCN, cluster, and explicitly created network resources with `scylla_k8s_example_oke=${OKE_CLUSTER_NAME}`. Teardown only selects live tagged clusters and VCNs with the configured names, deletes every selected cluster and its node pools first, then removes subnets, security lists, route tables, gateways, and the VCN in dependency order. OCI removes the VCN's default route table, default security list, and default DHCP options with the VCN. A final bounded discovery check prevents teardown from reporting success while any live tagged cluster or VCN remains. This prevents `-d` from deleting an unrelated same-named cluster or VCN. It also removes the generated `${OKE_CLUSTER_NAME}-oke` kubeconfig context.

If creation stops after the cluster or some node pools are active, fix the configuration and resume without deleting working resources:

```bash
./makeK8s_OKE/makeBasicCluster.bash --resume
```

Resume requires exactly one live tagged ACTIVE cluster and one live tagged AVAILABLE VCN, rediscovers every expected AVAILABLE network resource, verifies the existing cluster version/state, reuses ACTIVE same-named node pools, and creates only missing pools. For a non-ACTIVE same-named pool, it retrieves the latest associated work request. A failed request and its OCI errors/logs are reported even when the pool still says `CREATING`; the script never deletes, replaces, or adopts that partial pool automatically. A fully deleted deployment is not resumable; use a normal create, even if OCI still returns terminal records for its old name. A normal rerun detects genuinely live resources and directs you to `--resume` or teardown.

For a Dense I/O service-limit failure, preserve the ACTIVE cluster and system pool. Request enough AD-scoped limit for all other tenancy usage plus the full three-node Scylla pool, or free equivalent usage. If the standard form omits the limit, use Subscription `None` and the support path described above rather than assuming the limit is non-adjustable. If OCI is still reconciling the partial pool, wait for it to become `ACTIVE` and rerun `--resume`. To change the shape or availability domain in the same region, first verify the replacement through `oci ce node-pool-options get`, set the matching `SCYLLA_NODE_*` values, explicitly delete only the failed node pool by its OCID, wait for that delete work request to succeed, and then rerun `--resume`. Moving to another region requires recreating the regional OKE cluster there; an existing OKE cluster cannot attach a node pool from another region. Do not use the repository-wide `-d` path for same-region recovery because it removes the working cluster and system pool.

To discard a partial deployment instead, rerun with `-d` and then create it again. Untagged resources are intentionally outside the deletion scope.
