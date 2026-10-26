# Lab 2: Build the 1 controller + 2 worker k0s cluster on UTM

**Goal:** three Ubuntu 26.04.1 ARM64 VMs on UTM with static IPs, the Lab 1 OS baseline
applied by Ansible, and k0s v1.35.8+k0s.1 installed by `k0sctl` from the Mac.

**CKA relevance:** node roles, control-plane components, and kubeconfig handling are on
the curriculum (Cluster Architecture, 25%). The exam builds clusters with **kubeadm**;
k0sctl is the Mirantis-facing equivalent. The differences are called out as you go.

## Pinned versions and addresses

| Item | Value | Why |
|---|---|---|
| ISO | `ubuntu-26.04.1-live-server-arm64.iso` | Same OS as `a0`; the Ansible roles already handle its sudo-rs quirk |
| ISO URL | `https://cdimage.ubuntu.com/releases/26.04.1/release/ubuntu-26.04.1-live-server-arm64.iso` | |
| k0s (install) | `v1.35.8+k0s.1` | k0s v1.37 is not released yet, so the one-minor upgrade in Lab 3 is 1.35 → 1.36 |
| k0s (Lab 3 target) | `v1.36.4+k0s.1` | Current latest; matches `a0` |
| k0sctl | latest from Homebrew (v0.33.1 at time of writing) | |
| crictl | `v1.36.0` | Lab 1 toolkit role |
| Network | UTM **Shared Network**, `192.168.64.0/24`, gateway and DNS `192.168.64.1` | |
| controller | `192.168.64.10`, 2 vCPU / 4 GB / 30 GB | |
| worker-01 | `192.168.64.11`, 2 vCPU / 4 GB / 30 GB | |
| worker-02 | `192.168.64.12`, 2 vCPU / 4 GB / 30 GB | |

**Why not `10.0.0.0/24`:** in Shared Network mode, macOS's `vmnet` owns the subnet
(`192.168.64.0/24` by default), runs DHCP and NAT, and only routes that range. A guest
configured for `10.0.0.10` gets no gateway. Changing the vmnet subnet is a system-wide
macOS setting that would also renumber `a0`, so this lab stays on `192.168.64.0/24`.

**Why `.10`–`.12`:** vmnet hands out DHCP leases upward from `.2`; `a0` holds `.4`.
Static addresses at `.10`–`.12` sit inside the DHCP pool but well above what a handful of
VMs consume. If you later run more than five DHCP VMs at once, move these to `.200`+.

**Why 30 GB disks instead of 20:** UTM disk images are sparse, so the larger size costs
nothing until used, and Lab 8's NVIDIA images are several GB per worker.

## RAM budget (Mac Mini M4, 32 GB)

| Item | `a0` stopped | `a0` running |
|---|---|---|
| controller | 4 GB | 4 GB |
| worker-01 | 4 GB | 4 GB |
| worker-02 | 4 GB | 4 GB |
| `a0` | 0 GB | 10 GB |
| macOS + UTM/QEMU overhead (estimate) | ~5 GB | ~5 GB |
| **Total** | **~17 GB** | **~27 GB** |
| Headroom | ~15 GB | ~5 GB |

Stop `a0` while the multi-node cluster runs. 5 GB of headroom leaves macOS swapping as
soon as a browser and an IDE are open.

---

## Pre-check

Confirms the Lab 1 playbook and inventory are in place.

```bash
cd ~/Projects/hardened-k8s/ansible && ansible-playbook os.yml --syntax-check && ansible-inventory --graph multinode && k0sctl version
```

**Expected:** `playbook: os.yml`, the `multinode` tree with `controller`, `worker-01`,
`worker-02`, and a `version:` line from k0sctl.

---

### Step 1: Download and verify the ISO

