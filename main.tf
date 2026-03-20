module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.1"

  count = var.create_vpc ? 1 : 0

  name = var.project_name

  cidr = var.vpc_cidr_block

  azs             = local.availability_zones
  create_igw      = true
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }

  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = var.tags
}

# This is a small submodule to create a shared IAM role for node groups to use if an existing
# role is not passed. This is needed because the terraform-aws-modules/eks/aws module creates
# individual IAM roles per node group, which seems unnecessary in our case (specially taking
# into account we want to allow users to bring their own IAM roles).
module "iam" {
  source = "./modules/iam"

  create = var.create_iam_roles

  cluster_name         = var.project_name
  permissions_boundary = var.iam_role_permissions_boundary
  tags                 = var.tags
}

module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.7.0"

  name = "${var.project_name}-aws-ebs-csi"

  attach_aws_ebs_csi_policy = true

  tags = var.tags
}

module "eks" {
  source = "git::https://github.com/ns-mkusper/terraform-aws-eks.git?ref=fix/disable-custom-launch-template"

  name               = var.project_name
  kubernetes_version = var.kubernetes_version

  addons = {
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = module.ebs_csi_pod_identity.iam_role_arn,
        service_account = "ebs-csi-controller-sa"
      }]
    }
    coredns = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
  }

  # Use existing security group if provided or have EKS create one otherwise
  create_security_group = var.create_security_group
  security_group_id     = var.existing_security_group_id

  # VPC ID is either from the created VPC module or from the existing VPC
  vpc_id = var.create_vpc ? one(module.vpc[*].vpc_id) : var.existing_vpc_id

  subnet_ids                   = local.private_subnet_ids
  endpoint_private_access      = var.endpoint_private_access
  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  # Use existing cluster IAM role if provided or have the module create one otherwise
  create_iam_role               = var.create_iam_roles
  iam_role_arn                  = var.existing_cluster_iam_role_arn
  iam_role_name                 = var.create_iam_roles ? "${var.project_name}-cluster-role" : null
  iam_role_description          = "EKS cluster role for ${var.project_name}"
  iam_role_permissions_boundary = var.iam_role_permissions_boundary

  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions

  encryption_config = var.eks_kms_arn != null ? {
    provider_key_arn = var.eks_kms_arn
    resources        = ["secrets"]
  } : null

  enabled_log_types = var.cluster_enabled_log_types

  node_security_group_additional_rules = var.node_security_group_additional_rules

  eks_managed_node_groups = local.node_groups

  tags = var.tags
}

module "vpc_endpoints" {
  source = "./modules/vpc-endpoints"

  count = var.create_vpc ? 1 : 0

  project_name = var.project_name

  vpc_id          = one(module.vpc[*].vpc_id)
  subnet_ids      = flatten(module.vpc[*].private_subnets)
  route_table_ids = concat(flatten(module.vpc[*].public_route_table_ids), flatten(module.vpc[*].private_route_table_ids))

  interface_vpc_endpoint_services = local.interface_vpc_endpoint_services
  gateway_vpc_endpoint_services   = local.gateway_vpc_endpoint_services

  tags = var.tags
}

module "efs" {
  source  = "terraform-aws-modules/efs/aws"
  version = "2.0.0"

  # Create EFS resources only if EFS is enabled
  count = var.efs_enabled ? 1 : 0

  name = "${var.project_name}-efs"

  create_security_group = false
  mount_targets         = local.efs_mount_targets

  encrypted   = var.efs_encrypted
  kms_key_arn = var.efs_kms_key_arn

  performance_mode                = var.efs_performance_mode
  throughput_mode                 = var.efs_throughput_mode
  provisioned_throughput_in_mibps = var.efs_provisioned_throughput_in_mibps

  tags = var.tags
}
