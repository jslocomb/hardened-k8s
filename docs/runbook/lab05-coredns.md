# Lab 5: Break CoreDNS and trace the failure

**Goal:** cause two different DNS outages, read the symptoms from inside a pod, trace each
one to its cause, and fix it.
- **Part A:** CoreDNS has no running pods, so all lookups fail.
- **Part B:** CoreDNS runs, but its upstream `forward` target is unreachable. Cluster
  names still resolve and external names fail.

**CKA relevance:** DNS troubleshooting is on the curriculum (Troubleshooting 30%,
Services & Networking 20%). Reading `/etc/resolv.conf`, the `kube-dns` Service and its
endpoints, CoreDNS logs, and the `coredns` ConfigMap are all exam skills. The k0s
reconcile behaviour at the end is Mirantis-facing depth. This lab is the evidence run for
**incident #4 (CoreDNS / Service resolution failure)**.

## How DNS works in this cluster

| Piece | Value here |
|---|---|
| CoreDNS | `Deployment/coredns` in `kube-system`, label `k8s-app=kube-dns` |
| Replicas | 2 (k0s sets 1 + one per 10 nodes, and counts worker nodes) |
| Placement | Required pod anti-affinity: one replica per node |
| Service | `kube-dns`, ClusterIP `10.96.0.10` (10th address of the service CIDR) |
| Pod resolver | Every pod's `/etc/resolv.conf` points at `10.96.0.10` |
| Upstream | CoreDNS `forward . /etc/resolv.conf`, i.e. the worker's resolver, then `192.168.64.1` (UTM's NAT) |
| Managed by | k0s writes the manifests to `/var/lib/k0s/manifests/coredns/` on the controller and applies them |

**Image pulls do not use cluster DNS.** containerd runs on the node and resolves registry
names with the node's own resolver, never with CoreDNS. A broken CoreDNS cannot cause
`ImagePullBackOff`. Part B proves this.

---

## Pre-check

```bash
export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig && k get nodes && k -n kube-system get deploy coredns && k -n kube-system get svc kube-dns
```

**Expected:**

```text
NAME        STATUS   ROLES    AGE   VERSION
worker-01   Ready    <none>   3d    v1.36.4+k0s
worker-02   Ready    <none>   3d    v1.36.4+k0s
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
coredns   2/2     2            2           3d
NAME       TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)                  AGE
kube-dns   ClusterIP   10.96.0.10   <none>        53/UDP,53/TCP,9153/TCP   3d
```

---

### Step 1: Create a DNS test pod and record a healthy baseline

`netshoot` has `dig`, `nslookup`, and `curl`, and is multi-arch (runs on ARM64).

```bash
k create namespace dns-lab && k -n dns-lab run dnsutil --image=nicolaka/netshoot:v0.13 --command -- sleep infinity && k -n dns-lab wait --for=condition=Ready pod/dnsutil --timeout=120s
```

**Expected:** `namespace/dns-lab created`, `pod/dnsutil created`,
`pod/dnsutil condition met`.

```bash
k -n dns-lab exec dnsutil -- cat /etc/resolv.conf
```

**Expected:**

