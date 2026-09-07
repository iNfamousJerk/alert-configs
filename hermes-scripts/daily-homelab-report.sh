#!/bin/bash
# Daily Self-Hosted Health Report — runs once daily
# Posts separate Discord messages, one per node.
# Each message is small enough to never hit Discord's 2000-char limit (no truncation).
set -uo pipefail

PVE1="10.0.0.10"
PVE2="10.0.0.11"
PBS="10.0.0.12"
PVE_PASS="YOUR_PVE_ROOT_PASSWORD"
PBS_PASS="YOUR_PBS_ROOT_PASSWORD"

SSH_OPTS="-o ConnectTimeout=6 -o StrictHostKeyChecking=no -o PasswordAuthentication=no"
DISCORD_WEBHOOK="https://YOUR_DISCORD_WEBHOOK_URL"

# Post one message to the Discord webhook. Handles truncation defensively.
post_discord() {
  local msg="$1"
  python3 - "$msg" "$DISCORD_WEBHOOK" <<'EOF'
import json, sys, urllib.request
msg, hook = sys.argv[1], sys.argv[2]
if len(msg) > 1900:
    msg = msg[:1900] + "\n... (truncated)"
data = json.dumps({"content": msg}).encode()
req = urllib.request.Request(
    hook, data=data,
    headers={"Content-Type": "application/json", "User-Agent": "SelfHosted-HealthCheck/1.0"})
try:
    urllib.request.urlopen(req, timeout=15); print("Discord post OK")
except Exception as e:
    print(f"Discord post failed: {e}")
EOF
}

# "size used pct" -> "used/size (pct)"
fmt_disk() {
  set -- $1
  if [ "$#" -ge 3 ]; then
    echo "${2}/${1} (${3})"
  else
    echo "${1:-?}"
  fi
}

