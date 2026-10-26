# Lab 1: Shell ergonomics and the Ansible OS baseline

**Goal:** extend the existing `hardened-k8s/ansible` roles so the same OS baseline can be
pointed at the three multi-node VMs in Lab 2, and prove the changes converge on a real
Ubuntu ARM64 host (`a0`).

**CKA relevance:** shell setup (alias, completion, `$do`, vim) is exam-speed technique.
The Ansible work is extra depth for the Mirantis-facing lab, not exam content.

## What changes in this lab

| Item | Change |
|---|---|
| `group_vars/all.yml` | **New.** Shared variables moved out of `lab.yml` so both host groups get them |
| `group_vars/lab.yml` | Slimmed to `a0`-only values |
| `group_vars/multinode.yml` | **New.** Values for `controller`, `worker-01`, `worker-02` |
| `base` | Adds an opt-in passwordless-sudo drop-in (k0sctl requires it) |
| `k8s_prereqs` | Sysctls become a dictionary; adds `bridge-nf-call-ip6tables` and inotify limits. Still installs **no** container runtime: k0s bundles containerd |
| `toolkit` | Adds `conntrack`, `dnsutils`, `ipset`, and a checksum-verified `crictl` pointed at the k0s containerd socket |
| `ssh_hardening` | Unchanged (already key-only, root login off) |
| `k0s` | Unchanged. This is the **single-node** install path for `a0`. On the multi-node cluster, `k0sctl` does this job in Lab 2, so the role is never applied there |
| `kubectl` | Unchanged. Applied to the `controller` VM in Lab 2 |
| `inventory/hosts.yml` | Adds the `multinode` group (`controllers`, `workers`) |
| `os.yml` | **New** playbook: OS roles only, for the multi-node VMs |

Why the playbook runs against `a0` here instead of the three new VMs: those VMs are
created in Lab 2. Running the changed roles against `a0` now proves they converge on the
same OS and architecture before you build anything new. Lab 2 runs `os.yml` against the
three VMs.

---

## Pre-check

Run on the Mac. Confirms the repo is clean and `a0` answers.

```bash
cd ~/Projects/hardened-k8s && git status --short && git log --oneline -3 && cd ansible && ansible lab -m ping -e ansible_become=false
```

**Expected:** no lines from `git status --short`, three recent commits, and:

> `a0 | SUCCESS => { "changed": false, "ping": "pong" }`

If `git status` shows changes, commit or stash them first so this lab's diff stays readable.
`-e ansible_become=false` is needed because `ansible.cfg` turns on sudo for everything,
and an ad-hoc ping has no sudo password to offer.

---

### Step 1: Look at what is already there

```bash
cd ~/Projects/hardened-k8s && find ansible -type f -not -path 'ansible/collections/*' | sort
```

**Expected (before this lab):**

```text
ansible/README.md
ansible/ansible.cfg
ansible/group_vars/lab.yml
ansible/inventory/hosts.yml
ansible/requirements.yml
ansible/roles/base/tasks/main.yml
ansible/roles/chrony/handlers/main.yml
ansible/roles/chrony/tasks/main.yml
ansible/roles/firewall/tasks/main.yml
ansible/roles/k0s/tasks/main.yml
ansible/roles/k8s_prereqs/tasks/main.yml
ansible/roles/kubectl/tasks/main.yml
ansible/roles/kubectl_ergonomics/defaults/main.yml
ansible/roles/kubectl_ergonomics/tasks/main.yml
ansible/roles/ssh_hardening/handlers/main.yml
ansible/roles/ssh_hardening/tasks/main.yml
ansible/roles/toolkit/tasks/main.yml
ansible/roles/verify/tasks/main.yml
ansible/site.yml
```

The draft's role names map to the repo like this: `prereqs` = `k8s_prereqs`,
`ssh` = `ssh_hardening`. The repo names stay; nothing is renamed.

---

### Step 2: Install the Mac-side tools

`k0sctl`, `helm`, and `k9s` run on the Mac, not on the VMs. `k0sctl` connects to the VMs
over SSH. `watch` and `jq` are not part of macOS; later steps use both.

```bash
brew install k0sproject/tap/k0sctl helm k9s watch jq
```

**Verify:**

```bash
k0sctl version && helm version --short && k9s version --short && watch --version | head -1 && jq --version
```

