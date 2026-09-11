# Day 33 — State, Storage, Backup and Recovery

**Level 3+ (AWS CloudOps)** · ~2 hours · Prereqs: Day 32

Day 12 moved the state to S3 and locked it with DynamoDB. That is the setup. This
day is about the thing nobody rehearsed: **the state file is the platform's
database, and you need a backup story for it.**

## What you will be able to do

- Explain precisely what is lost if the state is lost
- Take a state backup and restore from one
- Set an RTO and RPO for the control plane, separately from the data plane
- Decide what deserves `prevent_destroy` and what does not
- Import resources that already exist instead of destroying and recreating them

## What is actually in the state, and what is not

Run this against the checked-in fixture to see the shape of it:

```bash
python3 - <<'PY'
import json, pathlib
state = json.loads(pathlib.Path("labs/local/sample.tfstate.json").read_text())
print("outputs:", sorted(state.get("outputs", {})))
print("resources:", len(state.get("resources", [])))
PY
```

The state contains resource IDs, attributes and outputs — including
`ansible_inventory_json`, which is the entire Terraform→Ansible bridge.

It does **not** contain:

- Your AWS resources. They exist whether or not the state does.
- Your secrets' *values* in the case of most attributes — but it does contain
  plenty that is sensitive: ARNs, IP addresses, key pair names, the whole
  topology. Treat the state bucket as confidential.
- Configuration. That is Git.

So the honest failure statement is:

> Losing the state does not delete anything. It deletes our **ability to change
> anything without risk**, because Terraform no longer knows what it manages.

That is a severe outage of the control plane, not of the service.

## Backup: versioning is not a strategy

The repository already contains a complete, correct S3 hardening pattern — on
the wrong bucket, arguably. In `terraform/modules/compute/main.tf`, the ALB
access-log bucket gets:

| Resource | What it gives you |
| --- | --- |
| `aws_s3_bucket_versioning.alb_logs` | Every overwrite is recoverable |
| `aws_s3_bucket_server_side_encryption_configuration.alb_logs` | Encryption at rest |
| `aws_s3_bucket_public_access_block.alb_logs` | All four public-access flags |
| `aws_s3_bucket_lifecycle_configuration.alb_logs` | Expiry, so logs do not cost forever |
| `aws_s3_bucket_ownership_controls.alb_logs` | Bucket-owner-enforced, no ACLs |
| `aws_s3_bucket_policy.alb_logs` | Explicit deny of non-TLS access |

The state bucket needs the same list **minus** the short expiry and **plus** one
thing: object lock or an MFA-delete requirement, because the state is the one
object you cannot regenerate.

A defensible state-bucket baseline:

```hcl
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

# Noncurrent versions are your point-in-time backups. Keep enough to survive a
# bad week, then expire them so the bucket does not grow forever.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 90 }
  }
}
```

### Manual backup and restore

Versioning protects you from automation. It does not protect you from someone
who is confident. So know the manual path cold:

```bash
# back up
terraform state pull > "state-backup-$(date -u +%Y%m%dT%H%M%SZ).tfstate"

# restore — only into an empty or quarantined backend
terraform state push state-backup-20260911T093000Z.tfstate
```

`terraform state push` is the most dangerous command in the toolchain. It
overwrites the backend with no diff and no review. Two rules:

1. Never run it against the production backend while anyone else is working.
2. `terraform state pull` **first**, so you have an undo.

### Disaster recovery, sized honestly

| Scenario | RPO | RTO | How |
| --- | --- | --- | --- |
| Corrupted/deleted state object | Minutes | ~15 min | Restore a versioned object, `state pull` to confirm |
| Lock table stuck | 0 | ~10 min | Find the holder in CloudTrail, `terraform force-unlock` |
| Whole region unavailable | Hours | Hours | State lives in one region; the resources do too. Cross-region replication buys you the state, not the fleet. |
| Account compromised | n/a | Days | This is not a DR scenario, it is an incident — Day 37 |

The row that people get wrong is the third. Replicating the state bucket to
another region gives you a list of resources in a region where those resources
do not exist. Rebuilding means a new stack in the second region and a DNS cut
over — rehearse that, do not assume it.

## `prevent_destroy`: use it on three things

Day 22 covered lifecycle blocks. Operationally, `prevent_destroy = true` should
be rare, because it also blocks *intentional* destruction and pushes people
toward `terraform state rm` — which is worse.

Worth protecting here:

- The state bucket (if it is in Terraform).
- The KMS key for logs, `aws_kms_key.logs` in
  `terraform/modules/network/main.tf`. It already has
  `deletion_window_in_days = 7`, which is the softer version of the same idea:
  a week to notice a mistake.
- Any bucket holding data you cannot rebuild. The ALB log bucket is **not** in
  that category — it holds 90-day access logs, and losing them is bad but not
  unrecoverable.

## Importing instead of recreating

