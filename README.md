# Scylla K8s Example

This repository holds examples of deploying ScyllaDB with the Kubernetes [Scylla Operator](https://github.com/scylladb/scylla-operator).

## End-to-End Deployment in K8s

This example will deploy a small-scale 6-node cluster in a single "datacenter" (cloud region). Two node groups are used - one is dedicated for ScyllaDB and a second node group is deployed for all the supporting resources. Optionally, a second datacenter can be deployed.

### Prerequisites

Install these tools to besides this github:

- A clone of this repo - run `git clone [https://](https://github.com/tluck/Scylla-K8s-Example.git)`
- Helm - for installing operators, etc
- Kubectl - for managing the k8s resources and definitions
- jq - for json result processing
- Access to the internet for the pulling helm charts and related container images in Dockerhub, such ScyllaDB Enterprise.

### TL;DR

- For a GKE K8s, Run `./makeK8s_GKE/makeBasicCluster.bash` or for an EKS K8s cluster, run `./makeK8s_EKS/makeBasicClusterTerraform.bash`
- Run `./_step_1` (symbolic link to setUpK8s.bash)
- Run `./_step_2` (symbolic link to deployScylla.bash)

Note: these scripts will set the kublet CPU manager policy to static - which is needed for CPU pinning.

### Setup

Once the K8s cluster is built, then there are some preparations needed to set up the enviroment for Scylla. Run the **`setUpK8s.bash`** script. It will:

1. Label the k8s nodes for targetting the ScyllaDB deployment.
2. Installs the Jetstack cert-manager for TLS certificate management.
3. Installs the Prometheus Operator.
4. Installs the ScyllaDB Operator.
5. Creates a storage class for Scylla to use local NVME persistent storage with XFS formatting.
6. (Optionally) Creates a Minio S3 server for a backup location for the Scylla Manager. Location is s3:scylla-backups.
7. For backup in GKE, a GCS bucket and Service account is needed.

### Deployment

Review the **`init.conf`** file for any changes. And then run the deploy script **`deployScylla.bash`** as it will:

1. Deploy the Scylla cluster via kubectl (or helm).
2. Deploy Scylla Monitoring (Grafana and Prometheus) via helm.
3. Deploy Scylla Manager (using S3, GCS, or Minio for backup storage) via helm.
4. Forward tcp ports to the localhost for Granfana and cqlsh access.

For a multi-dc cluster, change the `init.conf` dataCenterName to dc2 and rerun the **`deployScylla.bash`** to make a second 3-node cluster in the new "dc".

### Access

- cqlsh: use the `client.bash` script to connect to the Scylladb cluster.
- cqlsh: use the `client.bash -r` script to connect via kubectl in the pod to the Scylladb cluster.
- cqlsh: use the `client_tls.bash` script to connect to the Scylladb cluster using TLS on the secure port.
- sctool: use the `manager.bash` script to connect to the manager in its pod.

To create a backup, run `create_backup.bash`, or on the mananger pod run for cloud object storege backups:

- Run the following to update the configuuration with authentions
    Note: assuming the cluster is in namespace region1 and named scylla
          and there is a bucket scylla-backups-uswest2 (in that region configured)
`sctool cluster update --username cassandra --password cassandra -c region1/scylla`
- For AWS/Minio object storage (s3) run:
`sctool backup -c region1/scylla -L s3:scylla-backups-uswest2`
- For GCP object storage (GCS) run:
`sctool backup -c region1/scylla -L gcs:scylla-backups-gke`

- Run this to create an ongoing job:
`sctool backup --name="hourly_backup" --cluster="region1/scylla" --location='s3:scylla-backups-uswest2' --cron="@hourly" --retention=24`

### Sample App

To test the cluster, a sample data loader and query tool can be run in a pod.

- Launch the application pod, by running the `_deploy.bash` in the `sample_app`folder.
- Use kubectl exec to run a shell to the app pod
- Data can be loaded into a test schema - run: `./run_loader.bash`
- Then this new table can queried - run `./run_query.bash`
- Watch the activity in the grafana site!

### Destroy

- To remove the K8s reources, the `setupK8s.bash` and `deployScylladb.bash` scripts have a `-d` option to remove the resources created. use `-x` to permanently remove (including deletion of PVCs and namespaces)
- the `makeBasicCluster.bash` scripts can be run with `-d` option to delete/remove the EKS or GKE cluster.

Contributions should be submitted as pull requests.

## Documentation

Scylla Operator documentation is available at [Scylla Docs](https://operator.docs.scylladb.com)

## Features

- Deploying multi-zone clusters
- Scaling up or adding new racks
- Scaling down
- Monitoring with Prometheus and Grafana
- Integration with [Scylla Manager](https://docs.scylladb.com/operating-scylla/manager/)
- Dead node replacement
- Version Upgrade
- Backup
- Repairs
- Autohealing
