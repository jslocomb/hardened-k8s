# Lab 7: k0rdent on the Mac cluster, one GCP child cluster (torn down the same session)

**Goal:** turn the UTM cluster into a k0rdent management cluster, prove it is healthy on
Apple Silicon with a free pre-flight, then have it provision a 1 control-plane + 1
worker k0s cluster in GCP, use it, and delete it with nothing left behind.

**CKA relevance:** none directly; this is Mirantis-facing depth. k0rdent is built on
Cluster API (CAPI), which is how Mirantis manages fleets of k0s clusters. Kubeconfig
handling and Secrets are the CKA-adjacent parts.

## Before you start

| Item | Value |
|---|---|
| k0rdent | Open-source chart `oci://ghcr.io/k0rdent/kcm/charts/kcm`, version `1.11.0` |
| Providers kept | `cluster-api-provider-k0sproject-k0smotron`, `cluster-api-provider-gcp`, `projectsveltos` (the default installs 11) |
| GCP region | `us-west2` (Los Angeles) |
| Child cluster | 1 control plane + 1 worker, `e2-standard-2` (2 vCPU / 8 GB), Ubuntu 24.04 amd64 |
| GCP network | `k0rdent-lab`, created and deleted by k0rdent, so teardown cannot touch your `default` network |
| Estimated cost | About $0.20–0.30 per hour while the child cluster runs (2 VMs, a load balancer, disks, IPs). Billed to the $300 trial credit. This is an estimate; the budget alert in Step 9 is the real guard |
| Session length | About 2 hours, of which the child cluster exists for about 45 minutes |

### Caveat: memory, and where the k0rdent pods run

A k0s `controller` runs no kubelet (Lab 2), so **no pods run on it**. Every k0rdent pod
lands on the two workers. This lab therefore grows the **workers**, not the controller.

| VM | Labs 2–6 | Lab 7 |
|---|---|---|
| controller | 2 vCPU / 4 GB | 2 vCPU / 4 GB |
| worker-01 | 2 vCPU / 4 GB | 2 vCPU / **6 GB** |
| worker-02 | 2 vCPU / 4 GB | 2 vCPU / **6 GB** |
| macOS + UTM overhead (estimate) | ~5 GB | ~5 GB |
| **Total of 32 GB** | **~17 GB** | **~21 GB** (~11 GB headroom) |

`a0` must stay stopped. 6 GB per worker is an estimate: k0rdent publishes no minimum
size. The pre-flight (Steps 1–5) measures real usage before anything is created in GCP.

### Caveat: Apple Silicon

Every image the management cluster runs needs an `arm64` build. The k0rdent controller
is built for `arm64`; the provider images are not all confirmed. A missing build shows
up as a pod failing with `exec format error`. The pre-flight finds this at $0 cost. If
it fails, use the fallback at the end of this lab.

---

## Pre-check

```bash
export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig && k get nodes && k version | grep Server && utmctl status Linux
```

**Expected:** `worker-01` and `worker-02` `Ready`, `Server Version: v1.36.4+k0s`, and
`stopped` for `a0`. If Labs 4–6 left namespaces behind, delete them now:
`k delete namespace web-app client debugger dns-lab --ignore-not-found`.

---

## Part A: free pre-flight on the Mac cluster

### Step 1: Grow each worker to 6 GB, one at a time

Draining first moves pods off cleanly; this is the CKA maintenance pattern.

```bash
k drain worker-01 --ignore-daemonsets --delete-emptydir-data && utmctl stop worker-01 && sleep 10 && utmctl status worker-01
```

**Expected:** `node/worker-01 drained`, then `stopped`.

In UTM: select `worker-01` → **Edit** (settings icon) → **System** → **Memory** `6144`
MiB → **Save**. Then:

```bash
utmctl start worker-01 && k wait --for=condition=Ready node/worker-01 --timeout=300s && k uncordon worker-01 && ssh worker-01 'free -g | awk "/Mem:/{print \$2\" GB\"}"'
```

