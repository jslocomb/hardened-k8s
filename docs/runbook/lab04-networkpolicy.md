# Lab 4: NetworkPolicy lock-down and debug on kube-router

**Goal:** lock the `web-app` namespace down with a default-deny ingress policy, allow only
the `debugger` namespace back in, and trace both allowed and dropped traffic at the pod,
node, and iptables level.

**CKA relevance:** NetworkPolicy is on the curriculum (Services & Networking, 20%), and
writing a policy from a description is a common exam task. The node-level tracing
(NFLOG, iptables, ipsets) is extra depth. This lab is the evidence run for the
NetworkPolicy part of **incident #1 (cryptominer CronJob)**.

## How kube-router enforces NetworkPolicy

k0s runs kube-router with `--run-firewall=true`, so kube-router is the policy enforcer.
On every node it translates NetworkPolicy objects into iptables chains and ipsets:

| Object on the node | What it is |
|---|---|
| `KUBE-ROUTER-FORWARD`, `-INPUT`, `-OUTPUT` | Entry chains that send pod traffic into the per-pod chains |
| `KUBE-POD-FW-<hash>` | One chain per pod selected by any policy |
| `KUBE-NWPLCY-<hash>` | One chain per NetworkPolicy |
| `KUBE-SRC-*`, `KUBE-DST-*` ipsets | Pod IPs that policies match on |
| NFLOG group 100 | Packets dropped by policy are logged here before the drop |

The rules are the same as on any CNI, because they come from the Kubernetes API, not
from the CNI:
- A pod that **no** policy selects accepts all traffic.
- Once **any** policy selects a pod for `Ingress`, only traffic an `ingress` rule allows
  gets in. "Default deny" is a policy you write, not a CNI setting.
- Policies are additive. There are no deny rules; an allow in any policy wins.
- Traffic between containers **in the same pod** goes over `localhost` and is never
  filtered.

Calico and Cilium follow the same rules. They differ in implementation, logging, and
extra CRDs (`GlobalNetworkPolicy`, `CiliumNetworkPolicy`), not in how standard
NetworkPolicy behaves.

---

## Pre-check

```bash
export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig && k get nodes && k -n kube-system get ds kube-router
```

**Expected:**

```text
NAME        STATUS   ROLES    AGE   VERSION
worker-01   Ready    <none>   3d    v1.36.4+k0s
worker-02   Ready    <none>   3d    v1.36.4+k0s
NAME          DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
kube-router   2         2         2       2            2           <none>          3d
```

---

### Step 1: Write the lab manifests

Manifests go into the repo so the evidence is reproducible.

```bash
mkdir -p ~/Projects/hardened-k8s/manifests/labs/lab04 && cd ~/Projects/hardened-k8s/manifests/labs/lab04

cat > 00-namespaces.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: web-app
---
apiVersion: v1
kind: Namespace
metadata:
  name: client
---
apiVersion: v1
kind: Namespace
metadata:
  name: debugger
EOF

cat > 10-web.yaml << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: web
  namespace: web-app
  labels:
    app: web
spec:
  containers:
    - name: nginx
      image: nginx:1.27-alpine
      ports:
        - containerPort: 80
    - name: sidecar
      image: curlimages/curl:8.10.1
      command: ["sleep", "infinity"]
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

cat > 20-clients.yaml << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: curl
  namespace: client
  labels:
    app: curl
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: curl
  namespace: debugger
  labels:
    app: curl
spec:
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["sleep", "infinity"]
EOF
```

---

### Step 2: Deploy and confirm open traffic

```bash
cd ~/Projects/hardened-k8s/manifests/labs/lab04 && k apply -f 00-namespaces.yaml -f 10-web.yaml -f 20-clients.yaml && k -n web-app wait --for=condition=Ready pod/web --timeout=120s && k -n client wait --for=condition=Ready pod/curl --timeout=120s && k -n debugger wait --for=condition=Ready pod/curl --timeout=120s
```

**Expected:** three `created` lines for namespaces, then `pod/web created`,
`service/web created`, two `pod/curl created`, then three `condition met` lines.

Record the addresses used for the rest of the lab:

