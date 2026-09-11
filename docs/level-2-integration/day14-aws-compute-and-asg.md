# Day 14 — Compute, Auto Scaling and the Load Balancer

**Level 2** · ~90 min · Prereqs: Day 13

## What you will be able to do

- Build a launch template, ASG, ALB and target group
- Write least-privilege IAM for instances
- Use instance refresh and rolling patching without downtime
- Understand what happens to your Ansible configuration when an instance is replaced

## The pieces

```
aws_key_pair               SSH public key
aws_iam_role + profile     least-privilege identity for the instance
aws_launch_template        the recipe (AMI, type, SGs, user_data, IMDSv2)
aws_autoscaling_group      how many, where, how to replace
aws_lb + target_group      traffic and health
```

`terraform/modules/compute/main.tf` implements all of them.

## Launch template

```hcl
resource "aws_launch_template" "this" {
  name_prefix            = "${local.name_prefix}-lt-"
  image_id               = local.ami_id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = var.security_group_ids
  user_data              = base64encode(local.user_data)

  iam_instance_profile { arn = aws_iam_instance_profile.this.arn }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs { volume_size = 20, volume_type = "gp3", encrypted = true }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"   # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      ansible_managed   = "true"
      ansible_bootstrap = "user_data"
    })
  }
}
```

Three details worth copying:

1. **`http_tokens = "required"`** — IMDSv2. With v1, any SSRF in your app can
   read the instance's IAM credentials.
2. **`encrypted = true`** on the root volume.
3. **`tag_specifications`** for both `instance` and `volume` — untagged volumes
   are invisible to cost reporting.

The `ansible_managed = "true"` tag is what Day 15 filters on to build the
inventory.

## AMI selection

```hcl
data "aws_ami" "ubuntu" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"]   # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

locals {
  ami_id = var.ami_id != "" ? var.ami_id : try(data.aws_ami.ubuntu[0].id, "")
}
```

**`most_recent = true` is a footgun in production.** A new AMI appears and your
next scale-out uses it untested. Two safe patterns:

- Pin `ami_id` per environment, update it deliberately (with a plan review).
- Bake your own AMI (Packer), pin that, and let Ansible configure it.

## Least-privilege IAM

```hcl
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
```

Two statements, scoped by resource ARN. No `*` actions, no `AdministratorAccess`.
If an instance is compromised, this is the difference between a bad day and a
catastrophic quarter.

## Auto Scaling group

```hcl
resource "aws_autoscaling_group" "this" {
  vpc_zone_identifier = var.subnet_ids
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_capacity
  target_group_arns   = [aws_lb_target_group.this.arn]
  health_check_type   = "ELB"          # trust the load balancer, not just the OS

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences { min_healthy_percentage = 50 }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity]   # the ASG owns scaling, not you
  }
}
```

`ignore_changes = [desired_capacity]` is important: if the ASG has scaled to 5
and your tfvars say 2, a plan would propose to shrink it. Let the ASG own that
number.

`health_check_type = "ELB"` means a failed health check replaces the instance.
Combined with Day 18's verification, you get: unhealthy → replaced → user_data →
Ansible configures → agent reports.

## What instance replacement does to your Ansible work

This is the concept that separates people who have run this in production from
people who have not:

> **Every instance in an ASG is disposable.** Anything Ansible configured on
> instance `i-abc` is gone when `i-abc` is replaced.

Therefore one of two things must be true:

1. **Push mode:** something triggers `ansible-playbook` when a new instance
   appears (event → Lambda/CI → playbook).
2. **Pull mode:** `ansible-pull` runs on a cron and re-applies configuration.

Or the configuration is baked into the AMI (Packer + Ansible), and Ansible only
handles drift. Day 16 and Day 27 cover the trade-offs.

## user_data: the whole text

`terraform/modules/compute/templates/user_data.sh.tpl` is intentionally tiny:

```bash
set -euxo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1

# append SSH keys for the bootstrap user
echo '<key>' >> /home/ubuntu/.ssh/authorized_keys

# marker file that Ansible can wait for
echo "bootstrap-complete" > /var/tmp/ansible-bootstrap-complete
```

Three properties to steal:

- `set -euxo pipefail` — fail loudly, log every command.
- Output goes to `/var/log/user-data.log`. Without this, debugging a boot is
  guesswork.
- A **marker file**. `wait_for` on a file beats `sleep 60`.

## Lab 14.1 — read the compute module

```bash
cd Newrelic-agentinstallansible
grep -n "^resource\|^data\|^locals" terraform/modules/compute/main.tf
cat terraform/modules/compute/templates/user_data.sh.tpl
```

## Lab 14.2 — checkov on compute

```bash
checkov -d terraform/modules/compute --framework terraform --compact | grep -E "Passed|Failed"
```

The ALB, launch template and instance checks should pass. The HTTP-listener
checks fail only when `alb_certificate_arn` is empty — supplying an ACM
certificate produces an HTTPS listener with `ELBSecurityPolicy-TLS13-1-2-2021-06`
plus an HTTP→HTTPS 301 redirect.

## Lab 14.3 — the deliberate failure

Set `instance_refresh` to `strategy = "Rolling"` with
`min_healthy_percentage = 100` on a 2-instance ASG and think it through: with one
instance unhealthy for any reason, the refresh can never start. Now set it to 0
and think about what happens to availability. Choose 50 and explain why.

Then break it for real in a scratch copy: change
`health_check_type = "EC2"` and explain what you would no longer detect.

## Exercises

1. Add a scaling policy (target tracking on CPU at 60%).
2. Pin the AMI per environment via a variable and remove the `data` lookup for
   prod.
3. Add a second target group on port 8443 and a listener rule that routes
   `/admin` to it.

## Gotchas

- `desired_capacity` outside `[min, max]` fails at apply.
- Changing `user_data` does **not** update running instances. It only affects
  new launches — hence instance refresh.
- An ALB needs subnets in at least two AZs.
- Target group `health_check` path must return 2xx/3xx; a 401 from your app means
  perpetual "unhealthy".

## Check yourself

- [ ] You can explain why IMDSv2 matters in one sentence
- [ ] You know what happens to Ansible's configuration when an instance is replaced
- [ ] You can justify `ignore_changes = [desired_capacity]`

**Next:** [Day 15 — The Terraform ↔ Ansible Bridge](day15-terraform-ansible-integration.md)