**Expected:** `condition met`, `node/worker-01 uncordoned`, `5 GB` (the guest sees a
little less than 6).

Repeat for `worker-02`:

```bash
k drain worker-02 --ignore-daemonsets --delete-emptydir-data && utmctl stop worker-02 && sleep 10 && utmctl status worker-02
```

Set `worker-02` to `6144` MiB in UTM the same way, then:

```bash
utmctl start worker-02 && k wait --for=condition=Ready node/worker-02 --timeout=300s && k uncordon worker-02 && k get nodes
```

**Expected:** both workers `Ready`, neither `SchedulingDisabled`.

**Troubleshooting:** a drain that hangs on CoreDNS is the Lab 6 anti-affinity rule: the
CoreDNS replica has nowhere else to go, so its PodDisruptionBudget blocks eviction.
Add `--disable-eviction` to delete it directly; the ReplicaSet recreates it when the
worker returns.

---

### Step 2: Install k0rdent

```bash
helm install kcm oci://ghcr.io/k0rdent/kcm/charts/kcm --version 1.11.0 -n kcm-system --create-namespace
```

**Expected:** `STATUS: deployed` within ~1 min. The chart installs the k0rdent
controller, Flux, and supporting components; the controller then creates the
`Management` object, which installs the providers.

---

### Step 3: Trim the providers to the three this lab needs

The default `Management` object installs 11 infrastructure providers (AWS, Azure,
vSphere, OpenStack and more). Each is another controller to fit in memory and another
image that must exist for `arm64`. Replace the list as soon as the object appears.

```bash
until k get management kcm >/dev/null 2>&1; do sleep 5; done; k patch management kcm --type=merge -p '{"spec":{"providers":[{"name":"cluster-api-provider-k0sproject-k0smotron"},{"name":"cluster-api-provider-gcp"},{"name":"projectsveltos"}]}}' && k get management kcm -o jsonpath='{range .spec.providers[*]}{.name}{"\n"}{end}'
```

**Expected:**

```text
management.k0rdent.mirantis.com/kcm patched
cluster-api-provider-k0sproject-k0smotron
cluster-api-provider-gcp
projectsveltos
```

A merge patch replaces the whole list, so the other eight are removed. k0smotron supplies
the k0s control plane and bootstrap; Sveltos copies the GCP credential into the child
cluster (Step 12).

---

### Step 4: Wait for the management cluster to be ready

```bash
k wait --for=condition=Ready management/kcm --timeout=20m && k get management kcm
```

This can take ~10–15 min, don't panic. Watch progress from a second terminal:

```bash
export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig && watch -n 10 'kubectl get pods -A --no-headers | grep -v -E "kube-system" | awk "{print \$1, \$2, \$4}" | column -t'
```

**Expected:**

```text
management.k0rdent.mirantis.com/kcm condition met
NAME   READY   RELEASE      AGE
kcm    True    kcm-1-11-0   14m
```

---

### Step 5: The pre-flight gate

All four checks must pass before you create anything in GCP.

**Check 1: nothing is stuck.**

```bash
k get pods -A --no-headers | grep -v -E 'Running|Completed' || echo "PASS: all pods Running or Completed"
```

**Expected:** `PASS: all pods Running or Completed`. Run it twice, 5 minutes apart: a
pod that restarts in a loop can look `Running` for a moment.

**Check 2: no architecture failures.**

```bash
for p in $(k get pods -A --no-headers | awk '{print $1"/"$2}'); do k -n "${p%%/*}" logs "${p##*/}" --all-containers --tail=20 2>/dev/null | grep -q 'exec format error' && echo "ARCH FAIL: $p"; done; echo "check 2 done"
```

**Expected:** only `check 2 done`. Any `ARCH FAIL:` line names an image with no `arm64`
build: stop and use the fallback.

