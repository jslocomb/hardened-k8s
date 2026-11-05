# Postmortem 03: Cluster restore from etcd backup after a destructive change (DR drill)

| | |
|---|---|
| **Type** | Planned disaster-recovery drill (game day). The destructive change was deliberate; every finding below is real. |
| **Date** | 2026-11-04 (America/Los_Angeles) |
| **Cluster** | `hardened-k8s` lab: k0s, 1 controller (etcd) + 2 workers, Ubuntu 26.04 ARM64 on UTM |
| **Versions** | k0s v1.35.8+k0s.1 → v1.36.4+k0s.1; k0sctl v0.33.1 |
| **Author** | Jason Slocomb |
| **Status** | Complete. Recovery succeeded; 5 follow-ups recorded |
| **Runbook** | [runbook.md](runbook.md) |

## Summary

A namespace holding a workload and its configuration was deleted. The cluster was then
reset on all three nodes and rebuilt from an etcd backup taken eight minutes before the
deletion. The restore took **55 seconds** and brought back every object, including the
original Node and Pod objects. A fresh backup was then taken and the cluster was upgraded
one Kubernetes minor version, from 1.35 to 1.36, in **1 minute 32 seconds**, with no data
loss.

The drill confirmed that the backups can actually be restored, and measured how long
recovery takes. It also found five issues in the tooling and in the checks an operator
relies on. None blocked recovery; two would hide problems from a script or a tired
operator.

## Impact

| Measure | Value |
|---|---|
| Data lost | None. Everything deleted was restored. |
| Recovery point (RPO) | 18:46, the backup time. Changes made after a backup are lost in a full restore. |
| API unavailable | About 5 minutes (19:32 reset → 19:37 restore complete), mostly operator time between commands |
| Restore duration | 55 s (`k0sctl apply --restore-from`) |
| Upgrade duration | 1 m 32 s; workloads moved between workers, Service traffic continued |

**Important limit:** a full etcd restore rolls the **whole cluster** back to the backup
point, not only the deleted namespace. In a production cluster, anything created or
changed by anyone after 18:46 would also have been undone. Here nothing else had changed,
so the RPO cost was zero. That will not usually be true.

## Timeline (2026-11-04, PST)

| Time | Event |
|---|---|
| 18:22 | Pre-checks: both workers `Ready` on v1.35.8, clocks within 1 ms of NTP, repo clean |
| 18:30 | Baseline recorded: k0s v1.35.8+k0s.1 on all nodes, containerd 1.7.35 on workers |
| 18:37 | Backup path added to `.gitignore` (archives hold CA keys and every Secret); private backup folder created |
| 18:40 | Canary created: namespace `canary`, ConfigMap `proof` (`written=before-backup`), Deployment `web` (2 replicas) |
| **18:46** | **Backup 1** taken with `k0sctl backup`: `k0s_backup_1793846775.tar.gz`, 412 KB, 2 s |
| 18:48 | k0sctl left a staging directory on the controller (finding 1). Inspected (empty, `drwx------`) and removed |
| 18:53 | Backup checked offline: 36 of 36 certificate and key files byte-identical to the live controller |
| **18:54** | **Destructive change:** `kubectl delete namespace canary` |
| **19:32** | **Cluster reset** on all 3 nodes (`k0sctl reset --force`, 3 s). API refuses connections |
| 19:36–19:37 | **Restore** from Backup 1 (`k0sctl apply --restore-from`, 55 s). Same staging-directory leftover, removed |
| 19:41 | **Recovery verified:** ConfigMap `proof` = `before-backup`; Node objects show their original creation time; the original Pod objects (same names) are back with new IPs |
| 19:44 | **Backup 2** (pre-upgrade): `k0s_backup_1793850239.tar.gz`, 497 KB. Leftover again (3 of 3) |
| 19:47 | `k0sctl.yaml` version changed to v1.36.4+k0s.1 |
| 19:48–19:50 | **Upgrade:** controller first, then one worker at a time (1 m 32 s) |
| 19:58 | **Upgrade verified:** v1.36.4 everywhere, containerd 2.3.5, data intact, canary pods replaced by the drain |
| 20:00 | Both workers confirmed schedulable (`.spec.unschedulable` empty) |
| 20:02 | Upgrade committed (`29ca002`) |

## Detection

In this drill, detection was planned. In a real incident, the same loss would surface as:

- `kubectl get ns <name>` → `NotFound`, or an application reporting missing config
- `kubectl get events -A` showing mass deletions
- the API audit log naming the `delete` call and the user who made it

A full cluster loss (etcd corruption, or losing the controller disk) surfaces as
`The connection to the server 192.168.64.10:6443 was refused` from every client. That was
reproduced at 19:35.

## Root cause

**Of the simulated outage:** a namespace deletion. Kubernetes has no undo; `delete`
removes the objects from etcd immediately.

**Of what made recovery possible:** a recent, verified etcd backup, and a controller
address that did not change. k0s restores require the controller to keep its IP, because
the restored certificates and worker configurations point at it. The lab uses static IPs
for this reason; with DHCP, an address change between backup and restore would break the
restore.

