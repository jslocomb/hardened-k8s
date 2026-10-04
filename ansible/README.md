# Ansible: rebuild the lab node

Recreates the VM build documented in [docs/environment.md](../docs/environment.md),
then applies node hardening. Runs from the Mac over SSH; nothing is installed on the VM
except what the build itself needs.

**Status:** written from the documented manual build. Not yet validated end to end
against a fresh VM.

## What it does
| Role | Purpose |
|---|---|
| base | Hostname, apt update, safe upgrades |
| chrony | Clock-drift fix (`makestep 1 -1`) |
| k8s_prereqs | `overlay`/`br_netfilter` modules, forwarding sysctls, swap off |
| toolkit | Troubleshooting packages (sysstat, stress-ng, tcpdump, ...) |
| k0s | Pinned k0s binary, single-node controller, admin kubeconfig |
| kubectl | Pinned kubectl, SHA-256 verified |
| ssh_hardening | Key auth, password auth off, root login off |
| firewall | ufw, **off by default** (`firewall_enabled: false`) |
| verify | Waits for node Ready, prints cluster state |

## Prerequisites (on the Mac)
```bash
brew install ansible
ansible-galaxy collection install -r requirements.yml
```

## First run against a fresh VM
After installing Ubuntu Server with OpenSSH enabled, copy your key once
(the only step that uses a password):
```bash
ssh-copy-id jason@192.168.64.4
```

## Usage
```bash
cd ansible
ansible lab -m ping                       # connectivity check
ansible-playbook site.yml --check --diff -K   # dry run (sudo password prompt)
ansible-playbook site.yml -K              # apply
ansible-playbook site.yml -K --tags ssh   # run one area
```

## Notes
- Versions are pinned in `group_vars/lab.yml` to match the documented VM.
  Changing `k0s_version` does not upgrade an existing install; k0s upgrades are a
  separate procedure.
- The firewall role is off until tested. ufw's default policies can drop pod and
  service traffic; the role allows the pod and service CIDRs and routed traffic,
  but verify with the troubleshooting scenarios before enabling it permanently.
- `--check` mode will report some tasks (k0s install, kubeconfig) as skipped or
  changed, because they depend on commands that don't run in check mode.
