# Lab 3: Back up, prove the restore, then upgrade one minor version

**Goal:** take a k0s backup, prove it is valid with a full disaster-recovery restore, then
upgrade the cluster from v1.35.8+k0s.1 to v1.36.4+k0s.1 with a fresh backup in hand.

**CKA relevance:** etcd backup/restore and cluster upgrades are on the curriculum
(Cluster Architecture, 25%) and are near-certain exam tasks. The exam uses
`etcdctl`/`etcdutl` and `kubeadm upgrade`; the kubeadm commands are at the end of this
lab. `k0sctl backup` and `--restore-from` are extra depth for Mirantis.

**Order matters.** The restore drill runs **before** the upgrade, because a backup can
only be restored onto the same k0s version that took it. Draft corrections applied here:
- k0s has no `k0s upgrade --to` command. A k0sctl-managed cluster is upgraded by
  changing `spec.k0s.version` and re-running `k0sctl apply`.
- `k0s backup` has no passphrase. Encryption is done by piping through `gpg` or `age`.
- `k0s restore` restores onto a controller (and fails if the data directory already
  holds overlapping data). It cannot restore into a scratch directory for diffing, so
  Step 5 validates the archive by extracting it and comparing it with the live PKI.

This lab doubles as the evidence run for **incident #3 (etcd backup and restore after a
bad change)**. Keep the terminal output.

---

## Pre-check

If the VMs are stopped (`utmctl list`), start them controller first and wait ~60 s:

```bash
utmctl start controller && sleep 20 && utmctl start worker-01 && utmctl start worker-02
```

```bash
export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig && k get nodes && grep 'version:' ~/Projects/hardened-k8s/k0sctl/k0sctl.yaml && cd ~/Projects/hardened-k8s && git status --short && git log --oneline -1
```

**Expected:**

```text
NAME        STATUS   ROLES    AGE   VERSION
worker-01   Ready    <none>   4d    v1.35.8+k0s
worker-02   Ready    <none>   4d    v1.35.8+k0s
    version: v1.35.8+k0s.1
<commit> (HEAD -> main, origin/main) ...
```

`git status --short` prints nothing. `k get nodes` may also print the client/server skew
warning from Lab 2.

If the node `AGE` looks wrong, check the source value and the clocks before going on;
backups and certificates depend on correct time:

```bash
k get nodes -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp && date -u && for h in controller worker-01 worker-02; do echo "$h: $(ssh $h 'date -u; chronyc tracking | grep "System time"')"; done
```

**Expected:** `CREATED` matches when you ran Lab 2, and every VM is within a second of
the Mac and within milliseconds of NTP.

---

### Step 1: Record versions before the change

```bash
for h in controller worker-01 worker-02; do printf '%-10s ' "$h"; ssh "$h" 'sudo k0s version'; done && k get nodes -o custom-columns=NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion
```

**Expected:**

```text
controller v1.35.8+k0s.1
worker-01  v1.35.8+k0s.1
worker-02  v1.35.8+k0s.1
NAME        KUBELET       RUNTIME
worker-01   v1.35.8+k0s   containerd://1.7.35
worker-02   v1.35.8+k0s   containerd://1.7.35
```

The runtime column is the "before" value for the containerd 1.7 → 2.x jump in Step 11.

---

### Step 2: Keep backup archives out of git

A k0s backup contains the cluster **CA private keys** and the etcd snapshot, which holds
every Secret. Treat it like a root credential.

```bash
cd ~/Projects/hardened-k8s && grep -q 'k0sctl/backups/' .gitignore || cat >> .gitignore << 'EOF'

# k0s backups contain CA private keys and every Secret (etcd snapshot)
k0sctl/backups/
k0s_backup_*.tar.gz
k0s_backup_*.tar.gz.gpg
EOF
mkdir -p ~/Projects/hardened-k8s/k0sctl/backups && chmod 700 ~/Projects/hardened-k8s/k0sctl/backups
```

**Verify:**

```bash
cd ~/Projects/hardened-k8s && git check-ignore -v k0sctl/backups/k0s_backup_test.tar.gz && git status --short
```

**Expected:**

> `.gitignore:NN:k0sctl/backups/	k0sctl/backups/k0s_backup_test.tar.gz`
> ` M .gitignore`

