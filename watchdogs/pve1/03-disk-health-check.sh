#!/bin/bash
# Disk Health Check — run on the primary Proxmox host (collects over SSH)
# Collects per-disk SMART health (ALL drives, incl. boot) + ZFS pool state for
# PVE1, PVE2 and PBS. Posts each node as its OWN Discord message. Loudly flags
# FAILED health, DEGRADED/FAULTED pools, or elevated reallocated/pending sectors.
set -uo pipefail

PVE1="10.0.0.10"
PVE2="10.0.0.11"
PBS="10.0.0.12"
PVE_PASS="YOUR_PVE_ROOT_PASSWORD"
PBS_PASS="YOUR_PBS_ROOT_PASSWORD"
DISCORD_WEBHOOK="https://YOUR_DISCORD_WEBHOOK_URL"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

post_discord() {
  local msg="$1"
  DISCORD_WEBHOOK="$DISCORD_WEBHOOK" python3 - "$msg" <<'EOF'
import json, os, sys, urllib.request
msg, hook = sys.argv[1], os.environ["DISCORD_WEBHOOK"]
if not msg.strip():
    print("SKIP empty"); sys.exit(0)
if len(msg) > 1900:
    msg = msg[:1900] + "\n... (truncated)"
req = urllib.request.Request(hook, data=json.dumps({"content": msg}).encode(),
    headers={"Content-Type": "application/json", "User-Agent": "DiskHealth/1.0"})
try:
    urllib.request.urlopen(req, timeout=15); print("OK", len(msg))
except Exception as e:
    print(f"FAIL {e}")
EOF
}

# field helper: extract VALUE for KEY from a |-delimited record
getf() { echo "$1" | tr '|' '\n' | awk -v k="$2" '{if (NR%2==1 && $0==k) {getline; print; exit}}'; }

collect_report() {
  for dev in $(lsblk -dno NAME 2>/dev/null | grep -E "^(sd|nvme)"); do
    [ -b "/dev/$dev" ] || continue
    boot="no"
    # root may sit on an LVM LV nested below the disk — check the whole tree
    if lsblk -no MOUNTPOINT "/dev/$dev" 2>/dev/null | grep -qx "/"; then
      boot="yes"
    fi
    model=$(lsblk -dno MODEL "/dev/$dev" 2>/dev/null | xargs)
    size=$(lsblk -dno SIZE "/dev/$dev" 2>/dev/null | xargs)
    health=$(smartctl -H "/dev/$dev" 2>/dev/null | grep -oE "PASSED|FAILED" | head -1)
    [ -z "$health" ] && health="N/A"
    temp=$(smartctl -A "/dev/$dev" 2>/dev/null | grep -i "Temperature_Celsius" | awk '{print $10}' | head -1)
    [ -z "$temp" ] && temp="-"
    realloc=$(smartctl -A "/dev/$dev" 2>/dev/null | grep -iE "Reallocated_Sector_Ct" | awk '{print $10}' | head -1)
    [ -z "$realloc" ] && realloc="-"
    pending=$(smartctl -A "/dev/$dev" 2>/dev/null | grep -iE "Current_Pending_Sector" | awk '{print $10}' | head -1)
    [ -z "$pending" ] && pending="-"
    poh=$(smartctl -A "/dev/$dev" 2>/dev/null | grep -i "Power_On_Hours" | awk '{print $10}' | head -1)
    # strip any trailing junk (rare on some drives)
    [ -z "$poh" ] && poh="-"
    poh=$(echo "$poh" | grep -oE '^[0-9]+' | head -1)
    [ -z "$poh" ] && poh="-"
    echo "DEV|$dev|BOOT|$boot|MODEL|$model $size|HEALTH|$health|TEMP|$temp|REALLOC|$realloc|PENDING|$pending|POH|$poh"
  done
  if command -v zpool >/dev/null 2>&1; then
    zpool list -H -o name,health,alloc,capacity 2>/dev/null | while read -r zl; do
      echo "ZPOOL|$zl"
    done
    zpool status 2>/dev/null | grep -E "state:|errors:|scan:" | head -6 | sed 's/^/ZSTAT|/'
  fi
}

