terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
#      version = ">= 5.47.0, < 6.0.0"  # Adjust based on compatible versions
    }

    random = {
      source  = "hashicorp/random"
#      version = ">= 3.6.1"
    }

    tls = {
      source  = "hashicorp/tls"
#      version = ">= 4.0.5"
    }

    cloudinit = {
      source  = "hashicorp/cloudinit"
#      version = ">= 2.3.4"
    }
  }

#  required_version = "~> 1.3"
}

provider "aws" {
  region = var.region
}

# Fetch the default VPC
resource "aws_vpc" "existing_vpc" {
  # assign_generated_ipv6_cidr_block = false
  cidr_block = "172.31.0.0/16"
}

data "aws_vpc" "existing_vpc" {
  id = var.vpc_id
}

# Fetch subnets in the default VPC
data "aws_subnets" "existing_subnets" {
  filter {
    name   = "vpc-id"
    # values = [aws_vpc.existing.id]
    values = [data.aws_vpc.existing_vpc.id]
  }
}

# # Generate a random suffix for resource naming
resource "random_string" "suffix" {
  length  = 8
  special = false
}

# Use a exiting key pair for EC2 nodes
resource "aws_key_pair" "key_pair" {
  key_name   = "${local.cluster_name}-keypair"
  public_key = file(var.ssh_public_key_file)
}

# Get the security group ID from the cluster configuration
locals {
  #eks_security_group_id = module.eks.vpc_config[0].cluster_security_group_id
  eks_cluster_security_group_id = module.eks.cluster_security_group_id
  eks_node_security_group_id = module.eks.node_security_group_id
}

