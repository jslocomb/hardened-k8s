# Probes Quick Reference

**CKA relevance:** "self-healing primitives" (Workloads & Scheduling, 15%) and probe failures as a cause in Troubleshooting (30%). Course lecture: 120, Self Healing Applications.

Probes are set **per container**, not per pod. The kubelet runs them.

## The two you must know

| | Liveness | Readiness |
| --- | --- | --- |
| Question it asks | Is the container alive? | Is it ready for traffic? |
| On repeated failure | kubelet **restarts the container** | Pod is **removed from Service endpoints**; no restart |
| What you see | `RESTARTS` climbing, Events: `Liveness probe failed` | `READY 0/1`, Service has no endpoints |
| Typical use | App hangs or deadlocks but the process stays up | Slow start, warming caches, waiting on a dependency |

A third type, **startupProbe**, holds off liveness and readiness until a slow-starting app is up. (From the Kubernetes docs; not in the video.)

## Example

```yaml
spec:
  containers:
  - name: web
    image: nginx
    livenessProbe:            # swap the key to readinessProbe; the body stays the same
      httpGet:
        path: /healthz
        port: 8080
      initialDelaySeconds: 2  # wait after start before the first probe
      periodSeconds: 5        # probe every N seconds
      timeoutSeconds: 1       # seconds to answer before it counts as a failure
      failureThreshold: 3     # consecutive failures before acting
```

## Check methods

| Method | Use when |
| --- | --- |
| `httpGet` (path, port) | HTTP app; 200–399 counts as success |
| `tcpSocket` (port) | Something listening, no HTTP (databases, for example) |
| `exec` (command) | Exit code 0 counts as success, e.g. `cat /tmp/healthy` |
| `grpc` (port) | gRPC health-checking service |

## Defaults (when a field is omitted)

`initialDelaySeconds: 0` · `periodSeconds: 10` · `timeoutSeconds: 1` · `failureThreshold: 3` · `successThreshold: 1`

## Exam speed

- No imperative flag exists for probes. Generate YAML with `k run web --image nginx $do > web.yaml`, then add the probe block.
- Docs search term: "Configure Liveness, Readiness and Startup Probes".
- `k explain pod.spec.containers.livenessProbe --recursive` shows every field.
- An existing pod's probe can't be edited in place: `k edit` saves a copy to /tmp, then `k replace --force -f /tmp/<file>.yaml`.

## Troubleshooting

1. `k get pod`: `RESTARTS` climbing points to liveness; `READY 0/1` points to readiness.
2. `k describe pod <name>`: Events show `Liveness probe failed` / `Readiness probe failed`, with the HTTP code or error.
3. `k get endpoints <svc>`: empty usually means readiness is failing on every backend pod.
4. Common causes: wrong port or path, `initialDelaySeconds` too short for app startup, `timeoutSeconds` too tight.

---
Sources: Alta3 "Kubernetes Zero to Hero," probes segment 51:09–58:20 (https://www.youtube.com/watch?v=MTHGoGUFpvE); startupProbe, grpc and defaults from the Kubernetes docs page "Configure Liveness, Readiness and Startup Probes."