build_msg() {
  local node="$1" raw="$2" problem=0
  local lines out=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      DEV\|*)
        local dev boot model health temp realloc pending poh
        dev=$(getf "$line" DEV); boot=$(getf "$line" BOOT)
        model=$(getf "$line" MODEL); health=$(getf "$line" HEALTH)
        temp=$(getf "$line" TEMP); realloc=$(getf "$line" REALLOC)
        pending=$(getf "$line" PENDING); poh=$(getf "$line" POH)
        local icon="🟢" flag=""
        [ "$health" = "FAILED" ] && { icon="🔴"; flag=" **FAILING**"; problem=1; }
        [ "$health" = "N/A" ] && icon="⚪"
        [ "$boot" = "yes" ] && flag="$flag  *(boot)*"
        if [ "$health" = "PASSED" ] && [ "$realloc" != "-" ] && [ "$realloc" -gt 20 ] 2>/dev/null; then
          flag="$flag  ⚠️ realloc=$realloc"; problem=1
        fi
        if [ "$health" = "PASSED" ] && [ "$pending" != "-" ] && [ "$pending" -gt 5 ] 2>/dev/null; then
          flag="$flag  ⚠️ pending=$pending"; problem=1
        fi
        [ "$realloc" = "-" ] && realloc="n/a"
        [ "$pending" = "-" ] && pending="n/a"
        out+=$'\n'"${icon} **${dev}** — ${model}  |  SMART: ${health}  |  ${temp}°C"
        out+=$'\n'"     Reallocated: ${realloc}  |  Pending: ${pending}  |  POH: ${poh}h${flag}"
        ;;
      ZPOOL\|*)
        local pl="${line#ZPOOL|}"
        local pname=$(echo "$pl" | awk '{print $1}') phealth=$(echo "$pl" | awk '{print $2}')
        local pall=$(echo "$pl" | awk '{print $3}') pcap=$(echo "$pl" | awk '{print $4}')
        local picon="🟢"
        [ "$phealth" != "ONLINE" ] && { picon="🔴"; problem=1; }
        out+=$'\n'"${picon} **ZFS ${pname}**: ${phealth}  |  ${pall} used (${pcap})"
        ;;
      ZSTAT\|*)
        out+=$'\n'"    ${line#ZSTAT|}"
        ;;
    esac
  done <<< "$raw"
  local hdr="🟢 **$node — all drives healthy**"
  [ "$problem" -gt 0 ] && hdr="🔴 **$node — ⚠️ DISK ISSUE DETECTED**"
  printf '%s\n%s\n' "$hdr" "$out"
}

export SSHPASS="$PVE_PASS"
raw1=$(timeout 60 sshpass -e ssh $SSH_OPTS root@"$PVE1" "$(declare -f collect_report); collect_report" 2>&1)
raw2=$(timeout 60 sshpass -e ssh $SSH_OPTS root@"$PVE2" "$(declare -f collect_report); collect_report" 2>&1)
export SSHPASS="$PBS_PASS"
raw3=$(timeout 60 sshpass -e ssh $SSH_OPTS root@"$PBS" "$(declare -f collect_report); collect_report" 2>&1)

msg1=$(build_msg "PVE1 ($PVE1)" "$raw1")
msg2=$(build_msg "PVE2 ($PVE2)" "$raw2")
msg3=$(build_msg "PBS ($PBS)" "$raw3")

LOG=/var/log/disk-health.log
{ echo "=== $(date) ==="; echo "---PVE1---"; echo "$raw1"; echo "---PVE2---"; echo "$raw2"; echo "---PBS---"; echo "$raw3"; } >> "$LOG" 2>/dev/null

post_discord "$msg1"
post_discord "$msg2"
post_discord "$msg3"
exit 0