```bash
mkdir -p ~/Downloads/iso && cd ~/Downloads/iso && curl -fLO https://cdimage.ubuntu.com/releases/26.04.1/release/ubuntu-26.04.1-live-server-arm64.iso && curl -fLO https://cdimage.ubuntu.com/releases/26.04.1/release/SHA256SUMS && shasum -a 256 -c SHA256SUMS --ignore-missing
```

About 2.9 GB; this can take a few minutes.

**Verify — expected:**

> `ubuntu-26.04.1-live-server-arm64.iso: OK`

If you already have this ISO from building `a0`, point UTM at that copy and skip the
download. Use the plain `arm64` image, not `arm64+largemem` (that one is for 64K page
kernels on large servers).

---

### Step 2: Stop `a0`

```bash
utmctl list && utmctl stop Linux && sleep 10 && utmctl status Linux
```

`Linux` is `a0`'s name in UTM (`docs/host.md`). Use the name from `utmctl list` if yours
differs.

**Expected:** `stopped`

---

### Step 3: Create the `controller` VM in the UTM GUI

`utmctl` can start, stop, and query VMs but cannot create them, so creation is a one-time
GUI task. Labels can shift slightly between UTM releases; the flow is the same.

1. Open UTM (`open -a UTM`).
2. Click **+** (Create a New Virtual Machine).
3. Click **Virtualize**.
4. Click **Linux**.
5. Leave **Use Apple Virtualization** unchecked. This keeps the QEMU backend, the same as
   `a0`, which Lab 6 relies on for a hard power-off.
6. Under **Boot ISO Image**, click **Browse…** and select
   `~/Downloads/iso/ubuntu-26.04.1-live-server-arm64.iso`. Click **Continue**.
7. **Memory:** `4096` MiB. **CPU Cores:** `2`. Click **Continue**.
8. **Storage:** `30` GiB. Click **Continue**.
9. **Shared Directory:** leave empty. Click **Continue**.
10. **Summary:** set **Name** to `controller`. Click **Save**.
11. Select `controller` in the sidebar, click the **settings** (sliders) icon, open
    **Network**, and confirm **Network Mode** is **Shared Network**. Click **Save**.

**Verify:**

```bash
utmctl list
```

**Expected:** a row for `controller` with status `stopped`.

---

### Step 4: Install Ubuntu on `controller`, with a static IP

```bash
utmctl start controller
```

The console window opens. In the Ubuntu installer:

1. Choose **Try or Install Ubuntu Server** at the boot menu.
2. **Language:** English. If offered an installer update, choose **Continue without updating**.
3. **Keyboard:** your layout. **Done**.
4. **Type of installation:** **Ubuntu Server** (not minimized). **Done**.
5. **Network:** select the interface (`enp0s1`) → **Edit IPv4** → **IPv4 Method:
   Manual**, then enter:
   - Subnet: `192.168.64.0/24`
   - Address: `192.168.64.10`
   - Gateway: `192.168.64.1`
   - Name servers: `192.168.64.1`
   - Search domains: leave empty

   **Save**, then **Done**.
6. **Proxy:** leave empty. **Mirror:** accept the default once the mirror test passes.
7. **Storage:** **Use an entire disk**, **Set up this disk as an LVM group** (default).
   **Done**, then **Continue** at the destructive-action prompt. The installer gives `/`
   only half the volume group; the `base` role grows it later.
8. **Profile:** Your name `Jason`, server name `controller`, username `jason`, and a
   password you will type once more in Step 8.
9. **Ubuntu Pro:** **Skip for now**.
10. **SSH:** check **Install OpenSSH server**. Do not import keys. **Done**.
11. **Featured server snaps:** select none. **Done**.
12. Wait for **Installation complete!** (about 5–8 min), then choose **Reboot Now**.
13. When the console says to remove the installation medium: in the UTM window toolbar,
    click the **CD/DVD** icon and choose **Clear** (or VM settings → the CD/DVD drive →
    **Clear**), then press **Enter** in the console.

If the installer's network screen was skipped or the IP is wrong, fix it after first boot
by logging in at the console and writing the netplan file directly:

