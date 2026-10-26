# Daily cheatsheet

The 25 commands used most across Labs 1–8. `k` is `kubectl`; `$do` is
`--dry-run=client -o yaml` (Lab 1). Commands marked **k0s** differ on the kubeadm
clusters used in the CKA exam; the kubeadm form is in the comment.

```bash
# --- Context and health ---------------------------------------------------------
export KUBECONFIG=~/.kube/hardened-k8s.kubeconfig        # 1  point k at the lab cluster
k get nodes -o wide                                      # 2  node status, IPs, versions, runtime
k get pods -A -o wide | grep -v -E 'Running|Completed'   # 3  everything that is not healthy
k get events -A --sort-by=.lastTimestamp | tail -20      # 4  recent events, newest last
k top nodes; k top pods -A --sort-by=memory | head       # 5  CPU and memory (metrics-server)

# --- Inspect and debug workloads ------------------------------------------------
k describe pod <pod> -n <ns> | tail -20                  # 6  conditions and events for one pod
k logs <pod> -n <ns> -c <container> --previous           # 7  logs of the crashed container
k exec -it <pod> -n <ns> -- sh                           # 8  shell in a running container
k debug -it <pod> -n <ns> --image=nicolaka/netshoot:v0.13 --target=<container>   # 9  ephemeral debug container
k run tmp --image=nicolaka/netshoot:v0.13 --rm -it --restart=Never -- dig +short kubernetes.default.svc.cluster.local   # 10 one-off DNS test

# --- Create fast (exam speed) ---------------------------------------------------
k create deploy web --image=nginx:1.27-alpine --replicas=3 $do > web.yaml   # 11 generate YAML, then edit
k expose deploy web --port=80 $do > web-svc.yaml         # 12 Service for it
k apply -f web.yaml -f web-svc.yaml                      # 13 apply
k -n <ns> rollout status deploy/<name>; k -n <ns> rollout restart deploy/<name>   # 14 watch / restart a rollout
k get netpol -A; k -n <ns> describe netpol <name>        # 15 NetworkPolicy check (Lab 4)

# --- Services and DNS -----------------------------------------------------------
k -n <ns> get endpointslices -l kubernetes.io/service-name=<svc>   # 16 does the Service have backends?
k -n kube-system logs -l k8s-app=kube-dns --tail=20      # 17 CoreDNS logs (Lab 5)

# --- Nodes ------------------------------------------------------------------------
k drain <node> --ignore-daemonsets --delete-emptydir-data && k uncordon <node>   # 18 node maintenance
k get node <node> -o jsonpath='{.spec.taints}'           # 19 taints (Lab 6)
ssh <node> 'sudo journalctl -u k0sworker -n 50 --no-pager'   # 20 k0s: node agent logs   (kubeadm: journalctl -u kubelet)
ssh <node> 'sudo crictl ps -a'                           # 21 containers on the node, incl. exited (k0s socket set in /etc/crictl.yaml)

# --- Cluster lifecycle (k0s) ------------------------------------------------------
k0sctl apply --config ~/Projects/hardened-k8s/k0sctl/k0sctl.yaml   # 22 k0s: install/upgrade (kubeadm: kubeadm init/upgrade apply)
cd ~/Projects/hardened-k8s/k0sctl/backups && k0sctl backup --config ../k0sctl.yaml   # 23 k0s: backup (kubeadm: etcdctl snapshot save)
ssh controller 'sudo k0s status'                         # 24 k0s: control-plane status (kubeadm: k -n kube-system get pods)

# --- Fleet (k0rdent, Lab 7) -------------------------------------------------------
k get management kcm; k -n kcm-system get clusterdeployment,cluster,machines   # 25 management health and child clusters
```

## Exam habits

- Generate YAML with `$do`, edit it in vim, then `k apply`. Faster and safer than
  writing from scratch.
- Set the namespace once per task: `k config set-context --current --namespace=<ns>`.
- After any change, verify with a read-only command before moving on.
- `k explain <resource>.<field> --recursive | less` finds field names without the
  docs.