# EKS Module using the default VPC and its subnets
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  # version = "20.8.5"

  cluster_name                       = local.cluster_name
  cluster_version                    = var.eks_version
  cluster_endpoint_public_access     = true
  enable_cluster_creator_admin_permissions = true
  
  create_kms_key = false  # Prevents automatic KMS key creation
  cluster_encryption_config = {}  # Remove encryption configuration

  create_cloudwatch_log_group = false  # Lets EKS manage log groups
  cluster_enabled_log_types = []  # Optional: Disables all log types

  enable_irsa = false  # Disables OIDC provider creation

  # vpc_id                             = aws_vpc.existing.id
  vpc_id                             = data.aws_vpc.existing_vpc.id
  subnet_ids                         = data.aws_subnets.existing_subnets.ids

  cluster_addons = {
    aws-ebs-csi-driver = {
      # service_account_role_arn = module.irsa-ebs-csi.iam_role_arn
      # gp2 is the current standard - but is not the default
      # configuration_values = jsonencode({ defaultStorageClass = { enabled = true } })
      most_recent_version = true
    },
    kube-proxy = {
      # service_account_role_arn = module.irsa-kube-proxy.iam_role_arn
      most_recent_version = true
    },
    coredns = {
      # service_account_role_arn = module.irsa-coredns.iam_role_arn
      most_recent_version = true
    },
    # prometheus-node-exporter = {
    #   # service_account_role_arn = module.irsa-node-exporter.iam_role_arn
    #   most_recent_version = true
    # },
    # aws-mountpoint-s3-csi-driver = {
    #   # service_account_role_arn = module.irsa-mountpoint-s3-csi.iam_role_arn
    #   most_recent_version = true
    # }
    # vpc-cni = {
    #   service_account_role_arn = module.irsa-vpc-cni.iam_role_arn
    # }
  }

  node_security_group_additional_rules = {
    ingress_allow_ssh = {
      type        = "ingress"
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "TCP"
      cidr_blocks = ["0.0.0.0/0"]
    }

    ingress_allow_https = {
      type        = "ingress"
      description = "HTTPS"
      from_port   = 443
      to_port     = 443
      protocol    = "TCP"
      cidr_blocks = ["172.31.0.0/16"]
    }

    # ingress_allow_workers = {
    #   type        = "ingress"
    #   description = "Workers"
    #   from_port   = 28000
    #   to_port     = 29999
    #   protocol    = "TCP"
    #   cidr_blocks = ["0.0.0.0/0"]
    # }
    
    ingress_allow_webhook = {
      type        = "ingress"
      description = "webhook"
      from_port   = 5000
      to_port     = 5000
      protocol    = "TCP"
      cidr_blocks = ["0.0.0.0/0"]
    }

    ingress_allow_prometheus = {
      type        = "ingress"
      description = "Prometheus"
      from_port   = 9090
      to_port     = 9090
      protocol    = "TCP"
      cidr_blocks = ["0.0.0.0/0"]
    }

    ingress_allow_grafana = {
      type        = "ingress"
      description = "Grafana"
      from_port   = 3000
      to_port     = 3000
      protocol    = "TCP"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  eks_managed_node_groups = {
    eks_node_group_0 = {
      name                       = "${module.eks.cluster_name}-0"
      ami_type                   = "AL2023_x86_64_STANDARD"
      instance_types             = [local.instance_type0]
      capacity_type              = "SPOT"
      key_name                   = aws_key_pair.key_pair.key_name
      subnet_ids                 = [data.aws_subnets.existing_subnets.ids[1]]
      desired_size               = var.ng_0_size
      min_size                   = 3
      max_size                   = 6 #var.ng_0_size
      # iam_role_attach_cni_policy = true
      create_launch_template     = false
      use_custom_launch_template = true
      launch_template_id         = aws_launch_template.group_lt_0.id
      launch_template_version    = "$Latest"

      iam_role_additional_policies = {
        AmazonEBSCSIDriverPolicy = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
        AmazonEC2FullAccess      = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
        tjl-nodegroup-scylla-pool-PolicyEBS      = "arn:aws:iam::403205517060:policy/tjl-nodegroup-scylla-pool-PolicyEBS"
        # AmazonS3FullAccess       = "arn:aws:iam::aws:policy/AmazonS3FullAccess"  # For S3 CSI
      }
    },

    # eks_node_group_1 = {
    #   name                       = "${module.eks.cluster_name}-1"
    #   ami_type                   = "AL2023_x86_64_STANDARD"
    #   instance_types             = [local.instance_type1]
    #   # capacity_type              = "SPOT"
    #   key_name                   = aws_key_pair.key_pair.key_name
    #   desired_size               = var.ng_1_size
    #   min_size                   = 1
    #   max_size                   = var.ng_1_size
    #   iam_role_attach_cni_policy = true
    #   create_launch_template     = false
    #   use_custom_launch_template = true
    #   launch_template_id         = aws_launch_template.group_lt_1.id
    #   launch_template_version    = "$Latest"
    #   subnet_ids                 = [data.aws_subnets.existing_subnets.ids[1]]
    # },
  }
}

resource "aws_launch_template" "group_lt_0" {
  name          = "${var.prefix}group-eks-launch-template-0"
  # image_id      = "ami-08964567921c4211b" # Replace with the appropriate Amazon Linux AMI ID
  # instance_type = local.instance_type #5.4xlarge"
  # Specify the SSH key
  key_name = aws_key_pair.key_pair.key_name # Replace with your SSH key pair name
  # Specify the disk size
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = var.ebsSize # Disk size in GB
      volume_type = "gp3"
    }
  }
  metadata_options {
    http_tokens = "required"
    http_put_response_hop_limit = 2
    http_endpoint = "enabled"
  }
  # Attach EKS security group
  network_interfaces {
    #security_groups = [local.eks_cluster_security_group_id]
    #security_groups = [local.eks_cluster_security_group_id, local.eks_node_security_group_id ]
    security_groups = [local.eks_node_security_group_id ]
    delete_on_termination = true
  }
  # Add tags to propagate to instances and volumes
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${module.eks.cluster_name}-0"
    }
  }
  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${module.eks.cluster_name}-0"
    }
  }
}

# resource "aws_launch_template" "group_lt_1" {
#   name          = "${var.prefix}group-eks-launch-template-1"
#   key_name = aws_key_pair.key_pair.key_name # Replace with your SSH key pair name
#   # Specify the disk size
#   block_device_mappings {
#     device_name = "/dev/xvda"
#     ebs {
#       volume_size = var.ebsSize # Disk size in GB
#       volume_type = "gp3"
#     }
#   }
#   # Attach EKS security group
#   network_interfaces {
#     security_groups = [local.eks_node_security_group_id ]
#     delete_on_termination = true
#   }
#   # Add tags to propagate to instances and volumes
#   tag_specifications {
#     resource_type = "instance"
#     tags = {
#       Name = "${module.eks.cluster_name}-1"
#     }
#   }
#   tag_specifications {
#     resource_type = "volume"
#     tags = {
#       Name = "${module.eks.cluster_name}-1"
#     }
#   }
# }

resource "aws_iam_role_policy" "node_pass_role" {
  name = "eks-node-pass-role"
  role = module.eks.eks_managed_node_groups["eks_node_group_0"].iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "iam:PassRole"
      Resource = module.eks.eks_managed_node_groups["eks_node_group_0"].iam_role_arn
    }]
  })
}

resource "aws_security_group_rule" "metadata_access" {
  type              = "egress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["169.254.169.254/32"]  # EC2 metadata endpoint
  security_group_id = local.eks_node_security_group_id
}
