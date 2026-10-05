#!/usr/bin/env bash
# Reproduce high load average with low CPU work (scenario 03) and capture evidence.
# Runs stress-ng in the background with O_DIRECT, waits for I/O to build, then
# captures uptime, vmstat, iostat, and D-state processes while the load is live.
# Requires: stress-ng, sysstat (both installed by the Ansible toolkit role)
#
# Usage: ./dstate-repro.sh [duration] [workers] [total-bytes]
set -euo pipefail

DURATION="${1:-60s}"
WORKERS="${2:-4}"
BYTES="${3:-4G}"
WARMUP=20

for c in stress-ng vmstat iostat; do
  command -v "$c" >/dev/null || { echo "$c not installed" >&2; exit 1; }
done

# --hdd-opts direct bypasses the page cache. Without it, writes land in RAM
# and the disk (and load average) barely move on a VM with free memory.
stress-ng --hdd "$WORKERS" --hdd-bytes "$BYTES" --hdd-opts direct \
  --timeout "$DURATION" >/dev/null 2>&1 &
STRESS_PID=$!
trap 'kill "$STRESS_PID" 2>/dev/null || true' EXIT

echo "# stress-ng: $WORKERS hdd workers, $BYTES, O_DIRECT, $DURATION; capturing after ${WARMUP}s"
sleep "$WARMUP"

echo; echo "\$ uptime";   uptime
echo; echo "\$ vmstat 1 5"; vmstat 1 5
echo; echo "\$ iostat -x 1 3"; iostat -x 1 3
echo; echo "\$ ps -eo state,pid,cmd | awk '\$1==\"D\"'"
ps -eo state,pid,cmd | awk '$1=="D"'

wait "$STRESS_PID" 2>/dev/null || true