## What went well

- **The backup was verified before it was needed.** All 36 PKI files were checked hash by
  hash against the live controller, offline, without touching the cluster.
- **The restore brought back the cluster's identity, not only its data.** The original
  CA came back, so existing kubeconfigs kept working, and Node and Pod objects returned
  with their original creation times.
- **A pre-change backup was taken immediately before the upgrade,** so the rollback point
  had no gap.
- **The upgrade kept workloads running.** Workers upgraded one at a time; the canary
  pods were evicted and rescheduled; CoreDNS's disruption budget held a drain until a
  replica was ready.

## Findings

| # | Finding | Severity | Why it matters |
|---|---|---|---|
| 1 | k0sctl v0.33.1 leaves a staging directory in the controller's `/tmp` after every `backup` and `restore` (3 of 3 runs). It runs `rm` without `-r`. | Low | Verified empty and private (`drwx------`) on RAM-backed `tmpfs` each time. If a future version leaves the archive behind, it would expose the CA keys and Secrets. |
| 2 | With output piped (to `tee` or `grep`), k0sctl switches to logfmt, so `WARN` becomes `level=warning`. | Medium | A script that runs `grep WARN` reports success while warnings are hidden. Finding 1 was hidden this way on the third run. |
| 3 | The worker uncordon after the upgrade produced no `NodeSchedulable` event. | Medium | A check based only on events would wrongly report a node as still cordoned, or would miss a node that really stayed cordoned. |
| 4 | `.status.conditions[-1]` is not the `Ready` condition on Kubernetes 1.35; it returned `ContainerdHasNoDeprecations`. | Low | A health script reading the last condition reports the wrong state. |
| 5 | The k0s minor upgrade 1.35 → 1.36 also moved containerd from 1.7.35 to 2.3.5. | Medium | A major container runtime change rides along with what looks like a routine minor upgrade. Runtime-specific behaviour needs testing. |

## Follow-ups

| # | Action | Status |
|---|---|---|
| 1 | After every backup or restore, remove the empty leftover staging directory (runbook step) | Done, in the runbook |
| 2 | Always `grep -i` k0sctl output, and keep the full log with `tee` | Done, in the runbook |
| 3 | Verify uncordon with `.spec.unschedulable`, not events | Done, in the runbook |
| 4 | Read node conditions with a type filter: `conditions[?(@.type=="Ready")]` | Done, in the runbook |
| 5 | Record kubelet **and** container runtime versions before and after every upgrade | Done, in the runbook |
| 6 | Encrypt backups at rest (`gpg` or `age`) and store a copy off the Mac | Open |
| 7 | Report the staging-directory issue to the k0sctl project | Open |
| 8 | Prefer re-applying from git for a single deleted namespace, and keep full etcd restore for losing the control plane (see the runbook's decision table) | Done, in the runbook |

## Lessons learned

- **A backup you have not restored is a hope, not a backup.** The offline hash check
  found nothing wrong, but only the full restore proved the archive worked.
- **A full etcd restore is a cluster-wide rollback.** It is the right tool when the
  control plane is lost. It is a blunt tool for one deleted namespace, where re-applying
  the manifests from git loses nothing else.
- **Check state, not signals.** Two of the five findings (2 and 3) are cases where the
  usual signal, a log line or an event, was missing or hidden while the actual state was
  fine.
- **Static control-plane addressing is a recovery requirement**, not a convenience.

## Evidence

- Lab procedure: [`docs/runbook/lab03-upgrade-backup-restore.md`](../../docs/runbook/lab03-upgrade-backup-restore.md)
- Cluster definition before and after: `k0sctl/k0sctl.yaml` at `122246c` and `29ca002`
- Upgrade log and both backups: kept locally in `k0sctl/backups/` (gitignored: they hold
  CA keys and Secrets)

Key outputs:

```text
$ diff backup.sha live.sha && echo "PKI matches: ..."
PKI matches: 36 files

$ k0sctl apply --config k0sctl.yaml --restore-from backups/k0s_backup_1793846775.tar.gz
INFO ==> Running phase: Restore cluster state
INFO 192.168.64.10:22: restoring cluster state
WARN 192.168.64.10:22: failed to remove backup temp dir /tmp/f4maRp: ... Is a directory
INFO ==> Finished in 55s

$ kubectl get nodes -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp
worker-01   2026-11-01T03:48:48Z
worker-02   2026-11-01T03:48:48Z
$ kubectl -n canary get configmap proof -o jsonpath='{.data.written}'
before-backup
$ kubectl -n canary get pods -o wide
web-7f9c5dbc8d-nj27n   1/1   Running   0   61m   10.244.1.11   worker-02
web-7f9c5dbc8d-sjlnr   1/1   Running   0   61m   10.244.0.14   worker-01

$ kubectl get nodes -o custom-columns=NAME:.metadata.name,KUBELET:...,RUNTIME:...
worker-01   v1.36.4+k0s   containerd://2.3.5
worker-02   v1.36.4+k0s   containerd://2.3.5
```