**Expected:** a version line from each tool, for example:

> `version: v0.33.1` (k0sctl), `v3.x.y+g...` or `v4.x.y+g...` (helm), `Version  v0.x.y` (k9s), `watch from procps-ng 4.x`

**Troubleshooting:** `Error: No available formula with the name "k0sctl"` means the tap
was not added. Run `brew tap k0sproject/tap` and repeat the install.

**Mac gotcha:** everything installed by Homebrew on Apple Silicon is ARM64 and lives in
`/opt/homebrew/bin`. The VM binaries (k0s, kubectl, crictl) are separate `linux/arm64`
downloads handled by Ansible and k0sctl. Never copy a Mac binary into a VM.

---

### Step 3: Mac shell ergonomics (Homebrew bash)

The `kubectl_ergonomics` role configures bash **on the VMs**. Your Mac also runs bash
(Homebrew bash 5.3), so this step adds the same habits to `~/.bashrc` there.

Your setup already covers part of this, so nothing is duplicated:
- `~/.bash_profile` already loads Homebrew's `bash_completion.sh`.
- `~/.bashrc` already sets `EDITOR=vim`.
- `~/.vimrc` already has `syntax on` and `filetype plugin on`.

`.bash_profile` sources `.bashrc` **before** it loads bash-completion. kubectl's completion
script does not depend on bash-completion being loaded first, so the block can go in
`.bashrc`. The `grep` guards make this safe to re-run.

```bash
grep -q 'hardened-k8s kubectl ergonomics' ~/.bashrc || cat >> ~/.bashrc << 'EOF'

# >>> hardened-k8s kubectl ergonomics >>>
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
export do="--dry-run=client -o yaml"
# <<< hardened-k8s kubectl ergonomics <<<
EOF
grep -q 'expandtab' ~/.vimrc || cat >> ~/.vimrc << 'EOF'

" hardened-k8s: YAML-friendly indentation
filetype plugin indent on
set expandtab tabstop=2 shiftwidth=2 number
EOF
ln -sf /Applications/UTM.app/Contents/MacOS/utmctl "$(brew --prefix)/bin/utmctl"
source ~/.bashrc
```

The new `.vimrc` lines go after your vimwiki settings and do not change them.
`filetype plugin indent on` adds indent rules on top of your existing `filetype plugin on`.

**Verify:**

```bash
type k && echo "$do" && complete -p k && utmctl list
```

**Expected:**

> ``k is aliased to `kubectl'``
> `--dry-run=client -o yaml`
> `complete -o default -F __start_kubectl k`
> a table of UTM VMs that includes your existing `a0` VM (named `Linux` in UTM per `docs/host.md`)

Then type `k get po` and press **Tab** twice. It should offer `pod`, `pods`, and
similar completions.

**Troubleshooting:**
- `source ~/.bashrc` re-runs `starship init`, `zoxide init`, and `fzf --bash`. That is
  harmless, but opening a new iTerm tab gives a cleaner test.
- In vi mode (`set -o vi`), Tab completion works in insert mode only. Press `i` first if
  you are in command mode.
- The first `utmctl` call can trigger a macOS **Automation** prompt ("iTerm wants to
  control UTM"). Click **Allow**. If you clicked Don't Allow, re-enable it in
  System Settings → Privacy & Security → Automation.

---

### Step 4: Split group variables into shared and per-group files

`group_vars/lab.yml` holds variables both host groups need. Move the shared ones into
`all.yml` so the new `multinode` group inherits them.

```bash
cat > ~/Projects/hardened-k8s/ansible/group_vars/all.yml << 'EOF'
---
# Shared by every host: the a0 single-node lab and the multinode cluster.

# Map Ansible's architecture name to the release asset name
arch_map:
  aarch64: arm64
  x86_64: amd64
k8s_arch: "{{ arch_map[ansible_facts['architecture']] }}"

k8s_admin_user: "{{ ansible_user }}"

toolkit_packages:
  - sysstat
  - htop
  - iotop
  - net-tools
  - iproute2
  - tcpdump
  - lsof
  - ipmitool
  - stress-ng
  - jq
  - conntrack
  - dnsutils
  - ipset

# SSH hardening: public key on your Mac that should be authorized on the VMs
ssh_pubkey_file: "~/.ssh/id_ed25519.pub"
ssh_disable_password_auth: true

