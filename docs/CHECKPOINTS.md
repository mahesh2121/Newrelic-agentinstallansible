# Level Checkpoints

Attempt these at the end of each level. Do not look at the answers first.
If you score under 70%, re-read the days listed beside the questions you missed.

---

## Level 1 checkpoint (after Day 10)

### Concept

1. In one sentence each, what does Terraform own and what does Ansible own?
2. Ansible is push by default. Give one advantage and one disadvantage versus pull.
3. Full variable precedence, lowest to highest. Name at least six levels.
4. Why does `roles/x/defaults/main.yml` exist separately from `roles/x/vars/main.yml`?
5. When does a handler run, and how many times per play?
6. Name three things that break idempotency.
7. Why is `mode: "0644"` quoted in YAML?

### Practical

8. Run the local lab twice. What must the second recap show?
9. Prove the `lab` group's host uses a local connection, using one command.
10. Encrypt a value with `ansible-vault` and read it back without committing it.

### Failure diagnosis

11. A playbook prints nothing and exits 0. What is the first thing you check?
12. `fatal: ... found character '\t' that cannot start any token`. Cause and fix?
13. A task reports `changed=1` on every run even though nothing is different.
    Name two causes.

<details>
<summary>Answers</summary>

1. Terraform: what **exists** (cloud resources). Ansible: how it is **configured**
   (inside the OS).
2. Push advantage: no agent, works on a brand-new host. Disadvantage: the control
   node needs reachability and credentials to every host.
3. role defaults → group_vars/all → group_vars/\<group\> → host_vars → play vars →
   role vars → block/task vars → extra vars (`-e`).
4. `defaults` are the weakest variables in Ansible (overridable by inventory);
   `vars` are stronger than inventory. Anything you want overridable belongs in
   `defaults`.
5. Only if notified, at most once per play, after all tasks, in definition order.
6. `command`/`shell` without `changed_when`; templates containing
   `{{ now() }}`/timestamps; `package: state: latest`; `copy` with dynamic content.
7. Unquoted `0644` is parsed by YAML as a number (and loses the leading zero);
   Ansible then rejects or misapplies it.
8. `changed=0` (the deliberate-failure demo still reports `rescued=1`).
9. `ansible-inventory --host lab-local` → `ansible_connection: local`.
10. `ansible-vault create inventory/group_vars/vault.yml`, then
    `ansible-vault view inventory/group_vars/vault.yml`.
11. The callback plugin. `stdout_callback = yaml` without `community.general`
    aborts the run with exit 0 and no output.
12. A tab used for indentation. YAML forbids it; set your editor to spaces.
13. Missing `changed_when: false` on a command task; a template with a timestamp
    or other varying content.

Missed a question? → Days [1](level-1-foundations/day01-setup-and-mental-model.md),
[3](level-1-foundations/day03-playbooks-and-yaml.md),
[4](level-1-foundations/day04-variables-and-vault.md),
[6](level-1-foundations/day06-handlers-idempotency-tags.md)

</details>

---

## Level 2 checkpoint (after Day 20)

### Concept

1. Why does `for_each` keyed by AZ prevent an outage that `count` would cause?
2. What is in `terraform.tfstate` that makes it a security concern?
3. Name the three Terraform→Ansible inventory patterns and say which this repo
   uses by default, and why.
4. Why is the variable `env_name` and not `environment` in the generated inventory?
5. What exactly should `user_data` do? Why nothing more?
6. Why is `gather_facts: false` plus `raw` required in a bootstrap play?
7. List the four levels of "the agent works" and say which one is proof.
8. Why must the applied plan be the reviewed plan?
9. Name the four test levels and say which one proves anything.

### Practical

10. Generate an inventory from `labs/local/sample.tfstate.json` and prove Ansible
    can read it.
11. Show the rendered agent config and prove it is valid YAML.
12. Run the four-level gate in under a minute.

### Failure diagnosis

13. A rendered config contains `labels:      env: "dev"    commands:`. Cause?
14. `-e "d={'a':1}"` then `.items()` fails. Why?
15. A handler fails the play after every task succeeded. Why, and what is the fix?
16. `Blocks of type "monitoring" are not expected here`. What happened?

<details>
<summary>Answers</summary>

1. `for_each` addresses resources by key (`aws_subnet.public["ap-south-1b"]`).
   Removing the first AZ destroys only that AZ's resources. `count` addresses by
   index, so removing an element shifts every index and Terraform proposes to
   destroy and recreate the rest.
2. All attribute values in plaintext — passwords, keys, anything passed as a
   variable.
3. (a) Terraform output → generated file, (b) dynamic inventory script reading
   state, (c) cloud inventory plugin. This repo defaults to (a) because the file
   is an auditable artifact you can diff and attach to a PR.
4. `environment` is a reserved Ansible keyword; Ansible warns
   "Found variable using reserved name 'environment'".
5. Make the host reachable by Ansible: append SSH keys, log the boot, drop a
   marker file. It runs once per instance and is never re-run, so it cannot
   maintain state.
6. Fact gathering requires Python on the target. `raw` runs over SSH with no
   Python at all, so you can install Python first.
7. Package installed / service running / config sane / **data arriving at New
   Relic**. Only the last is proof.
8. Otherwise the plan a human approved is not what was applied — a change in the
   cloud between review and apply is silently included.
9. static (parse) → schema (validate) → policy (checkov) → **behaviour (run it)**.
   Only behaviour proves anything.
