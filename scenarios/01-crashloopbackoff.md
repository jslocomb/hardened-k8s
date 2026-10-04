# 01: CrashLoopBackOff

**Area:** Workloads
**CKA domain:** Troubleshooting

## Symptom
Pod repeatedly restarts; `STATUS` shows `CrashLoopBackOff` and `RESTARTS` climbs.

## Reproduce
```bash
kubectl apply -f manifests/scenarios/crashloop.yaml
```

## Triage
```bash
kubectl get pods -w
kubectl describe pod crashloop-demo      # Events: container started, then Back-off restarting
kubectl logs crashloop-demo              # current container output
kubectl logs crashloop-demo --previous   # output from the last crashed container
```
<!-- Paste your real output here -->

Note: `--previous` can return nothing if the prior container's logs are no longer
available. Fallback: check the exit code and reason in `kubectl describe` under
`Last State: Terminated`.

## Root cause
The container's command exits non-zero immediately, so the kubelet keeps restarting it
with exponential back-off.

## Fix
Correct the command or entrypoint, then reapply.

## Lessons learned
- `describe` first: Events and `Last State` usually name the cause.
- Exit code tells the story (1 = app error, 137 = killed/OOM, 126/127 = command problem).
