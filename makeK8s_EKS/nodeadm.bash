#!/bin/bash
set -ex

# Retrieve cluster details (replace placeholders)
# CLUSTER_NAME=$(aws eks list-clusters --query 'clusters[0]' --output text)
# API_ENDPOINT=$(aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.endpoint' --output text)
# CA_CERT=$(aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.certificateAuthority.data' --output text)
# SERVICE_CIDR=$(aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.kubernetesNetworkConfig.serviceIpv4Cidr' --output text)

# Generate NodeConfig with ALL required fields

cat > /etc/eks/nodeconfig.yaml <<EOF
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${cluster_name}
    apiServerEndpoint: ${api_endpoint}
    certificateAuthority: ${ca_cert}
    cidr: ${service_cidr}
  kubelet:
    config:
      cpuManagerPolicy: static
EOF

cat /etc/eks/nodeconfig.yaml

# Initialize node
nodeadm init -c file:///etc/eks/nodeconfig.yaml

