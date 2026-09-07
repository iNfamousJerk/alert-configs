#!/bin/bash
# ZFS/Drive Failure Watchdog — run on the primary Proxmox host, every 5 minutes via cron.
# SILENT normally. Only posts to Discord when a REAL disk problem appears:
#   - any ZFS pool leaves ONLINE (DEGRADED/FAULTED/UNAVAIL)
#   - any drive SMART health reports FAILED
# Uses a state file so it alerts on STATE CHANGE, not every 5 min (no spam).
set -uo pipefail

PVE1="10.0.0.10"; PVE2="10.0.0.11"; PBS="10.0.0.12"
PVE_PASS="YOUR_PVE_ROOT_PASSWORD"; PBS_PASS="YOUR_PBS_ROOT_PASSWORD"
DISCORD_WEBHOOK="https://YOUR_DISCORD_WEBHOOK_URL"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
STATE=/var/lib/disk-failure-watchdog.state
LOG=/var/log/disk-failure-watchdog.log

post_discord() {
  local msg="$1"
  DISCORD_WEBHOOK="$DISCORD_WEBHOOK" python3 - "$msg" <<'EOF'
import json, os, sys, urllib.request
msg, hook = sys.argv[1], os.environ["DISCORD_WEBHOOK"]
req = urllib.request.Request(hook, data=json.dumps({"content": msg}).encode(),
    headers={"Content-Type": "application/json", "User-Agent": "DriveWatchdog/1.0"})
try:
    urllib.request.urlopen(req, timeout=15); print("posted", len(msg))
except Exception as e:
    print("FAIL", e)
EOF
}

# Collect ONLY problem lines: pool not ONLINE, or SMART FAILED. Returns empty if all healthy.
# One SSH call per host - remote emits raw POOL|/SMART| markers only (no local-var formatting),
# which the caller maps to display text.
check_host() {
  local ip="$1" label="$2" pass="$3"
  export SSHPASS="$pass"
  timeout 40 sshpass -e ssh $SSH_OPTS root@"$ip" '
    zpool list -H -o name,health 2>/dev/null | while read -r pool health; do
      [ -z "$pool" ] && continue
      [ "$health" = "ONLINE" ] || echo "POOL|$pool|$health"
    done
    for dev in $(lsblk -dno NAME 2>/dev/null | grep -E "^(sd|nvme)"); do
      [ -b "/dev/$dev" ] || continue
      # match the actual health verdict line, NOT the WHEN_FAILED column header
      if smartctl -H "/dev/$dev" 2>/dev/null | grep -qE "self-assessment test result: FAILED|OVERALL HEALTH.*FAILED"; then
        echo "SMART|$dev|FAILED"
      fi
    done
  ' 2>/dev/null
}

# ── Run checks ──
all=""
for node in "PVE1|$PVE1|$PVE_PASS" "PVE2|$PVE2|$PVE_PASS" "PBS|$PBS|$PBS_PASS"; do
  label="${node%%|*}"; rest="${node#*|}"; ip="${rest%%|*}"; pass="${rest#*|}"
  while IFS='|' read -r kind a b; do
    [ -z "$kind" ] && continue
    case "$kind" in
      POOL)  all+=$'\n'"🔴 **$label** — ZFS pool **$a** is **$b**!" ;;
      SMART) all+=$'\n'"🔴 **$label** — drive **$a** SMART health **FAILED**!" ;;
    esac
  done < <(check_host "$ip" "$label" "$pass")
done

# trim
all="$(echo "$all" | sed '/^$/d')"

if [ -z "$all" ]; then
  # healthy - clear state so a future problem re-alerts
  [ -f "$STATE" ] && { echo "$(date '+%F %T') all clear" >> "$LOG"; rm -f "$STATE"; }
  exit 0
fi

# Problem detected - compute a signature to dedupe
sig="$(echo "$all" | md5sum | cut -d' ' -f1)"
if [ "$(cat "$STATE" 2>/dev/null)" != "$sig" ]; then
  # state changed (new problem or different problem) -> alert
  echo "$sig" > "$STATE"
  msg="🚨 **DISK FAILURE DETECTED** — $(date '+%a %b %d %Y %I:%M %p PT')${all}"
  post_discord "$msg"
  echo "$(date '+%F %T') ALERT: ${all}" >> "$LOG"
fi
exit 0