```bash
sudo tee /etc/netplan/50-cloud-init.yaml > /dev/null << 'EOF'
network:
  version: 2
  ethernets:
    enp0s1:
      dhcp4: false
      addresses: [192.168.64.10/24]
      routes:
        - to: default
          via: 192.168.64.1
      nameservers:
        addresses: [192.168.64.1]
EOF
sudo chmod 600 /etc/netplan/50-cloud-init.yaml && sudo netplan apply
```

Change `192.168.64.10` to `.11` or `.12` when you run it on a worker.

**Verify (from the Mac):**

```bash
ping -c 2 192.168.64.10 && ssh -o StrictHostKeyChecking=accept-new jason@192.168.64.10 'hostname; ip -4 -br addr show enp0s1; uname -m'
```

**Expected:**

> `2 packets transmitted, 2 packets received`
> `controller`
> `enp0s1  UP  192.168.64.10/24`
> `aarch64`

**Troubleshooting:**
- `No route to host` from Terminal, while the VM console shows the right IP: macOS
  **Local Network** privacy is blocking your terminal app. System Settings → Privacy &
  Security → Local Network → enable Terminal (or iTerm/Ghostty).
- `REMOTE HOST IDENTIFICATION HAS CHANGED`: you rebuilt a VM on a reused IP. Remove the
  old key with `ssh-keygen -R 192.168.64.10`.

---

### Step 5: Create and install `worker-01` and `worker-02`

Repeat Steps 3 and 4 twice with these values. Everything else is identical.

| UTM name | Installer server name | Static address |
|---|---|---|
| `worker-01` | `worker-01` | `192.168.64.11` |
| `worker-02` | `worker-02` | `192.168.64.12` |

Do not use **Clone** in UTM to make the workers: a clone copies the machine-id, SSH host
keys, and static IP, which breaks Kubernetes node identity and SSH.

**Verify:**

```bash
for ip in 10 11 12; do ssh -o StrictHostKeyChecking=accept-new jason@192.168.64.$ip 'echo "$(hostname) $(hostname -I)"'; done
```

**Expected:**

> `controller 192.168.64.10`
> `worker-01 192.168.64.11`
> `worker-02 192.168.64.12`

---

### Step 6: SSH keys and host aliases on the Mac

`ssh-copy-id` is the only step that uses the VM password. After Step 8 password login is
turned off.

```bash
for ip in 10 11 12; do ssh-copy-id -i ~/.ssh/id_ed25519.pub jason@192.168.64.$ip; done
```

```bash
grep -q 'Host controller' ~/.ssh/config 2>/dev/null || cat >> ~/.ssh/config << 'EOF'

# hardened-k8s multi-node lab
Host controller
    HostName 192.168.64.10
Host worker-01
    HostName 192.168.64.11
Host worker-02
    HostName 192.168.64.12
Host controller worker-01 worker-02
    User jason
    IdentityFile ~/.ssh/id_ed25519
EOF
chmod 600 ~/.ssh/config
```

**Verify:**

```bash
for h in controller worker-01 worker-02; do ssh -o BatchMode=yes "$h" hostname; done
```

**Expected:** `controller`, `worker-01`, `worker-02`, with no password prompt.

---

### Step 7: Save a golden copy of the clean OS disks

UTM keeps each VM as a `.utm` bundle. With the VMs stopped, an APFS clone (`cp -c`)
copies them instantly and uses no extra space until the originals change. This is your
re-entry point for every later lab.

```bash
for v in controller worker-01 worker-02; do utmctl stop "$v"; done; sleep 15; for v in controller worker-01 worker-02; do utmctl status "$v"; done
```

**Expected:** `stopped` three times.

```bash
UTM_DOCS=~/Library/Containers/com.utmapp.UTM/Data/Documents && mkdir -p ~/utm-golden/os-clean && for v in controller worker-01 worker-02; do cp -c -R "$UTM_DOCS/$v.utm" ~/utm-golden/os-clean/; done && ls ~/utm-golden/os-clean
```

