data "aws_vpc_endpoint_service" "interface" {
  for_each = toset(var.interface_vpc_endpoint_services)

  service      = each.value
  service_type = "Interface"
}

resource "aws_security_group" "vpc_endpoints" {
  # Keep stable naming to avoid forced SG replacement on existing clusters.
  name        = "${var.vpc_id}-vpc-endpoints-sg"
  description = "Security group for VPC endpoints in VPC ${var.vpc_id} for the ${var.project_name} project"
  vpc_id      = var.vpc_id

  tags = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  referenced_security_group_id = aws_security_group.vpc_endpoints.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "Allow HTTPS traffic from the same security group"
}

resource "aws_vpc_endpoint" "interface" {
  for_each = data.aws_vpc_endpoint_service.interface

  vpc_id              = var.vpc_id
  service_name        = each.value.service_name
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = var.tags
}

data "aws_vpc_endpoint_service" "gateway" {
  for_each = toset(var.gateway_vpc_endpoint_services)

  service      = each.value
  service_type = "Gateway"
}

resource "aws_vpc_endpoint" "gateway" {
  for_each = data.aws_vpc_endpoint_service.gateway

  vpc_id            = var.vpc_id
  service_name      = each.value.service_name
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.route_table_ids

  tags = var.tags
}
