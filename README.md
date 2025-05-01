# Scylla K8s Example

This repository holds examples of deploying ScyllaDB with the Kubernetes [Scylla Operator](https://github.com/scylladb/scylla-operator).

## End-to-End Deployment in K8s

This example will deploy a small-scale 3-node cluster in a single "datacenter". Optionally, a second datacenter can be deployed. 

### Prerequisites
- A K8s cluster (Kind, EKS, GKS) with admin access
- Helm
- Kubectl
- Access to the internet for the helm charts and images in dockerhub such ScyllaDB Enterprise

### TL;DR
* Run `./_step_1` (link to setUpK8s.bash)
* Run `./_step_2` (link to deployScylla.bash)

### Setup 

Once the K8s cluster is built, then there are some preparations needed to set up the enviroment for Scylla. Run the **`setUpK8s.bash`** script. It will:

1. Label the k8s nodes for targetting the ScyllaDB deployment.
2. Installs the Jetstack cert-manager for TLS certificate management.
3. Installs the Prometheus Operator.
4. Installs the ScyllaDB Operator.
5. Creates a storage class for Scylla to use local NVME persistent storage with XFS formatting.
6. Creates a Minio S3 server for a backup location for the Scylla Manager. Location is s3:scylla-backups.

### Deployment

Review the init.conf file for any changes. And then run the deploy script **`deployScylla.bash`** as it will:

1. Deploy the Scylla cluster via kubectl (or helm).
2. Deploy Scylla Monitoring (Grafana and Prometheus) via helm.
3. Deploy Scylla Manager (using Minio for S3 storage) via helm.
4. Forward tcp ports to the localhost for Granfana and cqlsh access.

For a multi-dc cluster, change the init.conf dataCenterName to dc2 and rerun the **`deployScylla.bash`** to make a second 3-node cluster in the new "dc".

### Access
* cqlsh: use the `client.bash` script to connect to the cluster pods.
* sctool: use the `manager.bash` script to connect to the manager pods.

On the manager, to run a backup:

	sctool cluster update --username cassandra --password cassandra -c scylla-dc1/scylla
	sctool backup -c scylla-dc1/scylla -L s3:scylla-backups

Contributions should be submitted as pull requests.

## Documentation
Scylla Operator documentation is available at [Scylla Docs](https://operator.docs.scylladb.com)

## Features
* Deploying multi-zone clusters
* Scaling up or adding new racks
* Scaling down
* Monitoring with Prometheus and Grafana
* Integration with [Scylla Manager](https://docs.scylladb.com/operating-scylla/manager/)
* Dead node replacement
* Version Upgrade
* Backup
* Repairs
* Autohealing