**Expected:** `controller.utm  worker-01.utm  worker-02.utm`

```bash
for v in controller worker-01 worker-02; do utmctl start "$v"; done; sleep 45; for h in controller worker-01 worker-02; do ssh -o BatchMode=yes "$h" hostname; done
```

**Troubleshooting:** `No such file or directory` for the `.utm` path means UTM stores
VMs elsewhere on your Mac. In UTM, right-click a VM → **Show in Finder** and use that
folder as `UTM_DOCS`.

---

### Step 8: Apply the OS baseline with Ansible

The first run needs `-K` (sudo password) because passwordless sudo does not exist yet.
`base` creates it, so the second run proves both idempotence and the k0sctl
prerequisite.

```bash
cd ~/Projects/hardened-k8s/ansible && ansible multinode -m ping -e ansible_become=false && ansible-playbook os.yml -K
```

This takes ~3–5 min: the first apt upgrade on a fresh install is the slow part.

**Expected recap (counts vary; the zeros matter):**

```text
controller : ok=NN changed=NN unreachable=0 failed=0 ...
worker-01  : ok=NN changed=NN unreachable=0 failed=0 ...
worker-02  : ok=NN changed=NN unreachable=0 failed=0 ...
```

**Verify idempotence and passwordless sudo (no `-K`):**

```bash
cd ~/Projects/hardened-k8s/ansible && ansible-playbook os.yml | tail -5
```

**Expected:** `changed=0 unreachable=0 failed=0` for all three hosts.

```bash
for h in controller worker-01 worker-02; do ssh "$h" 'sudo -n true && echo "$(hostname): nopasswd ok, swap=$(swapon --show | wc -l), root=$(df -h / | awk "NR==2{print \$2}")"'; done
```

**Expected:**

> `controller: nopasswd ok, swap=0, root=26G` (the same for both workers; about 26G once
> `base` has grown the LV, versus about 13G straight out of the installer)

**Troubleshooting:**
- `visudo: not found` during the sudoers task: on your build `visudo` lives under another
  name. Run `ssh controller 'ls /usr/sbin/visudo* /usr/bin/visudo*'` and change
  `validate:` in `roles/base/tasks/main.yml` to that path.
- Ansible stalls at `Gathering Facts` with no prompt: the sudo-rs prompt problem. Confirm
  `ansible-inventory --host controller | jq .ansible_become_exe` prints `"/usr/bin/sudo.ws"`.
- `Permission denied (publickey)` after the first run: Step 6 was skipped, so the key
  never reached that VM and `ssh_hardening` then turned password login off. At the UTM
  console, set `PasswordAuthentication yes` in `/etc/ssh/sshd_config.d/10-hardening.conf`,
  run `sudo systemctl restart ssh`, run the Step 6 `ssh-copy-id` from the Mac, then re-run
  this step (the playbook sets it back to `no`).

---

### Step 9: Write `k0sctl.yaml`

`k0sctl` runs on the **Mac** and drives all three VMs over SSH. It does not run on the
controller.

```bash
mkdir -p ~/Projects/hardened-k8s/k0sctl && cat > ~/Projects/hardened-k8s/k0sctl/k0sctl.yaml << 'EOF'
apiVersion: k0sctl.k0sproject.io/v1beta1
kind: Cluster
metadata:
  name: hardened-k8s
spec:
  hosts:
    - role: controller
      ssh:
        address: 192.168.64.10
        user: jason
        port: 22
        keyPath: ~/.ssh/id_ed25519
    - role: worker
      ssh:
        address: 192.168.64.11
        user: jason
        port: 22
        keyPath: ~/.ssh/id_ed25519
    - role: worker
      ssh:
        address: 192.168.64.12
        user: jason
        port: 22
        keyPath: ~/.ssh/id_ed25519
  k0s:
    version: v1.35.8+k0s.1
    config:
      apiVersion: k0s.k0sproject.io/v1beta1
      kind: ClusterConfig
      metadata:
        name: hardened-k8s
      spec:
        network:
          provider: kuberouter
          podCIDR: 10.244.0.0/16
          serviceCIDR: 10.96.0.0/12
EOF
```

