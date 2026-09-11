# Day 31 — AWS Identity and Access for Operating This Stack

**Level 3+ (AWS CloudOps)** · ~90 min · Prereqs: Day 30

Level 3 taught you to *build* the platform. This track is about the part that
comes after: running it, on AWS, on a Tuesday, while somebody is shouting.

There are three identities in play here, and every access question reduces to
"which one of these am I talking about?"

| Identity | Who/what it is | Where it is defined |
| --- | --- | --- |
| **Operator** | A human running `terraform plan` or `ansible-playbook` | AWS IAM Identity Center / IAM user — *not in this repo* |
| **Pipeline** | CI running `terraform/scripts/deploy.sh` | A role the workflow assumes — see `.github/ci.yml.example` |
| **Instance** | The EC2 hosts themselves | `terraform/modules/compute/main.tf` |

Only the third one is in this repository. That is deliberate: human and pipeline
identity belongs to the organisation, not to a stack. The moment you define
"who may deploy" inside a stack's own Terraform, the stack can widen its own
permissions.

## What you will be able to do

- Name the three identities and say which one is acting when a command fails
- Read the instance role and state exactly what it can and cannot do
- Explain why `AdministratorAccess` on an instance role is an incident waiting to happen
- Decide when to use the bastion versus SSM Session Manager
- Rotate the SSH material without rebuilding the fleet

## The instance role, line by line

`terraform/modules/compute/main.tf` defines one role and one inline policy:

```hcl
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
```

Two statements, no wildcards on `Action`, no `NotResource`. Read it as a
sentence:

> "This host may **read objects** from buckets named `newrelic-fleet-*`, and may
> **write log events** to log groups named `newrelic-fleet/*`."

That is the whole contract. Now ask the two questions an operator must be able
to answer without opening the console:

1. **Can a compromised app instance read the Terraform state?** No — the state
   bucket is not named `newrelic-fleet-*`, and even if it were, the grant is
   `s3:GetObject` on that prefix only, while the state bucket needs its own
   explicit grant to the operator/pipeline identity. Losing a host must not lose
   the platform.
2. **Can it read CloudWatch Logs back?** No. `PutLogEvents` and
   `CreateLogStream` only. Write-only by construction, which means a stolen
   instance cannot harvest the logs of its neighbours.

### A finding worth writing down

Read `terraform/modules/compute/templates/user_data.sh.tpl` again. It appends
SSH keys and writes a marker file. It does **not** touch S3.

So the `ReadArtifacts` statement is not used by anything this repository
deploys. It exists for the application that will later run on the host. That is
a defensible choice — but it is a *choice*, and six months from now nobody will
remember it was one. The CloudOps discipline is:

- Name the consumer in the `Sid` (`ReadArtifacts` is doing this job).
- If no consumer exists yet, do not grant it yet. Add it in the same commit that
  adds the consumer.

## Bastion or Session Manager?

The compute module builds a bastion (`aws_instance.bastion`) with a public IP,
and `terraform/modules/security/main.tf` restricts inbound SSH to
`var.bastion_allowed_cidrs`, which defaults to an **empty list** in
`terraform/environments/dev/variables.tf`:

```hcl
variable "bastion_allowed_cidrs" {
  type    = list(string)
  default = []
}
```

Empty list, no rule, no SSH from anywhere. That is the safe default and it is
worth defending in review, because the first thing a new engineer asks for is
`0.0.0.0/0` there.

The operational trade-off:

| | Bastion (what this repo builds) | SSM Session Manager |
| --- | --- | --- |
| Public IP needed | Yes, on one host | No |
| Credential to steal | An SSH private key | An AWS session, minutes long |
| Audit trail | Your own logging | CloudTrail, per session, with session recording available |
| Ansible path | Direct SSH through the bastion | Needs the SSM connection plugin |
| Cost | The instance, plus its public IPv4 | Free (the API is free; logs cost storage) |

### Deliberate failure — Session Manager does not work here, yet

Try it against a host this stack created:

```bash
aws ssm start-session --target i-0123456789abcdef
# An error occurred (TargetNotConnected) when calling the StartSession
# operation: The managed instance is not connected to the SSM service.
```

Diagnosis: the SSM agent is present on Ubuntu AMIs, but it needs an identity to
register with, and the instance role above has no `ssm:*` permission and no
`AmazonSSMManagedInstanceCore` attached. Confirm it without leaving the repo:

```bash
grep -rn "ssm" terraform/modules/compute/main.tf || echo "no ssm grant anywhere"
```

Fix — attach the AWS-managed policy rather than hand-writing one:

```hcl
resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
```