`.gitignore` is committed with the upgrade in Step 11.

---

### Step 3: Create a canary workload

The canary is what you look for after the restore. A ConfigMap proves etcd data came
back; a Deployment proves workloads reschedule onto rebuilt workers.

```bash
k create namespace canary && k -n canary create configmap proof --from-literal=written=before-backup && k -n canary create deployment web --image=nginx:stable-alpine --replicas=2 && k -n canary rollout status deployment/web --timeout=120s
```

**Verify:**

```bash
k -n canary get configmap proof -o jsonpath='{.data.written}{"\n"}' && k -n canary get pods -o wide
```

**Expected:**

> `before-backup`
> two `web-...` pods `Running`, one per worker

Note the two pod names; Step 8 checks whether the same objects come back.

A `bash: child setpgid (...): Operation not permitted` line during the create is a
harmless bash job-control race on macOS; the `k` commands still succeed.

---

### Step 4: Take the backup with `k0sctl backup`

`k0sctl backup` runs `k0s backup` on the controller and downloads the archive into the
current directory.

```bash
cd ~/Projects/hardened-k8s/k0sctl/backups && k0sctl backup --config ../k0sctl.yaml && chmod 600 k0s_backup_*.tar.gz && command ls -lh
```

About 2 s on this cluster.

**Expected:** `==> Finished in 2s`, then one `-rw-------` file named
`k0s_backup_<unix-timestamp>.tar.gz`, about 400–500 KB for this nearly empty cluster.
`command ls` bypasses an `ls` alias such as `eza`.

**Known k0sctl v0.33.1 issue: leftover staging directory.** Every `k0sctl backup` and
`k0sctl apply --restore-from` in the first live run ended with a warning like:

> `WARN 192.168.64.10:22: failed to clean up backup temp directory /tmp/VC3obf: ... rm: cannot remove '/tmp/VC3obf': Is a directory`

k0sctl removes the archive but then calls `rm` without `-r` on its staging directory.
In all three runs the directory was **empty** and `drwx------` (owned by the SSH user),
and `/tmp` on Ubuntu 26.04 is RAM-backed `tmpfs`, so the risk is low. Check and remove it
after every backup or restore anyway:

```bash
ssh controller 'sudo find /tmp -maxdepth 1 -type d -empty -user jason -mmin -30 -print -delete'
```

**Expected:** the `/tmp/XXXXXX` path from the warning. It only matches empty
directories owned by `jason` from the last 30 minutes. If you want to see the contents
first, run `ssh controller 'sudo ls -la /tmp/XXXXXX'` with the name from the warning.

The equivalent by hand on the controller (useful when k0sctl is not available):

```bash
ssh controller 'sudo mkdir -p /var/lib/k0s-backups && sudo k0s backup --save-path /var/lib/k0s-backups && sudo ls -lh /var/lib/k0s-backups'
```

**Expected:** a `k0s_backup_<ISO timestamp>.tar.gz` in `/var/lib/k0s-backups`. This copy
stays on the controller and is only a demonstration; the drill below uses the one on the
Mac.

**Encrypting at rest (recommended outside the lab):**

```bash
cd ~/Projects/hardened-k8s/k0sctl/backups && BACKUP=$(command ls -t k0s_backup_*.tar.gz | head -1) && gpg --symmetric --cipher-algo AES256 -o "$BACKUP.gpg" "$BACKUP" && ls -lh "$BACKUP.gpg"
```

Skip this if `gpg` is not installed (`brew install gnupg`). Keep the unencrypted copy for
the drill below; `k0sctl apply --restore-from` reads a plain `.tar.gz`.

**Troubleshooting:** `k0sctl backup` fails with `etcd: context deadline exceeded`: the
controller is overloaded or its clock is off. Check
`ssh controller 'sudo k0s status; sudo journalctl -u k0scontroller -n 30 --no-pager'`.

---

### Step 5: Validate the archive without touching the cluster

Extract the archive to a scratch directory on the Mac and compare its PKI files with the
live controller's, hash by hash.

