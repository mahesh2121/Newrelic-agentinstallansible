# Day 1 — Setup, Mental Model, First Contact

**Level 1** · ~60 min · Prereqs: [Day 0](../00-prerequisites.md)

## What you will be able to do

- Explain, in one sentence each, what Terraform and Ansible own
- Explain push vs pull, and why Ansible is push by default
- Run your first ad-hoc command and read its output
- Diagnose the most common first-day failure

## The mental model

Two tools, one job each:

| | Terraform | Ansible |
| --- | --- | --- |
| Question it answers | What **exists**? | How is it **configured**? |
| Language | HCL (declarative) | YAML (declarative tasks) |
| State | `terraform.tfstate` — required | none by default — reads the host |
| Typical targets | Cloud APIs: VPC, subnets, IAM, DNS | Inside the OS: packages, files, services |
| Idempotency | Compares state to reality | Compares task result to desired state |
| Runs from | Your laptop / CI | A control node over SSH |

**Why not one tool?** Terraform can run `remote-exec` and Ansible can call cloud
APIs, but each is bad at the other's job. Terraform has no good way to say
"ensure this config file has these lines"; Ansible has no good way to say
"ensure exactly two subnets exist in two AZs". The industry settled on:
**Terraform builds it, Ansible configures it.**

### Push vs pull

- **Push (Ansible default):** a control node SSHes into hosts and pushes changes.
  Simple, no agent, works on a brand-new box. Downside: the control node needs
  reachability and credentials to everything.
- **Pull (`ansible-pull`):** each host runs Ansible on a cron job and pulls from
  git. Scales to huge fleets, no inbound SSH. Downside: slow feedback, secrets on
  every host.

This repo is push-mode. Day 16 shows the pull hybrid.

## Lab 1.1 — verify the toolchain

```bash
cd Newrelic-agentinstallansible
ansible --version | head -3
```

The second line must read `config file = .../ansible/ansible.cfg` when you are
inside `ansible/`. If it says `config file = None`, Ansible is not picking up the
repo's config and later labs will behave differently.

```bash
cd ansible
ansible lab -m ping
```

Expected:

```
lab-local | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

`ping` is not ICMP — it is the `ansible.builtin.ping` module: connect, run
Python, return `pong`. A `SUCCESS` proves four things at once: inventory
resolved, connection worked, Python exists, the module executed.

## Lab 1.2 — the deliberate failure

Now break it on purpose, because you will see this error in production:

```bash
ansible lab -m ping -e ansible_connection=ssh
```

```
lab-local | UNREACHABLE! => {
    "changed": false,
    "msg": "Failed to connect to the host via ssh: ..."
}
```

**Diagnosis:** the `lab` group is defined with `ansible_connection: local` in
`ansible/inventory/hosts.yml`. Overriding it to `ssh` makes Ansible try to SSH to
itself, which needs a running sshd and a host key. The lesson: **inventory
variables are real configuration, not comments.** When a host is unreachable, the
first thing to inspect is what Ansible thinks the connection is:

```bash
ansible lab --list-hosts
ansible-inventory --host lab-local | head -20
```

## Lab 1.3 — read an ad-hoc command's output

```bash
ansible lab -m setup -a 'filter=ansible_distribution*'
```

`setup` is the facts module. Filtering keeps the output readable. Facts are
collected automatically at the start of a play unless you set `gather_facts: false`
— which matters a lot at scale (Day 23).

## Lab 1.4 — a config trap worth 20 minutes of your life

This repository deliberately does **not** set `stdout_callback = yaml` in
`ansible/ansible.cfg`. If you uncomment it on a machine without the
`community.general` collection, every Ansible command dies before it starts:

```
[WARNING]: Error loading plugin 'community.general.yaml': No module named 'ansible_collections.community'
[ERROR]: Could not load 'yaml' callback plugin.
```

and — this is the nasty part — **the playbook prints nothing at all** and exits 0,
which looks like success. That failure was reproduced while writing this course.

Lesson: pretty output is a dependency. Either install the collection
(Day 17) or leave the callback at the default.

## Exercises

1. Add a host `my-laptop` to the `lab` group in `ansible/inventory/hosts.yml` and
   prove it appears in `ansible-inventory --graph`.
2. Run `ansible lab -m command -a 'uname -a'`. Run it twice. What is different in
   the recap the second time, and why? (Answer on Day 6.)
3. Run `ansible --version` from the repo root and from inside `ansible/`. Explain
   the difference in the `config file` line.

## Gotchas

- `ansible` needs an inventory. With `-i localhost,` (note the trailing comma —
  it means "this is a host list, not a file") the connection defaults to **ssh**,
  so you also need `-c local`:
  ```bash
  ansible -i localhost, -c local localhost -m ping
  ```
- Ad-hoc commands cannot use handlers, and cannot express "do X only if Y
  changed". They are for one-offs; anything repeated belongs in a playbook (Day 3).

## Check yourself

You are done with Day 1 when you can:

- [ ] State what each tool owns, without notes
- [ ] Run `ansible lab -m ping` and get `SUCCESS`
- [ ] Explain why `stdout_callback = yaml` can silently break a run
- [ ] Find the inventory file that defines the `lab` group

**Next:** [Day 2 — Inventory & ad-hoc commands](day02-inventory-and-ad-hoc.md)