Then Session Manager works, you can narrow `bastion_allowed_cidrs` to nothing,
and eventually delete the bastion. Note the ordering trap: **changing an IAM
attachment does not restart the instance and does not re-run user_data.** The
agent picks up the new role credentials from the instance metadata service on its
next refresh, usually within a few minutes. If it does not, rebooting the
instance is the deterministic fix — and Day 32 covers rebooting a fleet safely.

## SSH material and rotation

Two variables feed the key material:

- `var.ssh_public_key` → `aws_key_pair.this`, used to create the instances.
- `var.ansible_ssh_authorized_keys` → rendered into
  `authorized_keys` by `terraform/modules/compute/templates/user_data.sh.tpl`.

The asymmetry matters operationally:

- Rotating `ssh_public_key` replaces the key pair resource, which is referenced
  by the launch template. New instances get it; **running instances do not**.
- Rotating `ansible_ssh_authorized_keys` also only affects new instances,
  because `user_data` runs **once at instance creation**. This is the single
  most misunderstood thing about this stack.

So a key rotation on a live fleet is a two-step operation, not a one-step
operation:

1. Change the variable, apply, and let the launch template carry the new key.
2. Replace the instances — either an ASG instance refresh (Day 32) or, for the
   bastion, a targeted `terraform apply -replace`.

Until step 2, the old key still opens the old hosts. Anyone who tells you
"rotate the key" without saying how the running hosts get it has not operated a
fleet.

The permanent fix is to stop treating `authorized_keys` as configuration and let
`ansible/roles/users/tasks/main.yml` own it, rendered from
`ansible/roles/users/templates/authorized_keys.j2` on every run. Then rotation is
a playbook, not a rebuild.

## Least privilege as a loop, not a state

Access review is not something you do once. The cheapest version, in priority
order:

1. **Find the keys.** Long-lived IAM user access keys are the top finding in
   almost every account. Move humans to Identity Center, pipelines to assumed
   roles.
2. **Find the unused grants.** CloudTrail + IAM Access Analyzer last-accessed
   data tells you which of the two statements above is actually exercised.
3. **Find the boundary.** A permission boundary on the pipeline role caps what
   any future change can do, even one merged by mistake.
4. **Prove it.** The check that a change did not widen access is a diff of the
   rendered policy, not a human reading Terraform.

## Lab (no AWS account required)

1. Print the exact set of actions the instance role grants:

   ```bash
   sed -n '/aws_iam_role_policy" "instance_minimal"/,/^}/p' \
     terraform/modules/compute/main.tf | grep -A6 'Action'
   ```

2. List every IAM resource the stack creates, and confirm there is no user and
   no access key:

   ```bash
   grep -rhn 'resource "aws_iam\|resource "aws_key_pair' terraform/
   ```

   You should see a role, an inline policy, an instance profile, a second
   role/policy pair for VPC flow logs (Day 34) — and no `aws_iam_user`, no
   `aws_iam_access_key`.

3. Prove the SSH default is closed:

   ```bash
   grep -n -A3 'variable "bastion_allowed_cidrs"' \
     terraform/environments/dev/variables.tf
   ```

4. Confirm nothing in the repo hard-codes a credential:

   ```bash
   grep -rniE 'AKIA[0-9A-Z]{16}|license_key.*=.*"[A-Za-z0-9]{20}' \
     terraform/ ansible/ || echo "no embedded credentials"
   ```

## Exercises

1. Add the `aws_iam_role_policy_attachment` for SSM, then write the
   `grep`-based assertion from the deliberate failure into the Makefile so a
   future edit cannot silently drop it.
2. Add a permission boundary to the pipeline role that denies `iam:*` outside a
   path prefix.
3. Move `authorized_keys` ownership from `user_data` to the `users` role, and
   describe how you would rotate a key without replacing a single instance.
4. Write the one-paragraph answer to "why is there a bastion at all?" that you
   would give an auditor.

## Gotchas

- `aws_iam_role_policy` is an **inline** policy. It cannot be reused and it is
  deleted with the role. That is the right call for an instance role and the
  wrong call for anything shared.
- IAM changes are eventually consistent. A `terraform apply` that succeeds can be
  followed by a 403 for a few seconds. Do not write retry-less automation
  against freshly applied policies.
- The instance role's log grant is scoped to `log-group:/${var.project}/*`. The
  VPC flow log group is `/aws/vpc/...` — a different prefix. Adding flow logs to
  the instance role's grant would be wrong; the flow log role in
  `terraform/modules/network/main.tf` already has its own.
- A key pair is region-scoped and cannot be imported into Terraform after the
  fact without `terraform import`.

## Check yourself

- [ ] You can name the three identities and say which one a given error belongs to
- [ ] You can recite what the instance role may and may not do, from memory
- [ ] You know why a key rotation is two steps, not one
- [ ] You know the SSM grant this stack is missing, and the one-line fix

**Next:** [Day 32 — EC2 and ASG Operations](day32-ec2-and-asg-operations.md)
