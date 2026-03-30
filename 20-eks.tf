module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name              = var.cluster_name
  cluster_version           = var.kubernetes_version
  cluster_service_ipv4_cidr = var.cluster_service_ipv4_cidr

  cluster_endpoint_public_access           = true
  cluster_endpoint_private_access          = true
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    "kube-proxy" = {
      most_recent = true
    }
    "vpc-cni" = {
      most_recent = true
    }
    "aws-ebs-csi-driver" = {
      most_recent              = true
      service_account_role_arn = module.irsa_ebs_csi.iam_role_arn
    }
  }

  eks_managed_node_groups = {
    primary = {
      instance_types = [var.node_instance_type]
      capacity_type  = "ON_DEMAND"
      min_size       = 3
      max_size       = 3
      desired_size   = 3

      labels = {
        role = "vault"
      }
    }
  }

  tags = local.tags
}