**Check 3: restarts are low.**

```bash
k get pods -A --no-headers | awk '$5+0 > 3 {print "HIGH RESTARTS:", $1, $2, $5}'; echo "check 3 done"
```

**Expected:** only `check 3 done`.

**Check 4: memory headroom.**

```bash
k top nodes
```

**Expected:** `MEMORY%` below about 80% on both workers. Above that, the child-cluster
reconcile in Part C can push a worker into memory pressure and evictions.

Also confirm the GCP template is installed and valid:

```bash
k get clustertemplate -n kcm-system | grep -E 'NAME|gcp-standalone'
```

**Expected:** a `gcp-standalone-cp-1-0-NN` row with `VALID` `true`.

**Gate result:** all four checks pass → continue to Part B. Any failure → the fallback
at the end of this lab. Either way, record the result: it is useful evidence.

```bash
mkdir -p ~/Projects/hardened-k8s/manifests/labs/lab07 && { date; k get management kcm; k top nodes; k get pods -A -o wide; } > ~/Projects/hardened-k8s/manifests/labs/lab07/preflight.txt 2>&1 && echo saved
```

---

## Part B: GCP project and credentials

### Step 6: Install and log in to `gcloud`

```bash
brew install --cask google-cloud-sdk && gcloud auth login && gcloud config list account
```

**Expected:** a browser sign-in, then `account = <your Google account>`. Activate the
$300 trial at <https://cloud.google.com/free-trial/> first if you have not.

---

### Step 7: Create a dedicated lab project

Project IDs are global, so a random suffix avoids collisions. The variables are saved
to a file so every new terminal can load them.

```bash
mkdir -p ~/.config/hardened-k8s && cat > ~/.config/hardened-k8s/gcp.env << EOF
export GCP_PROJECT=hk8s-lab-$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)
export GCP_REGION=us-west2
export GCP_SA=k0rdent-capg
EOF
source ~/.config/hardened-k8s/gcp.env && echo "$GCP_PROJECT" && gcloud projects create "$GCP_PROJECT" --name="hardened-k8s lab" && gcloud config set project "$GCP_PROJECT"
```

This heredoc uses unquoted `EOF` on purpose, so the random suffix is generated once and
written into the file.

**Expected:** a project ID such as `hk8s-lab-3kq9xz`, `Create in progress ... finished
successfully`, and `Updated property [core/project]`.

---

### Step 8: Link billing and enable the Compute Engine API

```bash
gcloud billing accounts list
```

**Expected:** one row with an `ACCOUNT_ID` like `0X0X0X-0X0X0X-0X0X0X` and `OPEN True`
(the trial billing account).

```bash
source ~/.config/hardened-k8s/gcp.env && BILLING=$(gcloud billing accounts list --filter=open=true --format='value(name)' | head -1 | sed 's#billingAccounts/##') && echo "export GCP_BILLING=$BILLING" >> ~/.config/hardened-k8s/gcp.env && gcloud billing projects link "$GCP_PROJECT" --billing-account="$BILLING" && gcloud services enable compute.googleapis.com
```

This can take ~1–2 min for the API to enable.

**Verify:**

```bash
source ~/.config/hardened-k8s/gcp.env && gcloud billing projects describe "$GCP_PROJECT" --format='value(billingEnabled)' && gcloud services list --enabled --filter=name:compute.googleapis.com --format='value(name)'
```

**Expected:** `True` and `compute.googleapis.com`.

---

### Step 9: Budget alert and quota check

A budget alert emails you at 50%, 90%, and 100% of $10. It does not stop spending; it
tells you something was left running.

```bash
source ~/.config/hardened-k8s/gcp.env && gcloud services enable billingbudgets.googleapis.com && gcloud billing budgets create --billing-account="$GCP_BILLING" --display-name="hk8s-lab-guard" --budget-amount=10USD --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0 --filter-projects="projects/$GCP_PROJECT"
```

