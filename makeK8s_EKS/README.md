# Deploy a cluster on EKS

The scripts are based on [hashicorp/learn-terraform-provision-eks-cluster](https://github.com/hashicorp/learn-terraform-provision-eks-cluster) to create a simple EKS cluster for internal testing. For more information, please refer to the [official blog](https://developer.hashicorp.com/terraform/tutorials/kubernetes/eks).

## Prerequisites

1. Install terraform. Ref: https://learn.hashicorp.com/tutorials/terraform/install-cli
2. Install the AWS cli. Ref: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
3. Configure AWS cli by running `aws configure` and input your information

## Create a cluster

1. `terraform init`
2. Run this command `makeBasicClusterTerraform.bash` which in turn runs with other settings `terraform apply -auto-approve`. This will take around 10-15 minutes to complete.
3. Note: to get the cluster info (which is part of the script), run: `aws eks update-kubeconfig --region $(terraform output -raw region) --name $(terraform output -raw cluster_name)`

## Destroying the cluster

1. Run this command `makeBasicClusterTerraform.bash -d` or `terraform destory -auto-approve`

## Customization

Any modifications will likely be in done with the `variables.tf`
1. EKS version: change the `cluster_version`
2. EC2 instance type: change the `instance` in the `variables.tf`
3. If needed, modify the eks.tf to make other mods, such as changing the `desired_size` in the `eks_managed_node_groups`, and change the `min_size` or `max_size` if necessary