The realistic version of "the state was lost": you still have the resources. Do
not `terraform apply` over them and let Terraform create duplicates. Import.

```bash
terraform import 'module.compute.aws_autoscaling_group.this' newrelic-fleet-dev-asg-abcd1234
```

Then `terraform plan` and read the diff as a **discrepancy report**, not as a
change request. Every line is a place where reality and Git disagree. Fix Git
for the things that are intentionally different; fix AWS for the things that are
drift.

Note the resource addresses in this stack are module-scoped —
`module.network.*`, `module.security.*`, `module.compute.*`, and
`module.monitoring[0].*` (the monitoring module is behind a `count`, so the
address has an index). Getting the address wrong is the most common import
failure; `terraform state list` shows the truth.

## A second use for the state backup

`terraform/scripts/tf_to_inventory.py` has a `--state-file` mode precisely so you
do not need Terraform, credentials or a working backend to produce an inventory:

```bash
terraform/scripts/tf_to_inventory.py \
  --state-file labs/local/sample.tfstate.json --stdout
```

That means a recent state backup is also an **offline host list**. During an
incident where the backend is unreachable, this is how you find out which hosts
exist and what their private IPs are. It is worth adding to the incident
runbook (Day 37) — a tool you have never run will not work the first time you
need it under pressure.

## Deliberate failure — planning with no state

Do this in the lab, where there is nothing to lose:

```bash
cd terraform/environments/dev
terraform init -backend=false
mv terraform.tfstate /tmp/state-aside.tfstate   # if you have one locally
terraform plan
```

Every resource comes back as `will be created`. Against a real account, applying
that plan would either fail on name collisions or, worse, **succeed** and create
a parallel stack — a second VPC, a second ASG, a second ALB, twice the bill, and
now two sources of truth.

**Diagnosis.** Terraform does not read AWS to decide what exists; it reads the
state. With an empty state, everything is new. This is the whole reason
`terraform plan` must be reviewed by a human who knows roughly how many resources
the stack should contain.

**Fix.** Restore: `mv /tmp/state-aside.tfstate terraform.tfstate`, or restore a
versioned object from the bucket, or import.

**Prevention.**
- Require `-out=tfplan` and apply the saved plan, as
  `terraform/scripts/deploy.sh` does. A saved plan cannot silently expand.
- Assert the resource count in CI: a plan that goes from 60 resources to 120
  deserves a human, and a plan that goes to 0 deserves a halt.
- Protect the state bucket with a deny on `s3:DeleteObject` without MFA.

## Lab (no AWS account required)

1. Read the state fixture and list every output the bridge depends on:

   ```bash
   python3 -c "import json;print(sorted(json.load(open('labs/local/sample.tfstate.json'))['outputs']))"
   ```

2. Generate an inventory with no Terraform installed and no credentials:

   ```bash
   terraform/scripts/tf_to_inventory.py \
     --state-file labs/local/sample.tfstate.json \
     -o ansible/inventory/generated/dev.yml
   ```

3. Check the repo's S3 hardening pattern you are going to copy:

   ```bash
   grep -n 'resource "aws_s3' terraform/modules/compute/main.tf
   ```

4. Confirm the KMS key already has a recovery window:

   ```bash
   grep -n -A4 'resource "aws_kms_key" "logs"' terraform/modules/network/main.tf
   ```

## Exercises

1. Write the state-bucket module yourself, using
   `terraform/modules/compute/main.tf`'s ALB log bucket as the reference, and add
   object lock. Justify every block in a comment. (Day 12 sketches the bootstrap
   stack; this is the hardened version of it.)
2. Rehearse the restore: `state pull`, delete the object in a test bucket,
   restore a version, `state pull` again and diff the two files.
3. Add a CI assertion that fails when a plan's resource count changes by more
   than a threshold, with an override label.
4. Add the offline-inventory command to the incident runbook and time yourself
   doing it.

## Gotchas

- `terraform state rm` removes a resource from management **without deleting
  it**. It is the correct tool for handing a resource to another stack and the
  wrong tool for "make this error go away".
- The lock table prevents concurrent writes; it does not prevent concurrent
  *reads* from a stale local copy. Never keep a local `terraform.tfstate` next
  to a remote backend.
- Versioning multiplies storage cost silently. The lifecycle rule is not
  optional.
- `s3:DeleteObjectVersion` is the permission that matters once versioning is on.
  Denying `s3:DeleteObject` alone is not enough.
- The state is not encrypted end to end unless you say so: bucket SSE, TLS in
  transit, and no copy to an unencrypted location.

## Check yourself

- [ ] You can state the real consequence of losing the state, without exaggerating
- [ ] You can pull and push state, and you know why push is dangerous
- [ ] You know the three things worth `prevent_destroy` and why the list is short
- [ ] You can produce a host list from a state backup with no cloud access

**Next:** [Day 34 — CloudWatch, Flow Logs and New Relic Correlation](day34-cloudwatch-newrelic-correlation.md)
