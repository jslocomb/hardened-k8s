# hardened-k8s

Hands-on Kubernetes lab focused on troubleshooting and security, built on my path to the
**CKA (Certified Kubernetes Administrator)**.

## Why this exists

I have 25+ years in Linux and infrastructure security, but production Kubernetes depth is
my current growth area. This repo is how I'm closing that gap: by building a cluster,
breaking it on purpose, and documenting how I diagnose and fix each failure.

Everything here is a personal lab, not production. Each scenario shows real commands and
real output from my own environment.

## Lab environment

| Component | Detail |
|---|---|
| Host | Mac Mini M4 |
| Hypervisor | UTM |
| Guest OS | Ubuntu 24.04 LTS (ARM64) |
| Kubernetes | k0s (single node) |

Setup notes: [docs/environment.md](docs/environment.md)

## Troubleshooting scenarios

Each scenario follows the same format: symptom, triage, root cause, fix, lessons learned.

| # | Scenario | Area | Status |
|---|---|---|---|
| 01 | [CrashLoopBackOff](scenarios/01-crashloopbackoff.md) | Workloads | Reproduced |
| 02 | [ImagePullBackOff](scenarios/02-imagepullbackoff.md) | Workloads | Reproduced |
| 03 | [High load average with idle CPU (D-state / I/O wait)](scenarios/03-load-avg-dstate.md) | Linux node | Reproduced |

New scenarios start from [scenarios/_template.md](scenarios/_template.md).

## Security hardening

Planned work, tracked in [security/README.md](security/README.md): RBAC, NetworkPolicies,
Pod Security Standards, and secrets hygiene.

## CKA progress

Domain-by-domain tracker: [cka/progress.md](cka/progress.md)

## Related work

- [hardened-infrasec](https://github.com/jslocomb/hardened-infrasec): AWS GovCloud,
  CMMC-aligned infrastructure built from the ground up.

## Contact

Jason Slocomb · jslocomb@technochaos.com
