# Lab environment

Documented from a live inventory of the VM (`scripts/vm-inventory.sh`).

## Host and hypervisor
- Host: Mac Mini M4
- Hypervisor: UTM (QEMU virt machine, Apple Silicon virtualization)
- Network: UTM Shared network (NAT, DHCP on 192.168.64.0/24)

## Guest VM
| Item | Value |
|---|---|
| OS | Ubuntu Server 26.04.1 LTS (Resolute Raccoon), ARM64 |
| Kernel | 7.0.0-34-generic |
| Hostname | a0 |
| vCPU | 4 |
| RAM | ~10 GB allocated (9.2 GiB visible to guest) |
| Swap | None (disabled, as Kubernetes expects) |
| Disk | 40 GB virtual disk, LVM |
| Time zone | UTC, synced by chrony |

### Disk layout
| Partition | Size | Type | Mount |
|---|---|---|---|
| vda1 | 1 GB | vfat | /boot/efi |
| vda2 | 2 GB | ext4 | /boot |
| vda3 | 36.9 GB | LVM PV | |
| ubuntu-vg/ubuntu-lv | 18.5 GB | ext4 | / |

Note: the Ubuntu installer allocated only about half the volume group to `/`.
About 18 GB is unallocated and can be added later:
```bash
sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
```

## Build steps (in order)

### 1. Base OS
Ubuntu Server installed from the ARM64 ISO with OpenSSH enabled, then:
```bash
sudo apt update && sudo apt upgrade -y
```

### 2. k0s (single node)
```bash
curl --proto '=https' --tlsv1.2 -sSf https://get.k0s.sh | sudo sh
sudo k0s install controller --single
sudo k0s start
sudo k0s status
```
`--single` runs controller and worker on one node. k0s installs a systemd unit,
`k0scontroller.service`, enabled at boot.

### 3. kubectl access
```bash
mkdir -p ~/.kube
sudo k0s kubeconfig admin > ~/.kube/config
chmod 600 ~/.kube/config

curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/arm64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
kubectl get nodes
```
Installed kubectl client: v1.37.1 (one minor version ahead of the v1.36 server,
which is within the supported version skew).

### 4. Troubleshooting toolkit
```bash
sudo apt install -y sysstat htop iotop net-tools iproute2 tcpdump lsof ipmitool stress-ng jq
```

### 5. Time sync fix (see Known quirks)
```bash
echo 'makestep 1 -1' | sudo tee /etc/chrony/conf.d/makestep.conf
sudo systemctl restart chrony
```

## Cluster state after build
| Component | Detail |
|---|---|
| Node | a0, Ready, control-plane |
| Container runtime | containerd 2.3.5 (bundled with k0s) |
| Service CIDR | 10.96.0.0/12 |
| Pod CIDR | 10.244.0.0/24 (kube-bridge) |
| kube-system pods | coredns, kube-proxy, kube-router, metrics-server |
| API server | RBAC + Node authorization, anonymous auth disabled, TLS 1.2 minimum |

Kernel prerequisites present: `overlay` and `br_netfilter` modules loaded,
`net.ipv4.ip_forward = 1`, `net.bridge.bridge-nf-call-iptables = 1`.

## Known quirks
- **k0s install URL.** Older references to `get.k0sproject.io` and raw GitHub install
  scripts failed. The working installer is `https://get.k0s.sh`.
- **Clock drift after host sleep.** After the Mac slept, the VM clock fell behind and
  `apt update` failed on repository signature validity. By default chrony only steps
  the clock during its first few updates, then slews slowly. Adding `makestep 1 -1`
  lets chrony step the clock whenever it is off by more than one second.
- **kubectl needs sudo-free access.** Running `k0s kubectl` requires sudo; the
  standalone kubectl plus an admin kubeconfig in `~/.kube/config` avoids that.

## Hardening gaps (tracked in [security/README.md](../security/README.md))
- SSH password authentication is still enabled.
- No host firewall installed.
