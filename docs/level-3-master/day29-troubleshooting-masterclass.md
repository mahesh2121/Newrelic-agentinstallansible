# Day 29 — Troubleshooting Masterclass

**Level 3** · ~2 hours · Prereqs: Day 28

## How to use this page

Fifteen real failures, each with **symptom → diagnosis → fix → prevention**.
Work top to bottom; every one of these will happen to you. The ones marked
✅ were reproduced while writing this course, in this repository.

---

## 1. `UNREACHABLE! ... Host key verification failed` ✅

**Symptom**
```
fatal: [localhost]: UNREACHABLE! => {"msg": "Failed to connect to the host via
ssh: Host key verification failed."}
```

**Diagnosis** — you ran `ansible-playbook -i localhost, x.yml`. A comma-list
inventory uses the default `ssh` connection.

**Fix** — add `-c local`, or use the `lab` group which sets
`ansible_connection: local`.

**Prevention** — put connection type in inventory, never on the command line.

---

## 2. The playbook prints nothing and exits 0 ✅

**Symptom** — no output at all:
```
[WARNING]: Error loading plugin 'community.general.yaml': No module named 'ansible_collections.community'
[ERROR]: Could not load 'yaml' callback plugin.
```

**Diagnosis** — `stdout_callback = yaml` in `ansible.cfg` without
`community.general` installed. The run aborts before the first play, **with exit
code 0**.

**Fix** — comment out the callback, or install the collection.

**Prevention** — treat "exit 0 but no recap" as a failure. In CI, assert that the
output contains `PLAY RECAP`.

---

## 3. Rendered YAML is garbage ✅

**Symptom** — the agent fails to start; the config looks like:
```
labels:      env: "dev"    commands:
```

**Diagnosis** — Jinja dash-tags (`{%- -%}`) strip newlines in Ansible's template
engine.

**Fix** — use plain block tags. Prove it by parsing the rendered file:
`python3 -c "import yaml;yaml.safe_load(open('/etc/newrelic-infra.yml'))"`.

**Prevention** — `labs/local/mock_bridge.sh` parses every rendered file. Add the
same assertion to your CI.

---

## 4. `object of type 'str' has no attribute 'items'` ✅

**Symptom** — a template crashes when you pass a dict on the command line.

**Diagnosis** — `-e "d={'a':1}"` arrives as a **string**.

**Fix** — `-e @vars.yml`.

**Prevention** — never pass structured data with inline `-e`.

---

## 5. Handler fails the play after everything succeeded ✅

**Symptom**
```
RUNNING HANDLER [newrelic_infra : Restart newrelic-infra]
fatal: [host]: FAILED! => {"msg": "Could not find the requested service newrelic-infra"}
PLAY RECAP ... failed=1
```

**Diagnosis** — the config changed (notifying the handler) but the service does
not exist on this host.

**Fix** — guard the handler:
```yaml
when:
  - newrelic_infra_restart_on_config_change | bool
  - newrelic_infra_install_packages | bool
```

**Prevention** — every handler that touches a service checks that the service
exists.

---

## 6. `Found variable using reserved name 'environment'` ✅

**Symptom** — a warning on every run.

**Diagnosis** — Terraform emitted `environment` as a host variable; it is a
reserved Ansible keyword.

**Fix** — rename to `env_name` in `terraform/environments/dev/outputs.tf`.

**Prevention** — lint generated inventory:
```bash
ansible-inventory -i inventory/generated/dev.yml --list --yaml | grep -E "^\s+(environment|role|vars|when|tags):"
```

---

## 7. Ansible ignores your inventory file silently ✅

**Symptom** — `ansible servers -m ping` says "no hosts matched", but the file is
right there.

**Diagnosis** — the file is named `inverntory.ini`. Ansible only reads what it was
told to read.

**Fix** — `ansible-inventory -i <file> --graph` to confirm; fix the name.

**Prevention** — `unparsed_is_failed = True` in `ansible.cfg`.

---

## 8. `monitoring` — valid HCL, invalid AWS ✅

**Symptom** — `terraform validate` says: `Blocks of type "monitoring" are not expected here.`

**Diagnosis** — `monitoring` is a boolean on `aws_instance`, a block on
`aws_launch_template`. An HCL parser cannot tell the difference.

**Fix** — `monitoring = true` on instances.

**Prevention** — run `checkov` (schema-aware) when `terraform validate` is
unavailable. It caught this exact bug here.

---

## 9. Agent installed, nothing in New Relic

**Symptom** — package present, service `active (running)`, UI empty.