**Expected:** a `name: billingAccounts/.../budgets/...` block. If the command fails on
permissions, create the same budget in the console: **Billing → Budgets & alerts →
Create budget**.

The child cluster needs 4 vCPUs in `us-west2`:

```bash
source ~/.config/hardened-k8s/gcp.env && gcloud compute regions describe "$GCP_REGION" --format=json | jq -r '.quotas[] | select(.metric=="CPUS" or .metric=="IN_USE_ADDRESSES" or .metric=="DISKS_TOTAL_GB") | "\(.metric) used=\(.usage) limit=\(.limit)"'
```

**Expected:** `CPUS used=0 limit=8` or higher (trial accounts often have 8), and
address and disk limits above zero.

---

### Step 10: Service account and key

k0rdent needs a service account with **Editor** and **Service Account Token Creator**.
The JSON key is a long-lived credential: it is stored outside the repo with `0600`
permissions and deleted in Step 17.

```bash
source ~/.config/hardened-k8s/gcp.env && gcloud iam service-accounts create "$GCP_SA" --display-name="k0rdent CAPG lab" && SA_EMAIL="$GCP_SA@$GCP_PROJECT.iam.gserviceaccount.com" && for role in roles/editor roles/iam.serviceAccountTokenCreator; do gcloud projects add-iam-policy-binding "$GCP_PROJECT" --member="serviceAccount:$SA_EMAIL" --role="$role" --condition=None --format='value(etag)' >/dev/null && echo "granted $role"; done
```

**Expected:** `Created service account [k0rdent-capg].`, `granted roles/editor`,
`granted roles/iam.serviceAccountTokenCreator`.

```bash
source ~/.config/hardened-k8s/gcp.env && umask 077 && gcloud iam service-accounts keys create ~/.config/hardened-k8s/k0rdent-capg.json --iam-account="$GCP_SA@$GCP_PROJECT.iam.gserviceaccount.com" && ls -l ~/.config/hardened-k8s/k0rdent-capg.json
```

**Expected:** `created key [...]` and `-rw-------` on the file.

**Security note:** Editor on a throwaway project is acceptable for a lab. In production,
scope a custom role to the Compute permissions CAPG uses, and prefer Workload Identity
Federation over a JSON key.

**Troubleshooting:** `Key creation is not allowed on this service account` means an
organization policy (`iam.disableServiceAccountKeyCreation`) applies. Personal Google
accounts have no organization; if this account belongs to one, use a personal account
for the lab.

---

### Step 11: Hand the credential to k0rdent

Three objects: a Secret holding the key, a `Credential` that k0rdent references, and a
template that copies the key into the child cluster for its cloud controller.

```bash
k -n kcm-system create secret generic gcp-cloud-sa --from-file=credentials=$HOME/.config/hardened-k8s/k0rdent-capg.json && k -n kcm-system label secret gcp-cloud-sa k0rdent.mirantis.com/component=kcm
```

**Expected:** `secret/gcp-cloud-sa created`, `secret/gcp-cloud-sa labeled`.
`--from-file` does the base64 encoding, so macOS vs GNU `base64` flags never come up.

```bash
cd ~/Projects/hardened-k8s/manifests/labs/lab07 && cat > 10-gcp-credential.yaml << 'EOF'
apiVersion: k0rdent.mirantis.com/v1beta1
kind: Credential
metadata:
  name: gcp-credential
  namespace: kcm-system
spec:
  identityRef:
    apiVersion: v1
    kind: Secret
    name: gcp-cloud-sa
    namespace: kcm-system
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: gcp-cloud-sa-resource-template
  namespace: kcm-system
  labels:
    k0rdent.mirantis.com/component: "kcm"
  annotations:
    projectsveltos.io/template: "true"
data:
  configmap.yaml: |
    {{- $secret := (getResource "InfrastructureProviderIdentity") -}}
    ---
    apiVersion: v1
    kind: Secret
    metadata:
      name: gcp-cloud-sa
      namespace: kube-system
    type: Opaque
    data:
      cloud-sa.json: {{ index $secret "data" "credentials" }}
EOF
k apply -f 10-gcp-credential.yaml && k -n kcm-system get credential gcp-credential
```