# Host firewall is OFF by default. ufw's default policies can block pod and
# service traffic; enable only after testing (see ansible/README.md).
firewall_enabled: false
pod_cidr: 10.244.0.0/16
service_cidr: 10.96.0.0/12

# Ubuntu 25.10+ defaults to sudo-rs, whose prompt Ansible doesn't detect.
# Use classic sudo for privilege escalation.
ansible_become_exe: /usr/bin/sudo.ws
EOF

cat > ~/Projects/hardened-k8s/ansible/group_vars/lab.yml << 'EOF'
---
# a0: single-node k0s (controller + workloads, kine/SQLite), built by site.yml.
# Versions pinned to what the documented VM runs (docs/environment.md).
k0s_version: "v1.36.4+k0s.1"
kubectl_version: "v1.37.1"
node_hostname: a0
EOF

cat > ~/Projects/hardened-k8s/ansible/group_vars/multinode.yml << 'EOF'
---
# controller + worker-01 + worker-02. k0s itself is installed by k0sctl
# (k0sctl/k0sctl.yaml, etcd datastore), not by the k0s role.
node_hostname: "{{ inventory_hostname }}"

# kubectl on the controller. v1.36 stays within the +/-1 minor skew of both the
# v1.35 install (Lab 2) and the v1.36 upgrade (Lab 3).
kubectl_version: "v1.36.4"

# k0sctl needs root or passwordless sudo over SSH. Root login stays disabled.
base_passwordless_sudo: true
EOF
```

**Verify:**

```bash
cd ~/Projects/hardened-k8s/ansible && ansible-inventory --host a0 | jq -r '.node_hostname, .k0s_version, (.toolkit_packages | length)'
```

**Expected:**

> `a0`
> `v1.36.4+k0s.1`
> `13`

---

### Step 5: `base` role, opt-in passwordless sudo

Defaults to **off**, so `a0` is unchanged. Only `multinode.yml` turns it on. The drop-in is
validated with `visudo` before it is written, so a bad line cannot lock you out of sudo.

```bash
mkdir -p ~/Projects/hardened-k8s/ansible/roles/base/defaults
cat > ~/Projects/hardened-k8s/ansible/roles/base/defaults/main.yml << 'EOF'
---
# k0sctl requires root or passwordless sudo. Off unless a group turns it on.
base_passwordless_sudo: false
EOF

cat > ~/Projects/hardened-k8s/ansible/roles/base/tasks/main.yml << 'EOF'
---
- name: Set hostname
  ansible.builtin.hostname:
    name: "{{ node_hostname }}"

- name: Update apt cache and apply safe upgrades
  ansible.builtin.apt:
    update_cache: true
    cache_valid_time: 3600
    upgrade: safe

- name: Grow root LV to fill the volume group
  community.general.lvol:
    vg: ubuntu-vg
    lv: ubuntu-lv
    size: +100%FREE
    resizefs: true

- name: Passwordless sudo for the admin user (k0sctl requirement)
  ansible.builtin.copy:
    dest: /etc/sudoers.d/90-k0sctl
    content: "{{ ansible_user }} ALL=(ALL) NOPASSWD:ALL\n"
    owner: root
    group: root
    mode: "0440"
    validate: visudo -cf %s
  when: base_passwordless_sudo | bool
EOF
```

**Security note (worth a line in an interview):** passwordless sudo widens what a stolen
SSH key can do. The mitigations here are key-only SSH, root login off, and lab-only scope.
In production, scope the sudoers line to the commands k0sctl runs or use a dedicated
deploy user.

---

### Step 6: `k8s_prereqs` role, sysctls as a dictionary

Same modules and swap handling as before. The sysctl list becomes a dictionary in
`defaults/` so values other than `1` are possible.

```bash
mkdir -p ~/Projects/hardened-k8s/ansible/roles/k8s_prereqs/defaults
cat > ~/Projects/hardened-k8s/ansible/roles/k8s_prereqs/defaults/main.yml << 'EOF'
---
k8s_prereqs_sysctls:
  net.ipv4.ip_forward: "1"
  net.bridge.bridge-nf-call-iptables: "1"
  net.bridge.bridge-nf-call-ip6tables: "1"
  # Many pods plus `kubectl logs -f` exhaust the default inotify limits
  fs.inotify.max_user_watches: "524288"
  fs.inotify.max_user_instances: "512"
