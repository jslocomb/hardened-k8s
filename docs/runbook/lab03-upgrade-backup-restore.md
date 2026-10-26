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

```bash
export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig && k get nodes && grep 'version:' ~/Projects/hardened-k8s/k0sctl/k0sctl.yaml
```

**Expected:**

```text
NAME        STATUS   ROLES    AGE   VERSION
worker-01   Ready    <none>   1h    v1.35.8+k0s
worker-02   Ready    <none>   1h    v1.35.8+k0s
    version: v1.35.8+k0s.1
```

(`k get nodes` may also print the client/server skew warning from Lab 2.)

---

### Step 1: Record versions before the change

```bash
for h in controller worker-01 worker-02; do printf '%-10s ' "$h"; ssh "$h" 'sudo k0s version'; done
```

**Expected:**

```text
controller v1.35.8+k0s.1
worker-01  v1.35.8+k0s.1
worker-02  v1.35.8+k0s.1
```

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
cd ~/Projects/hardened-k8s && git check-ignore -v k0sctl/backups/k0s_backup_test.tar.gz
```

**Expected:**

> `.gitignore:NN:k0sctl/backups/	k0sctl/backups/k0s_backup_test.tar.gz`

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

---

### Step 4: Take the backup with `k0sctl backup`

`k0sctl backup` runs `k0s backup` on the controller and downloads the archive into the
current directory.

```bash
cd ~/Projects/hardened-k8s/k0sctl/backups && k0sctl backup --config ../k0sctl.yaml && chmod 600 k0s_backup_*.tar.gz && ls -lh
```

This can take ~30–60 s.

**Expected:** one file named `k0s_backup_<timestamp>.tar.gz`, a few MB in size.

The equivalent by hand on the controller (useful when k0sctl is not available):

```bash
ssh controller 'sudo mkdir -p /var/lib/k0s-backups && sudo k0s backup --save-path /var/lib/k0s-backups && sudo ls -lh /var/lib/k0s-backups'
```

**Expected:** a `k0s_backup_<ISO timestamp>.tar.gz` in `/var/lib/k0s-backups`. This copy
stays on the controller and is only a demonstration; the drill below uses the one on the
Mac.

**Encrypting at rest (recommended outside the lab):**

```bash
cd ~/Projects/hardened-k8s/k0sctl/backups && BACKUP=$(ls -t k0s_backup_*.tar.gz | head -1) && gpg --symmetric --cipher-algo AES256 -o "$BACKUP.gpg" "$BACKUP" && ls -lh "$BACKUP.gpg"
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
BACKUP=$(ls -t ~/Projects/hardened-k8s/k0sctl/backups/k0s_backup_*.tar.gz | head -1) && rm -rf ~/k0s-restore-test && mkdir -p ~/k0s-restore-test && tar -xzf "$BACKUP" -C ~/k0s-restore-test && find ~/k0s-restore-test -maxdepth 2 | sort
```

**Expected:** a `pki` directory, a `k0s.yaml` (or similarly named config file), and an
etcd snapshot file, for example:

```text
/Users/jason/k0s-restore-test
/Users/jason/k0s-restore-test/k0s.yaml
/Users/jason/k0s-restore-test/pki
/Users/jason/k0s-restore-test/pki/etcd
...
/Users/jason/k0s-restore-test/etcd-snapshot.db
```

Exact names can differ between k0s releases; the three kinds of content are what matter.

```bash
PKI_DIR=$(find ~/k0s-restore-test -type d -name pki | head -1) && (cd "$PKI_DIR" && find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort -k2) > ~/k0s-restore-test/backup.sha && ssh controller 'cd /var/lib/k0s/pki && sudo find . -type f -exec sha256sum {} + | LC_ALL=C sort -k2' > ~/k0s-restore-test/live.sha && diff ~/k0s-restore-test/backup.sha ~/k0s-restore-test/live.sha && echo "PKI matches: $(wc -l < ~/k0s-restore-test/live.sha) files"
```

**Expected:**

> `PKI matches: NN files`

No `diff` lines means every certificate and key in the archive is byte-identical to the
live controller's. `LC_ALL=C` on both sides matters: macOS and Linux `sort` order
punctuation differently under a UTF-8 locale, which would produce a false mismatch.

```bash
find ~/k0s-restore-test -maxdepth 1 -type f -exec ls -lh {} + && grep -h 'name:' ~/k0s-restore-test/*.yaml | head -3
```

**Expected:** the config file (a few KB) and the etcd snapshot (several MB) listed, and
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

**Verify the reset:**

```bash
for h in controller worker-01 worker-02; do printf '%-10s ' "$h"; ssh "$h" 'test -d /var/lib/k0s && echo "k0s data still present" || echo "clean"'; done
```

**Expected:** `clean` for all three.

```bash
cd ~/Projects/hardened-k8s/k0sctl && BACKUP=$(ls -t backups/k0s_backup_*.tar.gz | head -1) && echo "Restoring from $BACKUP" && k0sctl apply --config k0sctl.yaml --restore-from "$BACKUP"
```

This can take ~4–6 min, don't panic. k0sctl reinstalls k0s v1.35.8+k0s.1, restores the
PKI and etcd snapshot onto the controller before starting it, then rejoins both workers.
Watch from a second terminal:

```bash
ssh controller 'sudo journalctl -u k0scontroller -f'
```

**Expected:** the run ends with `==> Finished` and reports k0s v1.35.8+k0s.1 installed.

**Why the static IPs matter here:** the restore requires the controller address to be the
same as when the backup was taken, because worker components connect to it and k0s
cannot re-point them. A DHCP address that changed between backup and restore would break
this drill.

---

### Step 8: Verify the restore

The restored PKI includes the original CA, so the kubeconfig from Lab 2 still works.
Regenerate it anyway to confirm k0sctl can talk to the restored cluster.

```bash
cd ~/Projects/hardened-k8s/k0sctl && k0sctl kubeconfig --config k0sctl.yaml > ~/.kube/hardened-k8s.kubeconfig && export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig && k get nodes && k -n canary get configmap proof -o jsonpath='{.data.written}{"\n"}' && k -n canary rollout status deployment/web --timeout=180s && k -n canary get pods -o wide
```

**Expected:**

```text
NAME        STATUS   ROLES    AGE   VERSION
worker-01   Ready    <none>   1h    v1.35.8+k0s
worker-02   Ready    <none>   1h    v1.35.8+k0s
before-backup
deployment "web" successfully rolled out
web-xxxxxxxxxx-xxxxx   1/1   Running   ...   worker-01
web-xxxxxxxxxx-xxxxx   1/1   Running   ...   worker-02
```

The node `AGE` shows the original creation time, not "2m": Node objects came back from
etcd. The `canary` namespace, deleted in Step 6, is back with its data.

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
cd ~/Projects/hardened-k8s/k0sctl/backups && k0sctl backup --config ../k0sctl.yaml && chmod 600 k0s_backup_*.tar.gz && ls -lt | head -3
```

**Expected:** a second, newer `k0s_backup_<timestamp>.tar.gz` at the top. This is the
**pre-upgrade** backup referenced in the Rollback section.

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
export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig && watch -n 2 'kubectl get nodes -o wide; echo; kubectl -n canary get pods -o wide'
```

In the first terminal:

```bash
cd ~/Projects/hardened-k8s/k0sctl && k0sctl apply --config k0sctl.yaml
```

This can take ~5–8 min, don't panic. In the watch window you should see, in order:
1. Both nodes stay `Ready` while the controller upgrades (the API may blip for a few
   seconds; `kubectl` errors in the watch window during that time are expected).
2. One worker at a time shows `Ready,SchedulingDisabled`, its `canary` pod moves to the
   other worker, its `VERSION` changes to `v1.36.4+k0s`, and it returns to `Ready`.
3. The second worker repeats the same sequence.

**Expected end of the k0sctl output:**

> `==> Finished`, reporting the cluster upgraded to `v1.36.4+k0s.1`

**Troubleshooting:**
- A drain hangs: a PodDisruptionBudget or a pod with local storage blocks eviction.
  `k get pdb -A` and `k get pods -A -o wide --field-selector spec.nodeName=worker-01`.
  The two-replica canary has no PDB, so this should not happen in this lab.
- `k0sctl` refuses the version jump: confirm the file says `v1.36.4+k0s.1`, not a
  two-minor jump such as `v1.37`.

---

### Step 11: Verify versions after the change

```bash
for h in controller worker-01 worker-02; do printf '%-10s ' "$h"; ssh "$h" 'sudo k0s version'; done && k version && k get nodes && k -n canary get configmap proof -o jsonpath='{.data.written}{"\n"}'
```

**Expected:**

```text
controller v1.36.4+k0s.1
worker-01  v1.36.4+k0s.1
worker-02  v1.36.4+k0s.1
Client Version: v1.37.1
Kustomize Version: v5.x.y
Server Version: v1.36.4+k0s
NAME        STATUS   ROLES    AGE   VERSION
worker-01   Ready    <none>   2h    v1.36.4+k0s
worker-02   Ready    <none>   2h    v1.36.4+k0s
before-backup
```

The skew warning from Lab 2 is gone: a v1.37 client against a v1.36 server is within
the supported +/-1.

```bash
cd ~/Projects/hardened-k8s && git add k0sctl/k0sctl.yaml .gitignore && git commit -m "k0sctl: upgrade k0s v1.35.8+k0s.1 -> v1.36.4+k0s.1; ignore backup archives"
```

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
cd ~/Projects/hardened-k8s/k0sctl && sed -i '' 's/version: v1.36.4+k0s.1/version: v1.35.8+k0s.1/' k0sctl.yaml && k0sctl reset --config k0sctl.yaml --force && PREUPGRADE=$(ls -t backups/k0s_backup_*.tar.gz | head -1) && echo "Restoring from $PREUPGRADE" && k0sctl apply --config k0sctl.yaml --restore-from "$PREUPGRADE"
```

`ls -t ... | head -1` picks the newest archive, which is the Step 9 backup as long as you
have not taken another one since. Check the `Restoring from` line before the reset
completes. After the rollback, run Step 11's verify; expect `v1.35.8+k0s.1` everywhere.

**Faster alternative:** restore the `~/utm-golden/k0s-1.35/` disk copies from Lab 2
(see the Lab 2 Rollback block). That discards everything done in this lab.

**Clean up the lab artifacts:**

```bash
k delete namespace canary && rm -rf ~/k0s-restore-test && ssh controller 'sudo rm -rf /var/lib/k0s-backups'
```

**Expected:** `namespace "canary" deleted`. Keep `~/Projects/hardened-k8s/k0sctl/backups/` (it is
gitignored) or delete it with `rm -P ~/Projects/hardened-k8s/k0sctl/backups/*` when you no longer
need the restore points.

**Next:** Lab 4 locks down a namespace with NetworkPolicy on kube-router.
