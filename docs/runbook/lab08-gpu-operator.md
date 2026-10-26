# Lab 8: NVIDIA GPU Operator on a cluster with no GPU

**Goal:** install the NVIDIA GPU Operator with Helm, list everything it creates, and
trace exactly why almost nothing runs: no node advertises an NVIDIA PCI device, so the
operator never schedules its GPU components. Then fake a GPU node to watch the gating
open, and see what fails next.

**CKA relevance:** Helm, DaemonSets, node labels and `nodeSelector`, CRDs, and extended
resources (`nvidia.com/gpu`) are all exam-adjacent. The GPU Operator itself is
Mirantis-facing depth; it builds on the GPU hardware troubleshooting Mirantis valued.

## How the operator decides where to run

| Step | Component | What it does |
|---|---|---|
| 1 | Node Feature Discovery (NFD) worker, a DaemonSet on every node | Reads each node's PCI bus and labels the node, e.g. `feature.node.kubernetes.io/pci-1af4.present=true` |
| 2 | GPU Operator (Deployment) | Watches for nodes labelled `feature.node.kubernetes.io/pci-10de.present=true`. `0x10de` is NVIDIA's PCI vendor ID |
| 3 | GPU Operator | Labels each such node `nvidia.com/gpu.present=true` and `nvidia.com/gpu.deploy.<component>=true` |
| 4 | Operand DaemonSets | Each has a `nodeSelector` on its `nvidia.com/gpu.deploy.*` label, so they only schedule onto GPU nodes |
| 5 | Device plugin | Registers `nvidia.com/gpu` with the kubelet, so pods can request GPUs |

On UTM's virtual hardware, step 1 finds only virtio devices (vendor `0x1af4`), so steps
2–5 never happen. The operand DaemonSets want **0** pods, which is correct behaviour,
not a failure.

**Draft corrections applied:** the Helm repo is `https://helm.ngc.nvidia.com/nvidia`,
and without a GPU the operands are mostly not scheduled at all. They do not all sit in
`CrashLoopBackOff`.

## Install settings

| Setting | Value | Why |
|---|---|---|
| Chart | `nvidia/gpu-operator`, version `v26.3.3` | |
| Release name | `gpu-operator` | Keeps resource names short (`gpu-operator-...`) |
| `driver.enabled` | `false` | No GPU to drive; the driver container would also need a kernel-specific image |
| `toolkit.enabled` | `false` | The container toolkit rewrites the node's containerd config. On k0s that config lives under `/etc/k0s/`, not the default path, and changing it on a lab node with no GPU only adds risk |

---

## Pre-check

```bash
export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig && k get nodes && k get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"  gpu="}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
```

**Expected:** both workers `Ready`, and `gpu=` empty on both: no node advertises a GPU.

---