EOF

cat > ~/Projects/hardened-k8s/ansible/roles/k8s_prereqs/tasks/main.yml << 'EOF'
---
# No container runtime is installed here: k0s bundles and manages containerd.
- name: Persist kernel modules for container networking
  ansible.builtin.copy:
    dest: /etc/modules-load.d/k8s.conf
    content: |
      overlay
      br_netfilter
    mode: "0644"

- name: Load kernel modules now
  community.general.modprobe:
    name: "{{ item }}"
    state: present
  loop: [overlay, br_netfilter]

- name: Set Kubernetes networking and kernel sysctls
  ansible.posix.sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    sysctl_file: /etc/sysctl.d/99-k8s.conf
    reload: true
  loop: "{{ k8s_prereqs_sysctls | dict2items }}"

- name: Check for active swap
  ansible.builtin.command: swapon --show --noheadings
  register: k8s_prereqs_swap
  changed_when: false

- name: Disable swap
  ansible.builtin.command: swapoff -a
  when: k8s_prereqs_swap.stdout | length > 0
  changed_when: true

- name: Remove swap entries from fstab
  ansible.builtin.replace:
    path: /etc/fstab
    regexp: '^([^#].*\sswap\s.*)$'
    replace: '# \1'
EOF
```

`vm.swappiness` is left out on purpose: swap is off, so it has no effect. `ipvs` modules
are left out too: k0s runs kube-proxy in iptables mode by default.

---

### Step 7: `toolkit` role, add `crictl`

`crictl` is the CKA's node-level container tool. k0s does not ship it, and k0s's
containerd listens on `/run/k0s/containerd.sock`, not the usual
`/run/containerd/containerd.sock`, so `/etc/crictl.yaml` points it there.

```bash
mkdir -p ~/Projects/hardened-k8s/ansible/roles/toolkit/defaults
cat > ~/Projects/hardened-k8s/ansible/roles/toolkit/defaults/main.yml << 'EOF'
---
toolkit_crictl_version: "v1.36.0"
toolkit_crictl_base_url: "https://github.com/kubernetes-sigs/cri-tools/releases/download"
toolkit_crictl_tarball: "crictl-{{ toolkit_crictl_version }}-linux-{{ k8s_arch }}.tar.gz"
EOF

cat > ~/Projects/hardened-k8s/ansible/roles/toolkit/tasks/main.yml << 'EOF'
---
- name: Install troubleshooting toolkit
  ansible.builtin.apt:
    name: "{{ toolkit_packages }}"
    state: present

- name: Download crictl (checksum verified)
  ansible.builtin.get_url:
    url: "{{ toolkit_crictl_base_url }}/{{ toolkit_crictl_version }}/{{ toolkit_crictl_tarball }}"
    checksum: "sha256:{{ toolkit_crictl_base_url }}/{{ toolkit_crictl_version }}/{{ toolkit_crictl_tarball }}.sha256"
    dest: "/var/tmp/crictl-{{ toolkit_crictl_version }}.tar.gz"
    mode: "0644"

- name: Install crictl
  ansible.builtin.unarchive:
    src: "/var/tmp/crictl-{{ toolkit_crictl_version }}.tar.gz"
    dest: /usr/local/bin
    remote_src: true
    include: [crictl]
    owner: root
    group: root
    mode: "0755"
  # In --check mode get_url does not download, so there is nothing to unpack yet
  when: not ansible_check_mode

- name: Point crictl at the k0s containerd socket
  ansible.builtin.copy:
    dest: /etc/crictl.yaml
    content: |
      runtime-endpoint: unix:///run/k0s/containerd.sock
      image-endpoint: unix:///run/k0s/containerd.sock
      timeout: 10
    owner: root
    group: root
    mode: "0644"
EOF
```

**CKA note:** on the exam's kubeadm nodes the socket is `/run/containerd/containerd.sock`
and is usually preconfigured. If `crictl` complains about the endpoint there, pass
`--runtime-endpoint unix:///run/containerd/containerd.sock` or set
`CONTAINER_RUNTIME_ENDPOINT`.

---

### Step 8: Inventory, add the multi-node group