```bash
BACKUP=$(command ls -t ~/Projects/hardened-k8s/k0sctl/backups/k0s_backup_*.tar.gz | head -1) && echo "$BACKUP" && rm -rf ~/k0s-restore-test && mkdir -p ~/k0s-restore-test && chmod 700 ~/k0s-restore-test && tar -xzf "$BACKUP" -C ~/k0s-restore-test && find ~/k0s-restore-test -maxdepth 2 | sort
```

**Expected (k0s v1.35.8, abbreviated):**

```text
/Users/jason/k0s-restore-test/etcd-snapshot.db
/Users/jason/k0s-restore-test/k0s.yaml
/Users/jason/k0s-restore-test/manifests
/Users/jason/k0s-restore-test/manifests/coredns
/Users/jason/k0s-restore-test/manifests/kuberouter
...
/Users/jason/k0s-restore-test/pki
/Users/jason/k0s-restore-test/pki/admin.conf
/Users/jason/k0s-restore-test/pki/ca.key
/Users/jason/k0s-restore-test/pki/etcd
/Users/jason/k0s-restore-test/pki/sa.key
...
```

`chmod 700` matters: the extracted `ca.key` (the cluster root key), `sa.key` (signs
ServiceAccount tokens), and `admin.conf` (a ready admin kubeconfig) are now on the Mac in
the clear. `manifests/` also lists `calico` folders; k0s creates one per provider, and
only `kuberouter` is used.

```bash
PKI_DIR=$(find ~/k0s-restore-test -type d -name pki | head -1) && (cd "$PKI_DIR" && find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort -k2) > ~/k0s-restore-test/backup.sha && ssh controller 'cd /var/lib/k0s/pki && sudo find . -type f -exec sha256sum {} + | LC_ALL=C sort -k2' > ~/k0s-restore-test/live.sha && diff ~/k0s-restore-test/backup.sha ~/k0s-restore-test/live.sha && echo "PKI matches: $(wc -l < ~/k0s-restore-test/live.sha | tr -d ' ') files"
```

**Expected:**

> `PKI matches: 36 files` (k0s v1.35.8, 1 controller)

No `diff` lines means every certificate and key in the archive is byte-identical to the
live controller's. `LC_ALL=C` on both sides matters: macOS and Linux `sort` order
punctuation differently under a UTF-8 locale, which would produce a false mismatch.

```bash
find ~/k0s-restore-test -maxdepth 1 -type f -exec ls -lh {} + && grep -h 'name:' ~/k0s-restore-test/*.yaml | head -3
```

**Expected:** the config file (a few KB) and the etcd snapshot (about 1–2 MB uncompressed
here) listed, and
`name: hardened-k8s` from the Lab 2 `ClusterConfig`.

**Troubleshooting:**
- `diff` shows `Only in` style lines (one side has an extra hash line): a certificate was
  rotated or added after the backup. Take a fresh backup (Step 4) and repeat this step.
- `find` returns nothing for `pki`: the archive is incomplete. Check its listing with
  `tar -tzf "$BACKUP" | head -20` and re-run Step 4.

---

### Step 6: Simulate the bad change

Delete the canary namespace as the "bad change" the restore will undo.

```bash
k delete namespace canary --wait=true && k get namespace canary
```

**Expected:**

> `namespace "canary" deleted`
> `Error from server (NotFound): namespaces "canary" not found`

---

### Step 7: Disaster-recovery drill: reset the cluster and restore from backup

**This destroys the cluster on all three VMs.** It is the honest test: if the backup is
bad, you find out now, in a lab, with the Lab 2 golden copy as a safety net.

```bash
cd ~/Projects/hardened-k8s/k0sctl && k0sctl reset --config k0sctl.yaml --force
```

If your k0sctl version rejects `--force`, run it without the flag and answer `y`.

**Expected:** `Reset workers`, `Reset controllers`, `Reset leader`, then
`==> Finished in 3s`. Five `WARN` lines are normal and harmless:
- Workers: `failed to remove existing configuration /etc/k0s/k0s.yaml: file does not exist`.
  Workers never have that file.
- Controller, in `Reset leader`: `k0s: not found` plus two `file does not exist` lines. With
  one controller, k0sctl resets it as "controller" and again as "leader"; the second pass
  finds nothing left.

**Verify the reset:**

