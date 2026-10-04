# Security hardening

Status key: Planned · In progress · Done

## Node (Ubuntu VM)
| Control | Status | Notes |
|---|---|---|
| SSH: key-only auth (`PasswordAuthentication no`) | Planned | Currently enabled |
| SSH: root login | Done | `prohibit-password` (Ubuntu default) |
| Host firewall (ufw or nftables), allow SSH + 6443 only | Planned | Not installed |
| Automatic security updates | Done | `unattended-upgrades` enabled |
| Swap disabled | Done | |

## Cluster
| Control | Status | Notes |
|---|---|---|
| API server: anonymous auth disabled, RBAC + Node authz | Done | k0s defaults, verified in process flags |
| RBAC: least-privilege roles and service accounts | Planned | |
| NetworkPolicies: default deny, explicit allow | Planned | kube-router enforces NetworkPolicy |
| Pod Security Standards (restricted) | Planned | |
| Image hygiene: pinned tags, trusted registries | Planned | |

## Repository
| Control | Status | Notes |
|---|---|---|
| Secrets hygiene: no kubeconfigs, keys, or inventory output committed | Done | See .gitignore |