```bash
WEB_IP=$(k -n web-app get pod web -o jsonpath='{.status.podIP}') && WEB_NODE=$(k -n web-app get pod web -o jsonpath='{.spec.nodeName}') && echo "web pod $WEB_IP on $WEB_NODE" && k get pods -A -l 'app in (web,curl)' -o wide
```

**Expected:** `web pod 10.244.x.y on worker-0N`, and the three pods with their node and
`10.244.x.y` IPs. A new terminal needs these two variables set again; re-run this command.

Test from both client namespaces, by Service name and by pod IP:

```bash
for ns in client debugger; do for target in web.web-app.svc.cluster.local "$WEB_IP"; do printf '%-9s -> %-32s ' "$ns" "$target"; k -n "$ns" exec curl -- sh -c "curl -s -m 5 -o /dev/null -w '%{http_code}' http://$target; echo \" exit=\$?\""; done; done
```

**Expected:**

```text
client    -> web.web-app.svc.cluster.local    200 exit=0
client    -> 10.244.x.y                       200 exit=0
debugger  -> web.web-app.svc.cluster.local    200 exit=0
debugger  -> 10.244.x.y                       200 exit=0
```

No policy selects `web` yet, so everything is allowed.

---

### Step 3: Apply default-deny ingress to `web-app`

```bash
cd ~/Projects/hardened-k8s/manifests/labs/lab04 && cat > 30-default-deny-ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: web-app
spec:
  podSelector: {}
  policyTypes:
    - Ingress
EOF
k apply -f 30-default-deny-ingress.yaml
```

`podSelector: {}` selects every pod in the namespace. `policyTypes: [Ingress]` with no
`ingress:` rules means nothing is allowed in.

**Verify:** run the Step 2 test loop again.

```bash
for ns in client debugger; do for target in web.web-app.svc.cluster.local "$WEB_IP"; do printf '%-9s -> %-32s ' "$ns" "$target"; k -n "$ns" exec curl -- sh -c "curl -s -m 5 -o /dev/null -w '%{http_code}' http://$target; echo \" exit=\$?\""; done; done
```

**Expected (takes ~20 s; each attempt waits out the 5 s timeout):**

```text
client    -> web.web-app.svc.cluster.local    000 exit=28
client    -> 10.244.x.y                       000 exit=28
debugger  -> web.web-app.svc.cluster.local    000 exit=28
debugger  -> 10.244.x.y                       000 exit=28
```

`exit=28` is curl's timeout. kube-router **drops** the packets rather than rejecting them,
so the client waits instead of getting `connection refused`. The name still resolves:
DNS goes to CoreDNS in `kube-system`, which this policy does not touch.

Now test from the sidecar **inside** the `web` pod:

```bash
k -n web-app exec web -c sidecar -- curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://localhost
```

**Expected:** `200`. Containers in one pod share a network namespace; `localhost` traffic
never crosses the pod's interface, so no NetworkPolicy can filter it. A compromised
sidecar is inside the boundary.

---

### Step 4: Allow ingress from the `debugger` namespace only

```bash
cd ~/Projects/hardened-k8s/manifests/labs/lab04 && cat > 40-allow-debugger.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-debugger
  namespace: web-app
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: debugger
      ports:
        - protocol: TCP
          port: 80
EOF
k apply -f 40-allow-debugger.yaml
```

`kubernetes.io/metadata.name` is a label the API server sets on every namespace, so no
manual labelling is needed.

**Verify:**

```bash
for ns in client debugger; do for target in web.web-app.svc.cluster.local "$WEB_IP"; do printf '%-9s -> %-32s ' "$ns" "$target"; k -n "$ns" exec curl -- sh -c "curl -s -m 5 -o /dev/null -w '%{http_code}' http://$target; echo \" exit=\$?\""; done; done
```

**Expected:**

```text
client    -> web.web-app.svc.cluster.local    000 exit=28
client    -> 10.244.x.y                       000 exit=28
debugger  -> web.web-app.svc.cluster.local    200 exit=0
debugger  -> 10.244.x.y                       200 exit=0
```

Both policies still select `web`. The deny policy allows nothing and the debugger policy
allows one source, and the union is "debugger only".

