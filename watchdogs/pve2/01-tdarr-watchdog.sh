#!/bin/bash
# Tdarr watchdog — run on the secondary Proxmox host, every 5 minutes via cron.
# Silent unless the tdarr container is down - then restarts the stack via compose.
# Logs only actions, so a healthy run produces no output (watchdog pattern).
LOG=/var/log/tdarr-watchdog.log

if ! pct exec 118 -- docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^tdarr$'; then
  echo "$(date '+%F %T') tdarr container down - restarting stack" >> "$LOG"
  pct exec 118 -- bash -c 'cd /opt/tdarr && docker compose up -d' >> "$LOG" 2>&1
fi
exit 0
