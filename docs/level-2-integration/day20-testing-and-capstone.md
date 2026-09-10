# Day 20 — Testing IaC, and the Level 2 Capstone

**Level 2** · ~3 hours · Prereqs: Day 19

## What you will be able to do

- Test Terraform and Ansible at four levels
- Write assertions that fail on real problems, not on style
- Build a "does monitoring actually work" gate
- Complete the Level 2 capstone

## The four levels

```
1. static     does it parse?          hcl2 parse, yamllint, ansible-lint
2. schema     is it valid?            terraform validate, ansible --syntax-check
3. policy     is it safe/compliant?   checkov, custom asserts
4. behaviour  does it work?           run it, then verify the result
```

Levels 1–3 are cheap and catch most mistakes. **Level 4 is the only one that
proves anything.** A common failure is a pipeline that is heavy on 1–3 and has no
level 4 at all — it goes green while production is broken.

## Level 1–2: static and schema

```bash
yamllint .
cd ansible && ansible-lint
cd ansible && ansible-playbook --syntax-check playbooks/site.yml
python3 tools/hcl_parse_check.py
terraform validate          # needs provider download
```

What each is worth:

- `ansible-lint` in this repo runs `--profile production` and passes on 62 files.
  It caught `state: latest` in `playbooks/patch.yml` — a real idempotency bug.
- `--syntax-check` proves nothing about logic. Keep it because it is free.
- `tools/hcl_parse_check.py` proves HCL syntax, **not** provider schema. The
  `monitoring` bug in Day 9 passed the parser and was caught by checkov.

## Level 3: policy

```bash
checkov --config-file .checkov.yaml
```

Result in this repo: `Passed checks: 110, Failed checks: 0`.

The discipline is in `.checkov.yaml`: **every skip has a written reason**, and the
reasons are grouped into false positives, accepted-by-design, and
configured-elsewhere. Day 24 audits them.

Ansible's equivalent of a policy check is an `assert` task at the top of a role:

```yaml
- name: Assert New Relic license key is available
  ansible.builtin.assert:
    that:
      - newrelic_infra_license_key | length > 10
    fail_msg: "newrelic_infra_license_key is empty - put it in the vault"
```

## Level 4: behaviour

### Ansible: run it twice

```bash
ansible-playbook ../labs/local/lab.yml     # changed=4
ansible-playbook ../labs/local/lab.yml     # changed=0  <- the assertion
```

Idempotency is a **test**, not a property you hope for. Automate it:

```bash
ansible-playbook play.yml | tee /tmp/run2
grep -q "changed=0" /tmp/run2 || { echo "NOT IDEMPOTENT"; exit 1; }
```

### The integration test: the bridge

`labs/local/mock_bridge.sh` is this repository's integration test. It exercises
the real code path — Terraform state → inventory generation → playbook → template
rendering — and asserts the output:

```
PASS  config.copy: valid YAML with 7 top-level key(s)
PASS  integration.copy: valid YAML with 1 top-level key(s)
PASS  display_name came from Terraform state: newrelic-fleet-dev-app-4d5e6f
```

It found two real bugs while being written:

1. **Jinja whitespace** — dash-tags collapsed a YAML mapping onto one line, so the
   agent config was invalid. A YAML parse of the rendered file caught it.
2. **Handler on a missing service** — `Restart newrelic-infra` failed the play
   because the agent was not installed. Running the role with
   `install_packages: false` caught it.

Neither would have been found by linting.

### Ansible assertions as tests

`roles/verify_agents` is a test suite that runs against production:

```yaml
- name: Assert configuration file exists and is not world readable
  ansible.builtin.assert:
    that:
      - newrelic_verify_config_stat['stat']['exists']
      - newrelic_verify_config_stat['stat']['mode'] in ['0600', '0400', '0640']
```

### Terraform: plan assertions

