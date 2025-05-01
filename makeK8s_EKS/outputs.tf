output "eks_cluster_name" {
  description = "Kubernetes Cluster Name"
  value = module.eks.cluster_name
}

output "eks_node_group_ids" {
  value = tomap({
    for key, value in module.eks.eks_managed_node_groups : key => value.node_group_id
  })
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group ids attached to the cluster control plane"
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group ids attached to the node group" 
  value       = module.eks.node_security_group_id
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "sshKey" {
  description = "AWS sshKey"
  value       = var.ssh_public_key_file
}

output "kubectl_config_cmd" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