**Diagnosis**, in order:
```bash
sudo tail -50 /var/log/newrelic-infra/newrelic-infra.log
sudo systemctl status newrelic-infra
curl -sv https://infra-api.newrelic.com 2>&1 | tail -5
ip route get 1.1.1.1
```
1. **No route out** — private subnet without NAT. Most common.
2. **Wrong license key / wrong region** — US key on an EU account. Log says
   `license key is not valid`.
3. **Proxy required** — set the agent's proxy settings.
4. **Firewall egress** — `roles/firewall` must allow 443 out.
5. **Clock skew** — TLS fails with a wrong clock. Check NTP.

**Prevention** — `roles/verify_agents` with `newrelic_verify_api_enabled: true`.

---

## 10. `Error acquiring the state lock`

**Diagnosis** — read the Lock Info block: who, when, which operation.

**Fix** — wait, or `terraform force-unlock <LOCK_ID>` **only** after confirming the
holder is dead.

**Prevention** — apply from CI only; `concurrency` group per environment.

---

## 11. `terraform plan` wants to destroy everything

**Symptom** — `Plan: 0 to add, 0 to change, 12 to destroy.`

**Diagnosis** — one of:
- the state's `lineage` changed (wrong backend/key)
- you are in the wrong workspace or directory
- a resource's forcing attribute changed (AMI, subnet, name)

**Fix** — **stop**. Do not apply. Check `terraform state list`, `terraform workspace show`,
and the `-refresh-only` plan.

**Prevention** — the destroy guard from Day 20/27.

---

## 12. `changed` every single run

**Symptom** — `changed=3` on every run, forever.

**Diagnosis** — a non-idempotent task: `command` without `changed_when`, a
template with `{{ now() }}`, or a file whose content legitimately varies (like
this repo's audit marker).

**Fix** — `changed_when: false`, or make the content static.

**Prevention** — run twice in CI and assert `changed=0`.

---

## 13. `MODULE FAILURE ... /usr/bin/python: No such file`

**Diagnosis** — fact gathering needs Python; the host does not have it.

**Fix** — bootstrap with `raw` (Day 16), or set `ansible_python_interpreter`.

**Prevention** — `gather_facts: false` in the bootstrap play.

---

## 14. checkov flags something you know is fine ✅

**Symptom** — `CKV_AWS_24: no security groups allow ingress from 0.0.0.0:0 to port 22`
on a rule that references a security group, not a CIDR.

**Diagnosis** — the check cannot resolve cross-resource references.

**Fix** — skip with a written justification in `.checkov.yaml`:
```yaml
# CKV_AWS_24: the SSH rule uses referenced_security_group_id, not 0.0.0.0/0.
- CKV_AWS_24
```

**Prevention** — every skip carries evidence and a checkov version. Review the
list quarterly.

---

## 15. The pipeline is green and production is broken

**Symptom** — CI passes; the fleet is unmonitored.

**Diagnosis** — your checks are all levels 1–3 (parse, validate, policy) and none
is level 4 (behaviour).

**Fix** — add the two tests that actually matter:
1. run the lab twice and assert `changed=0`
2. query New Relic (NerdGraph) and assert data arrived

**Prevention** — `labs/local/mock_bridge.sh` in CI. It found bugs #3 and #5 above.

---

## The diagnostic order that always works

```
1. what did I actually run?        (command, inventory, limit, extra vars)
2. what does Ansible believe?      ansible-inventory --host X
3. what does the target say?       -vvv, then the service's own log
4. what does the cloud say?        console / CLI, not the plan
5. what does the state say?        terraform show
6. what changed since it worked?   git log, CI history
```

Most people start at 4 or 5. Start at 1.

## Lab 29.1 — reproduce five of them

```bash
cd Newrelic-agentinstallansible
# #1  unreachable
cd ansible && ansible lab -m wait_for_connection -e ansible_connection=ssh -e ansible_host=10.255.255.1 -e ansible_user=nobody 2>&1 | tail -3
# #7  unparsed inventory
ansible-playbook -i does-not-exist.yml playbooks/verify.yml 2>&1 | tail -3
# #14 checkov skip
grep -A3 CKV_AWS_24 ../.checkov.yaml
```

## Exercises

1. Reproduce #2 by enabling the yaml callback, then fix `ansible.cfg`.
2. Write a CI step that fails when a playbook exits 0 without printing
   `PLAY RECAP`.
3. Build a one-page runbook for #9 and hand it to a teammate. Ask them to follow
   it without talking to you.

## Check yourself

- [ ] You can name the first three diagnostic questions
- [ ] You have reproduced at least five failures
- [ ] Every skip in `.checkov.yaml` has a reason you personally agree with

**Next:** [Day 30 — Master Capstone](day30-master-capstone.md)
