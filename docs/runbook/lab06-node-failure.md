# Lab 6: Power off a worker mid-workload

**Goal:** hard power-off `worker-02` while a 3-replica Deployment runs, record the exact
timeline from `NotReady` to taint to eviction to rescheduling, bring the node back, then
repeat the failure with only the worker service stopped.

**CKA relevance:** node `NotReady` troubleshooting, taints and tolerations, and
`drain`/`cordon` are all on the curriculum (Troubleshooting 30%, Workloads & Scheduling
15%). This lab is the evidence run for **incident #2 (Node NotReady)**. Part B is the
kubelet/runtime failure that incident is named after.

## What happens when a node disappears

| Time after power-off | Who acts | What you see |
|---|---|---|
| 0 s | | kubelet stops sending heartbeats (it normally renews its Lease every 10 s) |
| ~50 s | node lifecycle controller (`node-monitor-grace-period`) | Node `NotReady` (condition `Unknown`); taints `node.kubernetes.io/unreachable` `NoSchedule` and `NoExecute` added; its pods marked `Ready=False` and removed from Service endpoints |
| ~50 s + 300 s | taint manager (`tolerationSeconds: 300`) | Pods on the node are deleted; the ReplicaSet creates replacements on healthy nodes |
| Node back | kubelet | Node `Ready`, taints removed, old pods finally cleaned up. Running pods are **not** moved back |

Two numbers to know:
- **50 s** is the `kube-controller-manager` default for `--node-monitor-grace-period`
  in current Kubernetes (older docs and blog posts say 40 s). k0s does not change it.
- **300 s** comes from the `DefaultTolerationSeconds` admission plugin, which adds two
  `NoExecute` tolerations with `tolerationSeconds: 300` to every pod that does not set
  its own. There is no `--pod-eviction-timeout` any more; taint-based eviction replaced it.

So service traffic recovers at about 50 s (bad endpoints are removed), but full capacity
only returns at about 6 minutes, when replacements start.

---

## Pre-check

```bash
export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig && k get nodes && k -n kube-system get deploy coredns
```

**Expected:** both workers `Ready`, `coredns 2/2`. If Lab 5 left CoreDNS at `0/0`, run
the Lab 5 Rollback block first.

---

### Step 1: Deploy the workload

```bash
mkdir -p ~/Projects/hardened-k8s/manifests/labs/lab06 && cd ~/Projects/hardened-k8s/manifests/labs/lab06 && cat > web.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: web-app
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: web-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 10
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: web-app
spec:
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 80
EOF
k apply -f web.yaml && k -n web-app rollout status deployment web --timeout=120s && k -n web-app get pods -o wide
```

**Expected:** `deployment "web" successfully rolled out`, then three `web-...` pods
`Running` `1/1`, split 2/1 across `worker-01` and `worker-02`.

If all three landed on `worker-01`, rebalance before continuing:

```bash
k -n web-app rollout restart deployment web && k -n web-app rollout status deployment web && k -n web-app get pods -o wide
```

---

### Step 2: Record the starting state

```bash
k -n web-app get pod -l app=web -o jsonpath='{range .items[0].spec.tolerations[*]}{.key}{"  "}{.effect}{"  "}{.tolerationSeconds}{"\n"}{end}'
```

**Expected:**

```text
node.kubernetes.io/not-ready  NoExecute  300
node.kubernetes.io/unreachable  NoExecute  300
```

These are the tolerations `DefaultTolerationSeconds` added. Your manifest did not
contain them.

```bash
k -n web-app get endpointslices -l kubernetes.io/service-name=web -o wide && k -n kube-system get pods -l k8s-app=kube-dns -o wide
```

**Expected:** the EndpointSlice lists three pod IPs; one CoreDNS pod on each worker.

---

### Step 3: Start the timeline recorder (Terminal 2)

Open a **second terminal**. This loop writes timestamped snapshots to a file, which is
the incident timeline evidence.

```bash
export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig && while true; do echo "=== $(date +%T)"; kubectl get node worker-02 --no-headers; kubectl get node worker-02 -o jsonpath='taints: {.spec.taints[*].key}{"\n"}'; kubectl -n web-app get pods -o wide --no-headers; kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide --no-headers; sleep 10; done 2>&1 | tee ~/Projects/hardened-k8s/manifests/labs/lab06/timeline-poweroff.txt
```

Leave it running. `watch` would also work, but it does not keep a history.

