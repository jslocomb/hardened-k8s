#!/usr/bin/env bash
# vm-inventory.sh - capture the current state of the hardened-k8s lab VM
# Run inside the VM:  bash vm-inventory.sh
# Output: ~/vm-inventory-<date>.txt  (review and scrub before sharing)
set -uo pipefail

OUT="$HOME/vm-inventory-$(date +%Y%m%d-%H%M).txt"

section() { printf '\n===== %s =====\n' "$1"; }
run() { printf '$ %s\n' "$*"; eval "$@" 2>&1; echo; }

{
  section "SYSTEM"
  run cat /etc/os-release
  run uname -a
  run hostnamectl
  run timedatectl

  section "HARDWARE (as seen by guest)"
  run nproc
  run free -h
  run lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
  run df -hT -x tmpfs -x devtmpfs -x squashfs
  run swapon --show

  section "NETWORK"
  run ip -br addr
  run ip route
  run resolvectl status
  run "ls /etc/netplan/ && sudo cat /etc/netplan/*.yaml"

  section "USERS AND ACCESS"
  run id
  run "getent group sudo"
  run "sudo sshd -T 2>/dev/null | grep -Ei '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication)'"
  run "sudo ufw status verbose"

  section "PACKAGES (manually installed)"
  run "apt-mark showmanual | sort"
  run "snap list"
  run "ls -la /usr/local/bin"

  section "KERNEL SETTINGS"
  run "lsmod | grep -E 'br_netfilter|overlay'"
  run "sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables 2>/dev/null"
  run "ls /etc/modules-load.d/ /etc/sysctl.d/"

  section "K0S"
  run "k0s version"
  run "sudo k0s status"
  run "systemctl status k0scontroller --no-pager | head -15"
  run "ls -la /etc/k0s/ 2>/dev/null"
  run "sudo k0s kubectl get nodes -o wide"
  run "sudo k0s kubectl get pods -A"
  run "command -v kubectl && kubectl version --client"

  section "ENABLED SERVICES (non-default)"
  run "systemctl list-unit-files --state=enabled --no-pager | grep -vE '^(systemd|dbus|getty|cron|rsyslog|snapd)'"

  section "SHELL HISTORY (scrub before sharing)"
  run "cat ~/.bash_history"
} > "$OUT"

echo "Wrote $OUT"
echo "Review it and remove any tokens, passwords, or private IPs you don't want shared."
