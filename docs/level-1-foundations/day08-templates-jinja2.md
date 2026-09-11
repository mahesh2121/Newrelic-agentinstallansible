# Day 8 — Templates and Jinja2

**Level 1** · ~90 min · Prereqs: Day 7

## What you will be able to do

- Render configuration files from data
- Avoid the whitespace bug that produces invalid YAML
- Set correct ownership and permissions on files containing secrets
- Prove a rendered file is valid before the service reads it

## Why templates

Configuration is data. Hard-coding it into tasks means one task per setting and
no way to vary it per environment. Templates put the *shape* in a file and the
*values* in variables:

```
roles/newrelic_infra/templates/newrelic-infra.yml.j2   ← shape
inventory/group_vars/servers.yml                       ← values
```

```yaml
- name: Write newrelic-infra.yml
  ansible.builtin.template:
    src: newrelic-infra.yml.j2
    dest: "{{ newrelic_infra_config_path }}"
    owner: "{{ newrelic_infra_config_owner }}"
    mode: "{{ newrelic_infra_config_mode }}"      # "0600" - holds the license key
  notify: Restart newrelic-infra
```

`mode: "0600"` is not pedantry. That file contains your license key; anyone who
can read it can send data to your New Relic account and inflate your bill.

## Jinja2 in 10 minutes

```jinja
{{ variable }}                     substitution
{{ list | length }}                filter
{{ dict | to_nice_yaml }}          filter with arguments
{% for x in items %}...{% endfor %} loop
{% if cond %}...{% endif %}        conditional
{# comment #}                      comment (Jinja still parses it!)
```

Filters you will use constantly:

| Filter | Purpose |
| --- | --- |
| `| default('x')` | avoid undefined-variable failures |
| `| bool` | `"false"` → `False` |
| `| to_nice_yaml` | dict → readable YAML |
| `| to_json` | dict → JSON |
| `| b64decode` | decode `slurp` output |
| `| dict2items` | loop over a dict |
| `| quote` | shell-safe string |

## The bug that cost this course an afternoon

The infrastructure agent's config was rendering **invalid YAML**. Here is the
rendered output, exactly as produced:

```yaml
    labels:      env: "dev"    commands:
```

The cause was Jinja whitespace control. The template used dash-tags:

```jinja
labels:
{%- for key, value in labels.items() %}
  {{ key }}: "{{ value }}"
{%- endfor %}
```

In Ansible's template engine the dash form strips the surrounding newlines, so
the whole mapping collapses onto one line. This was proved by rendering both
forms side by side:

```
dash form  ->  labels:  env: "dev"  region: "ap-south-1"commands:
plain form ->  labels:
                 env: "dev"
                 region: "ap-south-1"
               commands:
```

**The rule:** in templates that produce YAML, use plain block tags. Both
`roles/newrelic_infra/templates/newrelic-infra.yml.j2` and
`roles/newrelic_integrations/templates/nri-flex-example.yml.j2` say so in a
comment.

### A second, sneakier version of the same bug

While fixing it, the *comment explaining the fix* broke the template:

```
Syntax error in template: tag name expected
```

because the comment contained literal block tags, and **Jinja parses comments**.
Write about tags in prose, or wrap the section in a `raw` block.

## Rendering conditionals without empty blocks

```jinja
{% if newrelic_infra_custom_attributes | length > 0 %}
custom_attributes:
{% for key, value in newrelic_infra_custom_attributes.items() %}
  {{ key }}: "{{ value }}"
{% endfor %}
{% endif %}
```

Guarding with `| length > 0` prevents emitting a bare `custom_attributes:` key
with no value, which the agent would read as null.

## Proving the render is correct

Rendering is not the same as being correct. `labs/local/mock_bridge.sh` parses
the result back:

```python
parsed = yaml.safe_load(path.read_text())
assert isinstance(parsed, dict) and parsed
```

Real output:

```
PASS  config.copy: valid YAML with 7 top-level key(s) -> ['custom_attributes',
      'display_name', 'labels', 'license_key', 'log', 'passthrough_environment', 'verbose']
PASS  integration.copy: valid YAML with 1 top-level key(s) -> ['integrations']
```

Adopt this habit for every template: **render, then parse.**

You can also push validation into the task itself:

```yaml
- name: Write config
  ansible.builtin.template:
    src: x.yml.j2
    dest: /etc/x.yml
    mode: "0600"
    validate: "python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' %s"
```

`validate` runs **before** the file is written to its destination, so a bad
render can never break a running service. For the agent, the better validator is
`newrelic-infra -config ... -validate` (Day 18).

## Lab 8.1 — render and inspect

```bash
bash labs/local/mock_bridge.sh
```

Read section 5 of the output. You should see the rendered agent config including
`custom_attributes`, `labels` and `passthrough_environment`, and section 7 should
print two `PASS` lines.

## Lab 8.2 — the deliberate failure

Break a template and watch Ansible catch it:

```bash
cd ansible
cp roles/newrelic_integrations/templates/nri-flex-example.yml.j2 /tmp/backup.j2
printf 'integrations:\n  - name: broken\n{% for x in y %}\n' \
  > roles/newrelic_integrations/templates/nri-flex-example.yml.j2
ansible-playbook playbooks/newrelic.yml --limit lab
```

```
Syntax error in template: unexpected 'end of template', expected 'end of statement'
```

Restore it:

```bash
cp /tmp/backup.j2 roles/newrelic_integrations/templates/nri-flex-example.yml.j2
```

## Lab 8.3 — permissions matter

```bash
bash labs/local/mock_bridge.sh 2>&1 | grep newrelic-infra.yml
```

```
-rw------- 1 root root 504 .../newrelic-infra.yml
```

`0600`, owned by root. Try reading it as your normal user and confirm you cannot.
`roles/verify_agents/tasks/main.yml` asserts this on every run:

```yaml
- name: Assert configuration file exists and is not world readable
  ansible.builtin.assert:
    that:
      - newrelic_verify_config_stat['stat']['exists']
      - newrelic_verify_config_stat['stat']['mode'] in ['0600', '0400', '0640']
```

## Exercises

1. Add a template variable `newrelic_infra_proxy` that renders an
   `proxy: http://...` line only when set. Prove it appears and disappears.
2. Render the same data with `to_nice_yaml` instead of a manual loop. Which is
   more readable in the diff?
3. Change `newrelic_infra_config_mode` to `"0644"` and run
   `playbooks/verify.yml`. Confirm the assertion fails.

## Gotchas

- `template:` compares content, so an identical render is not `changed`.
- Jinja `{{ }}` inside a YAML value that begins with `{` must be quoted.
- `ansible.builtin.copy` with `content:` also runs Jinja — the same bugs apply.
- Templates cannot use `{{ hostvars[...] }}` for a host that has not been
  contacted yet, unless facts are cached.

## Check yourself

- [ ] You can explain why dash-tags break YAML templates
- [ ] `labs/local/mock_bridge.sh` prints two `PASS` lines
- [ ] You know why the agent config is `0600`

**Next:** [Day 9 — Terraform Basics](day09-terraform-basics.md)