Notes on the file:
- `role: controller` (not `controller+worker`) mirrors a production control plane: the
  controller runs the API server, etcd, scheduler, and controller-manager as **host
  processes**, not pods, and runs **no workloads**.
- With one dedicated controller, k0s uses **etcd**. `a0` (`--single`) uses kine/SQLite.
  That difference matters for Lab 3 backups.
- No secrets are in this file (`keyPath` is a path), so it is safe to commit.

---

### Step 10: Install k0s with `k0sctl apply`

```bash
cd ~/Projects/hardened-k8s/k0sctl && k0sctl apply --config k0sctl.yaml
```

This can take ~3–5 min, don't panic. k0sctl downloads the ~240 MB k0s binary on each
host, installs the controller, waits for it, then joins the workers. Watch progress from
a second terminal:

```bash
ssh controller 'sudo journalctl -u k0scontroller -f'
```

**Expected:** the run ends with lines similar to:

> `==> Finished in 3m12s`
> `k0s cluster version v1.35.8+k0s.1 is now installed`

**Troubleshooting:**
- `sudo: a password is required` or a sudo-related connection error: passwordless sudo is
  missing. Re-run Step 8 and check the `nopasswd ok` output. If sudo works by hand but
  k0sctl still fails, the k0sctl v0.32 release notes recommend trying v0.31.1, which uses
  the older connection layer.
- A worker hangs at `Waiting for node to become ready`:
  `ssh worker-01 'sudo journalctl -u k0sworker -n 50 --no-pager'`. Look for
  `x509: certificate has expired or is not yet valid`, which means clock drift:
  `ssh worker-01 'sudo chronyc makestep'` and re-run `k0sctl apply`.
- k0sctl's own log is at `~/Library/Caches/k0sctl/k0sctl.log` on the Mac.

---

### Step 11: Get the admin kubeconfig onto the Mac

Writes a separate file so the existing `a0` context in `~/.kube/config` is untouched. The
repo's `.gitignore` already blocks `*.kubeconfig`, but the file lives outside the repo
regardless.

```bash
cd ~/Projects/hardened-k8s/k0sctl && k0sctl kubeconfig --config k0sctl.yaml > ~/.kube/hardened-k8s.kubeconfig && chmod 600 ~/.kube/hardened-k8s.kubeconfig && export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig
```

Every new terminal for Labs 2–8 needs:

```bash
export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig
```

**Verify:**

```bash
k version && k get nodes -o wide
```

**Expected:**

```text
Client Version: v1.37.1
Kustomize Version: v5.x.y
Server Version: v1.35.8+k0s
WARNING: version difference between client (1.37) and server (1.35) exceeds the supported minor version skew of +/-1
NAME        STATUS   ROLES    AGE   VERSION        INTERNAL-IP     ...   OS-IMAGE                       KERNEL-VERSION     CONTAINER-RUNTIME
worker-01   Ready    <none>   2m    v1.35.8+k0s    192.168.64.11   ...   Ubuntu 26.04.1 LTS             7.0.0-xx-generic   containerd://2.x.y
worker-02   Ready    <none>   2m    v1.35.8+k0s    192.168.64.12   ...   Ubuntu 26.04.1 LTS             7.0.0-xx-generic   containerd://2.x.y
```

**Two nodes, not three, is correct.** A k0s `controller` without the worker role runs no
kubelet, so it never registers as a Node. This is the biggest visible difference from
kubeadm, where control-plane nodes appear in `kubectl get nodes` with the
`control-plane` role and a `NoSchedule` taint.

