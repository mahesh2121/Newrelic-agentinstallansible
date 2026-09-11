# Day 12 — Remote State, Locking and Backend Strategy

**Level 2** · ~90 min · Prereqs: Day 11

## What you will be able to do

- Configure S3 + DynamoDB remote state
- Migrate local state to remote without losing resources
- Recover from a stuck lock safely
- Design state layout for multiple environments

## Why local state does not survive a team

`terraform.tfstate` on your laptop means:

- Nobody else can apply.
- No locking → two applies corrupt state.
- No history → no "what did production look like yesterday?"
- The file contains **plaintext secrets** — a laptop loss is a breach.

## The bootstrap problem

The state bucket itself is infrastructure. Two options:

1. Create it by hand once, document it, never touch it.
2. Keep a tiny separate Terraform root (`terraform/bootstrap/`) whose only job is
   the bucket and lock table. Recommended: it is still code.

## Configuration

The backend block is present but commented in
`terraform/environments/dev/providers.tf` so that `init` works without AWS:

```hcl
backend "s3" {
  bucket         = "my-tfstate-bucket"
  key            = "newrelic-fleet/dev/terraform.tfstate"
  region         = "ap-south-1"
  dynamodb_table = "terraform-locks"
  encrypt        = true
}
```

Backend blocks **cannot use variables or interpolation** — they are evaluated
before variables are loaded. For per-environment values use `-backend-config`:

```bash
terraform init \
  -backend-config="bucket=my-tfstate-bucket" \
  -backend-config="key=newrelic-fleet/${ENV}/terraform.tfstate" \
  -backend-config="region=ap-south-1"
```

### The bucket and table

```hcl
resource "aws_s3_bucket" "tfstate" {
  bucket = "my-tfstate-bucket"
  # versioning + public access block + SSE are mandatory, not optional
}

resource "aws_dynamodb_table" "tflock" {
  name         = "terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"          # must be exactly LockID

  attribute {
    name = "LockID"
    type = "S"
  }
}
```

Modern S3 backends also support **native S3 locking** (`use_lockfile = true`),
which removes the DynamoDB table. Either is fine; pick one and be consistent.

## Migrating existing state

```bash
# 1. add the backend block
# 2. initialise; Terraform offers to copy
terraform init -migrate-state
#    "Do you want to copy existing state to the new backend?" -> yes

# 3. verify
terraform state list
terraform plan          # MUST be empty
```

If `plan` is not empty, **stop**. Something in the backend does not match reality.

Rollback: keep the pre-migration local `terraform.tfstate` copy until the remote
plan is clean.

## Locking in practice

```bash
$ terraform apply
Acquiring state lock. This may take a few moments...
Error: Error acquiring the state lock

Lock Info:
  ID:        7f3c1e92-...
  Path:      newrelic-fleet/dev/terraform.tfstate
  Operation: OperationTypeApply
  Who:       priya@laptop
  Created:   2026-09-10 12:04:11 +0000 UTC
```

Decision tree:

1. **Who is it, and is their apply still running?** Ask. If yes, wait.
2. **Process is dead** (crashed CI job, killed laptop): `terraform force-unlock 7f3c1e92-...`
3. **Force-unlock fails:** the lock record can be removed from DynamoDB, but only
   after confirming no process holds it. Deleting it during a live apply corrupts
   state.

Prevention beats recovery:

- Run applies from CI, never from laptops (Day 19/27).
- Keep plans short — long plans hold locks.
- Never run `apply` in two terminals.

## State layout for environments

```
my-tfstate-bucket/
├── newrelic-fleet/dev/terraform.tfstate
├── newrelic-fleet/staging/terraform.tfstate
└── newrelic-fleet/prod/terraform.tfstate
```

**Separate state per environment** — never one state file with workspaces for
dev/staging/prod. Reasons:

- A prod mistake cannot be caused by a dev typo.
- Blast radius: a corrupted dev state does not affect prod.
- IAM: you can grant dev engineers read access to dev state only.
- Different backends/regions are possible per environment.

Day 21 expands this into the full multi-environment layout.

## Secrets in state

Terraform state stores attribute values in **plaintext**. Anything you pass as a
variable ends up readable by anyone who can read the state.

| Secret type | Handling |
| --- | --- |
| API keys (New Relic) | environment variable or CI secret; never in tfvars |
| DB passwords | `aws_secretsmanager_secret_version` + `ignore_changes`, or generate in AWS |
| SSH private keys | never — upload the public half only |
| tfvars files | `.gitignore` them; commit `.example` only |

This repo commits `terraform.tfvars.example` and ignores `terraform.tfvars`.

## Lab 12.1 — read the backend config

```bash
cd Newrelic-agentinstallansible
sed -n '1,40p' terraform/environments/dev/providers.tf
```

Note that the backend is commented out and why. Uncommenting it without a real
bucket makes `init` fail — which is the deliberate failure below.

## Lab 12.2 — the deliberate failure

```bash
cd terraform/environments/dev
cp providers.tf /tmp/providers.bak
# uncomment the backend block, then:
terraform init
```

```
Error: Failed to get existing workspaces: S3 bucket "my-tfstate-bucket" ...
```

Terraform fails **at init**, not at apply — which is good, but only if you notice.
In CI, an `init` failure must fail the job.

Restore:

```bash
cp /tmp/providers.bak providers.tf
```

## Lab 12.3 — inspect state without a backend

```bash
python3 - <<'PY'
import json
s = json.load(open("labs/local/sample.tfstate.json"))
print("lineage:", s["lineage"])
print("serial :", s["serial"])
print("outputs:", list(s["outputs"]))
PY
```

`lineage` is the identity of a state file. Two states with the same lineage are
the same lineage of history; different lineages means you are about to make a
mess.

## Exercises

1. Write `terraform/bootstrap/main.tf` that creates the state bucket with
   versioning, a public access block, SSE and a lifecycle rule, plus the lock
   table.
2. Add `-backend-config` flags to `terraform/scripts/deploy.sh` so the key is
   derived from the environment argument.
3. Write a runbook paragraph: "What to do when you see `Error acquiring the state
   lock` at 3am." Include the exact commands and the one thing you must not do.

## Gotchas

- `terraform init` will silently keep using local state if the backend block is
  commented out. Verify with `terraform backend` / the init output.
- S3 bucket names are global. Use an account-ID or org suffix.
- Do not enable object lock/versioning *without* a lifecycle rule; state
  versioning accumulates fast.
- `terraform force-unlock` requires the lock ID, not the path.

## Check yourself

- [ ] You can write the backend block from memory
- [ ] You know the three-step recovery for a stuck lock
- [ ] You can explain why each environment gets its own state file

**Next:** [Day 13 — AWS Networking](day13-aws-networking.md)