---

### Step 4: Pull the plug on `worker-02` (Terminal 1)

The sysrq `o` trigger powers the VM off immediately, without a clean shutdown. That is
the closest thing to pulling the power cable: the kubelet never says goodbye.

```bash
date +%T; ssh -o ServerAliveInterval=2 -o ServerAliveCountMax=2 worker-02 'echo o | sudo tee /proc/sysrq-trigger' ; utmctl status worker-02
```

**Expected:** a timestamp (write it down as T0), the SSH session ends with
`Connection to 192.168.64.12 closed` or a timeout after ~5 s, then `stopped`.

**Alternative:** in the UTM window for `worker-02`, click the **Stop** (power) button in
the toolbar and confirm the force stop. A graceful `sudo poweroff` is a different test:
the kubelet does a graceful node shutdown first, if configured.

---

### Step 5: Watch the first ~60 seconds

Watch Terminal 2. Then, from Terminal 1:

```bash
k get node worker-02 -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{"  "}{.reason}{"  "}{.message}{"\n"}{end}' && k get node worker-02 -o jsonpath='{range .spec.taints[*]}{.key}{"  "}{.effect}{"  "}{.timeAdded}{"\n"}{end}'
```

**Expected (once ~50 s have passed since T0):**

```text
Unknown  NodeStatusUnknown  Kubelet stopped posting node status.
node.kubernetes.io/unreachable  NoSchedule
node.kubernetes.io/unreachable  NoExecute  2026-10-26T21:05:51Z
```

`Unknown`, not `False`: the controller does not know the node's state, it only knows the
node stopped reporting. That is why the taint is `unreachable`, not `not-ready`.

```bash
k -n web-app get pods -o wide && k -n web-app get endpointslices -l kubernetes.io/service-name=web -o wide
```

**Expected:**
- The pod(s) on `worker-02` still show `Running` but `0/1` READY. The API has no newer
  information; the node controller set `Ready=False` on them.
- The EndpointSlice now lists only the `worker-01` pod IPs.

Service traffic is healthy again from this point, on reduced capacity:

```bash
k -n web-app run probe --image=curlimages/curl:8.10.1 --rm -i --restart=Never -- sh -c 'for i in 1 2 3 4 5; do curl -s -m 2 -o /dev/null -w "%{http_code} " http://web; done; echo'
```

**Expected:** `200 200 200 200 200`, then `pod "probe" deleted`. If the probe pod is
scheduled while `worker-02` is still `Ready`, it can land there and hang; delete it with
`k -n web-app delete pod probe --force` and run it again.

```bash
k get events -A --field-selector involvedObject.name=worker-02 --sort-by=.lastTimestamp | tail -5
```

**Expected:** a `NodeNotReady` event from `node-controller`.

---

### Step 6: Wait for eviction (~5 minutes after `NotReady`)

Keep watching Terminal 2. About 300 s after the `NoExecute` taint's `timeAdded`:

```bash
k -n web-app get pods -o wide && k -n kube-system get pods -l k8s-app=kube-dns -o wide
```

**Expected:**

```text
web-xxxxxxxxxx-aaaaa   1/1   Running       ...   worker-01
web-xxxxxxxxxx-bbbbb   1/1   Running       ...   worker-01
web-xxxxxxxxxx-ccccc   0/1   Terminating   ...   worker-02
web-xxxxxxxxxx-ddddd   1/1   Running       ...   worker-01
coredns-xxxxxxxxxx-eeeee   1/1   Running       ...   worker-01
coredns-xxxxxxxxxx-fffff   0/1   Terminating   ...   worker-02
coredns-xxxxxxxxxx-ggggg   0/1   Pending       ...   <none>
```

Three things to read from this:
1. **The replacement `web` pod is on `worker-01`.** Capacity is back to 3.
2. **The old pod is stuck in `Terminating`.** Deleting a pod asks its kubelet to stop
   it, and that kubelet is gone. The pod object stays until the node returns or someone
   force-deletes it. This is expected, not a fault.
3. **The new CoreDNS pod is `Pending`.** k0s gives CoreDNS a *required* anti-affinity
   rule (one replica per node), and the only healthy node already has one.

```bash
k -n kube-system get events --field-selector reason=FailedScheduling --sort-by=.lastTimestamp | tail -2
```

