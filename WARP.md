# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

Project: Scylla-K8s-Example

Purpose: End-to-end examples for deploying ScyllaDB on Kubernetes using Scylla Operator, with optional monitoring (Prometheus/Grafana), Scylla Manager, TLS, and backups to S3/GCS/Minio.

Common commands

- Quickstart (GKE/EKS provisioning)
  - GKE: ./makeK8s_GKE/makeBasicCluster.bash
  - EKS (Terraform): ./makeK8s_EKS/makeBasicClusterTerraform.bash

- Install operators, storage class, and prerequisites
  - One-step: ./_step_1
  - Equivalent: ./setupK8s.bash

- Deploy Scylla, monitoring, and Scylla Manager
  - One-step: ./_step_2
  - Equivalent: ./deployScylla.bash
  - Variants:
    - Cluster only (skip monitoring/manager): ./_step_2 -c
    - Include Helm instead of raw kubectl: set helmEnabled=true in init.conf before running

- Teardown
  - Remove cluster resources (keeps PVCs):
    - ./_step_2 -d
  - Full cleanup (also deletes PVCs/PVs/namespaces):
    - ./_step_2 -x
  - Remove operators/monitoring stack:
    - ./_step_1 -d
  - Full cleanup of operators/CRDs and namespaces:
    - ./_step_1 -x

- Port-forwarding (Grafana and CQL ports)
  - ./port_forward.bash
  - Opened local ports include: 3000 (Grafana), 9042/9142/19042/19142 (CQL), and 8000/8043 (Alternator) if enabled.

- Connect to Scylla
  - Non-TLS local CQLSH: ./client.bash
  - In-cluster CQLSH via kubectl: ./client.bash -r
  - TLS CQLSH (uses certs from scylla-server-certs secret): ./client_tls.bash

- Scylla Manager access and backups
  - Shell into Scylla Manager service pod: ./manager.bash
  - Create backup (chooses GCS if gcs-service-account.json exists on GKE, else S3): ./create_backup.bash

- Optional: Minio S3 for local backups
  - Deploy/teardown Minio: ./deployMinio.bash [-d|-x]

- Sample app container
  - Build and push the demo image: (requires Docker login if using a private registry)
    - (from sample_app/) ./build_image.bash
  - Deploy a demo Pod into the Scylla namespace:
    - (from sample_app/) ./_deploy.bash
  - Run workloads inside the Pod:
    - kubectl -n ${scyllaNamespace} exec -it myapplication -- bash
    - Inside the container, you can run python loaders/queries (see loader.py, query.py)

Key configuration file

- init.conf controls everything. Important flags and variables include:
  - helmEnabled (true/false): choose Helm vs kubectl manifests for cluster/manager
  - backupEnabled, minioEnabled
  - enableAuth, enableTLS, mTLS
  - operatorTag, dbVersion, managerVersion, agentVersion
  - clusterName, dataCenterName, scyllaNamespace (derived), scyllaManagerNamespace
  - resource sizing and storage capacity per environment
  - broadcastType/nodeServiceType and enableAlternator/writeIsolation
  - Context-sensitive defaults: docker-desktop vs cloud contexts

High-level architecture and structure