**CKA note:** a classic exam trap is the difference between these two `from` blocks:

```yaml
# ONE rule entry: namespace debugger AND pod label app=curl (both must match)
- from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: debugger}}
      podSelector: {matchLabels: {app: curl}}
# TWO rule entries: namespace debugger OR any pod labelled app=curl in web-app
- from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: debugger}}
    - podSelector: {matchLabels: {app: curl}}
```

The only difference is the `-` before `podSelector`.

---

### Step 5: Debug with the API objects

Start every NetworkPolicy investigation here, before touching nodes.

```bash
k get netpol -A && k -n web-app describe netpol allow-from-debugger && k -n web-app get pod web --show-labels && k get ns debugger --show-labels
```

**Expected:**
- `get netpol -A` lists `default-deny-ingress` and `allow-from-debugger` in `web-app`.
- `describe` shows `PodSelector: app=web`, `Allowing ingress traffic: To Port: 80/TCP`,
  `From: NamespaceSelector: kubernetes.io/metadata.name=debugger`.
- The pod has `app=web`; the namespace has `kubernetes.io/metadata.name=debugger`.

Most real NetworkPolicy failures are a label that does not match a selector. Comparing
these four outputs finds them.

---

### Step 6: Watch drops in kube-router's NFLOG

kube-router logs every packet it drops for policy to NFLOG group 100 on the node that
hosts the destination pod. The toolkit role installed `tcpdump` on the workers.

```bash
ssh -o ServerAliveInterval=5 "$WEB_NODE" 'sudo timeout 20 tcpdump -n -i nflog:100 -c 3' & sleep 4; k -n client exec curl -- curl -s -m 5 -o /dev/null "http://$WEB_IP"; k -n debugger exec curl -- curl -s -m 5 -o /dev/null -w 'debugger %{http_code}\n' "http://$WEB_IP"; wait
```

**Expected:** `listening on nflog:100`, then SYN packets from the `client` pod's IP to
`$WEB_IP.80`, for example:

```text
IP 10.244.1.7.43218 > 10.244.0.9.80: Flags [S], seq ...
IP 10.244.1.7.43218 > 10.244.0.9.80: Flags [S], seq ...
debugger 200
```

The `debugger` request never appears: allowed traffic is not logged. This is the fastest
way to answer "is a policy dropping this?" on kube-router.

**Troubleshooting:** `tcpdump: nflog:100: No such device exists` means this tcpdump build
lacks NFLOG support. Check with `ssh "$WEB_NODE" 'tcpdump -D | grep nflog'`; if it prints
nothing, skip to Step 8 and use the iptables counters instead.

---

### Step 7: Capture inside the pod with an ephemeral debug container

The `nginx` image has no `tcpdump`. `kubectl debug` attaches a temporary container that
shares the pod's network namespace. Use **two terminals**.

Terminal 1:

```bash
export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig && kubectl -n web-app debug web -it --image=nicolaka/netshoot:v0.13 --target=nginx -- tcpdump -n -i eth0 tcp port 80
```

Terminal 2 (set `WEB_IP` again first, see Step 2):

```bash
export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig && WEB_IP=$(kubectl -n web-app get pod web -o jsonpath='{.status.podIP}') && kubectl -n client exec curl -- curl -s -m 5 -o /dev/null "http://$WEB_IP"; kubectl -n debugger exec curl -- curl -s -m 5 -o /dev/null -w 'debugger %{http_code}\n' "http://$WEB_IP"
```

**Expected in Terminal 1:** only the `debugger` pod's connection (SYN, SYN-ACK, HTTP
GET, response, FIN). The `client` SYNs never reach the pod's `eth0`: kube-router dropped
them on the node, before the veth. Press **Ctrl-C** in Terminal 1 when done.

Comparing Step 6 and Step 7 places the drop exactly: seen on the node's NFLOG, absent
from the pod's interface.

**Troubleshooting:** `ephemeral containers are disabled` is not expected on k0s v1.36
(the feature is GA). `ImagePullBackOff` on the debug container: check egress from the
worker with `ssh "$WEB_NODE" 'sudo crictl pull nicolaka/netshoot:v0.13'`.

---

