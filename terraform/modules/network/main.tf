locals {
  name_prefix = "${var.project}-${var.environment}"

  # for_each needs a map, not a list: keys are stable identifiers (the AZ name)
  # so removing an AZ never causes the resources of another AZ to be recreated.
  # This is the single most important for_each lesson - see Day 22.
  public_subnets = {
    for idx, az in var.availability_zones : az => var.public_subnet_cidrs[idx]
  }

  private_subnets = {
    for idx, az in var.availability_zones : az => var.private_subnet_cidrs[idx]
  }

  nat_gateways = var.single_nat_gateway ? {
    (var.availability_zones[0]) = var.availability_zones[0]
  } : local.public_subnets

  common_tags = merge(var.tags, {
    Module      = "network"
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = false # public IP assigned explicitly, not by default

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-${each.key}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-${each.key}"
    Tier = "private"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-igw"
  })
}

resource "aws_eip" "nat" {
  for_each = var.enable_nat_gateway ? local.nat_gateways : {}

  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nat-eip-${each.key}"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  for_each = var.enable_nat_gateway ? local.nat_gateways : {}

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nat-${each.key}"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-rt"
  })
}

resource "aws_route_table" "private" {
  for_each = local.nat_gateways

  vpc_id = aws_vpc.this.id

  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[each.key].id
    }
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-rt-${each.key}"
  })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id = each.value.id
  route_table_id = var.single_nat_gateway ? (
    aws_route_table.private[var.availability_zones[0]].id
  ) : aws_route_table.private[each.key].id
}

# ---------------------------------------------------------------------------
# CKV2_AWS_12: the VPC's default security group must not allow anything.
# Declaring it with no ingress/egress blocks removes AWS's implicit allow-all.
# ---------------------------------------------------------------------------
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-default-sg-deny-all"
  })
}

# ---------------------------------------------------------------------------
# CKV2_AWS_11: VPC flow logs. Costs are dominated by log volume, so dev usually
# keeps a short retention - but they are the only record of who talked to whom,
# which is exactly what you want during an incident.
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

# CKV2_AWS_64 wants an explicit key policy. The two statements below are the
# minimum: account root keeps administration, and CloudWatch Logs can encrypt
# into this key only for log groups in this account and region.
resource "aws_kms_key" "logs" {
  count = var.enable_flow_logs ? 1 : 0

  description             = "CMK for ${local.name_prefix} VPC flow logs"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccountAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid     = "AllowCloudWatchLogsToEncrypt"
        Effect  = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-logs-kms"
  })
}

resource "aws_cloudwatch_log_group" "flow_log" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc/${local.name_prefix}-flow-logs"
  retention_in_days = var.flow_log_retention_days
  kms_key_id        = aws_kms_key.logs[0].arn

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-flow-logs"
  })
}

resource "aws_iam_role" "flow_log" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${local.name_prefix}-vpc-flow-log-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "flow_log" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${local.name_prefix}-vpc-flow-log-policy"
  role = aws_iam_role.flow_log[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "${aws_cloudwatch_log_group.flow_log[0].arn}:*"
    }]
  })
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id          = aws_vpc.this.id
  traffic_type    = "ALL"
  log_destination = aws_cloudwatch_log_group.flow_log[0].arn
  iam_role_arn    = aws_iam_role.flow_log[0].arn

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-flow-log"
  })
}
