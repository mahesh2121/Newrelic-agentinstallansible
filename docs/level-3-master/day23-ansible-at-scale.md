# Day 23 — Ansible at Scale

**Level 3** · ~2 hours · Prereqs: Day 22

## What you will be able to do

- Patch 500 hosts without downtime
- Cut runtime by 10x with connection reuse and fact caching
- Delegate, throttle and run async where it matters
- Reason about blast radius

## The four levers

| Lever | Setting | Effect |
| --- | --- | --- |
| Parallelism | `forks = 20` | hosts processed concurrently |
| Connection reuse | `ControlMaster`, `pipelining` | fewer SSH handshakes |
| Fact handling | `gathering = smart`, `fact_caching` | skip re-gathering |
| Blast radius | `serial`, `throttle`, `max_fail_percentage` | limit damage |

`ansible/ansible.cfg` sets the first three:

```ini
[defaults]
forks             = 20
gathering         = smart
fact_caching      = jsonfile
fact_caching_connection = ./.facts
fact_caching_timeout = 3600
show_custom_stats = True

[ssh_connection]
pipelining    = True
ssh_args      = -o ControlMaster=auto -o ControlPersist=300s -o ServerAliveInterval=30
control_path  = /tmp/ansible-%%h-%%r
```

`show_custom_stats = True` prints per-task timing at the end of a run. Without it
you cannot find your slow task.

## Rolling operations: `serial`

`playbooks/patch.yml`:

```yaml
- name: Patch managed hosts in batches
  hosts: servers
  serial: 2
  tasks:
    - name: Upgrade security packages (Debian)
      ansible.builtin.apt:
        upgrade: safe
        update_cache: true
        cache_valid_time: 3600

    - name: Check whether a reboot is required
      ansible.builtin.stat:
        path: /var/run/reboot-required
      register: patch_reboot_required

    - name: Reboot patched host and wait for it to return
      ansible.builtin.reboot:
        reboot_timeout: 600
        post_reboot_delay: 20
      when: patch_reboot_required['stat']['exists']

    - name: Ensure New Relic agent came back after reboot
      ansible.builtin.service:
        name: newrelic-infra
        state: started
      failed_when: false
```

How `serial: 2` behaves on 10 hosts: batches of 2, five rounds. **The play does
not move to the next batch until the current one finishes.** If a batch fails and
exceeds `max_fail_percentage`, the whole run stops.

Choosing `serial`:

| Value | Meaning | Use when |
| --- | --- | --- |
| omitted | all hosts at once | read-only, config-only |
| `1` | one at a time | database clusters, anything stateful |
| `2` or `"20%"` | small batches | web tier behind an ALB |
| `"50%"` | half at a time | disposable, highly redundant |

With `serial` and an ASG, also respect `min_healthy_percentage`: if the ALB
requires 50% healthy and you reboot 50%, health checks may flap. Use 20–30%.

`max_fail_percentage: 10` means "stop if more than 10% of the batch failed" —
without it, one bad host aborts the run; with `100`, nothing ever stops it.

## Fact caching

Gathering facts on 500 hosts costs ~1–3 seconds each, serialised by your forks.
Caching:

```ini
fact_caching      = jsonfile
fact_caching_connection = ./.facts
fact_caching_timeout = 3600
```

Rules:

- Cache only facts you trust to be stable (OS family, distribution). Not
  `ansible_date_time`, not disk usage.
- `.facts/` must be **git-ignored** — it contains host details.
- Use `redis` instead of `jsonfile` when multiple control nodes share a cache.
- `ansible <host> -m setup --tree ./.facts` refreshes deliberately.

To skip gathering entirely: `gather_facts: false` — but then `ansible_facts` is
empty and most conditionals break.

## Async and polling

For long-running operations that should not hold an SSH connection:

```yaml
- name: Run a long migration
  ansible.builtin.command:
    cmd: /opt/app/migrate.sh
  async: 3600
  poll: 30
  register: migration
```

`poll: 0` means fire-and-forget — check later with `async_status`. Useful for
"start this on 200 hosts, come back in 10 minutes".

## Delegation and `run_once`

```yaml
- name: Query New Relic API for this host
  ansible.builtin.uri:
    url: "{{ newrelic_verify_api_base_url }}/applications.json"
  delegate_to: localhost
  become: false
```

