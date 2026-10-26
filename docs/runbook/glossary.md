# Glossary

Terms as they are used in Labs 1–8. The lab where each one matters most is in brackets.

| Term | Meaning |
|---|---|
| **k0s** | Mirantis's Kubernetes distribution, shipped as one binary. Control-plane components run as host processes under `k0scontroller`; the kubelet and containerd run under `k0sworker`. A pure `controller` runs no pods and does not appear in `kubectl get nodes` [Lab 2] |
| **k0sctl** | Runs on the Mac and installs, upgrades, backs up, and resets k0s clusters over SSH from one `k0sctl.yaml`. Upgrade = change `spec.k0s.version` and re-run `k0sctl apply` [Labs 2–3] |
| **k0s backup / k0s restore** | `k0s backup` archives the PKI, the etcd (or kine) snapshot, `k0s.yaml`, and k0s-managed manifests from a controller. It has no passphrase; encrypt by piping through `gpg`. `k0s restore` restores onto a controller and only onto the same k0s version. `k0sctl backup` and `k0sctl apply --restore-from` wrap both. PersistentVolume data is not included [Lab 3] |
| **k0rdent** | Mirantis's open-source multi-cluster manager. It turns one Kubernetes cluster into a management cluster that creates, upgrades, and deletes child clusters on clouds and on-prem, built on Cluster API, k0smotron, and Sveltos [Lab 7] |
| **ClusterDeployment** | The k0rdent object that declares one child cluster: which template, which credential, and the template's settings (region, machine sizes, counts). Delete it and k0rdent deletes the cluster and its cloud resources [Lab 7] |
| **Credential (k0rdent)** | A k0rdent object that points at the Secret holding cloud credentials, so ClusterDeployments can refer to it by name [Lab 7] |
| **Cluster API (CAPI)** | The Kubernetes project that manages clusters as Kubernetes objects (`Cluster`, `Machine`). Infrastructure providers such as CAPG (GCP) do the cloud work [Lab 7] |
| **NetworkPolicy** | A namespaced object that limits which traffic reaches (Ingress) or leaves (Egress) selected pods. A pod no policy selects allows everything; once selected, only explicitly allowed traffic passes. Policies only add allows. Enforced by the CNI; here, kube-router [Lab 4] |
| **kube-router** | k0s's default CNI. Routes pod traffic, and with `--run-firewall` enforces NetworkPolicy with iptables chains and ipsets. Logs dropped packets to NFLOG group 100 [Lab 4] |
| **CoreDNS** | The cluster DNS server: a `Deployment` in `kube-system` behind the `kube-dns` Service (`10.96.0.10` here). Answers `cluster.local` names from the API and forwards everything else upstream. Image pulls never use it [Lab 5] |
| **Taint-based eviction** | When a node stops reporting (~50 s), it gets `node.kubernetes.io/unreachable` (or `not-ready`) `NoExecute` taints. Pods are evicted once their `tolerationSeconds` expires: 300 s by default, added to every pod by the `DefaultTolerationSeconds` admission plugin. Replaced the removed `--pod-eviction-timeout` flag [Lab 6] |
| **NVIDIA GPU Operator** | Installs and manages everything a GPU node needs, configured through one `ClusterPolicy` object. Its components run only on nodes NFD has marked as having an NVIDIA device [Lab 8] |
| **GPU Operator: driver** | Container that installs the NVIDIA kernel driver on the node. Disabled in Lab 8 [Lab 8] |
| **GPU Operator: container toolkit** | Configures the node's container runtime so containers can use the GPU. Disabled in Lab 8 because it rewrites containerd config [Lab 8] |
| **GPU Operator: device plugin** | Advertises `nvidia.com/gpu` as a schedulable resource to the kubelet. Without it, any pod requesting a GPU stays `Pending` [Lab 8] |
| **GPU Operator: GPU Feature Discovery (GFD)** | Adds detailed GPU labels (model, memory, MIG capability) to GPU nodes [Lab 8] |
| **GPU Operator: DCGM exporter** | Exports GPU metrics (utilization, temperature, errors) for Prometheus [Lab 8] |
| **GPU Operator: MIG manager** | Partitions supported GPUs into Multi-Instance GPU slices [Lab 8] |
| **GPU Operator: operator validator** | Checks driver, toolkit, and CUDA in order; every other operand waits on it in an init container [Lab 8] |
| **node-feature-discovery (NFD)** | A DaemonSet that inspects each node's hardware and labels it, e.g. `feature.node.kubernetes.io/pci-10de.present=true` for an NVIDIA device. The GPU Operator keys everything off that label [Lab 8] |
