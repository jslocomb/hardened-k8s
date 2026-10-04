# Lab environment

## Host and VM
- Host: Mac Mini M4
- Hypervisor: UTM
- Guest: Ubuntu 24.04 LTS, ARM64

## Kubernetes install (k0s)
<!-- Replace with the exact commands you used. Example shape: -->
```bash
curl -sSLf https://get.k0s.sh | sudo sh
sudo k0s install controller --single
sudo k0s start
sudo k0s status
sudo k0s kubectl get nodes
```

## Tools installed
- stress-ng (I/O load generation)
- <!-- add others -->

## Known quirks
- <!-- e.g., ARM64 image availability, UTM networking notes -->
