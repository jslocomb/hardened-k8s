# Runbook 03: Restore a k0s cluster from an etcd backup

**Use when:** the control plane is lost or corrupted, or a destructive change must be
undone and cannot be re-applied from git.
**Time:** about 10 minutes hands-on; the restore itself is about 1 minute.
**Tested:** 2026-11-04 on k0s v1.35.8+k0s.1, k0sctl v0.33.1 ([postmortem](postmortem.md)).
**kubeadm clusters:** see [kubeadm equivalent](#kubeadm-equivalent) at the end.

---

## 1. Decide: is a full restore the right fix?

A full restore **rolls the whole cluster back** to the backup time. Every change anyone
made after that is lost. Pick the narrowest fix that works.

| Situation | Do this | Not this |
|---|---|---|
| One namespace or object deleted, and its manifests are in git | Re-apply from git (`kubectl apply -f`, or let GitOps sync) | Full restore |
| Same, but nothing in git | Full restore **only** after the owner of every other workload agrees to lose changes since the backup | Restore without asking |
| API refuses connections and `k0scontroller` will not start; etcd data is corrupt or the controller disk is gone | Full restore (this runbook) | |
| A bad upgrade | Full restore of the **pre-upgrade** backup onto the **old** version (k0s cannot downgrade in place) | Setting the old version and running `apply` without a reset |

If unsure, stop here and escalate (section 8).

## 2. Symptoms

- `kubectl ...` → `The connection to the server 192.168.64.10:6443 was refused`
- `ssh controller 'sudo k0s status'` fails, or `journalctl -u k0scontroller` shows etcd
  errors
- Objects that existed are `NotFound` and cannot be recreated from source

## 3. Before you start: prerequisites

Check every row. A failed prerequisite means a failed restore.

| # | Check | Command | Expected |
|---|---|---|---|
| 1 | You have the backup file | `command ls -lt ~/Projects/hardened-k8s/k0sctl/backups/` | A `k0s_backup_<unix-time>.tar.gz` from before the problem |
| 2 | You know when it was taken | `date -r <unix-time>` (the number in the file name) | A time before the bad change. Everything after this is lost |
| 3 | **Same k0s version** as the backup | `grep version: ~/Projects/hardened-k8s/k0sctl/k0sctl.yaml` | The version that was running when the backup was taken. A restore only works onto the same version |
| 4 | **Same controller IP** as the backup | `ssh controller 'hostname -I'` | `192.168.64.10`. The restored certificates point at this address |
| 5 | SSH and passwordless sudo work | `for h in controller worker-01 worker-02; do ssh -o BatchMode=yes $h 'sudo -n true && hostname'; done` | Three hostnames, no prompts |
| 6 | Clocks are correct | `for h in controller worker-01 worker-02; do ssh $h 'chronyc tracking \| grep "System time"'; done` | Each within a few ms of NTP |

**Optional but recommended:** check that the archive is complete before you destroy
anything (2 minutes):

```bash
mkdir -p ~/k0s-restore-test && chmod 700 ~/k0s-restore-test && tar -xzf <backup-file> -C ~/k0s-restore-test && command ls ~/k0s-restore-test ~/k0s-restore-test/pki | head -20
```

**Expected:** `etcd-snapshot.db`, `k0s.yaml`, `manifests/`, and `pki/` containing
`ca.crt`, `ca.key`, `sa.key`. Delete the folder afterwards (`rm -rf ~/k0s-restore-test`);
it holds the cluster's private keys in clear text.

## 4. Restore

All commands run on the Mac, in a terminal with `KUBECONFIG` set:

```bash
export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig && cd ~/Projects/hardened-k8s/k0sctl
```

### 4a. Choose the backup and confirm it

```bash
BACKUP=backups/k0s_backup_<unix-time>.tar.gz && command ls -l "$BACKUP" && date -r "$(basename "$BACKUP" .tar.gz | sed 's/k0s_backup_//')"
```

**Expected:** the file, then its date. **Stop if the date is not before the bad change.**

### 4b. Reset the cluster on all nodes

**Point of no return.** This deletes k0s and all cluster data on every node.

```bash
k0sctl reset --config k0sctl.yaml --force
```

**Expected:** `==> Finished in` a few seconds. These `WARN` lines are normal:
`/etc/k0s/k0s.yaml: file does not exist` (workers), and `k0s: not found` during
`Reset leader` (the single controller is reset twice).

If `--force` is rejected, run it without the flag and type `y`.

Confirm the reset:

```bash
for h in controller worker-01 worker-02; do printf '%-10s ' "$h"; ssh "$h" 'test -d /var/lib/k0s && echo "STILL PRESENT" || echo clean'; done
```

**Expected:** `clean` three times. If any says `STILL PRESENT`, run the reset again
before continuing.

### 4c. Restore from the backup

```bash
k0sctl apply --config k0sctl.yaml --restore-from "$BACKUP" 2>&1 | tee "restore-$(date +%Y%m%d-%H%M).log"
```

**Expected (about 1 minute):** a `Restore cluster state` phase before
`Initialize the k0s cluster`, workers rejoining, then
`k0s cluster version <version> is now installed`.

### 4d. Remove k0sctl's leftover staging directory

k0sctl v0.33.1 leaves a staging directory on the controller (warning:
`failed to remove backup temp dir /tmp/XXXXXX`). During a restore it held the uploaded
archive, so look before deleting:

```bash
ssh controller 'sudo find /tmp -maxdepth 1 -type d -user jason -mmin -30 -newer /etc/k0s/k0s.yaml -exec ls -la {} \; ; sudo find /tmp -maxdepth 1 -type d -user jason -mmin -30 -newer /etc/k0s/k0s.yaml -exec rm -rf {} + -print'
```

**Expected:** an empty `drwx------` listing, then its path. Either way it is now gone.

## 5. Verify

```bash
k0sctl kubeconfig --config k0sctl.yaml > ~/.kube/hardened-k8s.kubeconfig && kubectl get nodes && kubectl get nodes -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp && kubectl get pods -A | grep -v -E 'Running|Completed' || echo "all pods Running"
```

| Check | Expected | If not |
|---|---|---|
| Nodes | Both workers `Ready` within ~3 min | Section 6 |
| Node `CREATED` | The original build date, **not** today | You restored nothing; the cluster is new. Check `$BACKUP` and repeat |
| Pods | `all pods Running` after ~2 min (images are pulled again) | Section 6 |
| The deleted object | Present again (`kubectl get ns <name>`) | The backup is from after the deletion; choose an older one |

Then confirm with the workload owner that their application works.

## 6. Troubleshooting

| Symptom | Likely cause | Check / fix |
|---|---|---|
| Restore fails: existing data | Reset did not finish on the controller | Repeat 4b and its check, then 4c |
| Workers stay `NotReady` > 3 min | Kubelets cannot reach the API through konnectivity | `ssh worker-01 'sudo journalctl -u k0sworker -n 50 --no-pager'` |
| Pods `ContainerCreating` for minutes | The reset cleared the image cache; images are pulling | `kubectl describe pod <pod> -n <ns> \| tail -15` |
| `x509: certificate ... not yet valid` | Clock skew | `ssh <host> 'sudo chronyc makestep'`, then re-run 4c |
| `kubectl` → `localhost:8080 refused` | `KUBECONFIG` not set in this terminal | `export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig` |
| Workers cannot reach the controller | Controller IP changed since the backup | Restore the original IP; k0s cannot re-point workers |

## 7. After the restore

1. Take a fresh backup, so the next restore point includes the recovered state:
   `cd ~/Projects/hardened-k8s/k0sctl/backups && k0sctl backup --config ../k0sctl.yaml 2>&1 | grep -iE 'warn|finished'`
   (use `grep -i`: piped k0sctl output writes `level=warning`, not `WARN`). Then repeat 4d.
2. Write down what the restore rolled back (everything between the backup time and
   now), and tell the affected owners.
3. Open a postmortem.

## 8. Escalate when

- Any prerequisite in section 3 fails and you cannot fix it.
- The backup is older than the team's agreed recovery point, or there is no backup.
- Verification fails after one retry of section 4.
- Other teams' workloads would lose changes, and no owner has agreed.

Escalate to the cluster owner or platform lead with: the backup file name and time, the
last command run, and its log (`restore-*.log`).

---

## Pre-change backup (before any upgrade or risky change)

```bash
cd ~/Projects/hardened-k8s/k0sctl/backups && k0sctl backup --config ../k0sctl.yaml 2>&1 | grep -iE 'warn|finished' ; chmod 600 k0s_backup_*.tar.gz && command ls -lt | head -3
```

Then repeat 4d. Record versions before and after the change, kubelet **and** container
runtime (the k0s 1.35 → 1.36 upgrade also moved containerd 1.7.35 → 2.3.5):

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion
```

After an upgrade, check that workers are schedulable by **state**, not events (no
`NodeSchedulable` event was emitted in testing):

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,UNSCHEDULABLE:.spec.unschedulable
```

**Expected:** `<none>` for every worker.

---

## kubeadm equivalent

The CKA exam uses kubeadm clusters. Same goal, different commands. Run these on the
control-plane node; the paths are kubeadm defaults, so check them in
`/etc/kubernetes/manifests/etcd.yaml`.

| Step | k0s (this runbook) | kubeadm |
|---|---|---|
| Back up | `k0sctl backup` (etcd + PKI + config in one archive) | `etcdctl snapshot save` (etcd only; back up `/etc/kubernetes/pki` separately) |
| Restore | `k0sctl reset` + `k0sctl apply --restore-from` | `etcdutl snapshot restore` to a new data directory, then point the etcd static pod at it |
| Control plane runs as | Processes under `k0scontroller` | Static pods from `/etc/kubernetes/manifests/` |

**Backup:**

```bash
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /opt/etcd-backup.db
```

**Restore:**

```bash
etcdutl snapshot restore /opt/etcd-backup.db --data-dir /var/lib/etcd-from-backup
sudo sed -i 's#path: /var/lib/etcd$#path: /var/lib/etcd-from-backup#' /etc/kubernetes/manifests/etcd.yaml
```

The kubelet sees the manifest change and restarts etcd on the restored data. Check the
`hostPath` under `volumes:` in `etcd.yaml` before and after; that is the line that must
change. Allow 1–2 minutes, then run `kubectl get pods -A`.