**Expected:** `credential.../gcp-credential created`, `configmap/... created`, then the
Credential with `READY` `true`. The `{{ }}` lines are a Sveltos template, rendered by
k0rdent, not by your shell; the quoted `'EOF'` keeps them literal.

The ConfigMap name must be the Secret name plus `-resource-template`.

---

## Part C: create, use, and delete the child cluster

### Step 12: Write the ClusterDeployment

```bash
source ~/.config/hardened-k8s/gcp.env && TEMPLATE=$(k get clustertemplate -n kcm-system --no-headers | awk '/^gcp-standalone-cp/{print $1}' | sort -V | tail -1) && echo "template: $TEMPLATE" && cd ~/Projects/hardened-k8s/manifests/labs/lab07 && cat > 20-gcp-lab.yaml << EOF
apiVersion: k0rdent.mirantis.com/v1beta1
kind: ClusterDeployment
metadata:
  name: gcp-lab
  namespace: kcm-system
spec:
  template: $TEMPLATE
  credential: gcp-credential
  config:
    project: "$GCP_PROJECT"
    region: "$GCP_REGION"
    controlPlaneNumber: 1
    workersNumber: 1
    network:
      name: k0rdent-lab
    controlPlane:
      instanceType: e2-standard-2
      imageFamily: projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64
      publicIP: true
    worker:
      instanceType: e2-standard-2
      imageFamily: projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64
      publicIP: true
EOF
cat 20-gcp-lab.yaml
```

**Expected:** `template: gcp-standalone-cp-1-0-NN` and the manifest with your project ID
filled in. Unquoted `EOF` here fills in the variables. The file contains a project ID
but no secrets, so it is safe to commit.

Notes on the choices:
- `controlPlaneNumber: 1` and `workersNumber: 1` override the template defaults of 3 and 2.
- The child VMs are `amd64` (normal GCP machines). Only the management cluster is ARM64.
- `network.name: k0rdent-lab` makes CAPG create a new VPC, firewall rules, and load
  balancer that it also deletes in Step 16.

---

### Step 13: Create it and watch it build

```bash
k apply -f ~/Projects/hardened-k8s/manifests/labs/lab07/20-gcp-lab.yaml && date +%T
```

This can take ~10–15 min, don't panic. Note the time: the cost clock starts now.

Watch from a second terminal:

```bash
export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig && watch -n 15 'kubectl -n kcm-system get clusterdeployment gcp-lab; echo; kubectl -n kcm-system get cluster,gcpcluster,machines 2>/dev/null'
```

And from the GCP side:

```bash
source ~/.config/hardened-k8s/gcp.env && gcloud compute instances list && gcloud compute forwarding-rules list
```

**Expected progression:**
1. `GCPCluster` becomes ready: the `k0rdent-lab` network, firewall rules, and the API
   load balancer exist.
2. A `Machine` for the control plane goes `Provisioning` → `Provisioned` → `Running`.
3. The worker `Machine` follows.
4. The ClusterDeployment shows `READY` `True`.

```text
NAME      READY   STATUS
gcp-lab   True    ClusterDeployment is ready
```

**Troubleshooting:**
- Stuck with a `Machine` in `Provisioning` for more than 10 min: read the provider log.
  `k get pods -A | grep -i capg` finds it, then
  `k -n <namespace> logs <capg-pod> --tail=50 | grep -i error`. `QUOTA_EXCEEDED` means
  Step 9's quota is too low; `PERMISSION_DENIED` means a missing role from Step 10.
- `k -n kcm-system describe clusterdeployment gcp-lab` shows template validation errors,
  such as a misspelled field.