IPs are on UTM's Shared Network (`192.168.64.0/24`, gateway `192.168.64.1`). The draft's
`10.0.0.0/24` does not work in Shared Network mode: macOS owns that subnet through
`vmnet`. Lab 2 explains the choice of `.10`–`.12`.

```bash
cat > ~/Projects/hardened-k8s/ansible/inventory/hosts.yml << 'EOF'
all:
  children:
    lab:
      hosts:
        a0:
          ansible_host: 192.168.64.4
          ansible_user: jason
    multinode:
      vars:
        ansible_user: jason
      children:
        controllers:
          hosts:
            controller:
              ansible_host: 192.168.64.10
        workers:
          hosts:
            worker-01:
              ansible_host: 192.168.64.11
            worker-02:
              ansible_host: 192.168.64.12
EOF
```

**Verify:**

```bash
cd ~/Projects/hardened-k8s/ansible && ansible-inventory --graph
```

**Expected:**

```text
@all:
  |--@ungrouped:
  |--@lab:
  |  |--a0
  |--@multinode:
  |  |--@controllers:
  |  |  |--controller
  |  |--@workers:
  |  |  |--worker-01
  |  |  |--worker-02
```

---

### Step 9: `os.yml`, the OS-only playbook for the multi-node VMs

`site.yml` stays as the single-node `a0` build. `os.yml` applies the OS roles to all three
VMs and kubectl to the controller only. It does **not** include the `k0s` role.

```bash
cat > ~/Projects/hardened-k8s/ansible/os.yml << 'EOF'
---
# OS baseline for the multi-node cluster. k0s is installed afterwards by
# k0sctl (k0sctl/k0sctl.yaml), so the k0s and verify roles are not used here.
- name: OS baseline for controller and workers
  hosts: multinode
  roles:
    - role: base
      tags: [base]
    - role: chrony
      tags: [chrony]
    - role: k8s_prereqs
      tags: [prereqs]
    - role: toolkit
      tags: [toolkit]
    - role: ssh_hardening
      tags: [ssh, hardening]

- name: Kubectl and shell ergonomics on the controller
  hosts: controllers
  roles:
    - role: kubectl
      tags: [kubectl]
    - role: kubectl_ergonomics
      tags: [kubectl, ergonomics]
EOF
```

---

### Step 10: Syntax check and lint

```bash
cd ~/Projects/hardened-k8s/ansible && ansible-playbook os.yml --syntax-check && ansible-playbook site.yml --syntax-check && ansible-lint
```

**Expected:**

> `playbook: os.yml`
> `playbook: site.yml`
> `Passed: 0 failure(s), 0 warning(s) ...` with `profile 'production'`

**Troubleshooting:**
- `couldn't resolve module/action 'community.general.lvol'`: the collections are missing
  from `./collections`. Run `ansible-galaxy collection install -r requirements.yml -p ./collections`.

---

### Step 11: Apply the changed OS roles to `a0`

Dry run first, then apply. `-K` prompts once for your sudo password. The tags limit the
run to OS roles, so the k0s install on `a0` is not touched.

```bash
cd ~/Projects/hardened-k8s/ansible && ansible-playbook site.yml -K --check --diff --tags base,chrony,prereqs,toolkit,ssh
```

**Expected:** the diff shows new lines in `/etc/sysctl.d/99-k8s.conf`, the new apt
packages, and the crictl config file. The recap shows `failed=0`. `Install crictl` is
skipped in check mode because nothing was downloaded yet.

```bash
cd ~/Projects/hardened-k8s/ansible && ansible-playbook site.yml -K --tags base,chrony,prereqs,toolkit,ssh
```

This can take ~60–90 s because of the apt upgrade.

**Expected recap:**

> `a0 : ok=NN changed=N unreachable=0 failed=0 skipped=2 ...`

The two skipped tasks are the passwordless-sudo drop-in (off for `a0`) and `Disable swap`
(swap is already off).

**Verify idempotence (second run must report `changed=0`):**

```bash
cd ~/Projects/hardened-k8s/ansible && ansible-playbook site.yml -K --tags base,chrony,prereqs,toolkit,ssh | tail -3
```

**Expected:**

> `a0 : ok=NN changed=0 unreachable=0 failed=0 skipped=2 ...`

**Verify on the node:**

```bash
ssh jason@192.168.64.4 'sysctl fs.inotify.max_user_watches net.bridge.bridge-nf-call-ip6tables; crictl --version; sudo crictl ps --name coredns -q | wc -l'
```

