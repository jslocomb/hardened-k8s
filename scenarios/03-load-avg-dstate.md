# 03: High load average with idle CPU (D-state / I/O wait)

**Area:** Linux node
**CKA domain:** Troubleshooting (node)

## Symptom
Load average climbs while the CPUs are doing almost no actual work.

## Reproduce
```bash
./scripts/dstate-repro.sh            # 4 workers, 4G, O_DIRECT, captures after 20s
```

## Triage (real output, trimmed)

**vmstat:** blocked processes and I/O wait, with almost no CPU work.
```
 r  b   swpd   free   buff  cache   si   so    bi     bo    in    cs us sy id wa
 1  0      0 6203276 169888 2516752   0    0    22   2176  2881     9  1  1 97  0   <- before load
 0  5      0 6199652 170060 2517416   0    0     0 374220 10546 15386  1  2 37 60
 0  4      0 6199652 170060 2517416   0    0 169984 955692 24014 37435  6 13  4 78
 0  4      0 6199652 170060 2517416   0    0 568064      0 14279 20812  1  4  6 90
 0  4      0 6199652 170060 2517416   0    0 868544      0 20295 30906  1  5  7 87
```
- `b` = 4-5: processes blocked on I/O, while `r` (runnable) is 0.
- `wa` = 60-90%: CPUs idle, waiting on disk. `us` + `sy` stay under 20%.
- `cache` doesn't grow: O_DIRECT is bypassing the page cache, so every I/O hits the disk.

**iostat -x:** the disk is the bottleneck.
```
avg-cpu:  %user   %nice %system %iowait  %steal   %idle
           0.87    0.00    6.09   87.54    0.00    5.51

Device       r/s     rkB/s  r_await  aqu-sz  %util
vda     17350.00 1110400.00     0.21    3.68  76.40
```
- ~17k reads/s, ~1.1 GB/s, average queue depth ~3.7, device ~76% utilized.

**D-state processes:**
```
D     391 [jbd2/dm-0-8]
D   51768 stress-ng-hdd
D   51769 stress-ng-hdd
D   51771 stress-ng-hdd
```
- Three stress workers in uninterruptible sleep, plus `jbd2`, the ext4 journal thread,
  blocked behind them.

**uptime** (20 seconds into the run): `load average: 1.35, 1.02, 0.69`
- Climbing, not yet peaked: load average is an exponentially smoothed value, so it trails
  the real state. With 4-5 processes in D state, it keeps rising toward ~4-5.

## Root cause
Linux load average counts processes in uninterruptible sleep (D state), not just runnable
ones. Processes waiting on disk I/O raise the load average while the CPUs sit mostly idle.

## Fix
Find and remove the I/O source (the stress job here). In production, typical sources are
a noisy neighbor on shared storage, a failing disk, a saturated storage backend, a hung
NFS/network mount, or a backup or log job hammering the disk.

## Lessons learned
- High load + low `us`/`sy` → check `wa` and the `b` column before suspecting CPU.
- `ps -eo state,pid,cmd | awk '$1=="D"'` names the blocked processes directly.
- Kernel threads like `jbd2` showing up in D state point at the filesystem layer, not
  just the application.
- **Reproducing it took two tries.** The first run wrote 2 GB through the page cache;
  with ~6 GB of free RAM, Linux absorbed the writes in memory and the disk barely moved
  (I/O wait 0%, no D-state processes). Adding `--hdd-opts direct` (O_DIRECT) forced real
  disk I/O. The same thing happens in production: a write-heavy job can look harmless
  until memory pressure or a sync forces the cache to flush.