---

### Step 14: Use the child cluster

```bash
k -n kcm-system get secret gcp-lab-kubeconfig -o jsonpath='{.data.value}' | base64 -d > ~/.kube/gcp-lab.kubeconfig && chmod 600 ~/.kube/gcp-lab.kubeconfig && KUBECONFIG=~/.kube/gcp-lab.kubeconfig kubectl get nodes -o wide
```

**Expected:** the worker node (`gcp-lab-md-...`) `Ready`, with an `amd64`-built Ubuntu
24.04 image and a `v1.36.x+k0s` kubelet. The control-plane VM does not appear if the
template runs it as a pure k0s controller, the same as your UTM controller.

```bash
KUBECONFIG=~/.kube/gcp-lab.kubeconfig kubectl get pods -A && KUBECONFIG=~/.kube/gcp-lab.kubeconfig kubectl -n kube-system get secret gcp-cloud-sa
```

**Expected:** system pods `Running` (Calico, CoreDNS, the GCP cloud controller manager,
konnectivity), and the `gcp-cloud-sa` Secret that Sveltos copied in from Step 11.

The child uses **Calico**, not kube-router: the GCP template's default. Two CNIs across
two clusters is normal in a fleet.

Run a workload to prove it is a real cluster:

```bash
KUBECONFIG=~/.kube/gcp-lab.kubeconfig kubectl create deployment hello --image=nginx:1.27-alpine && KUBECONFIG=~/.kube/gcp-lab.kubeconfig kubectl rollout status deployment/hello --timeout=180s && KUBECONFIG=~/.kube/gcp-lab.kubeconfig kubectl get pods -o wide
```

**Expected:** `successfully rolled out`, one `hello-...` pod on the GCP worker.

Save evidence before teardown:

```bash
{ date; k -n kcm-system get clusterdeployment gcp-lab -o wide; k -n kcm-system get cluster,machines; KUBECONFIG=~/.kube/gcp-lab.kubeconfig kubectl get nodes,pods -A -o wide; } > ~/Projects/hardened-k8s/manifests/labs/lab07/child-cluster.txt 2>&1 && echo saved
```

---

### Step 15: What k0rdent manages vs what k0s manages

| Layer | Owner | Seen in this lab as |
|---|---|---|
| Cloud infrastructure (VPC, firewall, load balancer, VMs) | k0rdent via CAPG | `GCPCluster`, `GCPMachine` objects |
| Cluster lifecycle (create, scale, upgrade, delete) | k0rdent via CAPI + k0smotron | `ClusterDeployment`, `Machine`, `K0sControlPlane` |
| What runs in every child (credentials, add-ons) | k0rdent via Sveltos | the `gcp-cloud-sa` Secret copied in |
| Kubernetes inside each node (API server, etcd, kubelet, containerd) | k0s | the same k0s you ran by hand in Labs 2–6 |

Scaling is a desired-state change, the same as a Deployment. Optional, if quota allows:

```bash
k -n kcm-system patch clusterdeployment gcp-lab --type=merge -p '{"spec":{"config":{"workersNumber":2}}}'
```

k0rdent creates a second worker VM in ~5 min. Patch back to `1` before teardown, or
leave it; Step 16 deletes everything.

---

### Step 16: Tear down (same session)

```bash
k -n kcm-system delete clusterdeployment gcp-lab --wait=true && date +%T
```

This can take ~5–10 min, don't panic. k0rdent deletes the VMs, then the load balancer,
firewall rules, and the `k0rdent-lab` VPC.

**Verify, from both sides:**

```bash
k -n kcm-system get clusterdeployment,cluster,machines 2>&1 | tail -3
```

**Expected:** `No resources found in kcm-system namespace.`

