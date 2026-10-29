# CKA Supplemental Resources

Outside material reviewed alongside the KodeKloud course. The course stays the backbone; these are for tips and second explanations, not extra study time.

## Current CKA domains (Linux Foundation, 2025 curriculum)

| Domain | Weight |
| --- | --- |
| Troubleshooting | 30% |
| Cluster Architecture, Installation & Configuration | 25% |
| Services & Networking | 20% |
| Workloads & Scheduling | 15% |
| Storage | 10% |

Source: [Linux Foundation, CKA program changes](https://training.linuxfoundation.org/certified-kubernetes-administrator-cka-program-changes/)

## 1. "Pass the CKA Exam: Step-by-Step Roadmap to Become a Kubestronaut"

- **Link:** https://www.youtube.com/watch?v=SuKkL8YjXMg (4 min)
- **Added:** Oct 27, 2026

**Exam format (per the video):** fully hands-on, 2 hours, up to 20 weighted tasks across multiple clusters, 66% to pass, one free retake, certification valid 2 years.

**Tips worth keeping**
1. **kubectl speed is survival.** Drill imperative commands until automatic; copy and paste object names instead of typing them.
2. **Know the docs.** Open book, but only kubernetes.io/docs. Practice finding Ingress, PV/PVC, NetworkPolicy and JSONPath examples in seconds.
3. **Verify every task.** `k get` or `k describe` before moving on.
4. **Troubleshooting is king (30%).** Break your own cluster and fix it; the hardened-k8s incident labs do exactly this.
5. **Time equals points.** Easy wins first, flag the hard ones, never sink 20 minutes into one YAML.
6. **Final prep:** Killercoda CKA scenarios, plus both killer.sh simulators (harder than the real exam).

**Corrections to the video** (checked against the Linux Foundation curriculum page)
- **etcd backup/restore:** correctly dropped from the curriculum. The course still teaches it, and it's still worth knowing for real-world operations.
- **HA and upgrades:** *not* dropped. "Highly available control plane" and "cluster lifecycle management" are still listed under Cluster Architecture (25%).
- **Pod Security Admission:** not named in the CKA curriculum. Closest item is "pod admission and scheduling controls." PSA by name is a CKS topic.

## 2. "Kubernetes Zero to Hero: The Complete Beginner's Guide (2025 Edition)" (Alta3, Chad)

- **Link:** https://www.youtube.com/watch?v=MTHGoGUFpvE (2 hr 50 min)
- **Added:** Oct 28, 2026

**Covers:** cluster architecture, pods and YAML, Deployments, Services (heavy on NodePort), namespaces, Secrets, liveness/readiness probes, a brief look at Ingress. Ends with a pitch for Alta3's paid course.

**Does not cover:** Helm, Kustomize, Gateway API, storage, RBAC, NetworkPolicy, scheduling, kubeadm.

**Verdict:** mostly overlaps Core Concepts and App Lifecycle, which are already done. Not worth course time. The one useful piece is the probes segment (51:09–58:20); see `CKA-Probes-Quick-Reference.md`.

**One exam note from the video:** expect at least one NodePort Service question. A NodePort answers on *any* node's IP, because kube-proxy runs on every node.
