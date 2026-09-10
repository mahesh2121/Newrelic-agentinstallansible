# Role: verify_agents

Turns "the playbook said OK" into evidence. Four levels of proof, weakest first:

1. **package present** - the RPM/DEB is installed
2. **service running** - systemd says `running`
3. **config sane** - file exists and is not world-readable (it holds the license key)
4. **data arriving** - the New Relic REST API knows about this host

Only #4 proves monitoring works. Enable it with:

```yaml
newrelic_verify_api_enabled: true
vault_newrelic_api_key: <user API key>     # in inventory/group_vars/vault.yml
```

Run it on a schedule from CI (Day 25) or after every deploy (Day 26):

```bash
ansible-playbook playbooks/verify.yml --limit servers
```