**The skew warning is expected** during Labs 2–3: Homebrew's kubectl is v1.37.1 and the
server is v1.35. The commands in these labs work, but it is outside the supported policy.
It clears after the Lab 3 upgrade to v1.36. On the controller, Ansible installed kubectl
v1.36.4, which is within skew of both versions.

---

### Step 12: Check the system pods

```bash
k get pods -A -o wide
```

**Expected (names and counts; suffixes differ):**

```text
NAMESPACE     NAME                              READY   STATUS    NODE
kube-system   coredns-xxxxxxxxxx-xxxxx          1/1     Running   worker-01
kube-system   coredns-xxxxxxxxxx-xxxxx          1/1     Running   worker-02
kube-system   konnectivity-agent-xxxxx          1/1     Running   worker-01
kube-system   konnectivity-agent-xxxxx          1/1     Running   worker-02
kube-system   kube-proxy-xxxxx                  1/1     Running   worker-01
kube-system   kube-proxy-xxxxx                  1/1     Running   worker-02
kube-system   kube-router-xxxxx                 1/1     Running   worker-01
kube-system   kube-router-xxxxx                 1/1     Running   worker-02
kube-system   metrics-server-xxxxxxxxxx-xxxxx   1/1     Running   worker-0x
```

What each one is:
- **coredns**: a Deployment (not a StatefulSet); Lab 5 breaks it.
- **konnectivity-agent**: k0s-specific. The controller has no pod network, so the API
  server reaches kubelets (for `logs`, `exec`, `port-forward`) through this reverse
  tunnel. kubeadm clusters do not have it.
- **kube-router**: the CNI and the NetworkPolicy enforcer for Lab 4.
- **etcd, kube-apiserver, scheduler, controller-manager**: not listed. On k0s they are
  processes on the controller host. On kubeadm they are static pods in `kube-system`.
  See them with:

```bash
ssh controller 'sudo k0s status; ps -eo comm | grep -E "^(etcd|kube-apiserver|kube-scheduler|kube-controller)" | sort -u'
```

**Expected:**

> `Version: v1.35.8+k0s.1` … `Role: controller` … `Workloads: false`
> `etcd`, `kube-apiserver`, `kube-controller`, `kube-scheduler`

`ps` truncates `kube-controller-manager` to 15 characters, hence `kube-controller`.

---

### Step 13: kubeconfig on the controller and `crictl` on a worker

```bash
ssh controller 'mkdir -p ~/.kube && sudo k0s kubeconfig admin > ~/.kube/config && chmod 600 ~/.kube/config && kubectl get nodes'
ssh worker-01 'sudo crictl ps --name kube-router'
```

**Expected:** the same two `Ready` nodes, then one running `kube-router` container.

Running `crictl` on the controller returns a socket error. That is correct: the
controller runs no containerd.

---

### Step 14: Smoke test across both workers

```bash
k create deployment hello --image=nginx:stable-alpine --replicas=2 && k rollout status deployment/hello --timeout=120s && k get pods -l app=hello -o wide
```

**Expected:**

> `deployment "hello" successfully rolled out`
> two `hello-...` pods `Running`, one on `worker-01` and one on `worker-02`, with pod IPs
> in `10.244.x.y` (each worker gets its own `/24` from `10.244.0.0/16`)

```bash
k expose deployment hello --port=80 && k run curl --image=curlimages/curl --rm -i --restart=Never -- curl -s -o /dev/null -w '%{http_code}\n' http://hello.default.svc.cluster.local
```

**Expected:** `200`, then `pod "curl" deleted`. That one request exercised the CNI,
kube-proxy, and CoreDNS.

```bash
k delete service,deployment hello
```

---

### Step 15: Commit the k0sctl config and save a second golden copy

