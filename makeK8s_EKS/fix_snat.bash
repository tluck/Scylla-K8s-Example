#!/usr/bin/env bash

# Stop the VPC CNI from SNATing pod traffic bound for another network (e.g. a peered
# VPC hosting a second ScyllaDB DC), so the far side sees the real pod IP instead of
# the node IP - needed when nodes/clients broadcast PodIP across VPCs.
#
# Usage: fix_snat.bash [eks-cluster-name] [exclude-cidr]
#   eks-cluster-name  default: ${prefix}scylla from tf.conf - the name eks.tf gives the cluster
#   exclude-cidr      default: 172.30.1.0/24 (comma-separate several CIDRs)
# Both can also come from the environment as EKS_CLUSTER_NAME / SNAT_EXCLUDE_CIDRS.

cd "$(dirname "$0")" || exit 1
[[ -e init.conf ]] && source init.conf   # AWS_PROFILE (awsProfile) and awsRegion
source tf.conf                           # prefix and region

# not clusterName - init.conf already uses that for the ScyllaDB cluster name
eksClusterName=${1:-${EKS_CLUSTER_NAME:-${prefix}scylla}}
snatExcludeCidrs=${2:-${SNAT_EXCLUDE_CIDRS:-172.30.1.0/24}}
region=${region:-us-west-2}

if ! aws eks describe-cluster --region "${region}" --name "${eksClusterName}" --query cluster.name --output text > /dev/null; then
  printf "* * * Error: EKS cluster '%s' not found in %s (profile '%s')\n" "${eksClusterName}" "${region}" "${AWS_PROFILE:-default}" >&2
  exit 1
fi

printf "Setting AWS_VPC_K8S_CNI_EXCLUDE_SNAT_CIDRS=%s on vpc-cni in %s (%s)\n" "${snatExcludeCidrs}" "${eksClusterName}" "${region}"
aws eks update-addon \
  --region "${region}" \
  --cluster-name "${eksClusterName}" \
  --addon-name vpc-cni \
  --resolve-conflicts OVERWRITE \
  --configuration-values "{\"env\":{\"AWS_VPC_K8S_CNI_EXCLUDE_SNAT_CIDRS\":\"${snatExcludeCidrs}\"}}" \
  --query 'update.[id,status]' --output text || exit 1

# the update rolls the aws-node daemonset - wait so the setting is live when this returns
aws eks wait addon-active --region "${region}" --cluster-name "${eksClusterName}" --addon-name vpc-cni \
  && printf "vpc-cni is ACTIVE with the new setting\n"