**Expected:** `FailedScheduling ... 0/2 nodes are available: 1 node(s) didn't match pod
anti-affinity rules, 1 node(s) had untolerated taint {node.kubernetes.io/unreachable: }`.

DaemonSet pods (`kube-router`, `kube-proxy`, `konnectivity-agent`) on `worker-02` are
**not** evicted: DaemonSets tolerate the `unreachable` taint by design.

```bash
k get events -n web-app --sort-by=.lastTimestamp | tail -8
```

**Expected:** `TaintManagerEviction` (`Marking for deletion Pod web-app/web-...`) and
`SuccessfulCreate` from the ReplicaSet.

---

### Step 7: Power `worker-02` back on

```bash
date +%T; utmctl start worker-02
```

This can take ~60–90 s for the VM to boot and the kubelet to re-register, don't panic.
Tail the worker from Terminal 1 once SSH answers:

```bash
until ssh -o ConnectTimeout=3 worker-02 true 2>/dev/null; do sleep 5; done; ssh worker-02 'sudo journalctl -u k0sworker -n 20 --no-pager'
```

**Expected (in Terminal 2 and with `k get nodes`):**
- `worker-02` returns to `Ready` and its taints list is empty.
- The `Terminating` pods disappear: the kubelet came back and confirmed they are gone.
- The `Pending` CoreDNS pod schedules onto `worker-02` and becomes `Running`.
- All three `web` pods **stay on `worker-01`**.

Stop the recorder in Terminal 2 with **Ctrl-C**.

```bash
k get nodes && k -n web-app get pods -o wide && k -n kube-system get pods -l k8s-app=kube-dns -o wide
```

**Kubernetes does not rebalance running pods.** The scheduler only places new pods. To
spread `web` again:

```bash
k -n web-app rollout restart deployment web && k -n web-app rollout status deployment web --timeout=120s && k -n web-app get pods -o wide
```

