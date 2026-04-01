# Scylla K8s Example

This repository holds examples of deploying ScyllaDB with the Kubernetes [Scylla Operator](https://github.com/scylladb/scylla-operator).

## End-to-End Deployment in K8s

This example deploys a small-scale six-node cluster in a single datacenter (cloud region). Two node groups are typical: one dedicated to ScyllaDB and a second for supporting workloads. Optionally, a second datacenter can be deployed by changing `init.conf` and re-running the deploy script.

### Prerequisites

Install these tools in addition to this repository:

- A clone of this repository (or copy of the `k8s` tree).
- [Helm](https://helm.sh/) — for installing operators and optional chart-based Scylla resources.
- `kubectl` — for applying manifests and managing resources.
- `jq` — for JSON processing (used during teardown and patches).
- Network access to pull Helm charts and container images (for example from Docker Hub and chart repositories).

### TL;DR

1. For GKE, run `./makeK8s_GKE/makeBasicCluster.bash`. For EKS, run `./makeK8s_EKS/makeBasicClusterTerraform.bash` (or the parallel scripts under `test_EKS/` if you use that layout).
2. Run `./setUpK8s.bash` — installs cert-manager, monitoring stack operator dependencies, Scylla Operator, local storage, and optional MinIO.
3. Edit `init.conf` as needed, then run `./deployScylla.bash` — deploys the Scylla cluster, ScyllaDB Monitoring, Scylla Manager, and optional port-forwards.

Some environments use convenience symlinks `./_step_1` → `setUpK8s.bash` and `./_step_2` → `deployScylla.bash`; if those links are not present, invoke the scripts by name as above.

These flows assume node tuning (for example kubelet CPU manager policy) is applied as part of your cluster provisioning scripts where required.

---

## Configuration: `init.conf`

`setUpK8s.bash` and `deployScylla.bash` both source `init.conf` when it exists. It defines:

- **Install mode:** `helmEnabled` — Scylla cluster / manager via Helm charts vs raw manifests.
- **Features:** `backupEnabled`, `minioEnabled`, `enableAlternator`, `enableAuth`, `enableTLS`, `mTLS`, `customCerts`, `writeIsolation`.
- **Versions:** `operatorTag`, `dbVersion`, `managerVersion`, `agentVersion`, `prometheusVersion`.
- **Topology:** `clusterName`, `dataCenterName`, `clusterNamespace`, `externalSeeds` (multi-DC), node selectors, capacities, and limits — often adjusted per `kubectl` context (`docker-desktop`, `gke`, `eks`, etc.).

---

## `setUpK8s.bash` — cluster prerequisites and operators

Run from the `k8s` directory (same directory as `init.conf`).

### Normal run (no flags)

1. **Helm repositories** — Adds/updates: Scylla operator charts, Jetstack (cert-manager), Prometheus community (kube-prometheus-stack), MinIO operator.
2. **Node labels (Docker Desktop only)** — If `context` matches `*docker*`, runs `./labelNodes.bash` so workloads can target labeled nodes.
3. **cert-manager** — Installs via Helm into `cert-manager` if not already present, with node selectors from `init.conf`.
4. **kube-prometheus-stack** — Installs as `monitoring` in `scyllaMonitoringNamespace` (from `init.conf`), then **removes** the chart’s default Grafana deployment so Scylla’s own monitoring stack can own Grafana.
5. **Scylla Operator** — Either:
  - **Helm** (`helmEnabled=true`): renders `templateOperator.yaml` to `scylla-operator.yaml` and `helm install`s, or  
  - **kubectl** (`helmEnabled=false`): applies `operator.yaml` from the Scylla Operator GitHub release matching `operatorTag`.
6. **Waits** — For `scylla-operator` and `webhook-server` deployments to become available.
7. **ScyllaOperatorConfig** — Applies a `ScyllaOperatorConfig` named `cluster` setting `scyllaUtilsImage` to `docker.io/scylladb/scylla:${dbVersion}` (aligned with your DB image tag).
8. **Local storage for Scylla**
  - **Docker / local:** Creates `StorageClass` `scylladb-local-xfs` using `rancher.io/local-path`.
  - **Cloud (non-Docker):** Renders `local-csi-driver/nodeconfig.yaml` from `nodeconfigTemplate.yaml` (EKS vs non-EKS), applies NodeConfig, applies the local CSI driver manifest set under `local-csi-driver/`, waits for the driver DaemonSet.
9. **MinIO** — If `minioEnabled=true`, runs `./deployMinio.bash`.

### Teardown flags


| Flag     | Behavior                                                                                                                                                                                                                                                    |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`-d`** | Deletes NodeConfigs, namespaces `local-csi-driver` and `scylla-operator-node-tuning`, uninstalls Helm releases: `monitoring`, `cert-manager`, `scylla-operator`. Optionally uninstalls MinIO if enabled. Does **not** remove namespaces or CRDs by default. |
| **`-x`** | Same as **`-d`**, plus deletes monitoring / cert-manager / scylla-operator namespaces and CRDs matching `scylla`, `cert-manager`, and `coreos` (Prometheus operator CRDs).                                                                                  |


**Note:** Script filename is **`setUpK8s.bash`** (capital **U**), not `SetupK8s.bash` or `setupK8s.bash`.

---

## `deployScylla.bash` — Scylla cluster, monitoring, and manager

Run from the `k8s` directory after `setUpK8s.bash` has created the `scylladb-local-xfs` storage class.

### Flags


| Flag     | Behavior                                                                                                                                                                                                                  |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`-c`** | **Cluster only** — Deploys the Scylla cluster (and related cert/config setup), waits for it, then runs `./port_forward.bash` when `dataCenterName` is `dc1`, and **exits** without ScyllaDB Monitoring or Scylla Manager. |
| **`-d`** | Removes Scylla cluster, manager, monitoring CRs, certificates, and issuers for the namespaces in `init.conf`. Leaves PVCs unless **`-x`**.                                                                                |
| **`-x`** | Same as **`-d`**, plus patches finalizers, deletes PVCs/PVs for the cluster and manager namespaces, and deletes those namespaces.                                                                                         |


### Normal deploy flow (no teardown flags)

1. **Preflight** — Verifies a storage class containing `xfs` exists (expects prior `setUpK8s.bash`).
2. **Namespace** — Ensures `clusterNamespace` exists.
3. **Backup agent secret** — If `backupEnabled`, creates `${clusterName}-agent-config-secret` with S3, MinIO, or GCS settings depending on context and `minioEnabled` / `gcs-service-account.json`.
4. **TLS** — Optional custom server issuers/certificates (`customCerts`), client ClusterIssuer and certificates for `mTLS` or custom client TLS.
5. **Scylla configuration** — When `enableAuth` is true and `helmEnabled` is false, applies a ConfigMap `${clusterName}-config` with `scylla.yaml` (auth, TLS, Alternator, optional object storage endpoints, etc.).
6. **ScyllaCluster** — Renders `templateClusterHelm.yaml` or `templateCluster.yaml` to a namespaced YAML and applies via Helm or `kubectl`. Supports multi-DC via `externalSeeds` when not `dc1`.
7. **GKE** — If `gcs-service-account.json` exists and context matches `*gke*`, annotates the member service account for Workload Identity.
8. **Wait and patch** — Waits for `ScyllaCluster` to be Available; patches `${clusterName}-client` to expose port **10000** (REST API) if missing.
9. With **`-c`** — Port-forward for `dc1` only, then stop.
10. **ScyllaDB Monitoring** — Applies `templateDBMonitoring.yaml` output; creates Prometheus RBAC and `Prometheus` CR; patches Grafana ConfigMaps (default dashboard, scrape interval), patches Grafana deployment dashboard mounts, restarts ReplicaSets as needed; prints Grafana admin credentials from the secret.
11. **Scylla Manager** — Renders manager template (Helm or kubectl); optional manager TLS certificate when `customCerts`; applies and waits for `scylla-manager` deployment.
12. **RBAC** — Applies pod watch Role/RoleBindings for Scylla member and manager service accounts.
13. **Port forwards** — For `dataCenterName=dc1`, runs `./port_forward.bash` (kills existing `kubectl port-forward`, optional MinIO 9000, headless client service, CQL/TLS/shard-aware ports, Alternator, Grafana, Prometheus; on macOS can trust Grafana cert in Keychain; may append `/etc/hosts` entries).

---

## Access

- **CQL (non-TLS):** `./client.bash`
- **CQL from inside a pod:** `./client.bash -r`
- **CQL with TLS:** `./client_tls.bash`
- **Scylla Manager CLI:** `./manager.bash`

Port-forward details and local hostnames are handled in `port_forward.bash` when invoked from `deployScylla.bash`.

---

## Backup

- Create backups with **`./create_backup.bash`**, or use `sctool` on the manager pod.
- Pass **`-n`** to use Manager’s **native** backup method (see the script for details).
- List backup tasks and stored backups with **`./list_backups.bash`** (same `init.conf` / bucket context as `create_backup.bash`).

Example manager commands (adjust cluster name and namespace to match `init.conf`):

```bash
sctool cluster update --username cassandra --password cassandra -c region1/scylla
sctool backup -c region1/scylla -L s3:scylla-backups-uswest2
sctool backup -c region1/scylla -L gcs:scylla-backups-gke
sctool backup --name="hourly_backup" --cluster="region1/scylla" --location='s3:scylla-backups-uswest2' --cron="@hourly" --retention=24
```

For GKE backups to GCS, provide `gcs-service-account.json` and configure buckets as in `init.conf`.

---

## Sample app

Under `sample_app/` you can build images and deploy workloads with scripts such as:

- **`_deploy_python-apps_k8s.bash`** / **`_deploy_java-apps_k8s.bash`** — deploy sample apps to the cluster.
- **`run_app_k8s.bash`** — run a Python script or `cqlsh` against the cluster from a configured environment.
- **`build_python_docker_image.bash`** / **`build_java_docker_image.bash`** — build the sample container images before deploy.

Top-level Python examples in `sample_app/` include **`loader.py`**, **`query.py`**, **`slow_loader.py`**, **`test_compression.py`**, **`tombstone.py`**, and **`proxy.py`** (see each file’s usage).

Subdirectories (each may have its own README, Makefile, or `run_it.bash`):


| Path                          | Role                                                                                                                                                                             |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`alternator-client/`**      | Python Alternator and CQL load generators, blob encode/decode helpers, cleanup utility — see [sample_app/alternator-client/README.md](sample_app/alternator-client/README.md). |
| **`alternator-boto3/`**       | boto3-oriented Alternator scripts (table create, ingest, query) and cert helper.                                                                                                 |
| **`alternator-java-ingest/`** | Java Alternator ingest sample (Maven, Docker).                                                                                                                                   |
| **`cql-java-ingest/`**        | Java CQL ingest sample and comparison helper scripts.                                                                                                                            |
| **`alternator-to-cql/`**      | Java library and integration tests for Alternator-to-CQL style writes.                                                                                                           |


Use `kubectl exec` into the application pod as needed. For TLS material from the cluster into a sample app, see `sample_app/get_certs_k8s.bash`.

---

## Destroy / cleanup

- **`setUpK8s.bash -d`** or **`-x`** — Removes operators, monitoring stack install, cert-manager, local CSI driver namespace pieces, and optionally CRDs/namespaces (see table above).
- **`deployScylla.bash -d`** or **`-x`** — Removes Scylla cluster, manager, monitoring, and certs; **`-x`** also clears PVCs/PVs and deletes cluster/manager namespaces.
- **Cluster provisioning scripts** — `makeBasicCluster.bash` (GKE/EKS) often support **`-d`** to tear down the whole Kubernetes cluster.

---

## Consistency notes (repository hygiene)

These are worth knowing when navigating the tree:


| Topic                | Note                                                                                                                                                    |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Step symlinks**    | README historically referenced `./_step_1` / `./_step_2`; they may not exist in every checkout — call `setUpK8s.bash` and `deployScylla.bash` directly. |
| **Parallel trees**   | `makeK8s_EKS/` and `test_EKS/` contain similar Terraform/helper scripts; keep changes in sync if you maintain both.                                     |
| **sample_app VCS**   | Nested `.git` directories under `sample_app` may appear; treat as optional submodules or vendored trees.                                                |


---

## Documentation

Scylla Operator documentation: [Scylla Operator Docs](https://operator.docs.scylladb.com).

---

## Features (high level)

- Multi-zone clusters and multi-datacenter patterns via `init.conf` and seeds.
- Scaling racks/nodes per operator and templates.
- Monitoring with Prometheus and Grafana (ScyllaDB Monitoring CR + kube-prometheus-stack base).
- [Scylla Manager](https://docs.scylladb.com/operating-scylla/manager/) for backups, repairs, and operations.
- TLS (operator-managed, custom, or mTLS), Alternator API, optional MinIO or cloud object storage for backups.
- Dead node replacement, upgrades, and other operator workflows as documented upstream.

Contributions can be submitted as pull requests to the owning repository.
