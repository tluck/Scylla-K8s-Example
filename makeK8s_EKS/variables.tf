variable "prefix" {
  description = "Unique Name"
  type        = string
  default     = "test-"
}

# default and test workspaces:
locals {
  cluster_name = "${var.prefix}scylla"
  instance_type0 = var.instance0
  instance_type1 = var.instance1
}

# the default VPC is used vs specifying one
variable "vpc_id" {
  type = string
  default = "vpc-412d8839"
}

variable "ssh_public_key_file" {
  description = "the existing sshkey to use - assuming the private key is known"
  default     = "~/.ssh/aws-us-west-2.pub"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "eks_cluster_version" {
  description = "AWS eks cluster version"
  type        = string
  default     = "1.32"
}

variable "eks_nodegroup_version" {
  description = "AWS eks nodegroup version"
  type        = string
  default     = "1.32"
}

variable "instance0" {
  type    = string
  default = "i4i.2xlarge" #"i3en.2xlarge"
}

variable "instance1" {
  type    = string
  default = "m5a.2xlarge" #"i3en.2xlarge"
}

variable "ng_0_size" {
  description = "number of nodes in node group 0"
  type    = number
  default = 3
}

variable "ng_1_size" {
  description = "number of nodes in node group 1"
  type    = number
  default = 3
}

variable "ebsSize" {
  description = "EBS Disk size"
  type    = number
  default = 100
}

variable "capacity_type" {
  description = "capacity type for the node group"
  type    = string
  default = "ON_DEMAND" # or SPOT
}
