# 03: High load average with idle CPU (D-state / I/O wait)

**Area:** Linux node
**CKA domain:** Troubleshooting (node)

## Symptom
Load average is high while CPU looks mostly idle.

## Reproduce
```bash
./scripts/dstate-repro.sh
```

## Triage
```bash
uptime                                   # load average
top                                      # watch 'wa' (I/O wait)
vmstat 1 5                               # 'b' = blocked processes, 'wa' = I/O wait
iostat -x 1 5                            # %util near 100 = saturated disk
ps -eo state,pid,cmd | awk '$1=="D"'     # processes in uninterruptible sleep
```

Observed in my lab: load average about 2.84, I/O wait 69-80%, disk at 100% utilization,
with live D-state processes visible in `ps`.

<!-- Paste your real output here -->

## Root cause
Linux load average counts processes in uninterruptible sleep (D-state), not just
runnable ones. Processes blocked on disk I/O raise load without using CPU.

## Fix
Find and address the I/O source (the stress job here). In production: noisy neighbor,
failing disk, saturated storage backend, or a hung NFS/network storage mount.

## Lessons learned
- High load + low CPU usage → think I/O wait and D-state first.
- `vmstat` `b` column and `ps` state `D` confirm it quickly.