- Top-level flow (two phases)
  - Phase 1: Setup (./setupK8s.bash or ./_step_1)
    - Adds Helm repos and installs:
      - cert-manager (for TLS and certificate issuance)
      - kube-prometheus-stack (Prometheus/Grafana)
      - scylla-operator (via Helm, repo is scylla or scylla-latest when operatorTag=latest)
    - Creates a ClusterIssuer (myclusterissuer) using cert-manager’s webhook CA secret so subsequent Certificates can be issued for Scylla and Scylla Manager
    - Storage setup for Scylla:
      - docker-desktop: creates a scylladb-local-xfs StorageClass using local-path provisioner
      - Cloud contexts: applies local-csi-driver manifests and a NodeConfig to enable XFS/local volume semantics; waits for reconciliation
    - Optional: deploys Minio S3 tenant (namespace minio) and configures a default bucket if enabled
  - Phase 2: Deployment (./deployScylla.bash or ./_step_2)
    - ScyllaCluster CR is rendered from templateCluster.yaml (or Helm values via templateClusterHelm.yaml) by substituting placeholders with values from init.conf
    - If backupEnabled=true, a scylla-agent-config-secret is created to configure backup endpoints:
      - Minio (endpoint http://minio.minio:9000) or native AWS S3 (with region); GKE+GCS supported by mounting a service account JSON into the agent
    - A Certificate for Scylla server certs (scylla-server-certs) is issued via cert-manager and mounted into the cluster pods
    - If enableAuth=true and Helm is not used, a scylla-config ConfigMap is created to configure:
      - CassandraAuthorizer and either PasswordAuthenticator or CertificateAuthenticator (for mTLS)
      - client_encryption_options and server_encryption_options with TLS materials mounted from scylla-server-certs
    - ScyllaDBMonitoring CR is created from templateDBMonitoring.yaml; Prometheus gets a PVC with selected StorageClass and capacity; Grafana is patched to use a single “master” dashboard to reduce load
    - Scylla Manager is deployed either via Helm (scylla/scylla-manager) or via templateManager.yaml (Deployment + Service + ConfigMap + ScyllaCluster for manager’s DB). A Certificate (scylla-manager-certs) is issued and client certs are referenced by the manager config
    - Final step waits for readiness, patches service accounts/roles as needed, and runs port forwarding

- Namespaces and addressing
  - Scylla workload namespace: ${scyllaNamespace} (defaults to "scylla-dc1")
  - Scylla Manager namespace: scylla-manager
  - Monitoring stack: scylla-monitoring; cert-manager: cert-manager; scylla-operator: scylla-operator; CSI driver: local-csi-driver
  - Client Service: ${clusterName}-client exposes CQL and TLS CQL; port-forward maps to localhost for development

- Node placement and resource isolation
  - Nodes are labeled with scylla.scylladb.com/node-type to separate Scylla workload nodes from operator/monitoring nodes
  - Racks use nodeAffinity to target the desired node-type values; tolerations also applied to keep non-Scylla workloads off the data nodes
  - CPU pinning is enabled via scyllaArgs and cpuset; setup also sets kubelet CPU manager policy to static when provisioning clusters via supplied scripts

- Template-driven manifests
  - The repo uses sed to substitute placeholders in these templates based on init.conf:
    - templateCluster.yaml -> ScyllaCluster
    - templateDBMonitoring.yaml -> ScyllaDBMonitoring
    - templateManager.yaml (or Helm values) -> Scylla Manager ConfigMap/Deployment/Service and manager’s ScyllaCluster
    - templateOperator.yaml -> Helm values for scylla-operator
  - Context switches influence developerMode, storage class, resource sizes, and backup provider selection

- TLS and authentication model
  - cert-manager issues Certificates via ClusterIssuer myclusterissuer
  - scylla-server-certs secret is mounted into Scylla pods; client.bash connects on 9042 (non-TLS), client_tls.bash on 9142 (TLS) using the secret’s ca/tls certs
  - Either password auth (cassandra/cassandra) or mTLS (CertificateAuthenticator) is used based on init.conf

- Backup and Scylla Manager integration
  - scylla-agent-config-secret defines S3/GCS/Minio endpoints for Scylla Manager Agent
  - create_backup.bash updates cluster registration credentials in Scylla Manager (user/pass or TLS) and triggers a backup to the configured location

- Monitoring specifics
  - ScyllaDBMonitoring CR selects endpoints by labels applied by Scylla Operator and configures Prometheus and Grafana
  - A post-deploy patch reduces Grafana dashboards to the “master” set for efficiency; credentials are retrieved from scylla-grafana-admin-credentials secret and printed by the scripts

Notes from README.md

- Prerequisites: Helm, kubectl, jq, and Internet access to pull charts/images; clone this repo
- TL;DR: create a cluster (optional helpers for GKE/EKS), run ./_step_1, then ./_step_2
- Destroy: use -d for standard removal and -x for full deletion including PVCs and namespaces on both steps

Tips

- Most behavior is controlled via init.conf; edit it before running steps
- The scripts auto-detect the kubectl context (docker-desktop vs cloud) and adjust developerMode, storage, and resource sizing accordingly
- If using GKE with GCS backups, place gcs-service-account.json in the repo root before running deployment