**Expected:** pods split across both workers again. In production, the
[descheduler](https://github.com/kubernetes-sigs/descheduler) automates this.

---

### Step 8: Repeat with a 30-second toleration

Shorten the eviction delay for this Deployment only, then run Steps 3–7 again with the
recorder writing to `timeline-poweroff-30s.txt` (change the file name in the Step 3
command).

```bash
k -n web-app patch deployment web --type=json -p '[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node.kubernetes.io/unreachable","operator":"Exists","effect":"NoExecute","tolerationSeconds":30},{"key":"node.kubernetes.io/not-ready","operator":"Exists","effect":"NoExecute","tolerationSeconds":30}]}]' && k -n web-app rollout status deployment web && k -n web-app get pod -l app=web -o jsonpath='{range .items[0].spec.tolerations[*]}{.key}{"  "}{.tolerationSeconds}{"\n"}{end}'
```

**Expected:** `node.kubernetes.io/unreachable  30` and `node.kubernetes.io/not-ready  30`.
Because the pod now sets these tolerations, the admission plugin does not add its 300 s
defaults.

**Expected on the second power-off:** replacements start ~80 s after T0 (≈50 s to
`NotReady` + 30 s) instead of ~350 s. CoreDNS still waits 300 s, because its own pods
keep the default.

The trade-off: a short toleration means a brief network blip or a slow kubelet restart
also evicts and reschedules pods. Stateful pods with local data pay the most for that.

### Where these timings are tuned

| Setting | Component | Default | Effect |
|---|---|---|---|
| `tolerationSeconds` on the pod | Pod spec | 300 (injected) | Per-workload eviction delay; the right place to tune |
| `--default-not-ready-toleration-seconds`, `--default-unreachable-toleration-seconds` | kube-apiserver | 300 | Cluster-wide value the admission plugin injects |
| `--node-monitor-grace-period` | kube-controller-manager | 50 s | Time without heartbeats before `NotReady` |
| `nodeStatusUpdateFrequency` / lease renewals | kubelet | 10 s | How often the node reports in; must stay well below the grace period |

On k0s, the API server and controller-manager flags are set in the cluster config
(`spec.api.extraArgs`, `spec.controllerManager.extraArgs` under `spec.k0s.config` in
`k0sctl.yaml`). The draft's `--pods-per-core` is a kubelet capacity setting and has no
effect on eviction timing.

---

## Part B: Node `NotReady` because the worker service died

Same symptom, different cause: the VM is up, but the kubelet is not. On k0s, the kubelet
and containerd both run under the one `k0sworker` systemd service.

### Step 9: Stop the worker service on `worker-02`

```bash
k -n web-app get pods -o wide && date +%T && ssh worker-02 'sudo systemctl stop k0sworker && systemctl is-active k0sworker'
```

**Expected:** the pod list (note which `web` pods are on `worker-02`), a timestamp,
then `inactive`.

Wait ~60 s, then:

```bash
k get node worker-02 && k get node worker-02 -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{"  "}{.message}{"\n"}{end}'
```

**Expected:** `worker-02   NotReady`, `Unknown  Kubelet stopped posting node status.`
From the API, this looks exactly like the power-off.

### Step 10: Triage it the way a runbook would

The first question for any `NotReady` node: **is the machine up?**

```bash
ping -c 2 192.168.64.12 && ssh worker-02 'uptime; systemctl is-active k0sworker; systemctl status k0sworker --no-pager | head -5'
```

**Expected:** ping and SSH work, `uptime` shows the VM was not rebooted, and the service
is `inactive (dead)`. The machine is up; the node agent is not. That rules out
hardware, the hypervisor, and the network.

```bash
ssh worker-02 'sudo journalctl -u k0sworker --since "10 min ago" --no-pager | tail -5; echo ---; pgrep -c containerd-shim || true; sudo crictl ps 2>&1 | head -2'
```

**Expected:**
- The journal ends with `Stopping k0sworker` / `Stopped k0sworker` lines, which shows
  someone or something stopped it (as opposed to a crash, which shows an error and
  `Main process exited, code=...`).
- `pgrep -c containerd-shim` prints a number above zero: the existing containers may
  still be running, orphaned from their kubelet. If it prints `0`, k0s stopped the
  containers too on your version.
- `crictl ps` fails with a `connect: no such file or directory` error on
  `/run/k0s/containerd.sock`: the runtime API is down with the service.

The pods may still be running, but the API marks them not ready and removes them from
endpoints, so they receive no Service traffic.

### Step 11: Fix and verify

```bash
ssh worker-02 'sudo systemctl start k0sworker && sleep 5 && systemctl is-active k0sworker' && k wait --for=condition=Ready node/worker-02 --timeout=180s && k get nodes && k -n web-app get pods -o wide
```

**Expected:** `active`, `node/worker-02 condition met`, both nodes `Ready`, and the
`web` pods on `worker-02` back to `1/1` with the **same names and restart counts**. The
service was restarted well inside the toleration window, so nothing was evicted.

If you leave it stopped longer than the toleration, pods are evicted exactly as in
Part A.

---

## kubeadm differences, for the exam

| Check | kubeadm (CKA exam) | k0s (this lab) |
|---|---|---|
| Node agent service | `systemctl status kubelet` | `systemctl status k0sworker` (kubelet + containerd together) |
| Agent logs | `journalctl -u kubelet` | `journalctl -u k0sworker` |
| Runtime service | `systemctl status containerd` (separate) | inside `k0sworker` |
| Kubelet config | `/var/lib/kubelet/config.yaml` | generated by k0s under `/var/lib/k0s/` |

Typical exam fixes for a `NotReady` node: start and enable `kubelet`, fix a wrong path or
flag in its config, or start `containerd`. Always `systemctl enable` as well as `start`,
so the fix survives a reboot.

---

## Rollback / Clean-up

If `worker-02` is still down:

```bash
utmctl start worker-02; until ssh -o ConnectTimeout=3 worker-02 true 2>/dev/null; do sleep 5; done; ssh worker-02 'sudo systemctl start k0sworker'; k wait --for=condition=Ready node/worker-02 --timeout=180s
```

If pods are stuck in `Terminating` and the node will not come back, force-delete them:

```bash
k -n web-app delete pod --field-selector spec.nodeName=worker-02 --force --grace-period=0
```

Only do this when you know the node is really gone: a force delete on a node that is
merely partitioned can leave two copies of a pod running.

Remove the lab workload:

```bash
k delete namespace web-app && k get nodes && k -n kube-system get deploy coredns
```

**Expected:** `namespace "web-app" deleted`, both workers `Ready`, `coredns 2/2`.

Commit the manifests and timelines as incident #2 evidence:

```bash
cd ~/Projects/hardened-k8s && git add manifests/labs/lab06 && git commit -m "lab06: node failure manifests and timelines"
```

**Next:** Lab 7 adds k0rdent and an AWS child cluster.
