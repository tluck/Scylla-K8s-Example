variable "prefix" {
  description = "Unique Name"
  type        = string
  default     = "tjl-"
}

# default and test workspaces:
locals {
  cluster_name = "${var.prefix}basic-eks"
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
  default     = "~/.ssh/tluck-aws-us-west-2.pub"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "eks_version" {
  description = "AWS eks version"
  type        = string
  default     = "1.32"
}

variable "instance0" {
  type    = string
  default = "m5a.2xlarge" #"i3en.2xlarge"
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
