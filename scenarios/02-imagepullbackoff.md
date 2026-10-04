# 02: ImagePullBackOff

**Area:** Workloads
**CKA domain:** Troubleshooting

## Symptom
Pod stuck in `ErrImagePull`, then `ImagePullBackOff`; never reaches `Running`.

## Reproduce
```bash
kubectl apply -f manifests/scenarios/imagepull.yaml
```

## Triage
```bash
kubectl get pods
kubectl describe pod imagepull-demo
```
Events chain observed: `Pulling` → `Failed` → `ErrImagePull` → `BackOff`

<!-- Paste your real Events output here -->

## Root cause
Image reference does not exist (bad name or tag). Other common causes: private registry
without `imagePullSecrets`, no network/DNS from the node, or no image for the node's
architecture (relevant on ARM64).

## Fix
Correct the image reference, then reapply.

## Lessons learned
- `kubectl logs` is useless here; the container never started. Events are the source of truth.
- On ARM64, confirm the image publishes a linux/arm64 variant.
