# Deploy a cluster on EKS

The scripts are copied from [hashicorp/learn-terraform-provision-eks-cluster](https://github.com/hashicorp/learn-terraform-provision-eks-cluster) to create a simple EKS cluster for internal testing. For more information, please refer to the [official blog](https://developer.hashicorp.com/terraform/tutorials/kubernetes/eks).

## Prerequisites
1. terraform installed. Ref: https://learn.hashicorp.com/tutorials/terraform/install-cli
2. aws cli installed. Ref: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
3. aws cli configured by running `aws configure` and input the proper information

## Create a cluster
1. `terraform init`
2. `terraform apply -auto-approve`. This will takes around 10-15 minutes
3. `aws eks update-kubeconfig --region $(terraform output -raw region) --name $(terraform output -raw cluster_name)`

## Destroying the cluster
1. `terraform destory -auto-approve`

## Customization
All the modifications will be in the `module "eks"` of `eks.tf` or `variables.tf`
1. EKS version: change the `cluster_version`
2. EC2 instance type: change the `instance` in the `variables.tf`
4. use more or less instances: change the `desired_size` in the `eks_managed_node_groups`, and change the `min_size` or `max_size` if necessary

## Access containers
docker is deprecated in v1.20 and removed after v1.22. For more information, please refer to the [official blog](https://kubernetes.io/blog/2020/12/02/dont-panic-kubernetes-and-docker/)

In most cases, if you need to execute commands inside a pod or a container, please use the following command:

```shell
$ kubectl exec -it <pod-id> [-c container-id] -- <command>

```

If you really need to execute commands on the node, please ssh to your instance, and use `sudo crictl` instead of `docker`. Remember the `crictl` must be executed by root. For more information, please refer to the [crictl doc](https://github.com/kubernetes-sigs/cri-tools/blob/master/docs/crictl.md#usage).
