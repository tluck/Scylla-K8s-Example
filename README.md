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
* Run `./setupK8s.bash`
* Run `./_deployScylla.bash`

### Setup 

Once the K8s cluster is built, then there are some preparations needed to set up the enviroment for Scylla. Run the **`setK8s.bash`** script. It will:

1. Create the k8s storage class for Scylla to use persistent storage.
2. Label the k8s nodes for targetting the deployment with the appropriate configuration and storage.
3. Install the Jetstack cert-manager for TLS certificate mangement.
4. Create a Minio S3 server for a backup location for the manager. Location is s3:scylla-backups

### Deployment

The deploy script **`deployScylla_dc1.bash`** will:

1. Deploy the Scylla operator via helm.
2. Deploy the Scylla cluster via kubetcl (or helm).
3. Deploy Scylla manager (using Minio for S3 storage) via helm.
4. Deploy Scylla monitoring (Grafana and Prometheus) via helm.
5. Forward ports to the localhost for Granfana and cqlsh access.

The **`deployScylla_dc2.bash`** makes a second 3-node cluster - so you have a multi-dc cluster.

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



