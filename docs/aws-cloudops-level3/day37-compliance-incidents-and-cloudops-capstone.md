# Day 37 — Compliance, Incidents and the CloudOps Capstone

**Level 3+ (AWS CloudOps)** · ~3 hours · Prereqs: Days 31–36

The last day of the track, and the one that decides whether the previous six
were worth reading. Compliance and incident response are the same skill seen from
two directions: both require you to produce **evidence about the current state of
the system**, on demand, under time pressure.

## What you will be able to do

- Present this stack's security posture to an auditor without hand-waving
- Explain what a scanner skip list really is, and where the risk hides in it
- Run a working incident for "an agent stopped reporting"
- Produce an operations manual someone else can follow

## Compliance: the skip list is the document

`docs/VERIFICATION.md` records `checkov --config-file .checkov.yaml` as
**110 passed, 0 failed**. That number means nothing on its own, because the
interesting content is in what was skipped.

`.checkov.yaml` organises its skips into three honest buckets:

| Bucket | Example | What it means |
| --- | --- | --- |
| **False positive** | `CKV_AWS_24` — the app SSH rule uses `referenced_security_group_id`, which checkov cannot resolve | The control is met; the tool is wrong. Verified by reading `terraform/modules/security/main.tf`. |
| **Accepted by design** | `CKV_AWS_260` — an internet-facing load balancer must accept 80/443 | The control is not met, and that is a business decision, written down. |
| **Deferred with a condition** | `CKV2_AWS_28` — WAF is opt-in because a web ACL costs money per environment | "Turn it on for prod, then delete this skip." |

That third bucket is the discipline. A skip with an exit condition is a plan. A
skip without one is debt with a comment.

An auditor does not want zero findings. They want every finding to be either
remediated or **accepted by a named person, with a reason and a review date**.
The file header says it plainly: *"A skip without a comment is just debt."*

### Deliberate failure — the scanner stays green while you open SSH to the world

This is the failure that the skip list makes possible, and it is worth
understanding precisely because the fix is cheap.

Add your home IP to the bastion's allow list in your tfvars — and, in a moment of
impatience, make it broad:

```hcl
bastion_allowed_cidrs = ["0.0.0.0/0"]
```

Now run the policy gate:

```bash
make scan
```

It passes. **You have just opened SSH to the entire internet and every automated
control in the repository is happy.**

**Diagnosis.** `CKV_AWS_24` — *"no security group allows ingress from 0.0.0.0 to
port 22"* — is in the skip list, because on the *app* security group it is a
false positive. But skips in `.checkov.yaml` are **global**, not per-resource.
The same skip that correctly silences the app SG also silences the bastion SG,
where it is exactly the check you want.

The bastion rule is a `for_each` over that variable, in
`terraform/modules/security/main.tf`:

```hcl
resource "aws_vpc_security_group_ingress_rule" "bastion_ssh" {
  for_each = toset(var.bastion_allowed_cidrs)
  ...
}
```

So one line of tfvars becomes an open rule, and nothing in `make verify` objects.

**Fix — a targeted assertion.** Global scanners cannot express "this specific
rule, this specific CIDR". Write the check yourself:

```bash
# fails if any environment allows SSH from anywhere
if grep -rn '0\.0\.0\.0/0' terraform/environments/*/terraform.tfvars* \
     | grep -i 'bastion_allowed_cidrs'; then
  echo "REFUSING: bastion SSH open to the world" >&2
  exit 1
fi
```

Add it to the `Makefile` as its own target and put it in the `verify` chain.
It is five lines, it is faster than checkov, and it cannot be silenced by a
global skip.

**The general rule.** Every entry you add to a skip list removes a check from
*every* resource in the scan. Before you add one, ask what else it will hide. If
the answer is anything, add the targeted assertion in the same commit.

## Host-level compliance

The infrastructure side is Terraform's job. The host side is Ansible's, and it is
flag-gated so you can enable one control at a time:

```bash
cd ansible && ansible-playbook playbooks/hardening.yml --limit servers --diff
```

`ansible/playbooks/hardening.yml` applies `ansible/roles/hardening/tasks/main.yml`,
with `ansible/roles/hardening/templates/sshd_hardening.conf.j2` and
`ansible/roles/hardening/templates/jail.local.j2`. The `.checkov.yaml` note on
`CKV_AWS_88` lists fail2ban as a **compensating control** for the bastion's
public IP — which makes the hardening role part of the compliance argument, not
a nice-to-have. If you disable it, the bastion justification weakens.

Evidence collection, cheapest first:

| Evidence | Command |
| --- | --- |
| Policy scan result | `make scan` |
| Lint + syntax + parse | `make lint syntax hcl` |
| Idempotency proof | `make idempotency` |
| Agent config is not world-readable | `ansible-playbook playbooks/verify.yml --limit servers` |
| Drift status | `ansible-playbook playbooks/drift-check.yml --limit servers` |
| Decommission audit trail | the tombstone file `ansible/playbooks/decommission.yml` writes |

That last one is a small thing with an outsized effect in an audit: every
decommissioned host leaves `/etc/ansible-managed/decommissioned.txt` behind,
naming itself and Ansible as the actor.