```bash
cat > ~/Projects/hardened-k8s/k0sctl/README.md << 'EOF'
# k0sctl: multi-node lab cluster

1 controller (`192.168.64.10`, etcd) + 2 workers (`.11`, `.12`) on UTM Shared Network.
OS baseline first (`ansible/os.yml`), then from this directory on the Mac:

    k0sctl apply --config k0sctl.yaml
    k0sctl kubeconfig --config k0sctl.yaml > ~/.kube/hardened-k8s.kubeconfig

Upgrades: change `spec.k0s.version` and re-run `k0sctl apply` (one minor at a time).
Full procedure: docs/runbook/lab02-k0s-multinode.md and lab03-upgrade-backup-restore.md.
EOF
cd ~/Projects/hardened-k8s && git add k0sctl && git commit -m "k0sctl: 1 controller + 2 worker cluster, k0s v1.35.8+k0s.1"
```

```bash
for v in controller worker-01 worker-02; do utmctl stop "$v"; done; sleep 15; UTM_DOCS=~/Library/Containers/com.utmapp.UTM/Data/Documents && mkdir -p ~/utm-golden/k0s-1.35 && for v in controller worker-01 worker-02; do cp -c -R "$UTM_DOCS/$v.utm" ~/utm-golden/k0s-1.35/; done && for v in controller worker-01 worker-02; do utmctl start "$v"; done
```

Start the controller first if you start them by hand: workers retry until the API is
back, but the controller-first order gets you to `Ready` faster.

**Verify (after ~60 s):**

```bash
export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig && k get nodes
```

**Expected:** `worker-01` and `worker-02` `Ready`.

---

## kubeadm vs k0s, for the exam

| Task | kubeadm (CKA exam) | k0s (this lab) |
|---|---|---|
| Install control plane | `kubeadm init` | `k0sctl apply` (or `k0s install controller`) |
| Join a worker | `kubeadm join ... --token ... --discovery-token-ca-cert-hash ...` | k0sctl creates and uses join tokens for you |
| Control-plane components | Static pods, manifests in `/etc/kubernetes/manifests/` | Host processes managed by `k0scontroller.service` |
| Control-plane node in `kubectl get nodes` | Yes, `control-plane` role | No, unless the role is `controller+worker` |
| Admin kubeconfig | `/etc/kubernetes/admin.conf` | `k0s kubeconfig admin` / `k0sctl kubeconfig` |
| containerd socket | `/run/containerd/containerd.sock` | `/run/k0s/containerd.sock` |
| PKI | `/etc/kubernetes/pki/` | `/var/lib/k0s/pki/` |

---

## Rollback / Clean-up

**Remove k0s but keep the OS baseline** (returns to the state after Step 8):

```bash
cd ~/Projects/hardened-k8s/k0sctl && k0sctl reset --config k0sctl.yaml --force
```

If your k0sctl version rejects `--force`, run it without the flag and answer `y`.
This takes ~1–2 min and reboots nothing. Afterwards re-run Step 10.

**Return to the clean OS disks** (state after Step 7):

```bash
for v in controller worker-01 worker-02; do utmctl stop "$v"; done; sleep 15; osascript -e 'quit app "UTM"'; sleep 5; UTM_DOCS=~/Library/Containers/com.utmapp.UTM/Data/Documents && for v in controller worker-01 worker-02; do rm -rf "$UTM_DOCS/$v.utm" && cp -c -R ~/utm-golden/os-clean/$v.utm "$UTM_DOCS/"; done && open -a UTM
```

UTM is quit before the swap so it does not hold the old bundles open. To return to the
k0s v1.35 state after Step 15 instead, use `~/utm-golden/k0s-1.35/` in place of
`~/utm-golden/os-clean/`. The swapped-in copies have
the same host keys, so SSH does not complain.

**Remove the VMs entirely:** in UTM, right-click each VM → **Delete**. Then remove the
`~/.ssh/config` block, `ssh-keygen -R` the three IPs, and
`rm ~/.kube/hardened-k8s.kubeconfig`.

**Next:** Lab 3 backs up, restores, and upgrades this cluster.