```text
search dns-lab.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

```bash
k -n dns-lab exec dnsutil -- sh -c 'dig +short +time=2 +tries=1 kubernetes.default.svc.cluster.local; dig +short +time=2 +tries=1 example.com; curl -s -m 5 -o /dev/null -w "external http %{http_code}\n" https://example.com'
```

**Expected:**

```text
10.96.0.1
<one or more public IPv4 addresses>
external http 200
```

`10.96.0.1` is the `kubernetes` Service (the API server). Keep this command; it is the
health check for the whole lab.

---

### Step 2: Part A: delete the CoreDNS pods (self-healing, not an outage)

The draft step "delete the CoreDNS pods" is worth running once to see why it does not
produce an outage.

```bash
k -n kube-system delete pod -l k8s-app=kube-dns && k -n kube-system get pods -l k8s-app=kube-dns -o wide
```

**Expected:** two `pod "coredns-..." deleted` lines, then two **new** `coredns-...` pods,
`ContainerCreating` or `Running`, one per worker.

The Deployment's ReplicaSet replaced them within seconds. Lookups during that window
may fail briefly; nothing stays broken. To cause a real outage, the desired state itself
has to change.

---

### Step 3: Part A: scale CoreDNS to zero

```bash
k -n kube-system scale deployment coredns --replicas=0 && k -n kube-system get deploy coredns
```

**Expected:**

```text
deployment.apps/coredns scaled
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
coredns   0/0     0            0           3d
```

k0s does not scale it back on its own (see "Why k0s did not revert it" in Step 11).

**Symptom from a workload pod:**

```bash
k -n dns-lab exec dnsutil -- sh -c 'nslookup -timeout=2 -retry=1 kubernetes.default.svc.cluster.local; echo "exit=$?"'
```

**Expected:** within a few seconds, one of:

> `;; communications error to 10.96.0.10#53: connection refused`
> `;; no servers could be reached`
> `exit=1`

or `;; connection timed out; no servers could be reached`. `connection refused` comes from
kube-proxy: a Service with no endpoints gets an iptables `REJECT` rule, so the client is
told immediately instead of waiting.

---

### Step 4: Part A: trace it

Work from the client outward. Each command answers one question.

**Is the pod pointed at the right DNS server?**

```bash
k -n dns-lab exec dnsutil -- grep nameserver /etc/resolv.conf && k -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}{"\n"}'
```

**Expected:** `nameserver 10.96.0.10` and `10.96.0.10`. They match, so the client side
is fine.

**Does the Service have anything behind it?**

```bash
k -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns
```

**Expected:** the EndpointSlice exists with `ENDPOINTS` shown as `<unset>`. No endpoints
is the finding.

**Why are there no endpoints?**

```bash
k -n kube-system get pods -l k8s-app=kube-dns && k -n kube-system get deploy coredns -o jsonpath='{.spec.replicas}{"\n"}' && k -n kube-system get events --sort-by=.lastTimestamp --field-selector involvedObject.kind=ReplicaSet | tail -5
```

**Expected:**

> `No resources found in kube-system namespace.`
> `0`
> events ending with `Deleted pod: coredns-...` from the ReplicaSet controller (reason
> `SuccessfulDelete`)

Root cause: desired replicas is 0. With the pods gone, `k logs` has nothing to show,
which is itself a clue: an empty selector means look at the controller, not the pods.

To see who changed it, check the managed fields:

```bash
k -n kube-system get deploy coredns --show-managed-fields -o jsonpath='{range .metadata.managedFields[*]}{.manager}{"\t"}{.operation}{"\t"}{.time}{"\n"}{end}'
```

**Expected:** a line with `kubectl` and `Update` at the time of Step 3, alongside the
k0s-owned entries. On a real incident this points to a person or tool, not a bug.

---

### Step 5: Part A: fix and verify

```bash
k -n kube-system scale deployment coredns --replicas=2 && k -n kube-system rollout status deployment coredns --timeout=120s
```

**Expected:** `deployment "coredns" successfully rolled out`.

Use **2**, the value k0s set for this cluster. Check what k0s generated with:

```bash
ssh controller 'sudo grep -m1 "replicas:" /var/lib/k0s/manifests/coredns/coredns.yaml'
```

**Expected:** `  replicas: 2`

**Verify:** re-run the Step 1 health check.

```bash
k -n dns-lab exec dnsutil -- sh -c 'dig +short +time=2 +tries=1 kubernetes.default.svc.cluster.local; dig +short +time=2 +tries=1 example.com; curl -s -m 5 -o /dev/null -w "external http %{http_code}\n" https://example.com'
```

**Expected:** `10.96.0.1`, public IPs, `external http 200`.

---

### Step 6: Part B: save the ConfigMap, then break the upstream

```bash
mkdir -p ~/Projects/hardened-k8s/manifests/labs/lab05 && k -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' > ~/Projects/hardened-k8s/manifests/labs/lab05/Corefile.orig && grep -n forward ~/Projects/hardened-k8s/manifests/labs/lab05/Corefile.orig
```