```bash
for h in controller worker-01 worker-02; do printf '%-10s ' "$h"; ssh "$h" 'test -d /var/lib/k0s && echo "k0s data still present" || echo "clean"'; done; k get nodes 2>&1 | head -1
```

**Expected:** `clean` for all three, then
`The connection to the server 192.168.64.10:6443 was refused`. The cluster is down.

```bash
cd ~/Projects/hardened-k8s/k0sctl && BACKUP=$(command ls -t backups/k0s_backup_*.tar.gz | head -1) && echo "Restoring from $BACKUP" && k0sctl apply --config k0sctl.yaml --restore-from "$BACKUP"
```

Check that the first line names the Step 4 backup. This took 55 s in the first live run;
allow up to ~6 min. k0sctl reinstalls k0s v1.35.8+k0s.1, restores the
PKI and etcd snapshot onto the controller before starting it, then rejoins both workers.
Watch from a second terminal:

```bash
ssh controller 'sudo journalctl -u k0scontroller -f'
```

**Expected:** a `Restore cluster state` phase (`restoring cluster state`) before
`Initialize the k0s cluster`, then `==> Finished in 55s` and
`k0s cluster version v1.35.8+k0s.1 is now installed`.

The restore also hits the staging-directory issue from Step 4 (`failed to remove backup
temp dir /tmp/XXXXXX`). For a restore, k0sctl uploads your archive to the controller, so
check it before deleting:

```bash
ssh controller 'sudo find /tmp -maxdepth 1 -type d -user jason -mmin -30 -exec ls -la {} \; ; sudo find /tmp -maxdepth 1 -type d -empty -user jason -mmin -30 -print -delete'
```

**Expected (first live run):** an empty `drwx------` listing, then the path deleted. If
the directory is not empty, it holds a copy of the backup; delete it with
`sudo rm -rf /tmp/XXXXXX`.

**Why the static IPs matter here:** the restore requires the controller address to be the
same as when the backup was taken, because worker components connect to it and k0s
cannot re-point them. A DHCP address that changed between backup and restore would break
this drill.

---

### Step 8: Verify the restore

The restored PKI includes the original CA, so the kubeconfig from Lab 2 still works.
Regenerate it anyway to confirm k0sctl can talk to the restored cluster.

```bash
cd ~/Projects/hardened-k8s/k0sctl && k0sctl kubeconfig --config k0sctl.yaml > ~/.kube/hardened-k8s.kubeconfig && export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig && k get nodes && k get nodes -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp && k -n canary get configmap proof -o jsonpath='{.data.written}{"\n"}' && k -n canary rollout status deployment/web --timeout=180s && k -n canary get pods -o wide
```

**Expected:**

```text
NAME        STATUS   ROLES    AGE     VERSION
worker-01   Ready    <none>   3d23h   v1.35.8+k0s
worker-02   Ready    <none>   3d23h   v1.35.8+k0s
NAME        CREATED
worker-01   2026-11-01T03:48:48Z
worker-02   2026-11-01T03:48:48Z
before-backup
deployment "web" successfully rolled out
web-7f9c5dbc8d-nj27n   1/1   Running   0   61m   10.244.1.11   worker-02
web-7f9c5dbc8d-sjlnr   1/1   Running   0   61m   10.244.0.14   worker-01
```

What each line proves:

| Result | Proves |
|---|---|
| `CREATED` is the Lab 2 build date, not today | Node objects came back from etcd |
| `before-backup` | The namespace deleted in Step 6 is back with its data |
| Same pod **names** as Step 3, original `AGE` | The pod objects themselves were restored |
| New pod **IPs** | Kubelets on the rebuilt workers started fresh containers for the restored objects |

etcd held the desired state; the nodes rebuilt the actual state.

**Reading node conditions:** use a filter, not a position.
`.status.conditions[-1].type` returns `ContainerdHasNoDeprecations` on v1.35, not
`Ready`, because conditions are not ordered. Use
`-o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'`.

**Troubleshooting:**
- Nodes stay `NotReady` for more than 3 min: kubelets are up but cannot reach the API
  through konnectivity. `k -n kube-system get pods -o wide` and
  `ssh worker-01 'sudo journalctl -u k0sworker -n 50 --no-pager'`.
