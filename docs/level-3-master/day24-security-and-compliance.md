# Day 24 — Security and Compliance

**Level 3** · ~2 hours · Prereqs: Day 23

## What you will be able to do

- Apply least privilege across IAM, SSH and secrets
- Audit a checkov skip list like an auditor
- Prove the agent config cannot leak a key
- Build a compliance story you can defend

## Threat model, briefly

For this system the assets are: your New Relic account (billing + data), the AWS
account, and the hosts. The realistic threats:

| Threat | Control in this repo |
| --- | --- |
| License key committed to git | vault + `default('')` + git-ignored vault file |
| Key readable on the host | config mode `0600`, verified by `verify_agents` |
| Instance compromised → AWS takeover | least-privilege instance role, IMDSv2 |
| SSH brute force | key-only auth, `MaxAuthTries 3`, fail2ban |
| Rogue security group change | SGs in Terraform, default SG denies all |
| Unreviewed destructive plan | plan artifact + destroy guard (Day 20/27) |
| Supply chain (collection update) | pinned `requirements.yml` |

## Least privilege: IAM

`terraform/modules/compute/main.tf` gives instances exactly two permissions:

```hcl
Statement = [
  { Sid = "ReadArtifacts", Action = ["s3:GetObject"],
    Resource = ["arn:aws:s3:::${var.project}-*/*"] },
  { Sid = "PublishLogs",   Action = ["logs:CreateLogStream", "logs:PutLogEvents"],
    Resource = ["arn:aws:logs:*:*:log-group:/${var.project}/*"] }
]
```

Test: could a compromised instance delete your S3 bucket? Read your Terraform
state? Assume another role? All no. That is the bar.

The flow-log role is equally narrow — and its KMS key policy restricts
CloudWatch Logs by encryption context:

```hcl
Condition = {
  ArnLike = {
    "kms:EncryptionContext:aws:logs:arn" =
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
  }
}
```

## Least privilege: SSH

`roles/hardening/templates/sshd_hardening.conf.j2`:

```
PermitRootLogin no
PasswordAuthentication no
MaxAuthTries 3
ClientAliveInterval 300
X11Forwarding no
AllowAgentForwarding no
```

Written with `validate: sshd -t -f %s`, so a syntax error cannot lock you out.

Ordering is enforced by `playbooks/site.yml`: bootstrap (`users`) before
configure (`hardening`). Keys land first, then passwords are disabled.

## Secrets

Three layers:

1. **Vault at rest** — `inventory/group_vars/vault.yml`, encrypted.
2. **Never in state** — Terraform takes the New Relic API key from
   `NEW_RELIC_API_KEY`, not from a variable that would be written to state.
3. **`no_log: true`** on any task touching a credential
   (`roles/verify_agents/tasks/main.yml`).

Check your own work:

```bash
grep -rn "license_key" ansible/ terraform/ | grep -v "vault\|{{\|LAB-PLACEHOLDER"
```

Any hit that is a literal key is a breach waiting to happen.

## Auditing the skip list

`.checkov.yaml` in this repo skips 12 checks. An auditor's process:

1. **Is it a false positive?** Prove it by reading the code.
2. **Is it configured elsewhere?** Prove the compensating resource exists.
3. **Is it an accepted risk?** State the risk, the reason, and the compensating
   control.
4. **Is it just unimplemented?** That is debt — put a date on it.

Three examples from the file:

```yaml
# CKV_AWS_24: the SSH rule uses referenced_security_group_id, not 0.0.0.0/0.
# Checkov cannot resolve cross-resource references here.
- CKV_AWS_24                        # <- false positive, with evidence

# CKV2_AWS_6: aws_s3_bucket_public_access_block.alb_logs sets all four flags.
# Confirm with a real plan before trusting this list.
- CKV2_AWS_6                        # <- configured elsewhere, with a verification step

# CKV_AWS_88: the bastion is the ONE instance that must have a public IP.
# Compensating controls: bastion_allowed_cidrs, key-only SSH, IMDSv2,
# detailed monitoring, encrypted root volume, fail2ban.
- CKV_AWS_88                        # <- accepted risk, with named controls
```

Note the second one carries a **verification instruction**, because the claim
could not be confirmed in an offline sandbox. That honesty is the difference
between a skip list you can defend and one you cannot.

## Lab 24.1 — run the audit

```bash
cd Newrelic-agentinstallansible
checkov --config-file .checkov.yaml | grep -E "Passed|Failed"
grep -c "^  - CKV" .checkov.yaml
```

Real output: `Passed checks: 110, Failed checks: 0`, and 12 skips.

Now read every skip and write one sentence agreeing or disagreeing. If you cannot
justify a skip, remove it and fix the finding.

## Lab 24.2 — prove the key cannot leak

```bash
# 1. the rendered config is root-only
bash labs/local/mock_bridge.sh 2>&1 | grep -- "-rw"

# 2. the verification role asserts it
grep -A6 "not world readable" ansible/roles/verify_agents/tasks/main.yml

# 3. break it and confirm the assertion fails
cd ansible && ansible-playbook playbooks/verify.yml --limit lab \
  -e newrelic_infra_config_path=/etc/hostname
```

## Lab 24.3 — the deliberate failure: a key in the log

```bash
cd ansible
ansible lab -m debug -a "msg={{ newrelic_license_key }}"
```

The key prints in plaintext. That is what happens without `no_log`. Now:

```bash
ansible lab -m debug -a "msg={{ newrelic_license_key }}" -e '{"no_log": true}' 2>&1 | head -3
```

Note that `-e` cannot set `no_log` on a task this way — the real fix is in the
task definition:

```yaml
- name: Query New Relic API for this host
  ansible.builtin.uri:
    ...
  no_log: true
```

`no_log` also suppresses the task's *variables* in output, which occasionally
hides useful debugging info. Use `no_log: false` temporarily and deliberately,
never permanently.

## Lab 24.4 — Ansible lint as a security gate

```bash
cd ansible && ansible-lint
```

This repo runs `--profile production` and passes on 62 files. Security-relevant
rules it enforces: `no-log-password`, `risky-file-permissions` (every
`file`/`template`/`copy` must set `mode`), `no-changed-when`, `package-latest`.

`risky-file-permissions` is why every template task here has an explicit `mode:` —
a task without one inherits the umask, which on some hosts means `0644` for a file
containing a license key.

## Exercises

1. Write an IAM policy for a CI role that can plan anything but only apply to
   non-prod.
2. Add a pre-commit hook that runs `detect-secrets` or `gitleaks`.
3. Add a `check` block to your Terraform that fails if any security group allows
   22 from `0.0.0.0/0`.
4. Convert one `.checkov.yaml` skip into a real fix and record the before/after.

## Gotchas

- `become: true` in `ansible.cfg` means every task is root by default. Add
  `become: false` to tasks that do not need it.
- Facts are transmitted to the control node. On multi-tenant control nodes,
  `.facts/` is sensitive.
- `ansible-vault` encrypts the file, not the values inside other files. A
  `group_vars/all.yml` containing a plaintext key is still plaintext.
- Checkov results vary by version. Pin it and record the version in the skip list
  comments (this repo's does: "Verified as of checkov 3.3.17").
- Deleting `.git` history does not remove a leaked secret. Rotate it.

## Check yourself

- [ ] You can justify every skip in `.checkov.yaml`
- [ ] You know three layers of secret protection in this repo
- [ ] `ansible-lint --profile production` passes

**Next:** [Day 25 — Drift Detection & Self-Healing](day25-drift-detection-self-healing.md)
