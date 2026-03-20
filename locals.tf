data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

locals {

  # Determine availability zones to use. If not specified, select up to 3 available AZs in the region.
  availability_zones = length(var.availability_zones) > 0 ? var.availability_zones : slice(
    data.aws_availability_zones.available.names,
    0,
    min(3, length(data.aws_availability_zones.available.names))
  )

  # Calculate subnet CIDRs using cidrsubnet
  # For a /16 VPC, creates /20 subnets (16 + 4 = 20)
  # Public subnets:  indices 0-7  (10.10.0.0/20, 10.10.16.0/20, 10.10.32.0/20, ...)
  # Private subnets: indices 8-15 (10.10.128.0/20, 10.10.144.0/20, 10.10.160.0/20, ...)
  public_subnets  = [for i in range(length(local.availability_zones)) : cidrsubnet(var.vpc_cidr_block, 4, i)]
  private_subnets = [for i in range(length(local.availability_zones)) : cidrsubnet(var.vpc_cidr_block, 4, i + 8)]

  # Private subnet IDs to use for the EKS cluster and EFS mount targets are the ones created
  # with the VPC if existing ones are not provided.
  private_subnet_ids = var.create_vpc ? flatten(module.vpc[*].private_subnets) : var.existing_private_subnet_ids

  interface_vpc_endpoint_services = var.create_vpc ? [
    "ec2",
    "ecr.api",
    "ecr.dkr",
    "sts",
    "eks",
    "eks-auth",
    "logs",
    "elasticloadbalancing",
    "autoscaling",
  ] : []
  gateway_vpc_endpoint_services = var.create_vpc ? [
    "s3",
  ] : []

  # Cluster security group is the one automatically created by EKS unless an existing
  # one is provided.
  cluster_security_group_id = var.create_security_group ? module.eks.cluster_primary_security_group_id : var.existing_security_group_id

  node_iam_role_arn = var.create_iam_roles ? module.iam.node_iam_role_arn : var.existing_node_iam_role_arn

  # Additional security groups to attach to node groups, depending on whether VPC endpoints 
  # are created and whether an existing security group is provided
  additional_node_security_group_ids = compact([
    one(module.vpc_endpoints[*].security_group_id),
    var.existing_security_group_id,
  ])

  # Map node groups to the format expected by the EKS module
  node_groups = {
    for name, config in var.node_groups : name => {
      name = name

      instance_types = [config.instance]
      capacity_type  = config.spot ? "SPOT" : "ON_DEMAND"
      disk_size      = config.disk_size
      ami_type       = config.ami_type

      min_size     = config.min_nodes
      max_size     = config.max_nodes
      desired_size = config.min_nodes

      # Use a shared IAM role for all node groups instead of creating or specifying
      # individual ones
      create_iam_role = false
      iam_role_arn    = local.node_iam_role_arn

      vpc_security_group_ids = local.additional_node_security_group_ids

      labels = config.labels

      # The EKS module expects taints as a map
      taints = {
        for idx, taint in config.taints :
        idx => {
          key    = taint.key
          value  = taint.value
          effect = taint.effect
        }
      }

      # Explicitly manage launch templates so root disk sizing is stable and
      # reproducible across rolling updates/reconciliations.
      create_launch_template                 = true
      use_custom_launch_template             = true
      update_launch_template_default_version = true

      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            delete_on_termination = true
            encrypted             = true
            volume_size           = coalesce(config.disk_size, 20)
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 125
          }
        }
      }
    }
  }

  # Map each private subnet ID to its EFS mount target configuration
  efs_mount_targets = var.efs_enabled ? {
    for idx, subnet_id in local.private_subnet_ids :
    idx => {
      subnet_id       = subnet_id
      security_groups = [local.cluster_security_group_id]
    }
  } : {}
}
