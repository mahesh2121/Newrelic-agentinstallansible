locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = merge(var.tags, {
    Module      = "compute"
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

# Latest Ubuntu LTS unless an explicit AMI was supplied.
data "aws_ami" "ubuntu" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ami_id = var.ami_id != "" ? var.ami_id : try(data.aws_ami.ubuntu[0].id, "")
}

resource "aws_key_pair" "this" {
  key_name   = "${local.name_prefix}-key"
  public_key = var.ssh_public_key

  tags = local.common_tags
}

# ------------------------------------------------------------------ IAM
# Least privilege: instances only need to read from S3 and write CloudWatch.
# No AdministratorAccess, no wildcard actions.
resource "aws_iam_role" "instance" {
  name = "${local.name_prefix}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "instance_minimal" {
  name = "${local.name_prefix}-instance-policy"
  role = aws_iam_role.instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadArtifacts"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["arn:aws:s3:::${var.project}-*/*"]
      },
      {
        Sid      = "PublishLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:*:*:log-group:/${var.project}/*"]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "this" {
  name = "${local.name_prefix}-instance-profile"
  role = aws_iam_role.instance.name

  tags = local.common_tags
}

# ------------------------------------------------------------- user_data
# This is the ENTIRE job of user_data: make the host reachable by Ansible.
# Note the explicit marker file - Day 16 explains why.
locals {
  user_data = templatefile("${path.module}/templates/user_data.sh.tpl", {
    bootstrap_user             = var.bootstrap_user
    ansible_ssh_authorized_keys = var.ansible_ssh_authorized_keys
    ansible_pull_url           = var.ansible_pull_url
    project                    = var.project
    environment                = var.environment
  })
}

resource "aws_launch_template" "this" {
  name_prefix            = "${local.name_prefix}-lt-"
  image_id               = local.ami_id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = var.security_group_ids
  user_data              = base64encode(local.user_data)

  iam_instance_profile {
    arn = aws_iam_instance_profile.this.arn
  }

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size = 20
      volume_type = "gp3"
      encrypted   = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"

    tags = merge(local.common_tags, {
      Name              = "${local.name_prefix}-app"
      ansible_managed   = "true"
      ansible_bootstrap = "user_data"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.common_tags
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------------------------------------------ ASG
resource "aws_autoscaling_group" "this" {
  name_prefix         = "${local.name_prefix}-asg-"
  vpc_zone_identifier = var.subnet_ids
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_capacity

  target_group_arns = [aws_lb_target_group.this.arn]
  health_check_type = "ELB"

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  dynamic "tag" {
    for_each = merge(local.common_tags, {
      Name            = "${local.name_prefix}-app"
      ansible_managed = "true"
    })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity]
  }
}

# ------------------------------------------------------------------ ALB
resource "aws_lb" "this" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.alb_subnet_ids

  drop_invalid_header_fields  = true
  enable_deletion_protection  = var.enable_alb_deletion_protection

  dynamic "access_logs" {
    for_each = var.enable_alb_access_logs ? [1] : []
    content {
      bucket  = aws_s3_bucket.alb_logs[0].bucket
      prefix  = local.name_prefix
      enabled = true
    }
  }

  tags = local.common_tags
}

resource "aws_lb_target_group" "this" {
  name_prefix = "${local.name_prefix}-"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = "/health"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = local.common_tags
}

# Listener topology depends on whether an ACM certificate was supplied:
#
#   certificate supplied -> 80 redirects to 443, 443 terminates TLS 1.3/1.2
#   no certificate       -> 80 forwards directly (dev only, flagged by checkov
#                           CKV_AWS_2/103 and justified in .checkov.yaml)
resource "aws_lb_listener" "http_forward" {
  count = var.alb_certificate_arn == "" ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  tags = local.common_tags
}

resource "aws_lb_listener" "http_redirect" {
  count = var.alb_certificate_arn != "" ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = local.common_tags
}

resource "aws_lb_listener" "https" {
  count = var.alb_certificate_arn != "" ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.alb_certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Bastion host. Exists so humans (and Ansible, when there is no VPN) can reach
# the private subnets over SSH - see Day 16 for the ProxyJump setup.
# It is also why the bastion security group is never reported as unused.
# ---------------------------------------------------------------------------
resource "aws_instance" "bastion" {
  count = var.create_bastion ? 1 : 0

  ami                         = local.ami_id
  instance_type               = var.bastion_instance_type
  key_name                    = aws_key_pair.this.key_name
  subnet_id                   = var.bastion_subnet_id
  vpc_security_group_ids      = [var.bastion_security_group_id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = true
  ebs_optimized               = true
  user_data                   = base64encode(local.user_data)

  root_block_device {
    volume_size = 10
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # NOTE: on aws_instance `monitoring` is a BOOLEAN argument. The
  # `monitoring { enabled = true }` block form belongs to aws_launch_template.
  # An HCL parser accepts both; only a schema-aware check (checkov CKV_AWS_126)
  # catches the difference.
  monitoring = true

  tags = merge(local.common_tags, {
    Name            = "${local.name_prefix}-bastion"
    ansible_managed = "true"
    role            = "bastion"
  })

  volume_tags = local.common_tags
}

# ---------------------------------------------------------------------------
# ALB access logs (CKV_AWS_91). The bucket is locked down: private, versioned,
# encrypted, TLS-only, with a lifecycle rule so logs do not accumulate forever.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "alb_logs" {
  count = var.enable_alb_access_logs ? 1 : 0

  bucket        = "${local.name_prefix}-alb-logs-${var.aws_account_id}"
  force_destroy = false

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-alb-logs"
  })
}

resource "aws_s3_bucket_versioning" "alb_logs" {
  count = var.enable_alb_access_logs ? 1 : 0

  bucket = aws_s3_bucket.alb_logs[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  count = var.enable_alb_access_logs ? 1 : 0

  bucket                  = aws_s3_bucket.alb_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  count = var.enable_alb_access_logs ? 1 : 0

  bucket = aws_s3_bucket.alb_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  count = var.enable_alb_access_logs ? 1 : 0

  bucket = aws_s3_bucket.alb_logs[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  count = var.enable_alb_access_logs ? 1 : 0

  bucket = aws_s3_bucket.alb_logs[0].id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    expiration {
      days = var.alb_access_log_retention_days
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  count = var.enable_alb_access_logs ? 1 : 0

  bucket = aws_s3_bucket.alb_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowTLSOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.alb_logs[0].arn,
          "${aws_s3_bucket.alb_logs[0].arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
      {
        Sid       = "AllowALBLogDelivery"
        Effect    = "Allow"
        Principal = { AWS = var.alb_log_delivery_principal }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.alb_logs[0].arn}/*"
      },
      {
        Sid       = "AllowALBLogAclCheck"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.alb_logs[0].arn
      },
    ]
  })
}