### Step 1: Add the NVIDIA Helm repo

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update nvidia && helm search repo nvidia/gpu-operator --versions | head -4
```

**Expected:** `"nvidia" has been added`, then a table whose rows include
`nvidia/gpu-operator  v26.3.3`.

---

### Step 2: Install the operator

```bash
helm install gpu-operator nvidia/gpu-operator -n gpu-operator --create-namespace --version=v26.3.3 --set driver.enabled=false --set toolkit.enabled=false && k -n gpu-operator rollout status deployment/gpu-operator --timeout=300s
```

This can take ~2–3 min while images pull, don't panic. `--wait` is left off on purpose:
with no GPU node, some resources never become "ready" in Helm's sense and `--wait`
would sit until its timeout.

**Expected:** `STATUS: deployed`, then `deployment "gpu-operator" successfully rolled out`.

**Troubleshooting:** `exec format error` in `k -n gpu-operator logs deploy/gpu-operator`
means an image has no `arm64` build for this version. Check the platform support page
for v26.3, or install the latest chart version that supports `arm64`.

---

### Step 3: List everything the chart created

**Pods:**

```bash
k -n gpu-operator get pods -o wide
```

**Expected (names abbreviated):**

```text
gpu-operator-xxxxxxxxxx-xxxxx                          1/1   Running   worker-0N
gpu-operator-node-feature-discovery-gc-xxxxx           1/1   Running   worker-0N
gpu-operator-node-feature-discovery-master-xxxxx       1/1   Running   worker-0N
gpu-operator-node-feature-discovery-worker-xxxxx       1/1   Running   worker-01
gpu-operator-node-feature-discovery-worker-xxxxx       1/1   Running   worker-02
```

Only the operator and NFD run. There are no driver, device-plugin, DCGM, MIG, or
validator pods.

**DaemonSets and what each would need to schedule:**

```bash
k -n gpu-operator get ds -o custom-columns='NAME:.metadata.name,DESIRED:.status.desiredNumberScheduled,READY:.status.numberReady,NODE-SELECTOR:.spec.template.spec.nodeSelector'
```

**Expected:** the NFD worker with `DESIRED 2`. Operand DaemonSets such as
`nvidia-device-plugin-daemonset`, `nvidia-dcgm-exporter`, `gpu-feature-discovery`,
`nvidia-operator-validator`, and `nvidia-mig-manager` show `DESIRED 0` and a selector
like `map[nvidia.com/gpu.deploy.device-plugin:true]`. Depending on the operator
version, some operand DaemonSets are not created at all until a GPU node appears; an
empty list is the same finding.

**CRDs, RBAC, and the ClusterPolicy:**

```bash
k get crd -o name | grep -E 'nvidia|nfd' && k get clusterrole -o name | grep -E 'gpu-operator|node-feature' && k -n gpu-operator get sa
```

**Expected:**
- CRDs `clusterpolicies.nvidia.com`, `nvidiadrivers.nvidia.com`, and the NFD CRDs
  (`nodefeatures.nfd.k8s-sigs.io`, `nodefeaturerules.nfd.k8s-sigs.io`,
  `nodefeaturegroups.nfd.k8s-sigs.io`).
- ClusterRoles for the operator and for NFD.
- ServiceAccounts for the operator and each NFD component.

```bash
k get clusterpolicy && k get clusterpolicy cluster-policy -o jsonpath='{.status.state}{"\n"}'
```

**Expected:** one `cluster-policy` object. `ClusterPolicy` is the operator's single
desired-state object: everything the operator deploys is configured here (Helm values
end up in it).

---

### Step 4: See what NFD found

```bash
for n in worker-01 worker-02; do echo "== $n"; k get node "$n" -o json | jq -r '.metadata.labels | keys[] | select(startswith("feature.node.kubernetes.io/pci"))'; done
```

**Expected:** labels such as `feature.node.kubernetes.io/pci-1af4.present` on both
workers, and **no** `pci-10de`. `0x1af4` is the virtio vendor ID (Red Hat), which is
what UTM's QEMU backend presents for disk and network. You may also see `pci-1b36`
(QEMU's own devices).

NFD works. It labelled what is there; NVIDIA hardware is not there.

---

### Step 5: Read the gating from the operator

```bash
k -n gpu-operator logs deployment/gpu-operator --tail=300 | grep -i -E 'gpu node|no gpu|nodes with gpu' | tail -5
```

**Expected:** lines saying that no GPU nodes were found and the operator is waiting
for one to join. The exact wording varies between versions.

```bash
k get nodes -L nvidia.com/gpu.present -L nvidia.com/gpu.deploy.device-plugin
```

**Expected:** both workers with empty `GPU.PRESENT` and `GPU.DEPLOY.DEVICE-PLUGIN`
columns. No label means no operand pods.

---

### Step 6: Prove no pod can get a GPU

```bash
k run gpu-test -n gpu-operator --image=busybox:1.37 --restart=Never --overrides='{"spec":{"containers":[{"name":"gpu-test","image":"busybox:1.37","command":["sh","-c","echo got-a-gpu"],"resources":{"limits":{"nvidia.com/gpu":1}}}]}}' && sleep 5 && k -n gpu-operator get pod gpu-test && k -n gpu-operator get events --field-selector involvedObject.name=gpu-test | tail -2
```

**Expected:**

```text
pod/gpu-test created
NAME       READY   STATUS    RESTARTS   AGE
gpu-test   0/1     Pending   0          5s
... FailedScheduling  ... 0/2 nodes are available: 2 Insufficient nvidia.com/gpu ...
```

`nvidia.com/gpu` is an **extended resource**. Only the device plugin can advertise it,
and no device plugin is running.

```bash
k -n gpu-operator delete pod gpu-test
```

---

### Step 7: Fake a GPU node and watch the gate open

Add the label NFD would add on a real NVIDIA node to `worker-02`:

```bash
k label node worker-02 feature.node.kubernetes.io/pci-10de.present=true && sleep 30 && k get node worker-02 -o json | jq -r '.metadata.labels | to_entries[] | select(.key|startswith("nvidia.com/")) | "\(.key)=\(.value)"'
```

**Expected:** within ~30 s the operator adds labels such as:

```text
nvidia.com/gpu.present=true
nvidia.com/gpu.deploy.device-plugin=true
nvidia.com/gpu.deploy.dcgm-exporter=true
nvidia.com/gpu.deploy.gpu-feature-discovery=true
nvidia.com/gpu.deploy.operator-validator=true
...
```

If nothing appears after 60 s, check the operator log from Step 5 for an error about
`worker-02`.

```bash
k -n gpu-operator get pods -o wide --field-selector spec.nodeName=worker-02
```

**Expected:** new pods for the operator validator, device plugin, GPU Feature Discovery,
and DCGM exporter on `worker-02`, stuck in `Init:0/N`, `Init:Error`, or
`Init:CrashLoopBackOff`.

Find out what they are waiting for:

```bash
POD=$(k -n gpu-operator get pods --field-selector spec.nodeName=worker-02 -o name | grep validator | head -1) && echo "$POD" && k -n gpu-operator get "$POD" -o jsonpath='{range .status.initContainerStatuses[*]}{.name}{"  "}{.state}{"\n"}{end}' && k -n gpu-operator logs "$POD" -c driver-validation --tail=10
```

**Expected:** the first init container, `driver-validation`, failing or retrying, with
a log line saying it cannot find the NVIDIA driver or `nvidia-smi`. Every other operand
has an init container that waits for the validator, so the whole stack stops at this
first check. On a real GPU node the validator passes, writes ready files under
`/run/nvidia/validations/`, and the rest start in order.

This is the second gate. The first gate (Step 5) was "is there an NVIDIA PCI device?";
the second is "does the driver work on it?".

**What the device plugin would log:** on a real GPU node it reports finding the GPUs and
registering the `nvidia.com/gpu` resource with the kubelet. On a node where the plugin
starts but finds no devices, it logs that no devices were found and waits. Here it never
gets that far: it is held in its init container behind the validator.

---

### Step 8: Close the gate again

```bash
k label node worker-02 feature.node.kubernetes.io/pci-10de.present- && sleep 45 && k -n gpu-operator get pods -o wide --field-selector spec.nodeName=worker-02 && k get node worker-02 -o json | jq -r '.metadata.labels | keys[] | select(startswith("nvidia.com/"))'
```

**Expected:** the operand pods on `worker-02` terminate and only the NFD worker remains.
The operator removes or sets to `false` its `nvidia.com/gpu.deploy.*` labels. If some
`nvidia.com/` labels remain, remove them by hand:

```bash
k label node worker-02 $(k get node worker-02 -o json | jq -r '.metadata.labels | keys[] | select(startswith("nvidia.com/")) | . + "-"') 2>/dev/null; k get node worker-02 --show-labels | tr ',' '\n' | grep -c 'nvidia.com/' || true
```

**Expected:** `0`.

---

## What changes on a real GPU node

| Without a GPU (this lab) | With an NVIDIA GPU |
|---|---|
| NFD labels `pci-1af4` only | NFD adds `pci-10de.present=true` |
| No `nvidia.com/gpu.deploy.*` labels | Operator labels the node for every enabled operand |
| Operand DaemonSets want 0 pods | One pod per GPU node per operand |
| No `nvidia.com/gpu` resource | Device plugin advertises `nvidia.com/gpu: <count>` |
| GPU pods `Pending: Insufficient nvidia.com/gpu` | GPU pods schedule and see `/dev/nvidia*` |

On a k0s GPU node, enabling the container toolkit also means pointing it at k0s's
containerd configuration instead of the default `/etc/containerd/config.toml`. Check the
k0s and GPU Operator documentation for the current settings before doing that.

---

## Rollback / Clean-up

```bash
helm uninstall gpu-operator -n gpu-operator && k delete namespace gpu-operator
```

**Expected:** `release "gpu-operator" uninstalled`, `namespace "gpu-operator" deleted`.

Helm leaves CRDs behind on uninstall. Remove them:

```bash
k get crd -o name | grep -E 'nvidia\.com|nfd\.k8s-sigs\.io' | xargs -r k delete
```

NFD's labels stay on the nodes after it is gone. Remove them:

```bash
for n in worker-01 worker-02; do L=$(k get node "$n" -o json | jq -r '.metadata.labels | keys[] | select(startswith("feature.node.kubernetes.io/") or startswith("nvidia.com/")) | . + "-"'); [ -n "$L" ] && k label node "$n" $L; done; k get nodes --show-labels | grep -c -E 'feature.node.kubernetes.io|nvidia.com' || true
```

**Expected:** a `node/worker-0N unlabeled` line per worker, then `0`.

**Next:** [cheatsheet.md](cheatsheet.md), [glossary.md](glossary.md), and
[reset.md](reset.md).