`ansible/roles/verify_agents/tasks/main.yml` asserts the agent config mode is one
of `0600`, `0400`, `0640` — because the file contains the licence key
(`newrelic_infra_config_mode: "0600"` in
`ansible/roles/newrelic_infra/defaults/main.yml`). That single assertion answers
a question every security review asks about agent deployments.

## Incident response: "an agent stopped reporting"

The alert is `agent_not_reporting`, defined in
`terraform/modules/monitoring/main.tf`. Work it as a script, not as improvisation.

**T+0 — Triage (2 minutes).**

```bash
# how many hosts should there be?
cd terraform/environments/dev && terraform output ansible_hostnames
# what does the live inventory say?
terraform/scripts/tf_to_inventory.py --stdout
```

Compare the two lists. If they differ, you have an infrastructure event, not a
monitoring event, and Day 32 is your runbook.

**T+2 — One host or all of them?**

All of them, at once, is almost never an agent problem. It is a tag mismatch
(Day 34), a New Relic account/region mismatch, an expired licence key, or a NAT
gateway failure. Check the cheap global causes first.

**T+5 — Is the host there?**

```bash
cd ansible
ansible <host> -m ping
ansible <host> -m service_facts
ansible <host> -m debug -a "var=ansible_facts.services['newrelic-infra.service']"
```

**T+10 — Converge and verify.**

```bash
ansible-playbook playbooks/newrelic.yml --limit <host> --diff
ansible-playbook playbooks/verify.yml --limit <host>
```

Converge first, then verify. Never verify-then-assume.

**T+15 — If the agent is running and New Relic still sees nothing**, it is a
network or attribute problem, and Day 34's flow-log join is the next step.

**Close-out.** Three questions, written down:

1. What did the alert tell us, and how late?
2. Which check should have caught it earlier?
3. Did any `failed_when: false` hide it? (Day 35.)

Also close the loop on cost: if you raised `newrelic_infra_verbosity` or the log
level to debug during the incident, put it back. Add that to the close-out
checklist, because nobody remembers.

### Severity, honestly

| Sev | Definition | Who |
| --- | --- | --- |
| 1 | Customer impact, or the platform cannot be changed safely | Everyone now |
| 2 | Degraded, or monitoring is blind | On call, this shift |
| 3 | Drift, a failed check, a skipped control | Next working day |

"Monitoring is blind" is a Sev 2, not a Sev 3. That classification is the whole
point of this track: an unmonitored fleet is one incident away from being an
unknown fleet.

## The capstone

Take a fresh copy of this repository. Do not deploy anything. In three hours,
produce an **operations manual** for it, and then defend it out loud.

**Required sections:**

1. **Access model** — the three identities from Day 31, what each can do, and how
   a key is rotated end to end (including how running hosts get it).
2. **Change control** — the patch window from Day 35, with the abort condition
   stated *before* the window opens.
3. **State recovery** — RTO and RPO for the control plane, and the exact restore
   commands from Day 33, tested.
4. **Observability** — the attribute chain from Day 34, drawn, with the one query
   that separates a tag problem from an agent problem.
5. **Cost** — the six drivers from Day 36, the top lever, and the budget that
   fires first.
6. **Compliance** — the skip list, bucketed, with a named owner and review date
   on every accepted risk.
7. **Incidents** — three runbooks: agent silent, ASG flapping, state lost.

**Grading — the uncomfortable part.** For each of the seven sections, name the
**check that proves it is true**, and say whether that check runs automatically.

| Section | A real check | Automatic today? |
| --- | --- | --- |
| Access | `grep` for the SSM attachment | No — Day 31 exercise |
| Change control | `make idempotency` | Yes |
| State recovery | A rehearsed restore | No |
| Observability | Two greps on inventory + rendered config | No — Day 34 exercise |
| Cost | Allocation percentage | No |
| Compliance | `make scan` **plus** the CIDR assertion | Partially — Day 37 |
| Incidents | A game day | No |

Count the "No"s. That number is your backlog, and it is a better backlog than any
roadmap, because every item in it is a question you could not answer under
pressure.

## Where this leaves you

Level 3 taught you to build a platform. This track taught you to keep one:

| Day | The one thing |
| --- | --- |
| 31 | There are three identities, and only one of them is in the repo |
| 32 | A launch template edit changes nothing until you refresh |
| 33 | Losing the state loses control, not infrastructure |
| 34 | Four hops between a Terraform variable and an NRQL `WHERE` |
| 35 | `failed_when: false` is a decision, and decisions need owners |
| 36 | Tags are not cost allocation until you activate them |
| 37 | Every global skip hides more than you meant it to |

Go run the thing. Break it on purpose. Write down what you could not answer —
that list is the job.

## Check yourself

- [ ] You can bucket every entry in `.checkov.yaml` and say who accepted each one
- [ ] You know what the skip list silently permits, and the five-line check that closes it
- [ ] You can run the agent-silent incident from memory to the converge step
- [ ] You have a backlog of checks that do not yet run automatically

**Next:** back to [`TUTORIAL.md`](../../TUTORIAL.md), or
[`docs/CHECKPOINTS.md`](../CHECKPOINTS.md) if you want to test yourself.
