# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A collection of bash scripts and YAML templates for deploying ScyllaDB on Kubernetes via the [Scylla Operator](https://github.com/scylladb/scylla-operator). It is **not** a Go project, Helm chart, or Terraform module — it is a configuration-driven shell pipeline that reads `init.conf`, renders templates with `sed`, and applies the result with `kubectl` or `helm`.

Prereqs on the operator's machine: `kubectl`, `helm`, `jq`, `bash` (the scripts assume bash 4+ in places), and a working kubeconfig context. Cloud provisioning additionally needs `terraform` (EKS) or `gcloud` (GKE).

## Core architecture

Three things drive everything:

1. **`init.conf`** — sourced by almost every script. Defines install mode (`helmEnabled`), feature flags (`backupEnabled`, `minioEnabled`, `enableAlternator`, `enableAuth`, `enableTLS`, `mTLS`, `customCerts`), versions (`operatorTag`, `dbVersion`, `managerVersion`, `agentVersion`, `prometheusVersion`), and topology (`clusterName`, `dataCenterName`, `clusterNamespace`, `externalSeeds`, node selectors, resource caps). **The bottom of the file branches by `kubectl` context** — Docker Desktop gets tiny resource limits and force-enables MinIO; non-Docker gets cloud-sized defaults and assumes pre-labeled nodepools. Almost every behavioral switch in the pipeline can be traced back to this file.

2. **`setupK8s.bash`** (alias `_step_1`) — cluster-wide prerequisites: cert-manager, kube-prometheus-stack (then deletes the chart's bundled Grafana so Scylla's monitoring CR owns Grafana), Scylla Operator (Helm renders `templateOperator.yaml`; non-Helm path applies upstream `operator.yaml` keyed off `operatorTag`), `ScyllaOperatorConfig` aligning `scyllaUtilsImage` with `dbVersion`, local storage (Docker: `rancher.io/local-path` StorageClass; cloud: applies the manifest set under `local-csi-driver/` after rendering `nodeconfigTemplate.yaml`), and optional MinIO.

3. **`deployScylla.bash`** (alias `_step_2`) — the Scylla cluster, monitoring, and manager. Preflights for the `xfs` storage class, creates the backup-agent secret (S3 / MinIO / GCS depending on context and `gcs-service-account.json` presence), provisions TLS material when `customCerts` / `mTLS`, writes a `${clusterName}-config` ConfigMap with `scylla.yaml` when `enableAuth && !helmEnabled`, renders `templateCluster.yaml` (or `templateClusterHelm.yaml`) per-namespace and applies it, waits for the cluster Available condition, patches `${clusterName}-client` to expose port 10000 (REST API), then applies `templateDBMonitoring.yaml` (with Prometheus CR + RBAC + Grafana ConfigMap patches) and the manager template, and finally runs `port_forward.bash` for `dataCenterName=dc1`.

Teardown flags are uniform across both scripts:
- **`-d`** — delete deployments / Helm releases, leave PVCs / CRDs / namespaces.
- **`-x`** — `-d` plus patches finalizers, deletes PVCs/PVs, removes cluster/manager namespaces; `setupK8s.bash -x` additionally removes CRDs matching `scylla`/`cert-manager`/`coreos`.

`deployScylla.bash -c` deploys the cluster only, port-forwards if `dataCenterName=dc1`, and exits before monitoring/manager.

## The `sed` template engine

Most `template*.yaml` files contain literal placeholders (`NAMESPACE`, `CLUSTERNAME`, `DBVERSION`, `#BAK `, `#GCS `, `#MDC `, `#ALT `, `#CERTS `, `#CUSTC `, etc.) that the deploy scripts substitute via long `sed` pipelines (see `deployScylla.bash:343-375`, `672-690`). Outputs are written to namespaced files like `${clusterNamespace}-${clusterName}.ScyllaCluster.yaml`.

When changing cluster shape (racks, capacities, broadcast types), **edit the template, not the rendered file** — the rendered file is overwritten on the next deploy.

The `#XYZ ` placeholders work as comment toggles: a sed replacement of `#BAK ` → empty string un-comments the lines tagged with that prefix; non-replacement leaves them as comments. Be careful adding new tokens — the existing set has at least one collision (`#CUSTC ` is reused for two distinct meanings between the cluster template and the manager template).

## Common commands