- `canary` pods stuck in `ContainerCreating`: the reset wiped each worker's image cache,
  so images are pulled again. `k -n canary describe pod -l app=web | tail -15` shows the
  pull progress or an error.
- k0sctl fails with an error about existing data: the reset did not finish on the
  controller. Re-run the reset and the Step 7 verify, then the restore.

---

### Step 9: Fresh backup immediately before the upgrade

The Step 4 archive is still valid, but standard practice is a backup taken right before
the change, so the rollback point has no gap.

```bash
cd ~/Projects/hardened-k8s/k0sctl/backups && k0sctl backup --config ../k0sctl.yaml 2>&1 | grep -iE 'warn|finished' ; chmod 600 k0s_backup_*.tar.gz && command ls -lt
```

**Expected:** `Finished in 2s`, then a second, newer `k0s_backup_<timestamp>.tar.gz` at
the top (about 500 KB, slightly larger after the restore). This is the **pre-upgrade**
backup referenced in the Rollback section.

Use `grep -i`. When k0sctl's output goes to a pipe it switches to logfmt
(`level=info msg=...`, `level=warning msg=...`), so a case-sensitive `grep WARN` hides
warnings. Then clean up the staging directory as in Step 4:

```bash
ssh controller 'sudo find /tmp -maxdepth 1 -type d -empty -user jason -mmin -30 -print -delete'
```

---

### Step 10: Upgrade to v1.36.4+k0s.1

k0s upgrades one minor version at a time. k0sctl upgrades the controller first, then
cordons, drains, upgrades, and uncordons each worker.

```bash
cd ~/Projects/hardened-k8s/k0sctl && sed -i '' 's/version: v1.35.8+k0s.1/version: v1.36.4+k0s.1/' k0sctl.yaml && git diff k0sctl.yaml
```

**Expected diff:**

```diff
-    version: v1.35.8+k0s.1
+    version: v1.36.4+k0s.1
```

`sed -i ''` is the macOS form; GNU `sed -i` without the empty string fails on the Mac
with `invalid command code`.

In a **second terminal**, start a watch before you apply:

```bash
export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig && watch -n 2 'kubectl get nodes -o wide; echo; kubectl -n canary get pods -o wide; echo; kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide'
```

In the first terminal:

```bash
cd ~/Projects/hardened-k8s/k0sctl && k0sctl apply --config k0sctl.yaml 2>&1 | tee ~/Projects/hardened-k8s/k0sctl/backups/upgrade-1.35-to-1.36.log
```

`tee` keeps the output as incident evidence, in the gitignored backups folder. The first
live run took **1m32s**; allow up to ~8 min. In the watch window you should see, in order:
1. Both nodes stay `Ready` while the controller upgrades (the API may blip for a few
   seconds; `kubectl` errors in the watch window during that time are expected).
2. One worker at a time shows `Ready,SchedulingDisabled`, its `canary` pod moves to the
   other worker, its `VERSION` changes to `v1.36.4+k0s`, and it returns to `Ready`.
3. The second worker repeats the same sequence.

A short pause before the second drain is normal: CoreDNS requires one replica per node,
so the replica evicted from the first worker sits `Pending` until that worker is back,
and CoreDNS's PodDisruptionBudget holds the second eviction until it is ready.

**Expected end of the k0sctl output (logfmt, because of the pipe):**

```text
level=warning msg="192.168.64.10:22: k0s will be upgraded"      (one per host; this is the plan, not a problem)
...
level=info msg="Upgrading max 1 workers in parallel"
level=info msg="192.168.64.11:22: upgrade finished"
level=info msg="192.168.64.12:22: upgrade finished"
level=info msg="==> Finished in 1m32s"
level=info msg="k0s cluster version v1.36.4+k0s.1 is now installed"
```

The log has **no drain lines** even though k0sctl drains by default. Step 11 proves the
drain happened from the cluster's side.

**Troubleshooting:**
- A drain hangs: a PodDisruptionBudget or a pod with local storage blocks eviction.
  `k get pdb -A` and `k get pods -A -o wide --field-selector spec.nodeName=worker-01`.
  The two-replica canary has no PDB, so this should not happen in this lab.
- `k0sctl` refuses the version jump: confirm the file says `v1.36.4+k0s.1`, not a
  two-minor jump such as `v1.37`.