10. `python3 terraform/scripts/tf_to_inventory.py --state-file labs/local/sample.tfstate.json -o /tmp/inv.yml && ansible-inventory -i /tmp/inv.yml --graph`
11. `bash labs/local/mock_bridge.sh` → section 7 prints two `PASS` lines.
12. `make verify`.
13. Jinja dash-tags strip newlines in Ansible's template engine. Use plain block
    tags.
14. Inline `-e` values are strings. Use `-e @file.yml`.
15. The config changed and notified the handler, but the service does not exist on
    that host. Guard the handler with `when: newrelic_infra_install_packages | bool`.
16. `monitoring` is a boolean on `aws_instance` but a block on
    `aws_launch_template`. An HCL parser accepts both; only a schema-aware check
    catches it.

Missed a question? → Days
[11](level-2-integration/day11-terraform-modules.md),
[15](level-2-integration/day15-terraform-ansible-integration.md),
[16](level-2-integration/day16-bootstrap-userdata-proxyjump.md),
[18](level-2-integration/day18-newrelic-agents-end-to-end.md),
[20](level-2-integration/day20-testing-and-capstone.md)

</details>

---

## Level 3 checkpoint (after Day 30)

### Architecture

1. Why directories over workspaces for dev/staging/prod?
2. What must never differ between environments, and what must?
3. Name five cost items people forget.
4. When is a module the wrong answer?
5. What is the module publishing checklist?

### Operations

6. Two drift types that must never be auto-healed, and why.
7. What makes a plan "reviewable"? What would you refuse to approve?
8. Name the four levers for scaling Ansible and the setting for each.
9. Choose `serial` for: a web tier behind an ALB, a Postgres cluster, a read-only
   audit.
10. What happens to Ansible's configuration when an ASG replaces an instance, and
    what are the three answers?

### Security

11. Justify or reject this skip: `CKV_AWS_88` (EC2 must not have a public IP).
12. Name three layers of secret protection in this repo.
13. Why does `risky-file-permissions` matter for a file containing a license key?

### Observability

14. Trace `var.environment` to an NRQL `WHERE` clause. Name every hop.
15. Why does a typo in an NRQL filter produce silence rather than an error?
16. What is a dead-man's switch, and why do you need one?

<details>
<summary>Answers</summary>

1. Separate state files, separate IAM boundaries, obvious blast radius. Workspaces
   share a backend path and a `terraform.tfvars`, and it is easy to apply to the
   wrong one.
2. Never differ: module/provider versions, tagging, IAM boundaries, encryption,
   the *set* of resources. Must differ: sizes, NAT topology, retention, deletion
   protection, CIDRs, allowed CIDRs.
3. NAT gateway (hourly + per GB), VPC flow logs, detailed monitoring, ALB LCUs,
   idle EIPs, cross-AZ traffic, monitoring ingest volume from custom attributes.
4. When it is used once forever; when it only passes variables through without
   adding decisions; when you are abstracting before you have three real cases.
5. `versions.tf`, described+typed variables, described outputs, README with an
   inputs/outputs table, working `examples/`, CHANGELOG entry, semver tag.
6. A security group changed in the console (someone had a reason) and a deleted
   resource (needs a human decision, possibly `import`).
7. A plan you can read: few lines, every destroy explained, no
   `known after apply` cascade hiding a replacement. Refuse: any unexplained
   destroy, any resource you do not recognise.
8. `forks`, `ControlMaster`+`pipelining`, fact caching (`gathering`/`fact_caching`),
   `serial`/`throttle`/`max_fail_percentage`.
9. Web tier: `serial: 2` or `"20%"`. Postgres: `serial: 1`. Read-only audit: no
   `serial`.
10. It is gone. Answers: push on instance-launch events, pull via `ansible-pull`
    cron, or bake it into the AMI.
11. Accept for the bastion only — a public IP is its purpose. Compensating
    controls: restricted source CIDRs, key-only SSH, IMDSv2, detailed monitoring,
    encrypted root volume, fail2ban. Reject it for any other instance.
12. Vault-encrypted at rest; never in Terraform state (API key comes from an env
    var); `no_log: true` on tasks touching credentials. Plus mode `0600` on the
    host, asserted by `verify_agents`.
13. Without an explicit `mode`, the file inherits the umask — often `0644`, which
    makes the license key world-readable.
14. `var.environment` → `output ansible_inventory_json` → `env_name` host var →
    `group_vars` template → `newrelic_infra_labels` → `/etc/newrelic-infra.yml`
    labels → New Relic `tags.env` → NRQL `WHERE tags.env = 'dev'`.
15. The query is valid; it matches nothing; `uniqueCount` is null; and
    "null below 1" is not true, so the condition never fires.
16. An alert that fires when an expected heartbeat **is** present (or fails to
    fire when it is absent), proving the alerting path itself works.

Missed a question? → Days
[21](level-3-master/day21-multi-environment-architecture.md),
[23](level-3-master/day23-ansible-at-scale.md),
[24](level-3-master/day24-security-and-compliance.md),
[25](level-3-master/day25-drift-detection-self-healing.md),
[26](level-3-master/day26-observability-pipeline-newrelic.md),
[28](level-3-master/day28-cost-scale-and-module-versioning.md)

</details>

---

## Scoring

| Score | Meaning |
| --- | --- |
| 90%+ | Master level. Build the Day 30 capstone and teach someone else. |
| 70–89% | Solid. Revisit the linked days, then do the capstone. |
| 50–69% | Working knowledge, shaky foundations. Redo the level's labs. |
| <50% | Start the level again. The labs matter more than the reading. |