# ─────────────────────────────────────────────────────────────
# Message 1 — PVE1
# ─────────────────────────────────────────────────────────────
pve1_raw=$(timeout 45 ssh $SSH_OPTS root@"$PVE1" '
  echo "VER:$(dpkg -s pve-manager 2>/dev/null | grep "^Version:" | cut -d" " -f2 || echo unknown)"
  echo "UP:$(uptime -p | sed "s/^up //")"
  echo "LOAD:$(uptime | awk -F"load average:" "{print \$2}" | xargs)"
  echo "MEM:$(free -h | awk "/^Mem:/{print \$3\"/\"\$2\" used\"}")"
  echo "SWAP:$(free -m | awk "/^Swap:/{print \$3}")"
  echo "DISK:$(df -h / | tail -1 | tr -s " " | cut -d" " -f2,3,5)"
  echo "CT:$(pct list 2>/dev/null | tail -n +2 | wc -l)"
  echo "UPDATES:$(apt list --upgradable 2>/dev/null | grep -c upgradable)"
  echo "REBOOT:$([ -f /var/run/reboot-required ] && echo YES || echo NO)"
' 2>&1) || pve1_raw="UNREACHABLE"

pve1_ver=$(echo "$pve1_raw" | sed -n 's/^VER://p')
pve1_up=$(echo "$pve1_raw" | sed -n 's/^UP://p')
pve1_load=$(echo "$pve1_raw" | sed -n 's/^LOAD://p')
pve1_mem=$(echo "$pve1_raw" | sed -n 's/^MEM://p')
pve1_swap=$(echo "$pve1_raw" | sed -n 's/^SWAP://p')
pve1_disk=$(echo "$pve1_raw" | sed -n 's/^DISK://p')
pve1_ct=$(echo "$pve1_raw" | sed -n 's/^CT://p')
pve1_upd=$(echo "$pve1_raw" | sed -n 's/^UPDATES://p')
pve1_rb=$(echo "$pve1_raw" | sed -n 's/^REBOOT://p')
[ -z "$pve1_ver" ] && pve1_ver="?"
[ -z "$pve1_up" ] && pve1_up="unreachable"
[ -z "$pve1_load" ] && pve1_load="?"
[ -z "$pve1_mem" ] && pve1_mem="?"
[ -z "$pve1_swap" ] && pve1_swap="?"
[ -z "$pve1_disk" ] && pve1_disk="?" || pve1_disk="$(fmt_disk "$pve1_disk")"
[ -z "$pve1_ct" ] && pve1_ct="?"
pve1_upd=$(echo "$pve1_upd" | grep -o '^[0-9]*' | head -1); [ -z "$pve1_upd" ] && pve1_upd=0

MSG1=$(printf '━━━ 🖥️ **PVE1 — %s** ━━━\n  `v%s`  |  up %s\n  Load: %s  |  Mem: %s  |  Swap: %s MB\n  Disk: %s  |  Containers: %s running\n  %s' \
  "$PVE1" "$pve1_ver" "$pve1_up" "$pve1_load" "$pve1_mem" "$pve1_swap" "$pve1_disk" "$pve1_ct" \
  "$( [ "$pve1_upd" -gt 0 ] && echo "🔄 **$pve1_upd** updates available${pve1_rb:+, reboot required}" || echo "✅ All packages up to date" )")

# ─────────────────────────────────────────────────────────────
# Message 2 — PVE2
# ─────────────────────────────────────────────────────────────
pve2_raw=$(timeout 45 ssh $SSH_OPTS root@"$PVE2" '
  echo "VER:$(dpkg -s pve-manager 2>/dev/null | grep "^Version:" | cut -d" " -f2 || echo unknown)"
  echo "UP:$(uptime -p | sed "s/^up //")"
  echo "LOAD:$(uptime | awk -F"load average:" "{print \$2}" | xargs)"
  echo "MEM:$(free -h | awk "/^Mem:/{print \$3\"/\"\$2\" used\"}")"
  echo "SWAP:$(free -m | awk "/^Swap:/{print \$3}")"
  echo "DISK:$(df -h / | tail -1 | tr -s " " | cut -d" " -f2,3,5)"
  echo "CT:$(pct list 2>/dev/null | tail -n +2 | wc -l)"
  echo "ZFS:$(zpool list -H -o name,size,alloc,capacity,health media 2>/dev/null)"
  echo "UPDATES:$(apt list --upgradable 2>/dev/null | grep -c upgradable)"
  echo "REBOOT:$([ -f /var/run/reboot-required ] && echo YES || echo NO)"
' 2>&1) || pve2_raw="UNREACHABLE"

pve2_ver=$(echo "$pve2_raw" | sed -n 's/^VER://p')
pve2_up=$(echo "$pve2_raw" | sed -n 's/^UP://p')
pve2_load=$(echo "$pve2_raw" | sed -n 's/^LOAD://p')
pve2_mem=$(echo "$pve2_raw" | sed -n 's/^MEM://p')
pve2_swap=$(echo "$pve2_raw" | sed -n 's/^SWAP://p')
pve2_disk=$(echo "$pve2_raw" | sed -n 's/^DISK://p')
pve2_ct=$(echo "$pve2_raw" | sed -n 's/^CT://p')
pve2_zfs=$(echo "$pve2_raw" | sed -n 's/^ZFS://p')
pve2_upd=$(echo "$pve2_raw" | sed -n 's/^UPDATES://p')
pve2_rb=$(echo "$pve2_raw" | sed -n 's/^REBOOT://p')
[ -z "$pve2_ver" ] && pve2_ver="?"
[ -z "$pve2_up" ] && pve2_up="unreachable"
[ -z "$pve2_load" ] && pve2_load="?"
[ -z "$pve2_mem" ] && pve2_mem="?"
[ -z "$pve2_swap" ] && pve2_swap="?"
[ -z "$pve2_disk" ] && pve2_disk="?" || pve2_disk="$(fmt_disk "$pve2_disk")"
[ -z "$pve2_ct" ] && pve2_ct="?"
[ -z "$pve2_zfs" ] && pve2_zfs="ZFS: n/a"
pve2_upd=$(echo "$pve2_upd" | grep -o '^[0-9]*' | head -1); [ -z "$pve2_upd" ] && pve2_upd=0

# Parse ZFS line: name size alloc cap health
zfs_size=$(echo "$pve2_zfs" | awk '{print $2}')
zfs_used=$(echo "$pve2_zfs" | awk '{print $3}')
zfs_pct=$(echo "$pve2_zfs" | awk '{print $4}')
zfs_health=$(echo "$pve2_zfs" | awk '{print $5}')
if [ -n "$zfs_health" ]; then
  zfs_line="  📀 ZFS media — ${zfs_used}B/${zfs_size}B (${zfs_pct}) — ${zfs_health}"
else
  zfs_line="  📀 ZFS media — n/a"
fi

MSG2=$(printf '━━━ 🖥️ **PVE2 — %s** ━━━\n  `v%s`  |  up %s\n  Load: %s  |  Mem: %s  |  Swap: %s MB\n  Disk: %s  |  Containers: %s running\n%s\n  %s' \
  "$PVE2" "$pve2_ver" "$pve2_up" "$pve2_load" "$pve2_mem" "$pve2_swap" "$pve2_disk" "$pve2_ct" \
  "$zfs_line" \
  "$( [ "$pve2_upd" -gt 0 ] && echo "🔄 **$pve2_upd** updates available${pve2_rb:+, reboot required}" || echo "✅ All packages up to date" )")

# ─────────────────────────────────────────────────────────────
# Message 3 — PBS
# ─────────────────────────────────────────────────────────────
export SSHPASS="$PBS_PASS"
pbs_raw=$(timeout 45 sshpass -e ssh -o ConnectTimeout=6 -o StrictHostKeyChecking=no root@"$PBS" '
  echo "VER:$(proxmox-backup-manager versions --verbose 2>/dev/null | grep proxmox-backup-server | awk "{print \$2}")"
  echo "UP:$(uptime -p | sed "s/^up //")"
  echo "LOAD:$(uptime | awk -F"load average:" "{print \$2}" | xargs)"
  echo "MEM:$(free -h | awk "/^Mem:/{print \$3\"/\"\$2\" used\"}")"
  echo "SWAP:$(free -m | awk "/^Swap:/{print \$3}")"
  echo "DISK:$(df -h / | tail -1 | tr -s " " | cut -d" " -f2,3,5)"
  echo "DS:$(df -h /mnt/datastore/backups 2>/dev/null | tail -1 | tr -s " " | cut -d" " -f2,3,5)"
  echo "UPDATES:$(apt list --upgradable 2>/dev/null | grep -c upgradable)"
  echo "REBOOT:$([ -f /var/run/reboot-required ] && echo YES || echo NO)"
' 2>&1) || pbs_raw="UNREACHABLE"

pbs_ver=$(echo "$pbs_raw" | sed -n 's/^VER://p')
pbs_up=$(echo "$pbs_raw" | sed -n 's/^UP://p')
pbs_load=$(echo "$pbs_raw" | sed -n 's/^LOAD://p')
pbs_mem=$(echo "$pbs_raw" | sed -n 's/^MEM://p')
pbs_swap=$(echo "$pbs_raw" | sed -n 's/^SWAP://p')
pbs_disk=$(echo "$pbs_raw" | sed -n 's/^DISK://p')
pbs_ds=$(echo "$pbs_raw" | sed -n 's/^DS://p')
pbs_upd=$(echo "$pbs_raw" | sed -n 's/^UPDATES://p')
pbs_rb=$(echo "$pbs_raw" | sed -n 's/^REBOOT://p')
[ -z "$pbs_ver" ] && pbs_ver="?"
[ -z "$pbs_up" ] && pbs_up="unreachable"
[ -z "$pbs_load" ] && pbs_load="?"
[ -z "$pbs_mem" ] && pbs_mem="?"
[ -z "$pbs_swap" ] && pbs_swap="?"
[ -z "$pbs_disk" ] && pbs_disk="?" || pbs_disk="$(fmt_disk "$pbs_disk")"
[ -z "$pbs_ds" ] && pbs_ds="n/a" || pbs_ds="$(fmt_disk "$pbs_ds")"
pbs_upd=$(echo "$pbs_upd" | grep -o '^[0-9]*' | head -1); [ -z "$pbs_upd" ] && pbs_upd=0

MSG3=$(printf '━━━ 💾 **PBS — %s** ━━━\n  `v%s`  |  up %s\n  Load: %s  |  Mem: %s  |  Swap: %s MB\n  Disk: %s  |  Datastore backups: %s\n  %s' \
  "$PBS" "$pbs_ver" "$pbs_up" "$pbs_load" "$pbs_mem" "$pbs_swap" "$pbs_disk" "$pbs_ds" \
  "$( [ "$pbs_upd" -gt 0 ] && echo "🔄 **$pbs_upd** updates available${pbs_rb:+, reboot required}" || echo "✅ All packages up to date" )")

# ─────────────────────────────────────────────────────────────
# Log locally + post all three
# ─────────────────────────────────────────────────────────────
LOG="$HOME/self-hosted-report.log"
{ echo "=== $(date) ==="; echo "$MSG1"; echo; echo "$MSG2"; echo; echo "$MSG3"; } >> "$LOG" 2>/dev/null

post_discord "$MSG1"
post_discord "$MSG2"
post_discord "$MSG3"

exit 0