---

### Step 11: Verify versions after the change

```bash
for h in controller worker-01 worker-02; do printf '%-10s ' "$h"; ssh "$h" 'sudo k0s version'; done
```

**Expected:** `v1.36.4+k0s.1` three times.

```bash
export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig && k version 2>&1 | grep -E 'Server|Warning' ; k get nodes -o custom-columns=NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion && k -n canary get configmap proof -o jsonpath='{.data.written}{"\n"}' && k -n canary get pods -o wide && k get events -A --sort-by=.lastTimestamp | grep -iE 'cordon|drain|NodeNotSchedulable|NodeSchedulable|Evict' | tail -8
```

**Expected:**

```text
Server Version: v1.36.4+k0s
NAME        KUBELET       RUNTIME
worker-01   v1.36.4+k0s   containerd://2.3.5
worker-02   v1.36.4+k0s   containerd://2.3.5
before-backup
web-7f9c5dbc8d-q5gd4   1/1   Running   ...   worker-01
web-7f9c5dbc8d-wtsm9   1/1   Running   ...   worker-01
... NodeNotSchedulable   node/worker-01 ...
... NodeNotSchedulable   node/worker-02 ...
```

| Check | Means |
|---|---|
| `Server Version: v1.36.4` and no `Warning` line | The Lab 2 skew warning is gone (v1.37 client, v1.36 server) |
| `containerd://2.3.5` (was 1.7.35) | The upgrade moved the runtime up a major version |
| `before-backup` | Data survived the upgrade |
| New pod names | The drain evicted and replaced the canary pods |
| Both pods on one worker | Expected: the last-drained worker's pods could only go to the other one, and the scheduler never moves running pods back |
| `NodeNotSchedulable` per worker | Each worker was cordoned |

**Troubleshooting:** `The connection to the server localhost:8080 was refused` means this
terminal has no `KUBECONFIG`. Run the `export` at the start of the command. To set it in
every new terminal: `grep -q 'hardened-k8s.kubeconfig' ~/.bashrc || echo 'export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig' >> ~/.bashrc`.

**Confirm both workers were uncordoned.** In the first live run, no `NodeSchedulable`
event appeared after the uncordon. Check the node state, not only the events:

```bash
k get nodes && k get nodes -o custom-columns=NAME:.metadata.name,UNSCHEDULABLE:.spec.unschedulable
```

**Expected:** both `Ready` (not `Ready,SchedulingDisabled`) and `UNSCHEDULABLE` `<none>`.
If one is still cordoned, run `k uncordon worker-0N`.

```bash
cd ~/Projects/hardened-k8s && git add k0sctl/k0sctl.yaml .gitignore && git status --short && git commit -m "k0sctl: upgrade k0s v1.35.8+k0s.1 -> v1.36.4+k0s.1; ignore backup archives" && git push
```

**Expected:** only `M  .gitignore` and `M  k0sctl/k0sctl.yaml`. Nothing from
`k0sctl/backups/` may appear.

---

## Findings from the first live run (incident #3 evidence)

| # | Finding | Impact | Mitigation |
|---|---|---|---|
| 1 | k0sctl v0.33.1 leaves an empty `drwx------` staging directory in the controller's `/tmp` after every `backup` and `restore` (3 of 3 runs) | Low: verified empty, private, on `tmpfs` | `find /tmp -maxdepth 1 -type d -empty -user jason -mmin -30 -delete` after each run |
| 2 | Piped k0sctl output uses logfmt (`level=warning`), so `grep WARN` misses warnings | Warnings silently hidden in scripts and CI | `grep -i`, or keep the full log with `tee` |
| 3 | The worker uncordon produced no `NodeSchedulable` event | An events-only check would report a still-cordoned node | Check `.spec.unschedulable` |
| 4 | `.status.conditions[-1]` is not the Ready condition on v1.35 | Scripts that read by position report the wrong state | Filter: `conditions[?(@.type=="Ready")]` |
| 5 | k0s 1.35 → 1.36 also moves containerd 1.7.35 → 2.3.5 | A major runtime change rides along with a minor k8s bump | Record runtime versions before and after; test workloads on the new runtime |

Restore timing: reset 3 s, restore 55 s, cluster usable within ~2 min. Upgrade: 1m32s.

