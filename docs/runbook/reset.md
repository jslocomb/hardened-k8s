# Single-command reset

Destroys everything Labs 2–8 built so you can start again from Lab 2. Run it from the
Mac.

**What it removes, in order:**
1. Any k0rdent child clusters (so GCP resources are deleted by k0rdent while the
   management cluster still exists).
2. The GPU Operator and k0rdent Helm releases.
3. The `controller`, `worker-01`, and `worker-02` UTM VMs. `a0` (named `Linux` in UTM) is
   **never** touched.
4. The lab kubeconfigs, the `~/.ssh/config` block, and the three VMs' SSH host keys.
5. GCP: service-account keys, then (if you confirm) the whole lab project.
6. `~/Projects/hardened-k8s` (only if you type its name, and only when it has no
   unpushed commits or uncommitted changes).

Steps 5 and 6 ask before acting. Everything else runs without prompting; the script
prints the plan and waits for `RESET` first.

## Install the script

```bash
mkdir -p ~/Projects/hardened-k8s/scripts && cat > ~/Projects/hardened-k8s/scripts/reset-lab.sh << 'EOF'
#!/usr/bin/env bash
# Reset the hardened-k8s multi-node lab. See docs/runbook/reset.md.
set -uo pipefail

REPO="$HOME/Projects/hardened-k8s"
KCFG="$HOME/.kube/hardened-k8s.kubeconfig"
GCP_ENV="$HOME/.config/hardened-k8s/gcp.env"
VMS=(controller worker-01 worker-02)

say() { printf '\n==> %s\n' "$*"; }

say "This destroys the multi-node lab VMs (${VMS[*]}), lab Helm releases, child clusters, and lab kubeconfigs."
echo "    a0 ('Linux' in UTM) is not touched."
read -r -p "Type RESET to continue: " answer
[ "$answer" = "RESET" ] || { echo "Aborted."; exit 1; }

# 1. Child clusters first, while the management cluster can still clean up the cloud.
if [ -f "$KCFG" ] && kubectl --kubeconfig "$KCFG" get nodes >/dev/null 2>&1; then
  say "Deleting k0rdent ClusterDeployments (can take ~10 min)"
  if kubectl --kubeconfig "$KCFG" get crd clusterdeployments.k0rdent.mirantis.com >/dev/null 2>&1; then
    kubectl --kubeconfig "$KCFG" delete clusterdeployment --all -A --wait=true --timeout=20m \
      || echo "WARN: ClusterDeployment delete did not finish; check GCP in step 5."
  else
    echo "    none (k0rdent not installed)"
  fi

  # 2. Helm releases.
  say "Uninstalling Helm releases"
  helm --kubeconfig "$KCFG" uninstall gpu-operator -n gpu-operator 2>/dev/null && echo "    gpu-operator removed" || echo "    gpu-operator not installed"
  helm --kubeconfig "$KCFG" uninstall kcm -n kcm-system 2>/dev/null && echo "    kcm removed" || echo "    kcm not installed"
else
  say "Lab cluster not reachable; skipping steps 1-2 (child clusters and Helm releases)"
  echo "    If a GCP child cluster existed, step 5 is your cleanup."
fi

# 3. VMs.
say "Stopping and deleting UTM VMs"
for vm in "${VMS[@]}"; do
  if utmctl status "$vm" >/dev/null 2>&1; then
    utmctl stop "$vm" >/dev/null 2>&1 || true
    sleep 5
    utmctl delete "$vm" && echo "    deleted $vm"
  else
    echo "    $vm not found"
  fi
done

# 4. Local client state.
say "Removing kubeconfigs, SSH config block, and host keys"
rm -f "$KCFG" "$HOME/.kube/gcp-lab.kubeconfig"
if [ -f "$HOME/.ssh/config" ]; then
  sed -i '' '/^# hardened-k8s multi-node lab$/,/^    IdentityFile ~\/.ssh\/id_ed25519$/d' "$HOME/.ssh/config"
fi
for ip in 192.168.64.10 192.168.64.11 192.168.64.12; do ssh-keygen -R "$ip" >/dev/null 2>&1; done
for h in controller worker-01 worker-02; do ssh-keygen -R "$h" >/dev/null 2>&1; done

# 5. GCP.
if [ -f "$GCP_ENV" ] && command -v gcloud >/dev/null 2>&1; then
  # shellcheck disable=SC1090
  source "$GCP_ENV"
  say "GCP project $GCP_PROJECT"
  SA_EMAIL="$GCP_SA@$GCP_PROJECT.iam.gserviceaccount.com"
  for key in $(gcloud iam service-accounts keys list --iam-account="$SA_EMAIL" --managed-by=user --format='value(name)' 2>/dev/null); do
    gcloud iam service-accounts keys delete "$key" --iam-account="$SA_EMAIL" --quiet && echo "    deleted key $key"
  done
  rm -P "$HOME/.config/hardened-k8s/k0rdent-capg.json" 2>/dev/null || true
  echo "    Instances still in the project:"
  gcloud compute instances list --project="$GCP_PROJECT" --format='value(name)' 2>/dev/null | sed 's/^/      /'
  read -r -p "Delete the entire GCP project $GCP_PROJECT? [y/N] " del
  if [ "$del" = "y" ]; then
    gcloud projects delete "$GCP_PROJECT" --quiet && rm -f "$GCP_ENV" && echo "    project scheduled for deletion"
  else
    echo "    project kept"
  fi
else
  say "No GCP lab config found; skipping GCP"
fi

# 6. Repository.
if [ -d "$REPO/.git" ]; then
  say "Repository $REPO"
  dirty=$(git -C "$REPO" status --porcelain | wc -l | tr -d ' ')
  git -C "$REPO" fetch -q origin 2>/dev/null || true
  ahead=$(git -C "$REPO" rev-list --count '@{u}..HEAD' 2>/dev/null || echo "unknown")
  echo "    uncommitted changes: $dirty, unpushed commits: $ahead"
  if [ "$dirty" = "0" ] && [ "$ahead" = "0" ]; then
    read -r -p "Type the folder name (hardened-k8s) to delete the local clone, or press Enter to keep it: " name
    if [ "$name" = "hardened-k8s" ]; then
      rm -rf "$REPO" && echo "    removed $REPO (GitHub copy untouched)"
    else
      echo "    kept"
    fi
  else
    echo "    kept: commit and push first, or remove it by hand"
  fi
fi

say "Reset complete. Start again at docs/runbook/lab02-k0s-multinode.md (golden VM copies in ~/utm-golden are kept)."
EOF
chmod +x ~/Projects/hardened-k8s/scripts/reset-lab.sh && bash -n ~/Projects/hardened-k8s/scripts/reset-lab.sh && echo "syntax OK"
```

**Expected:** `syntax OK`.

## Run it

```bash
~/Projects/hardened-k8s/scripts/reset-lab.sh
```

**Expected:** the plan, a `Type RESET to continue:` prompt, then one `==>` heading per
step. Deleting child clusters can take ~10 min.

## Verify

```bash
utmctl list; ls ~/.kube/; grep -c 'hardened-k8s multi-node lab' ~/.ssh/config || true
```

**Expected:** `controller`, `worker-01`, and `worker-02` absent from the UTM list
(`Linux` still present), no `hardened-k8s.kubeconfig`, and `0`.

## Notes

- The golden disk copies in `~/utm-golden/` from Lab 2 are kept: restoring them is
  faster than rebuilding from the ISO. Delete with `rm -rf ~/utm-golden` if you want
  the disk space back.
- `gcloud projects delete` schedules the project for deletion; it can be restored for
  30 days with `gcloud projects undelete`.
- The script deletes the repo's local clone only. The commits on GitHub are untouched,
  so `git clone` brings it back.