```bash
# Full setup from a fresh kubeconfig
./setupK8s.bash         # or ./_step_1
./deployScylla.bash     # or ./_step_2

# Cluster only (skip monitoring + manager)
./deployScylla.bash -c

# Teardown
./deployScylla.bash -d   # keep PVCs / namespaces
./deployScylla.bash -x   # full wipe of cluster + manager namespaces
./setupK8s.bash -d       # remove operators, keep CRDs/namespaces
./setupK8s.bash -x       # full wipe of operators, CRDs, and namespaces

# CQL access
./client.bash            # cqlsh against local port-forward (default host: scylla-client)
./client.bash -r         # cqlsh via `kubectl exec` into the in-cluster client service
./client_tls.bash        # TLS variant

# Manager + backups
./manager.bash           # exec sctool inside the manager pod
./create_backup.bash     # ad-hoc backup; -n uses Manager native mode
./list_backups.bash      # list tasks and stored backups

# Stuck-resource recovery
./remove_stuck_crds.bash <type/name> <namespace>   # strips finalizers, then deletes
./remove_stuck_namespace.bash <namespace>
./remove_stuck_manager_tasks.bash [namespace]      # Degraded ScyllaDBManagerTasks
./remove_stuck_pv.bash <pv-name> [<pv-name>...]    # validated: refuses --all / non-pv

# Operator upgrade
./upgrade_operator_latest_helm.bash
```

## Cluster provisioning (cloud)

Underlying Kubernetes provisioning lives in sibling trees — **not** in `setupK8s.bash`:

- **`makeK8s_GKE/`** — `makeBasicCluster.bash`, plus `create_second_pool.bash` for a second nodepool. `createServiceAccount.bash` creates the `gke-sa` GCP service account, grants it the bucket roles, and mints a JSON key to `gcs-service-account.json` (symlinked into the repo root). **The credentials that actually reach the agents are that key file** — `deployScylla.bash` puts it in the `gcs-service-account` secret, which `templateCluster.yaml` mounts at `/etc/scylla-manager-agent/gcs-service-account.json`. `deployScylla.bash` also applies the `iam.gke.io/gcp-service-account` Workload Identity annotation to the member ServiceAccount, but nothing depends on it while the key file is mounted; treat the key file as the authoritative mechanism.
- **`makeK8s_EKS/`** — Terraform (`eks.tf.v6` / `eks.tf.v5`, `variables.tf`); driven by `makeBasicClusterTerraform.bash`. Also has `create_cluster_eksctl.bash` (alternative path) and `nodeadm.bash` / `nodeconfig.bash` for in-place node tuning.
- **`makeK8s_OKE/`** — OCI CLI provisioning driven by `makeBasicCluster.bash`. It creates the VCN/networking, an OKE Enhanced Cluster, a system pool, a Dense I/O ScyllaDB pool spread across OCI fault domains, and an optional application pool. The generated context ends in `-oke`; `setupK8s.bash` selects `local-csi-driver/nodeconfigOKE.yaml`, and monitoring/Manager use `oci-bv`. OKE backups deliberately default to in-cluster MinIO because OCI Object Storage is not in ScyllaDB Manager's documented S3 provider list.

All flows typically accept `-d` for teardown. After provisioning, the rest of the pipeline (`setupK8s.bash` → `deployScylla.bash`) is identical.

## Sample apps (`sample_app/`)

Workloads that exercise the deployed cluster. They have their **own** `sample_app/init.conf` (separate from the top-level one — with overlapping variable names; treat them as independent files) and helper scripts:

- **`_deploy_python-apps_k8s.bash` / `_deploy_java-apps_k8s.bash`** — deploy app pods.
- **`build_python_docker_image.bash` / `build_java_docker_image.bash`** — build the images first.
- **`run_app_k8s.bash <script.py> [args]`** — exec a Python script (or `cqlsh`) inside an app pod with env-derived credentials and contact points (`CLUSTER`, `DC`, `USERNAME`, `PASSWORD`, `CONTACT_POINTS`).
- **`get_certs_k8s.bash`** — copies operator-issued TLS material out of the cluster into the app for TLS clients.

Top-level Python load generators live directly under `sample_app/` (`loader.py`, `slow_loader.py`, `query.py`, `tombstone.py`, `proxy.py`). Subdirectories:

| Path | Purpose |
| --- | --- |
| `alternator-client/` | Python Alternator + CQL load generators, blob encode/decode helpers. Has its own README with per-script flags. |
| `alternator-boto3/` | boto3 Alternator scripts (table create/ingest/query) + CA cert helper. |
| `alternator-java-ingest/` | Java Alternator ingest sample (Maven `pom.xml`, `Dockerfile`, `run_it.bash`). |
| `cql-java-ingest/` | Java CQL ingest sample with comparison helpers (`compare_ingest_java.bash`). |
| `alternator-to-cql/` | Java library + integration tests using Alternator's internal CQL layout. Has a `Makefile`. |

Nested `.git` directories may appear under some `sample_app/` subtrees — vendored from other repos.

## Sharp edges (read before editing)

- **Scripts intentionally run without `set -e`.** `deployScylla.bash` has `# set -eo pipefail` commented out on line 3; `setupK8s.bash` has none. Errors propagate as confusing downstream timeouts rather than immediate failures. Be cautious adding logic that depends on prior commands succeeding — wrap with explicit checks.

- **Script casing matters.** `setupK8s.bash` has a capital **U**. The README warns about this explicitly.

- **`init.conf` is silently optional.** Each script does `[[ -e init.conf ]] && source init.conf`. If you run from the wrong directory, every variable expands to empty and you get cryptic `kubectl -n  apply ...` failures.

- **K8s convention: node-role labels carry empty-string values.** `labelNodes.bash` previously used `select(... != "")` and silently labeled nothing on Docker Desktop — now uses `has(...)`. Apply the same `has()` pattern if you write similar selectors.

- **Two TLS / auth flags are tightly coupled.** `enableTLS` requires `enableAuth`; `mTLS` swaps user/password auth for client certs; `customCerts` replaces operator-managed certs (needed for two DCs in one k8s cluster with TLS). See `TLS Certs - Use Cases.md` for what each operator-issued secret is for.

- **`templateCluster.yaml` vs `templateClusterHelm.yaml`** — kept in sync manually, render to the same final manifest shape via different paths. Touch both when adjusting cluster topology.

- **The `scylla-latest` symlink** at the repo root points to `/opt/Source/scylla/scylla-operator/helm/` — a developer-machine path. Only used when `operatorTag=latest`; will hard-fail for anyone else.

- **`dbVersion` is pinned in two places.** `init.conf` sets it; `setupK8s.bash:138-143` has a hardcoded fallback for the `ScyllaOperatorConfig.scyllaUtilsImage` when `operatorTag` is outside the 1.2x range, documented as a workaround for the 2025.2 / 2025.3 image bug. Update both together.

- **`gcs-service-account.json` must be non-empty, and every guard tests `-s`, not `-e`.** A failed `gcloud iam service-accounts keys create` leaves a zero-byte file; with `-e` that file selected the GCS path, mounted empty credentials, and produced a misleading `403: Provided scope(s) are not authorized` when Manager validated the backup location — while also making `createServiceAccount.bash` exit early forever, so it could never repair itself. Use `-s` for any new test of this file.

- **The agent secrets are mounted with `subPath`, which Kubernetes never refreshes.** `gcs-service-account` and `${clusterName}-agent-config-secret` reach the agents via `subPath` mounts (`templateCluster.yaml:125` and friends). Rewriting the secret does **nothing** to a running pod. `deployScylla.bash` hashes both secrets before and after writing and rolls the rack StatefulSets only when the content actually changed, so a first deploy and a no-op re-run restart nothing. Anything else that edits these secrets must restart the racks itself.

- **Re-applying the ScyllaCluster can orphan its Manager tasks.** The CR gets a new `owner-uid` and can no longer adopt the task it created previously, so the task goes Degraded with `task name <name> is already used`. The operator also backs off for a long time before retrying a Degraded `ScyllaDBManagerTask` — a task whose root cause was fixed can sit Degraded for the better part of an hour. `remove_stuck_manager_tasks.bash` handles both.

- **The pre-1.19 monitoring template** (`templateDBMonitoring.pre-1.19.yaml`) exists because the CR schema changed in operator 1.19. Don't delete it without verifying the minimum supported operator version.

- **The step symlinks (`_step_1`, `_step_2`) may not exist in every checkout.** Call the underlying scripts by name when in doubt.

## Reference

- Scylla Operator docs: https://operator.docs.scylladb.com
- Scylla Manager docs: https://docs.scylladb.com/operating-scylla/manager/
- `README.md` is the long-form walkthrough of every flag and step — keep it in sync with script behavior.
- `TLS Certs - Use Cases.md` documents what each operator-issued TLS secret is for.
