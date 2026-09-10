# Day 13 — AWS Networking with Terraform

**Level 2** · ~90 min · Prereqs: Day 12

## What you will be able to do

- Build a production-shaped VPC: public/private subnets, NAT, route tables
- Reason about egress — the part that actually breaks monitoring
- Write security groups that a security review will approve
- Pass the networking-related checkov checks

## The layout this repo builds

```
VPC 10.0.0.0/16
├── public  10.0.1.0/24 (ap-south-1a)   ── IGW ──▶ internet
│   └── ALB, bastion
├── public  10.0.2.0/24 (ap-south-1b)
│   └── ALB
├── private 10.0.11.0/24 (ap-south-1a)  ── NAT ──▶ internet (outbound only)
│   └── app instances, New Relic agents
└── private 10.0.12.0/24 (ap-south-1b)
    └── app instances
```

Private subnets reach the internet **outbound only**, via NAT. That is exactly
what the New Relic agent needs, and nothing more.

## The networking fact that answers most monitoring tickets

The infrastructure agent makes **outbound HTTPS** calls to New Relic's ingest
endpoints. It does not listen on any port. Therefore:

> **You never need to open an inbound firewall rule for monitoring.**

`terraform/modules/security/main.tf` encodes that as one rule:

```hcl
resource "aws_vpc_security_group_egress_rule" "app_https_out" {
  security_group_id = aws_security_group.app.id
  description       = "New Relic ingest + package repos (HTTPS out)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}
```

and `roles/firewall/defaults/main.yml` says the same thing on the host:

```yaml
firewall_allowed_tcp_ports_newrelic: []   # nothing inbound required
```

Two failure modes follow from forgetting this:

1. **No NAT in the private subnet** → agent installs, never reports. Symptom:
   agent log shows connection timeouts; `curl https://infra-api.newrelic.com`
   hangs.
2. **Corporate proxy required** → set the agent's proxy settings rather than
   opening holes.

> **Unverified here:** the New Relic hostnames could not be resolved from the
> sandbox that generated this course. Confirm the exact endpoint list against
> New Relic's docs and your agent version before allowlisting by FQDN.

## Subnets with `for_each`, keyed by AZ

```hcl
locals {
  public_subnets = {
    for idx, az in var.availability_zones : az => var.public_subnet_cidrs[idx]
  }
}

resource "aws_subnet" "public" {
  for_each                = local.public_subnets
  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = false   # assign public IPs explicitly
}
```

`map_public_ip_on_launch = false` is deliberate: even public subnets should not
hand out IPs implicitly. The bastion sets `associate_public_ip_address = true`
explicitly, so the one public instance is a **choice you can see in the code**.

## NAT: one or one-per-AZ

```hcl
locals {
  nat_gateways = var.single_nat_gateway ? {
    (var.availability_zones[0]) = var.availability_zones[0]
  } : local.public_subnets
}
```

- `single_nat_gateway = true` — one NAT gateway. Cheapest. All egress uses one IP.
  Fine for dev.
- `false` — one per AZ. Resilient; egress IP depends on the subnet.

`terraform/environments/dev/main.tf` sets it by environment:

```hcl
single_nat_gateway = var.environment != "prod"
```

Export the egress IPs — you will need them for allowlists:

```hcl
output "nat_gateway_public_ips" {
  value = { for az, eip in aws_eip.nat : az => eip.public_ip }
}
```

## Route tables

```hcl
resource "aws_route_table" "private" {
  for_each = local.nat_gateways
  vpc_id   = aws_vpc.this.id

  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[each.key].id
    }
  }
}
```

The `dynamic` block is how you express "this route exists only if NAT exists"
without duplicating the resource.

## Security groups

Three groups, and the rules that matter:

| Group | Inbound | Outbound |
| --- | --- | --- |
| `bastion` | 22 from `bastion_allowed_cidrs` only | all |
| `app` | app port from ALB **SG**, 22 from bastion **SG** | 443 |
| `alb` | 80, 443 from the internet | app port to app **SG** |

Note that app-tier rules reference **security groups**, not CIDRs:

```hcl
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.app_ingress_port
  to_port                      = var.app_ingress_port
  ip_protocol                  = "tcp"
}
```

SG-to-SG references scale with the ASG — no IP updates when instances are
replaced. CIDR rules do not.

Also in this module: `aws_default_security_group` declared with **no rules**, so
the VPC's default group denies everything (checkov CKV2_AWS_12). New instances
launched without an explicit SG inherit the default group; if it allows all,
every mistake becomes an incident.

## VPC flow logs

```hcl
resource "aws_flow_log" "this" {
  count           = var.enable_flow_logs ? 1 : 0
  vpc_id          = aws_vpc.this.id
  traffic_type    = "ALL"
  log_destination = aws_cloudwatch_log_group.flow_log[0].arn
  iam_role_arn    = aws_iam_role.flow_log[0].arn
}
```

Encrypted with a KMS key that has an explicit policy and a 365-day retention.
Flow logs are the only record of *who connected to whom* — you want them before
the incident, not after.

## Lab 13.1 — read the module

```bash
cd Newrelic-agentinstallansible
grep -n "resource \"" terraform/modules/network/main.tf
grep -n "resource \"" terraform/modules/security/main.tf
```

Count the resources. Then answer: which resource would you delete to break
monitoring for the whole fleet? (`aws_nat_gateway`.)

## Lab 13.2 — prove the security posture

```bash
checkov -d terraform/modules/security --framework terraform
```

Then check the whole repo:

```bash
checkov --config-file .checkov.yaml | grep -E "Passed|Failed"
```

Real output: `Passed checks: 110, Failed checks: 0`.

Read `.checkov.yaml` and, for each skip, decide whether you agree with the
justification. That review is Day 24's exercise; do a first pass now.

## Lab 13.3 — the deliberate failure

Set `bastion_allowed_cidrs = ["0.0.0.0/0"]` in a scratch tfvars and run checkov:

```bash
checkov -d terraform --framework terraform | grep -A2 CKV_AWS_24
```

Watch a real finding appear. Then revert. This is how you learn which rules catch
what — break it, see the finding, fix it.

## Exercises

1. Add a third AZ by editing only `terraform.tfvars`. Predict the plan: how many
   resources are added? (Three subnets, one route table association, plus
   NAT/EIP if `single_nat_gateway = false`.)
2. Add an S3 **gateway endpoint** to the VPC so instances can reach S3 without
   paying NAT data charges.
3. Add an egress rule allowing the package repository on port 443 restricted to
   the NAT's own SG. Explain why that does not work for the agent.

## Gotchas

- A subnet must have at least 5 usable IPs for an ASG target group health check
  to behave; /28 subnets cause mystery failures.
- NAT gateways cost per hour **and** per GB. A chatty agent fleet in a private
  subnet is a real bill — check the flow logs.
- Changing a VPC CIDR after launch means recreating subnets. Choose it once.
- `aws_route` resources inside a route table conflict with standalone
  `aws_route` resources. Pick one style.

## Check yourself

- [ ] You can draw the VPC from memory, including which tier has internet access
- [ ] You can state why monitoring needs no inbound rule
- [ ] `checkov` passes and you have read every skip justification

**Next:** [Day 14 — Compute & Auto Scaling](day14-aws-compute-and-asg.md)