**Expected:**

> `fs.inotify.max_user_watches = 524288`
> `net.bridge.bridge-nf-call-ip6tables = 1`
> `crictl version v1.36.0`
> `1` (the running CoreDNS container, found through the k0s socket)

**Troubleshooting:**
- `crictl ps` returns `connect: no such file or directory`: check the socket with
  `ssh jason@192.168.64.4 'sudo ls -l /run/k0s/containerd.sock'`. If it is missing,
  k0s is not running: `ssh jason@192.168.64.4 'sudo k0s status; sudo journalctl -u k0scontroller -n 30'`.
- Ansible hangs at `BECOME password:` or times out: confirm `ansible_become_exe` landed in
  `all.yml` with `ansible-inventory --host a0 | jq .ansible_become_exe`. Expected `"/usr/bin/sudo.ws"`.
- `apt` fails on repository signature validity: the VM clock drifted after the Mac slept.
  `ssh jason@192.168.64.4 'sudo chronyc makestep'` and re-run.

---

### Step 12: Update the Ansible README role table and commit

```bash
cd ~/Projects/hardened-k8s && cat > /tmp/os-yml-readme.md << 'EOF'

## Multi-node cluster (Labs 2+)
`os.yml` applies the OS roles (`base`, `chrony`, `k8s_prereqs`, `toolkit`,
`ssh_hardening`) to the `multinode` group, and `kubectl` + `kubectl_ergonomics` to the
controller. k0s is installed afterwards by k0sctl from `k0sctl/k0sctl.yaml`; the `k0s`
role is the single-node path for `a0` only.

    cd ansible
    ansible-playbook os.yml -K        # first run, before passwordless sudo exists
    ansible-playbook os.yml           # later runs
EOF
cat /tmp/os-yml-readme.md >> ansible/README.md && rm /tmp/os-yml-readme.md
git add ansible && git status --short
```

**Expected:**

```text
M  ansible/README.md
A  ansible/group_vars/all.yml
M  ansible/group_vars/lab.yml
A  ansible/group_vars/multinode.yml
M  ansible/inventory/hosts.yml
A  ansible/os.yml
A  ansible/roles/base/defaults/main.yml
M  ansible/roles/base/tasks/main.yml
A  ansible/roles/k8s_prereqs/defaults/main.yml
M  ansible/roles/k8s_prereqs/tasks/main.yml
A  ansible/roles/toolkit/defaults/main.yml
M  ansible/roles/toolkit/tasks/main.yml
```

```bash
cd ~/Projects/hardened-k8s && git commit -m "ansible: shared group_vars, multinode inventory, os.yml, crictl, opt-in passwordless sudo"
```

---

## Rollback / Clean-up

**Before committing:** discard every Lab 1 change in the repo.

```bash
cd ~/Projects/hardened-k8s && git restore --staged ansible && git checkout -- ansible && git clean -fd ansible
```

**After committing:** revert the commit.

```bash
cd ~/Projects/hardened-k8s && git revert --no-edit HEAD
```

**On `a0`:** reverting the repo does not undo what was applied. Remove the additions:

```bash
ssh jason@192.168.64.4 'sudo rm -f /usr/local/bin/crictl /etc/crictl.yaml /var/tmp/crictl-v1.36.0.tar.gz && sudo sed -i "/bridge-nf-call-ip6tables/d;/fs.inotify/d" /etc/sysctl.d/99-k8s.conf && sudo sysctl --system >/dev/null && echo cleaned'
```

**Expected:** `cleaned`. The extra apt packages are harmless and can stay; remove them
with `sudo apt-get remove conntrack dnsutils ipset` if you want a byte-for-byte revert.

**On the Mac:** remove the bash and vim blocks if you want them gone.

```bash
sed -i '' '/>>> hardened-k8s kubectl ergonomics >>>/,/<<< hardened-k8s kubectl ergonomics <<</d' ~/.bashrc && sed -i '' '/hardened-k8s: YAML-friendly indentation/,/set expandtab tabstop=2 shiftwidth=2 number/d' ~/.vimrc
```

Note the `-i ''`: macOS `sed` requires an explicit (empty) backup suffix, unlike GNU `sed`.

**Next:** Lab 2 builds the three VMs and runs `os.yml` against them.