Real code from `roles/verify_agents/tasks/main.yml`. The API call happens on the
control node — the target hosts do not need outbound internet or `curl`.

```yaml
- name: Register the deploy once, not per host
  ansible.builtin.command:
    cmd: newrelic-deployment-marker ...
  run_once: true
  delegate_to: localhost
```

`run_once` runs the task on the **first** host only. Combine with
`delegate_to: localhost` for control-plane actions. Careful: `run_once` results
are shared across all hosts, which surprises people.

`throttle: 5` limits concurrency for a single task regardless of `forks` — useful
for an API with rate limits.

## Strategies

```yaml
- hosts: servers
  strategy: free        # hosts proceed independently, no per-task barrier
```

Default is `linear` (all hosts do task 1, then task 2). `free` is faster for
heterogeneous fleets but makes output interleaved and `serial` semantics odd.
Use `free` for read-only or host-independent work.

## The 500-host playbook

```bash
# 1. can we reach everything?
ansible servers -m ping -f 50 | tail -20

# 2. what would change? (fast, read-only)
ansible-playbook playbooks/configure.yml --check --diff -f 20 | tee check.log

# 3. how many hosts would change?
grep -c "changed=" check.log

# 4. apply to a canary first
ansible-playbook playbooks/configure.yml --limit 'servers[0:2]' --diff

# 5. the rest
ansible-playbook playbooks/configure.yml --limit 'servers[2:]' -f 20
```

Step 4 is not optional. A canary is how you find the host with the unusual OS.

## Lab 23.1 — measure your configuration

```bash
cd ansible
ansible-playbook ../labs/local/lab.yml
```

The recap plus custom stats show per-task timing. Now run with `-f 1` and compare
wall-clock time. On one host you will barely notice; on 500 you would notice
enormously.

## Lab 23.2 — simulate a fleet

```bash
python3 - <<'PY'
import yaml, pathlib
hosts = {f"sim-{i:03d}": {"ansible_connection": "local"} for i in range(50)}
inv = {"all": {"children": {"sim": {"hosts": hosts}}}}
pathlib.Path("/tmp/sim-inventory.yml").write_text(yaml.safe_dump(inv))
print("wrote", len(hosts), "hosts")
PY
ansible-inventory -i /tmp/sim-inventory.yml --graph | head -8
time ansible sim -i /tmp/sim-inventory.yml -m ping -f 25 | tail -3
```

50 hosts, one machine, no cloud. Watch how `-f` changes the wall clock.

## Lab 23.3 — the deliberate failure

Run a rolling playbook with a failure injected and no failure tolerance:

```bash
ansible sim -i /tmp/sim-inventory.yml -m fail -a "msg=boom" -f 25
```

Now the same with a play using `serial: 5` and `max_fail_percentage: 0`: the run
stops after the first batch. Change to `max_fail_percentage: 100` and watch it
plough through all 50. Neither default is right for every situation — which is why
you set it explicitly.

## Exercises

1. Add `max_fail_percentage: 20` to `playbooks/patch.yml` and explain what
   happens with 10 hosts and 3 failures.
2. Add fact caching with Redis and prove the second run is faster.
3. Write a playbook that registers a New Relic deployment marker exactly once per
   deploy, using `run_once` + `delegate_to`.

## Gotchas

- `forks` beyond your control node's CPU/RAM gives diminishing returns and can
  exhaust file descriptors.
- `ControlPersist=300s` keeps sockets open; on a shared control node, stale
  sockets cause "mux_client_hello_exchange" errors. `rm /tmp/ansible-*`.
- `serial` + `pre_tasks`/`post_tasks`: `pre_tasks` run per batch, not once.
- `async` tasks are killed if the SSH connection drops and `poll > 0`. Use
  `poll: 0` plus `async_status` for true fire-and-forget.
- `run_once` uses the *first* host's variables — which may not be the host you
  meant.

## Check yourself

- [ ] You can explain `serial`, `max_fail_percentage`, `forks` and `throttle`
- [ ] You have measured a run with and without fact caching
- [ ] You always run a canary before the full fleet

**Next:** [Day 24 — Security & Compliance](day24-security-and-compliance.md)