### Step 8: Read the iptables chains kube-router built

kube-router uses its own bundled iptables, so read the rules from inside its pod on the
web pod's node rather than with the host's `iptables` binary.

```bash
KR=$(k -n kube-system get pod -l k8s-app=kube-router --field-selector spec.nodeName="$WEB_NODE" -o name) && echo "$KR" && k -n kube-system exec "$KR" -c kube-router -- sh -c 'iptables-save -c | grep -E "^:KUBE-(NWPLCY|POD-FW)|NFLOG|KUBE-NWPLCY-.*-j (ACCEPT|MARK)" | head -20; echo ---; ipset list -n | grep -E "^KUBE-(SRC|DST)" | head'
```

**Expected:**
- Chain declarations such as `:KUBE-NWPLCY-ABCDEFGHIJKLMNOP - [0:0]` (two, one per
  policy) and `:KUBE-POD-FW-...` (one for the `web` pod).
- A rule with `-j NFLOG --nflog-group 100` followed by the drop in the pod firewall chain,
  with a packet counter in `[packets:bytes]` above zero from the `client` attempts.
- `KUBE-SRC-...` / `KUBE-DST-...` ipset names.

The exact hashes differ per cluster. What to look for is that the policy exists as a
chain on the right node and the drop counter moves when the failing client retries.

**Troubleshooting:** `iptables-save: not found` in the pod: k0s's kube-router image
bundles it, but if a future image moves it, run the host's copy that k0s ships:
`ssh "$WEB_NODE" 'sudo /var/lib/k0s/bin/iptables-save | grep KUBE-NWPLCY | head'`.

---

### Step 9: Egress default-deny breaks DNS (common real failure)

Lock the `client` namespace's **egress** and watch name resolution fail before the HTTP
request does.

```bash
cd ~/Projects/hardened-k8s/manifests/labs/lab04 && cat > 50-client-deny-egress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: client
spec:
  podSelector: {}
  policyTypes:
    - Egress
EOF
k apply -f 50-client-deny-egress.yaml && k -n client exec curl -- sh -c 'curl -sS -m 20 -o /dev/null http://web.web-app.svc.cluster.local./; echo "exit=$?"'
```

**Expected (after ~10 s):**

> `curl: (6) Could not resolve host: web.web-app.svc.cluster.local.`
> `exit=6`

The DNS query to CoreDNS on UDP 53 is blocked, so curl never gets as far as connecting.
Error `(6)` means name resolution failed; `(28)` with "Connection timed out" means the
name resolved and the connection failed. If you see `(28) Resolving timed out`, that is
the same DNS failure reported by curl's own timer. The trailing dot makes the name fully
qualified, so the pod's resolver skips its `ndots:5` search-list attempts and fails faster.

Allow DNS to CoreDNS only:

```bash
cd ~/Projects/hardened-k8s/manifests/labs/lab04 && cat > 60-client-allow-dns.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: client
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
EOF
k apply -f 60-client-allow-dns.yaml && k -n client exec curl -- sh -c 'curl -sS -m 5 -o /dev/null http://web.web-app.svc.cluster.local./; echo "exit=$?"'
```

**Expected:**

> `curl: (28) Connection timed out after 5002 milliseconds`
> `exit=28`

DNS now works; the connection still fails, because `client` has
no egress rule to `web-app` and `web-app` has no ingress rule from `client`. A
cross-namespace flow needs **both** sides to allow it.

---

## Rollback / Clean-up

Remove only the policies (returns to the open state of Step 2):

```bash
k -n web-app delete netpol --all && k -n client delete netpol --all
```

**Expected:** four `networkpolicy ... deleted` lines. Re-run the Step 2 test loop to see
`200` everywhere.

Remove the whole lab:

```bash
k delete namespace web-app client debugger
```

**Expected:** three `namespace "..." deleted` lines (~10–30 s). kube-router removes its
chains for the deleted pods and policies automatically.

Commit the manifests as evidence:

```bash
cd ~/Projects/hardened-k8s && git add manifests/labs/lab04 && git commit -m "lab04: NetworkPolicy manifests (kube-router)"
```

**Next:** Lab 5 breaks CoreDNS.
