# k0sctl: multi-node lab cluster

1 controller (`192.168.64.10`, etcd) + 2 workers (`.11`, `.12`) on UTM Shared Network.
OS baseline first (`ansible/os.yml`), then from this directory on the Mac:

    k0sctl apply --config k0sctl.yaml
    mkdir -p ~/.kube && k0sctl kubeconfig --config k0sctl.yaml > ~/.kube/hardened-k8s.kubeconfig

Upgrades: change `spec.k0s.version` and re-run `k0sctl apply` (one minor at a time).
Full procedure: docs/runbook/lab02-k0s-multinode.md and lab03-upgrade-backup-restore.md.