**Expected:** `11:    forward . /etc/resolv.conf` (line number may differ).

Point `forward` at `192.0.2.53`. That address is in TEST-NET-1 (RFC 5737), reserved for
documentation, so nothing answers there.

```bash
k -n kube-system get configmap coredns -o yaml | sed 's#forward \. /etc/resolv\.conf#forward . 192.0.2.53#' | k replace -f - && k -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' | grep forward
```

**Expected:**

> `configmap/coredns replaced`
> `    forward . 192.0.2.53`

On the exam, make the same change with `k -n kube-system edit configmap coredns`. The
`sed` pipeline is used here so the step can be pasted without an editor.

CoreDNS does not need a restart. The kubelet refreshes the mounted ConfigMap (up to
~60 s) and the `reload` plugin checks the file every ~30 s. Wait for the reload:

```bash
k -n kube-system logs -l k8s-app=kube-dns --since=3m -f --max-log-requests=2 | grep --line-buffered -i reload
```

**Expected (within ~2 min), one line per replica:**

> `[INFO] Reloading`
> `[INFO] plugin/reload: Running configuration SHA512 = ...`
> `[INFO] Reloading complete`

Press **Ctrl-C** once both replicas have reloaded.

---

### Step 7: Part B: the symptom

```bash
k -n dns-lab exec dnsutil -- sh -c 'echo "internal: $(dig +short +time=2 +tries=1 kubernetes.default.svc.cluster.local)"; echo "external:"; dig +time=3 +tries=1 example.com | grep -E "status:|timed out"; curl -sS -m 10 -o /dev/null https://example.com; echo "curl exit=$?"'
```

**Expected:**

```text
internal: 10.96.0.1
external:
;; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: ...
curl: (6) Could not resolve host: example.com
curl exit=6
```

If `dig` times out instead of returning `SERVFAIL`, CoreDNS was still waiting on the
upstream when `dig` gave up. Both mean the same thing.

This is the pattern to recognize: **cluster names work, external names fail.** CoreDNS
answers `cluster.local` from the Kubernetes API itself and only forwards everything else
upstream.

---

### Step 8: Part B: prove image pulls are unaffected

Pull an image the workers have never pulled. If cluster DNS were involved, this would
fail.

```bash
k -n dns-lab run pulltest --image=busybox:1.37 --restart=Never --command -- echo pulled-ok && k -n dns-lab wait --for=jsonpath='{.status.phase}'=Succeeded pod/pulltest --timeout=120s && k -n dns-lab logs pulltest
```

**Expected:**

> `pod/pulltest condition met`
> `pulled-ok`

The image pulled while pods cannot resolve `example.com`. The node resolved
`registry-1.docker.io` itself:

```bash
NODE=$(k -n dns-lab get pod pulltest -o jsonpath='{.spec.nodeName}') && ssh "$NODE" 'resolvectl query registry-1.docker.io | head -2'
```

**Expected:** `registry-1.docker.io: <IP addresses>`, answered by the node's
`systemd-resolved`, not by CoreDNS.

---

### Step 9: Part B: trace it

**Is CoreDNS up and are endpoints present?** (rules out Part A)

```bash
k -n kube-system get pods -l k8s-app=kube-dns -o wide && k -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns
```

**Expected:** two `Running` pods and an EndpointSlice listing their two `10.244.x.y`
addresses.

**What does CoreDNS say?**

```bash
k -n kube-system logs -l k8s-app=kube-dns --since=5m --max-log-requests=2 | grep -E 'ERROR|192.0.2.53' | tail -5
```

**Expected:**

> `[ERROR] plugin/errors: 2 example.com. A: read udp 10.244.x.y:NNNNN->192.0.2.53:53: i/o timeout`

The log names the upstream it is trying to reach. That points straight at `forward`.

**What is the config?**

```bash
k -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' | grep -n forward && diff ~/Projects/hardened-k8s/manifests/labs/lab05/Corefile.orig <(k -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')
```

**Expected:**