```bash
source ~/.config/hardened-k8s/gcp.env && for r in instances disks forwarding-rules target-tcp-proxies backend-services health-checks addresses firewall-rules routers networks; do printf '%-20s ' "$r"; gcloud compute $r list --format='value(name)' 2>/dev/null | grep -v '^default' | tr '\n' ' '; echo; done
```

**Expected:** every line empty after the name, except `firewall-rules` and `networks`
may list GCP's own `default-*` rules and `default` network, which the `grep` filters
out. Anything else is a leftover that costs money.

**Belt and braces:** if anything remains, delete it by hand, for example:

```bash
source ~/.config/hardened-k8s/gcp.env && gcloud compute instances list --format='value(name,zone.basename())' | while read -r n z; do gcloud compute instances delete "$n" --zone="$z" --quiet; done
```

---

### Step 17: Remove the credential

```bash
source ~/.config/hardened-k8s/gcp.env && SA_EMAIL="$GCP_SA@$GCP_PROJECT.iam.gserviceaccount.com" && for key in $(gcloud iam service-accounts keys list --iam-account="$SA_EMAIL" --managed-by=user --format='value(name)'); do gcloud iam service-accounts keys delete "$key" --iam-account="$SA_EMAIL" --quiet; done && rm -P ~/.config/hardened-k8s/k0rdent-capg.json && k -n kcm-system delete secret gcp-cloud-sa && rm -f ~/.kube/gcp-lab.kubeconfig && echo "credential removed"
```

**Expected:** `Deleted key [...]`, `secret "gcp-cloud-sa" deleted`, `credential removed`.
`rm -P` overwrites the file before deleting it (macOS).

To run Lab 7 again later, repeat Steps 10–11 for a fresh key.

Commit the evidence:

```bash
cd ~/Projects/hardened-k8s && git add manifests/labs/lab07 && git commit -m "lab07: k0rdent GCP child cluster manifests and evidence"
```

---

## Fallback: management cluster on a GCP VM

Use this if the Step 5 gate fails. The child-cluster steps (Part B Steps 6–11, Part C)
do not change; only where the management cluster runs does.

1. Complete Steps 6–9 (gcloud, project, billing, budget).
2. Create an `amd64` VM: `e2-standard-4` (4 vCPU / 16 GB), Ubuntu 24.04, 50 GB disk.
   About $0.15 per hour of credit, on top of the child cluster.
3. On it, install single-node k0s as on `a0`:
   `curl -sSf https://get.k0s.sh | sudo sh && sudo k0s install controller --single && sudo k0s start`.
4. Copy its admin kubeconfig to the Mac over SSH (`gcloud compute ssh`), point
   `KUBECONFIG` at it, and run Steps 2–5 and 10–17 against it.
5. Delete the VM in Step 16 with the rest.

`--single` matters here: unlike your UTM controller, it runs pods, so k0rdent fits on one
VM.

---

## Rollback / Clean-up

Remove k0rdent from the management cluster (after Step 16 has deleted every
ClusterDeployment, or CAPG can no longer clean up GCP):

```bash
k get clusterdeployment -A --no-headers 2>/dev/null | wc -l
```

**Expected:** `0`. Only then:

```bash
helm uninstall kcm -n kcm-system && k delete namespace kcm-system --wait=false && k get crd -o name | grep -E 'k0rdent|cluster.x-k8s.io|projectsveltos|fluxcd' | xargs -r k delete
```

**Expected:** `release "kcm" uninstalled`, then many `customresourcedefinition ... deleted`.
Namespaces created by the providers clear within a few minutes.

Delete the whole GCP project (removes anything missed, and stops all billing for it):

```bash
source ~/.config/hardened-k8s/gcp.env && gcloud projects delete "$GCP_PROJECT" --quiet && rm ~/.config/hardened-k8s/gcp.env
```

Return workers to 4 GB if you want the Labs 2–6 footprint back: repeat Step 1 with
`4096` MiB.

**Next:** Lab 8 installs the NVIDIA GPU Operator on a cluster with no GPU.