```bash
terraform plan -out=tfplan
terraform show -json tfplan > plan.json

python3 - <<'PY'
import json, sys
plan = json.load(open("plan.json"))
summary = plan["resource_changes"] if "resource_changes" in plan else []
destroys = [c["address"] for c in summary if c["change"]["actions"] == ["delete"]]
if destroys:
    print("REFUSING: this plan destroys", destroys)
    sys.exit(1)
print("ok:", len(summary), "resource changes")
PY
```

A guard that refuses to apply a plan containing destroys is one of the highest
value/effort ratios in all of IaC.

### Testing against real infrastructure

For that you need ephemeral environments. Options:

- **LocalStack** for AWS API emulation (Terraform works, some services partial)
- **Molecule** with a Docker or EC2 driver for Ansible roles
- A real throwaway account, destroyed nightly

Pick one and make it boring. A test suite nobody runs is worse than none, because
it rots.

## Lab 20.1 — build the four-level gate

```bash
cd Newrelic-agentinstallansible
echo "== L1/L2 =="; yamllint . && (cd ansible && ansible-lint) && python3 tools/hcl_parse_check.py | tail -1
echo "== L3 ==";    checkov --config-file .checkov.yaml | grep -E "Passed|Failed"
echo "== L4 ==";    bash labs/local/mock_bridge.sh | tail -5
```

That is the whole gate in four commands. Put it in a Makefile target called
`make verify`.

## Lab 20.2 — the deliberate failure

Break idempotency and watch level 4 catch what levels 1–3 miss:

```bash
cd ansible
sed -i 's/content: "lab: complete/content: "lab: complete {{ ansible_date_time["iso8601"] }}/' ../labs/local/lab.yml
ansible-lint                      # still passes
ansible-playbook ../labs/local/lab.yml
ansible-playbook ../labs/local/lab.yml    # changed > 0  <- caught
```

Revert the file. The lesson: **only execution detects this.**

## Level 2 capstone

Build a working Terraform + Ansible pipeline for a small service. Requirements:

1. **Terraform**: a module creating a VPC, one subnet, a security group and an
   instance. An `output` exporting an Ansible-shaped inventory.
2. **Bridge**: a script (you may copy `terraform/scripts/tf_to_inventory.py`) that
   turns that output into an inventory file.
3. **Ansible**: a role that installs nginx and a second role that installs a
   monitoring agent config, both with `defaults/`, `handlers/`, `templates/`.
4. **Verification**: a `verify.yml` that asserts nginx is running **and** the
   agent config is valid YAML.
5. **CI**: a workflow running the four-level gate.

**Acceptance criteria:**

- [ ] `terraform plan` shows no destroys on a second run
- [ ] Inventory is generated, never hand-edited (the file carries a GENERATED banner)
- [ ] `ansible-playbook site.yml` twice → second run `changed=0`
- [ ] `verify.yml` fails if you chmod the agent config to `0644`
- [ ] CI runs the four-level gate and is green
- [ ] A deliberate fault (wrong license key, missing NAT, bad YAML) is caught by a
      named check, and you can say which one

If criterion 6 fails — if you cannot *name* the check that catches a given fault —
you do not have a test suite, you have a pile of commands.

## Exercises

1. Add a plan-assertion step that refuses any plan destroying a VPC.
2. Make `mock_bridge.sh` exit non-zero when the rendered YAML is invalid (it
   already does — verify with `echo $?`).
3. Write a Molecule scenario for `roles/newrelic_infra` using the Docker driver.

## Gotchas

- `terraform plan` exit code 2 means "changes present" with `-detailed-exitcode`.
  Use it for drift detection (Day 25), not for pass/fail in CI.
- A test that requires real cloud credentials will not run on PRs from forks.
- Snapshot-style tests (golden files) break on every formatting change. Prefer
  assertions about properties.

## Check yourself

- [ ] You can run the four-level gate in under a minute
- [ ] You can name the check that catches each deliberate fault
- [ ] Capstone criteria all ticked

**Next:** [Day 21 — Multi-Environment Architecture](../level-3-master/day21-multi-environment-architecture.md)