```text
11:    forward . 192.0.2.53
11c11
<     forward . /etc/resolv.conf
---
>     forward . 192.0.2.53
```

Root cause: the `forward` target was changed to an unreachable resolver.

---

### Step 10: Part B: fix and verify

```bash
k -n kube-system get configmap coredns -o yaml | sed 's#forward \. 192\.0\.2\.53#forward . /etc/resolv.conf#' | k replace -f - && diff ~/Projects/hardened-k8s/manifests/labs/lab05/Corefile.orig <(k -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}') && echo "Corefile matches original"
```

**Expected:** `configmap/coredns replaced`, `Corefile matches original`.

Wait for the reload as in Step 6 (up to ~2 min), then run the health check:

```bash
k -n kube-system logs -l k8s-app=kube-dns --since=3m -f --max-log-requests=2 | grep --line-buffered -i 'reloading complete'
```

Press **Ctrl-C** after two `Reloading complete` lines.

```bash
k -n dns-lab exec dnsutil -- sh -c 'dig +short +time=2 +tries=1 kubernetes.default.svc.cluster.local; dig +short +time=2 +tries=1 example.com; curl -s -m 5 -o /dev/null -w "external http %{http_code}\n" https://example.com'
```

**Expected:** `10.96.0.1`, public IPs, `external http 200`.

**Faster alternative:** `k -n kube-system rollout restart deployment coredns` reads the
ConfigMap immediately on start. Fine in a lab; in production a rolling restart is a
second change during an incident, so prefer waiting for `reload` when it is working.

---

### Step 11: Why k0s did not revert either change

k0s generated the CoreDNS Deployment and ConfigMap, yet both manual changes stuck. That
is because of how the k0s manifest applier works:
- It applies a stack when a file under `/var/lib/k0s/manifests/` **changes**, and once
  at controller start.
- Before updating a resource it compares a checksum annotation on the live object with
  the file. A `kubectl` edit changes the data but not that annotation, so k0s sees no
  difference and leaves the edit alone, even across controller restarts.
- The edit is overwritten only when k0s generates a **different** manifest, for example
  after a k0s upgrade or a ClusterConfig change. Then k0s patches whatever fields its
  template changed.

Check the annotation:

```bash
k -n kube-system get configmap coredns -o jsonpath='{.metadata.annotations.k0s\.k0sproject\.io/stack-checksum}{"\n"}'
```

**Expected:** a hex checksum string. It was written by k0s when it last applied the
stack, and it is unchanged by the Part B edit.

**Runbook consequence:** on k0s, a hand-edit to a system component can survive for
months and then vanish during an upgrade. Treat any manual change to `kube-system`
objects as a temporary fix. The supported, durable way to customize CoreDNS is
`spec.network.coreDNS.patches` in the cluster config (in `k0sctl.yaml` under
`spec.k0s.config`). It is marked experimental in the k0s docs, so test it before relying
on it. Not applied in this lab.

**kubeadm difference (exam):** on kubeadm, the CoreDNS ConfigMap is created once by
`kubeadm init` and is yours afterwards; `kubeadm upgrade` may migrate it. Editing it with
`kubectl edit` is the normal, expected method.

---

## Rollback / Clean-up

If either outage is still active, restore both pieces:

```bash
k -n kube-system get configmap coredns -o yaml | sed 's#forward \. 192\.0\.2\.53#forward . /etc/resolv.conf#' | k replace -f - && k -n kube-system scale deployment coredns --replicas=2 && k -n kube-system rollout restart deployment coredns && k -n kube-system rollout status deployment coredns --timeout=120s
```

**Expected:** `configmap/coredns replaced`, `deployment.apps/coredns scaled`,
`deployment.apps/coredns restarted`, `successfully rolled out`.

Remove the lab namespace:

```bash
k delete namespace dns-lab
```

Commit the original Corefile as evidence:

```bash
cd ~/Projects/hardened-k8s && git add manifests/labs/lab05 && git commit -m "lab05: baseline CoreDNS Corefile (k0s v1.36)"
```

**Next:** Lab 6 powers off a worker mid-workload.
