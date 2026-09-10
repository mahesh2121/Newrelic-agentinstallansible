# Day 30 — Master Capstone

**Level 3** · ~4–6 hours · Prereqs: Days 1–29

## The brief

Build a **self-maintaining, observable, secure platform** for a small service,
from nothing, in one sitting. No copying this repo — you may *read* it, but write
your own.

### Requirements

**Terraform**
1. Modules for network, security and compute, each with typed, described inputs
   and documented outputs.
2. Three environments from one implementation, differing only in values.
3. Remote state with locking, one state per environment.
4. Least-privilege instance IAM and IMDSv2.
5. An output that exports an Ansible-shaped inventory.
6. A monitoring module creating an alert policy and a dashboard.

**The bridge**
7. Generated inventory — never hand-edited, with a GENERATED banner.
8. A dynamic inventory script that reads state directly.
9. One script that does: plan → apply → generate inventory → configure → verify.

**Ansible**
10. Roles with `defaults/`, `tasks/`, `handlers/`, `templates/`, `meta/`.
11. Vault-encrypted secrets; no plaintext credentials anywhere.
12. A bootstrap path that works on a host with no Python and no deploy user.
13. A verification role with four levels of proof, including an API check.
14. Idempotent: second run `changed=0`.

**Delivery**
15. CI running a four-level gate on every PR.
16. Plan on PR, apply on merge, with a destroy guard.
17. Nightly drift detection that alerts.
18. A deploy marker sent to your monitoring backend.

**Operations**
19. A rollback runbook.
20. A troubleshooting runbook covering at least the top 5 failures from Day 29.

## The rubric

Score yourself honestly. Below 70% — redo the relevant days.

| # | Criterion | Pass condition |
| --- | --- | --- |
| 1 | Reproducibility | A colleague can build the whole thing from your README |
| 2 | Isolation | A mistake in dev cannot affect prod |
| 3 | Idempotency | Two consecutive runs: second is `changed=0` |
| 4 | Secrets | `git log -p \| grep -i key` finds nothing real |
| 5 | Verification | A wrong license key fails the pipeline |
| 6 | Drift | Editing a config by hand is detected within an hour |
| 7 | Blast radius | No plan can destroy a VPC without an explicit label |
| 8 | Cost | Every resource carries `Environment` and `CostCenter` |
| 9 | Reversibility | You can roll back a bad deploy in under 10 minutes |
| 10 | Honesty | Every skipped check and every unverified assumption is documented |

Criterion 10 is the one that separates a senior engineer from a confident one.
This repository ships `docs/VERIFICATION.md` for exactly that reason.

## The interview questions

If you can answer all of these without notes, you are at master level.

**Terraform**
1. Why is `for_each` keyed by AZ safer than `count`?
2. What is in a state file that makes it a security concern?
3. When do you use `moved` blocks instead of `terraform state mv`?
4. Why does `desired_capacity` belong in `ignore_changes`?
5. What makes a plan "reviewable", and what would you refuse to approve?

**Ansible**
6. Full variable precedence, lowest to highest.
7. Why `defaults/` and not `vars/` for anything overridable?
8. Why do handlers exist, and what two guards should a service handler have?
9. Why `gather_facts: false` plus `raw` in a bootstrap play?
10. Name three things that break idempotency.

**Integration**
11. What exactly should `user_data` do, and why nothing more?
12. Compare the three Terraform→Ansible inventory patterns.
13. Why must the applied plan be the reviewed plan?
14. What happens to Ansible's configuration when an ASG replaces an instance?
15. Why does a typo in an NRQL filter produce silence instead of an error?

## Reference architecture

What "done" looks like, end to end:

```
                PR
                 │
   ┌─────────────┴──────────────┐
   │ CI: lint, parse, policy,   │
   │     lab (behaviour test)   │
   └─────────────┬──────────────┘
                 │ plan artifact + PR comment
                 ▼
           human approval
                 │ merge
                 ▼
   ┌────────────────────────────┐
   │ terraform apply tfplan     │
   │   ├─ VPC / SG / ASG / ALB  │
   │   └─ NR alerts + dashboard │
   └─────────────┬──────────────┘
                 │ output: ansible_inventory_json
                 ▼
   ┌────────────────────────────┐
   │ tf_to_inventory.py         │
   └─────────────┬──────────────┘
                 ▼
   ┌────────────────────────────┐
   │ ansible-playbook site.yml  │
   │   bootstrap → configure    │
   │   → newrelic → verify      │
   └─────────────┬──────────────┘
                 ▼
   ┌────────────────────────────┐
   │ deploy marker + pipeline   │
   │ event to New Relic         │
   └─────────────┬──────────────┘
                 ▼
        nightly drift job → alert or auto-heal
```

## Where to go after this

| Direction | Next step |
| --- | --- |
| Certifications | HashiCorp Certified: Terraform Associate; Red Hat EX407 (Ansible) |
| Policy as code | Open Policy Agent / Sentinel with Terraform |
| Kubernetes | Terraform for the cluster, Ansible for the nodes, Helm for workloads |
| Immutable infra | Packer + Ansible baked AMIs; Ansible only for drift |
| Compliance automation | InSpec/Ansible compliance profiles, continuous evidence collection |
| Platform engineering | Internal developer platform with self-service environments |

## Final exercise

Take this repository and **break it in five different ways**, then repair it. For
each:

1. Describe the break.
2. Predict which check catches it (lint / parse / policy / behaviour).
3. Verify your prediction by running the check.
4. If no check caught it, **write one**.

That last step is the actual job. Tools are the easy part; knowing what to assert
is the craft.

---

## You are done

Thirty days, three levels, one integrated platform. If you built the capstone and
scored 70%+, you can provision infrastructure with Terraform, configure it with
Ansible, integrate the two safely, and defend every decision you made — which is
what the job actually asks for.

Go build something, and write down what breaks.
