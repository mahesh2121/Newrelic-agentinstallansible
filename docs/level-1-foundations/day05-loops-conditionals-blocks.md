# Day 5 — Loops, Conditionals and Error Handling

**Level 1** · ~75 min · Prereqs: Day 4

## What you will be able to do

- Loop over lists and dicts with readable output
- Write conditions that do not blow up on undefined variables
- Use `block / rescue / always` for rollback and guaranteed cleanup
- Choose between `failed_when`, `ignore_errors` and `rescue`

## Loops

### The right way to loop over packages

```yaml
- name: Install baseline packages
  ansible.builtin.package:
    name: "{{ common_base_packages }}"   # the module accepts a list
    state: present
```

**Do not** write `loop: "{{ common_base_packages }}"` here. One package call
resolves dependencies together and is dramatically faster than 8 calls. Loop only
when each iteration must be independent.

This is the real code in `roles/common/tasks/main.yml`.

### When you do need a loop

```yaml
- name: Render one site configuration per web server
  ansible.builtin.template:
    src: site.conf.j2
    dest: "{{ lab_root }}/sites/{{ item.name }}.conf"
    mode: "0644"
  loop: "{{ lab_web_servers }}"
  loop_control:
    label: "{{ item.name }}:{{ item.port }}"
```

`loop_control.label` is not cosmetic. Without it, Ansible prints the entire dict
per iteration and your log becomes unreadable. With it you get:

```
changed: [lab-local] => (item=web-01:8081)
changed: [lab-local] => (item=web-02:8082)
```

That output is from `labs/local/lab.yml`, which you will run below.

### Looping over a dict

```yaml
loop: "{{ newrelic_infra_labels | dict2items }}"
loop_control:
  label: "{{ item.key }}"
# then use item.key and item.value
```

### Cartesian product

`roles/firewall/tasks/main.yml` pairs ports with CIDRs:

```yaml
loop: "{{ firewall_allowed_tcp_ports | product(firewall_allowed_from_cidrs) | list }}"
```

## Conditionals

```yaml
- name: Enable and start NTP service
  ansible.builtin.service:
    name: "{{ common_ntp_service }}"
    state: started
    enabled: true
  when: common_manage_ntp | bool
```

Rules that prevent 90% of conditional bugs:

1. **No Jinja in `when`.** Write `when: x | bool`, never `when: "{{ x }}"`.
2. **Cast explicitly.** Variables arriving from inventory are strings; `"false"`
   is truthy in Python. `| bool` fixes it.
3. **Guard dictionary access.** `when: ansible_facts['services'][svc] is defined`
   not `when: ansible_facts['services'][svc]['state'] == 'running'`.
4. **Feature flags beat `ansible_os_family` checks** for testability. Every role
   here gates risky work behind a boolean so the same role runs in a container.

See `roles/common/tasks/main.yml` — the pattern `when: common_manage_X | bool`
is used on every task that needs root or systemd.

## Error handling

### block / rescue / always

From `labs/local/lab.yml`, which runs for real:

```yaml
- name: Simulate a risky step safely
  block:
    - name: Attempt an operation that can fail
      ansible.builtin.command:
        cmd: test -f {{ lab_root }}/does-not-exist.txt
      changed_when: false
  rescue:
    - name: Handle the failure
      ansible.builtin.debug:
        msg: "Rescued - the file is missing, continuing without failing the play."
  always:
    - name: Write the lab completion marker
      ansible.builtin.copy:
        content: "lab: complete\n"
        dest: "{{ lab_root }}/DONE.txt"
        mode: "0644"
```

Semantics: `rescue` runs only if something in `block` failed; `always` runs no
matter what. In the recap you see `rescued=1 failed=0`.

Real uses: stop the service → apply a risky change → restart it even on failure;
or take a host out of the load balancer → patch → put it back.

### failed_when

```yaml
- name: Validate agent configuration file
  ansible.builtin.command:
    cmd: newrelic-infra -config {{ newrelic_infra_config_path }} -validate
  register: newrelic_infra_validate
  changed_when: false
  failed_when:
    - newrelic_infra_validate.rc != 0
    - "'unknown flag' not in (newrelic_infra_validate.stderr | default(''))"
```

This is `roles/newrelic_infra/tasks/verify.yml`. It fails on a genuine validation
error but tolerates agent versions that do not implement `-validate`. Note
`changed_when: false` — a validation command never changes anything, and without
it Ansible would report `changed` forever.

### When to use what

| Tool | Use when |
| --- | --- |
| `failed_when` | The module returns success but the *content* means failure |
| `rescue` | You need to do something else after a failure |
| `ignore_errors: true` | Almost never — it hides failures |
| `any_errors_fatal: true` | One host failing must stop the whole play |

## Lab 5.1 — run and read

```bash
cd ansible
ansible-playbook ../labs/local/lab.yml --diff
```

Confirm: `rescued=1`, `failed=0`, the handler fired exactly once, and
`~/tf-ansible-lab/DONE.txt` exists even though a task failed.

## Lab 5.2 — the deliberate failure

Remove `changed_when: false` from the failing command task and run twice:

```bash
ansible-playbook ../labs/local/lab.yml
```

The recap now shows an extra `changed`. Now imagine that task were a service
restart notified by a handler: **every run would restart your agent.** That is why
`ansible-lint` enforces `no-changed-when` on command tasks, and why this repo runs
`ansible-lint --profile production` in CI.

## Lab 5.3 — make a condition fail loudly

```yaml
- name: Assert New Relic license key is available
  ansible.builtin.assert:
    that:
      - newrelic_infra_license_key | length > 10
    fail_msg: >-
      newrelic_infra_license_key is empty. Put it in an ansible-vault file...
    quiet: true
```

Run it without a key:

```bash
ansible-playbook playbooks/newrelic.yml --limit lab -e newrelic_infra_install_packages=true
```

A clear `fail_msg` at the top of a role beats a cryptic failure 40 tasks later.
Put asserts at the boundary of every role.

## Exercises

1. Add a third web server to `lab_web_servers` in `labs/local/lab.yml`. Confirm
   only the new file is `changed` on the next run.
2. Convert the `rescue` block into a `failed_when: false` task. What do you lose?
3. Write a task that fails if the current user is not in the `sudo` group, using
   `assert` and `ansible_facts['user_id']`.

## Gotchas

- `loop` + `when` evaluates the condition **per item**; to skip the whole task,
  put the condition on a wrapping `block`.
- `with_items` is legacy. Use `loop`.
- `register` inside a loop produces `results` (a list), not a single dict.
- `changed_when` must be set on every `command`/`shell` task, or idempotency is
  a lie.

## Check yourself

- [ ] You can explain why `package: name={{ list }}` beats `loop:`
- [ ] `labs/local/lab.yml` shows `rescued=1 failed=0`
- [ ] You know when `failed_when` is the right tool

**Next:** [Day 6 — Handlers, Idempotency, Tags](day06-handlers-idempotency-tags.md)
