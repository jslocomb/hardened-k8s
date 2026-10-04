#!/usr/bin/env bash
# Generate disk I/O load to reproduce high load average with idle CPU (scenario 03).
# Requires: stress-ng (sudo apt install stress-ng)
set -euo pipefail

DURATION="${1:-60s}"
WORKERS="${2:-4}"

command -v stress-ng >/dev/null || { echo "stress-ng not installed" >&2; exit 1; }

echo "Running ${WORKERS} hdd workers for ${DURATION}. In another terminal, run:"
echo "  uptime; vmstat 1 5; iostat -x 1 5; ps -eo state,pid,cmd | awk '\$1==\"D\"'"
stress-ng --hdd "${WORKERS}" --timeout "${DURATION}" --metrics-brief