---

## What `k0s backup` does not capture

| Not in the archive | Consequence |
|---|---|
| PersistentVolume data | Application data on disks is lost unless backed up separately (Velero, storage snapshots) |
| Worker node state | Workers are rebuilt and re-pull images; nothing on a worker is restored |
| Manual host changes outside `/var/lib/k0s/manifests` | Lost, which is one more reason to keep host config in Ansible |
| `k0sctl.yaml` and your kubeconfig files | Keep `k0sctl.yaml` in git; regenerate kubeconfigs with `k0sctl kubeconfig` |

What it does capture: PKI (`/var/lib/k0s/pki`), the etcd snapshot (or the kine/SQLite
database on a `--single` node such as `a0`), `k0s.yaml`, custom manifests under
`/var/lib/k0s/manifests`, image bundles under `/var/lib/k0s/images`, and Helm
configuration.

---

## kubeadm equivalents, for the exam

These are what the CKA asks for. Practice them on the KodeKloud lab clusters, not here.

**etcd backup** (on the control-plane node; paths match the kubeadm defaults in the course):

```bash
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key snapshot save /opt/etcd-backup.db
```

**etcd restore** to a new data directory, then point the static pod at it:

```bash
etcdutl snapshot restore /opt/etcd-backup.db --data-dir /var/lib/etcd-from-backup
sudo sed -i 's#path: /var/lib/etcd$#path: /var/lib/etcd-from-backup#' /etc/kubernetes/manifests/etcd.yaml
```

The kubelet sees the manifest change and recreates the etcd pod. Check the `hostPath`
`volumes` entry in `etcd.yaml` before and after; that is the line that must change.

**Upgrade** (control plane, then each worker):

```bash
kubeadm upgrade plan
sudo kubeadm upgrade apply v1.36.4
kubectl drain <node> --ignore-daemonsets
sudo kubeadm upgrade node
kubectl uncordon <node>
```

Each node also needs its `kubeadm`, `kubelet`, and `kubectl` packages upgraded
(`apt-mark unhold`, `apt-get install`, `apt-mark hold`) and `systemctl restart kubelet`.
k0sctl hides all of this behind one `apply`.

---

## Rollback / Clean-up

**Roll back the upgrade.** k0s does not support in-place downgrades. Restore the
pre-upgrade backup (Step 9) onto the old version:

```bash
cd ~/Projects/hardened-k8s/k0sctl && sed -i '' 's/version: v1.36.4+k0s.1/version: v1.35.8+k0s.1/' k0sctl.yaml && k0sctl reset --config k0sctl.yaml --force && PREUPGRADE=$(command ls -t backups/k0s_backup_*.tar.gz | head -1) && echo "Restoring from $PREUPGRADE" && k0sctl apply --config k0sctl.yaml --restore-from "$PREUPGRADE"
```

`command ls -t ... | head -1` picks the newest archive (`command` bypasses an `ls` alias
such as `eza`, whose `-t` means something else), which is the Step 9 backup as long as you
have not taken another one since. Check the `Restoring from` line before the reset
completes. After the rollback, run Step 11's verify; expect `v1.35.8+k0s.1` everywhere.

**Faster alternative:** restore the `~/utm-golden/k0s-1.35/` disk copies from Lab 2
(see the Lab 2 Rollback block). That discards everything done in this lab.

**Clean up the lab artifacts:**

```bash
k delete namespace canary && rm -rf ~/k0s-restore-test && ssh controller 'sudo rm -rf /var/lib/k0s-backups' && command ls ~/Projects/hardened-k8s/k0sctl/backups/
```

**Expected:** `namespace "canary" deleted`, then the two backups and
`upgrade-1.35-to-1.36.log`. `rm -rf ~/k0s-restore-test` removes the clear-text CA key
copy from Step 5. (`/var/lib/k0s-backups` exists only if you ran the manual
`k0s backup` example in Step 4.) Keep `~/Projects/hardened-k8s/k0sctl/backups/` (it is
gitignored) or delete it with `rm -P ~/Projects/hardened-k8s/k0sctl/backups/*` when you no longer
need the restore points.

**Next:** Lab 4 locks down a namespace with NetworkPolicy on kube-router.
