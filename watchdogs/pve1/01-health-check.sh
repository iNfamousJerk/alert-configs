#!/bin/bash
# Condensed host health check (primary/secondary Proxmox hosts + backup server):
# uptime, updates, container status, drive stats.
# Called by the automation-agent cron — silent unless output is produced.

PVE_IP="10.0.0.10"
PVE_PASS="YOUR_PVE_ROOT_PASSWORD"
PBS_IP="10.0.0.12"
PBS_PASS="YOUR_PBS_ROOT_PASSWORD"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# ===== PVE =====
pve_raw=$(sshpass -p "$PVE_PASS" ssh $SSH_OPTS root@$PVE_IP '
  echo "===UPDATES==="
  apt update -qq 2>/dev/null
  apt list --upgradable 2>/dev/null | grep -c upgradable
  echo "REBOOTREQ"
  [ -f /var/run/reboot-required ] && echo "YES" || echo "NO"
  echo "===VERSION==="
  dpkg -s pve-manager 2>/dev/null | grep "^Version:" | cut -d" " -f2 || echo "unknown"
  echo "===UPTIME==="
  uptime -p | sed "s/^up //"
  echo "===LOAD==="
  uptime | awk -F"load average:" "{print \$2}" | xargs
  echo "===MEM==="
  free -h | grep Mem | awk "{print \$3\"/\"\$2\" used\"}"
  echo "===DISK-ROOT==="
  df -h / | tail -1 | awk "{print \$3\"/\"\$2\" (\"\$5\")\"}"
  echo "===DISK-MODEL==="
  lsblk -ndo MODEL /dev/sda 2>/dev/null | head -1
  echo "===DISK-SIZE==="
  lsblk -ndo SIZE /dev/sda 2>/dev/null | head -1
  echo "===SMART==="
  smartctl -H /dev/sda 2>/dev/null | grep -o "PASSED\|FAILED" || echo "N/A"
  echo "===LV-DETAIL==="
  lvs --noheadings -o lv_name,lv_size,data_percent 2>/dev/null | awk "{if (\$3 != \"\") print \$1,\$2,\$3\"%\"; else print \$1,\$2,\"-\"}"
  echo "===CTS==="
  for vmid in $(pct list 2>/dev/null | tail -n +2 | awk "{print \$1}"); do
    status=$(pct status $vmid 2>/dev/null | awk "{print \$2}")
    hostname=$(pct exec $vmid -- hostname 2>/dev/null || echo "?")
    echo "$vmid $status $hostname"
  done
' 2>&1)
pve_exit=$?

# ===== PVE2 =====
pve2_raw=$(sshpass -p "$PVE_PASS" ssh $SSH_OPTS root@10.0.0.11 '
  echo "===UPDATES==="
  apt update -qq 2>/dev/null
  apt list --upgradable 2>/dev/null | grep -c upgradable
  echo "REBOOTREQ"
  [ -f /var/run/reboot-required ] && echo "YES" || echo "NO"
  echo "===VERSION==="
  dpkg -s pve-manager 2>/dev/null | grep "^Version:" | cut -d" " -f2 || echo "unknown"
  echo "===UPTIME==="
  uptime -p | sed "s/^up //"
  echo "===LOAD==="
  uptime | awk -F"load average:" "{print \$2}" | xargs
  echo "===MEM==="
  free -h | grep Mem | awk "{print \$3\"/\"\$2\" used\"}"
  echo "===DISK-ROOT==="
  df -h / | tail -1 | awk "{print \$3\"/\"\$2\" (\"\$5\")\"}"
  echo "===BOOT-DISK==="
  lsblk -ndo MODEL,SIZE /dev/sde 2>/dev/null | head -1
  echo "===SMART==="
  smartctl -H /dev/sde 2>/dev/null | grep -o "PASSED\|FAILED" || echo "N/A"
  echo "===ZPOOL==="
  zpool list -H -o name,size,alloc,capacity,health 2>/dev/null | head -1
  echo "===ZPOOL-DISKS==="
  zpool status media 2>/dev/null | grep -E "^\s+(sda|sdb|sdc|sdd)" | awk "{print \$1\" \"\$3\" \"\$4}" | sed "s/\(..*\)$/\1/"
  echo "===CTS==="
  for vmid in $(pct list 2>/dev/null | tail -n +2 | awk "{print \$1}"); do
    status=$(pct status $vmid 2>/dev/null | awk "{print \$2}")
    hostname=$(pct exec $vmid -- hostname 2>/dev/null || echo "?")
    echo "$vmid $status $hostname"
  done
' 2>&1)
pve2_exit=$?

# ===== PBS =====
pbs_raw=$(sshpass -p "$PBS_PASS" ssh $SSH_OPTS root@$PBS_IP '
  echo "===UPDATES==="
  apt update -qq 2>/dev/null
  apt list --upgradable 2>/dev/null | grep -c upgradable
  echo "REBOOTREQ"
  [ -f /var/run/reboot-required ] && echo "YES" || echo "NO"
  echo "===VERSION==="
  proxmox-backup-manager versions --verbose 2>/dev/null | grep "proxmox-backup-server" | awk "{print \$2}" || echo "(unknown)"
  echo "===UPTIME==="
  uptime -p | sed "s/^up //"
  echo "===LOAD==="
  uptime | awk -F"load average:" "{print \$2}" | xargs
  echo "===MEM==="
  free -h | grep Mem | awk "{print \$3\"/\"\$2\" used\"}"
  echo "===DISK-ROOT==="
  df -h / | tail -1 | awk "{print \$3\"/\"\$2\" (\"\$5\")\"}"
  echo "===ZPOOL==="
  zpool list -H -o name,size,alloc,capacity,health 2>/dev/null | head -1
  echo "===DISKS==="
  for d in sda sdb sdc; do
    model=$(lsblk -ndo MODEL /dev/$d 2>/dev/null | head -1)
    size=$(lsblk -ndo SIZE /dev/$d 2>/dev/null | head -1)
    smart=$(smartctl -H /dev/$d 2>/dev/null | grep -m1 "PASSED\|FAILED" | grep -o "PASSED\|FAILED" || echo "?")
    echo "$d $size $smart $model"
  done
  echo "===DATASTORE==="
  proxmox-backup-manager datastore list 2>/dev/null | grep -A4 "backups" || true
' 2>&1)
pbs_exit=$?

# ===== Helper =====
extract_line_after() {
  echo "$1" | sed -n "/^$2$/{n;p}"
}
extract_block() {
  echo "$1" | sed -n "/^$2$/,/^$3$/{/^$2$/d;/^$3$/d;p}"
}

# ===== PVE output =====
echo "**📡 Health Check — $(date '+%a %b %d %Y %I:%M %p')**"
echo ""

if [ $pve_exit -eq 0 ]; then
  pve_ver=$(extract_line_after "$pve_raw" "===VERSION===")
  pve_uptime=$(extract_line_after "$pve_raw" "===UPTIME===")
  pve_load=$(extract_line_after "$pve_raw" "===LOAD===")
  pve_mem=$(extract_line_after "$pve_raw" "===MEM===")
  pve_disk=$(extract_line_after "$pve_raw" "===DISK-ROOT===")
  pve_model=$(extract_line_after "$pve_raw" "===DISK-MODEL===")
  pve_disk_size=$(extract_line_after "$pve_raw" "===DISK-SIZE===")
  pve_smart=$(extract_line_after "$pve_raw" "===SMART===")
  pve_updates=$(extract_block "$pve_raw" "===UPDATES===" "REBOOTREQ" | head -1)
  pve_reboot=$(extract_line_after "$pve_raw" "REBOOTREQ")
  pve_lvs=$(extract_block "$pve_raw" "===LV-DETAIL===" "===CTS===" | grep -v '^$')
  pve_cts=$(extract_block "$pve_raw" "===CTS===" "" | grep -v '^$')

  # Count CTs by status — use grep exit code safely to avoid false lines
  pve_ct_total=$(echo "$pve_cts" | grep -c '.' 2>/dev/null || echo 0)
  pve_ct_running=$(echo "$pve_cts" | awk '$2 == "running"' | wc -l)
  pve_ct_stopped=$(echo "$pve_cts" | awk '$2 == "stopped"' | wc -l)

  echo "**🖥️ PVE — 10.0.0.10**  |  up $pve_uptime"
  echo "  \`v$pve_ver\`  |  Load: $pve_load  |  Mem: $pve_mem"
  echo ""

  # Drive section
  echo "  **💾 Drive:** ${pve_model} (${pve_disk_size})  |  SMART: ${pve_smart}  |  ${pve_disk}"
  while IFS= read -r lv; do
    [ -z "$lv" ] && continue
    lv_name=$(echo "$lv" | awk '{print $1}')
    lv_size=$(echo "$lv" | awk '{print $2}')
    lv_pct=$(echo "$lv" | awk '{print $3}')
    [ "$lv_pct" != "-" ] && echo "    └─ $lv_name  ${lv_size}  (${lv_pct})" || echo "    └─ $lv_name  ${lv_size}"
  done <<< "$pve_lvs"
  echo ""

  # CT section
  echo "  **📦 Containers:** ${pve_ct_total} total  |  🟢 ${pve_ct_running} running  |  🔴 ${pve_ct_stopped} stopped"
  while IFS= read -r ct; do
    [ -z "$ct" ] && continue
    ct_vmid=$(echo "$ct" | awk '{print $1}')
    ct_status=$(echo "$ct" | awk '{print $2}')
    ct_name=$(echo "$ct" | awk '{print $3}')
    if [ "$ct_status" = "running" ]; then
      echo "    🟢 $ct_vmid ($ct_name)"
    else
      echo "    🔴 $ct_vmid ($ct_name)"
    fi
  done <<< "$pve_cts"
  echo ""

  # Updates
  if [ "$pve_updates" -gt 0 ] 2>/dev/null; then
    echo "  🔄 **$pve_updates** updates available"
  else
    echo "  ✅ All packages up to date"
  fi
  [ "$pve_reboot" = "YES" ] && echo "  ⚠️  **Reboot required** (kernel updated)"
else
  echo "**🔴 PVE — 10.0.0.10** — SSH connection failed"
fi

echo ""
echo "━━━━━━━━━━━━━━━"
echo ""

# ===== PVE2 output =====
if [ $pve2_exit -eq 0 ]; then
  pve2_ver=$(extract_line_after "$pve2_raw" "===VERSION===")
  pve2_uptime=$(extract_line_after "$pve2_raw" "===UPTIME===")
  pve2_load=$(extract_line_after "$pve2_raw" "===LOAD===")
  pve2_mem=$(extract_line_after "$pve2_raw" "===MEM===")
  pve2_disk=$(extract_line_after "$pve2_raw" "===DISK-ROOT===")
  pve2_boot=$(extract_line_after "$pve2_raw" "===BOOT-DISK===")
  pve2_smart=$(extract_line_after "$pve2_raw" "===SMART===")
  pve2_zpool=$(extract_line_after "$pve2_raw" "===ZPOOL===")
  pve2_zpool_disks=$(extract_block "$pve2_raw" "===ZPOOL-DISKS===" "===CTS===" | grep -v '^$')
  pve2_updates=$(extract_block "$pve2_raw" "===UPDATES===" "REBOOTREQ" | head -1)
  pve2_reboot=$(extract_line_after "$pve2_raw" "REBOOTREQ")
  pve2_cts=$(extract_block "$pve2_raw" "===CTS===" "" | grep -v '^$')

  pve2_ct_total=$(echo "$pve2_cts" | grep -c '.' 2>/dev/null || echo 0)
  pve2_ct_running=$(echo "$pve2_cts" | awk '$2 == "running"' | wc -l)
  pve2_ct_stopped=$(echo "$pve2_cts" | awk '$2 == "stopped"' | wc -l)

  echo "**🖥️ PVE2 — 10.0.0.11**  |  up $pve2_uptime"
  echo "  \`v$pve2_ver\`  |  Load: $pve2_load  |  Mem: $pve2_mem"
  echo ""

  # Boot drive
  echo "  **💾 Boot:** $pve2_boot  |  SMART: $pve2_smart  |  ${pve2_disk}"
  echo ""

  # ZFS Pool info
  if [ -n "$pve2_zpool" ]; then
    pool_name=$(echo "$pve2_zpool" | awk '{print $1}')
    pool_size=$(echo "$pve2_zpool" | awk '{print $2}')
    pool_alloc=$(echo "$pve2_zpool" | awk '{print $3}')
    pool_cap=$(echo "$pve2_zpool" | awk '{print $4}')
    pool_health=$(echo "$pve2_zpool" | awk '{print $5}')
    echo "  **🗄️ ZFS Pool:** ${pool_name}  |  ${pool_size} total, ${pool_alloc} used (${pool_cap})  |  **${pool_health}**"
    while IFS= read -r zd; do
      [ -z "$zd" ] && continue
      echo "    └─ /dev/$zd"
    done <<< "$pve2_zpool_disks"
    echo ""
  fi

  # CT section
  echo "  **📦 Containers:** ${pve2_ct_total} total  |  🟢 ${pve2_ct_running} running  |  🔴 ${pve2_ct_stopped} stopped"
  while IFS= read -r ct; do
    [ -z "$ct" ] && continue
    ct_vmid=$(echo "$ct" | awk '{print $1}')
    ct_status=$(echo "$ct" | awk '{print $2}')
    ct_name=$(echo "$ct" | awk '{print $3}')
    if [ "$ct_status" = "running" ]; then
      echo "    🟢 $ct_vmid ($ct_name)"
    else
      echo "    🔴 $ct_vmid ($ct_name)"
    fi
  done <<< "$pve2_cts"
  echo ""

  # Updates
  if [ "$pve2_updates" -gt 0 ] 2>/dev/null; then
    echo "  🔄 **$pve2_updates** updates available"
  else
    echo "  ✅ All packages up to date"
  fi
  [ "$pve2_reboot" = "YES" ] && echo "  ⚠️  **Reboot required** (kernel updated)"
else
  echo "**🔴 PVE2 — 10.0.0.11** — SSH connection failed"
fi

echo ""
echo "━━━━━━━━━━━━━━━"
echo ""

# ===== PBS output =====
if [ $pbs_exit -eq 0 ]; then
  pbs_ver=$(extract_line_after "$pbs_raw" "===VERSION===")
  pbs_uptime=$(extract_line_after "$pbs_raw" "===UPTIME===")
  pbs_load=$(extract_line_after "$pbs_raw" "===LOAD===")
  pbs_mem=$(extract_line_after "$pbs_raw" "===MEM===")
  pbs_root_disk=$(extract_line_after "$pbs_raw" "===DISK-ROOT===")
  pbs_zpool=$(extract_line_after "$pbs_raw" "===ZPOOL===")
  pbs_disks=$(extract_block "$pbs_raw" "===DISKS===" "===DATASTORE===" | grep -v '^$')
  pbs_updates=$(extract_block "$pbs_raw" "===UPDATES===" "REBOOTREQ" | head -1)
  pbs_reboot=$(extract_line_after "$pbs_raw" "REBOOTREQ")

  echo "**💾 PBS — 10.0.0.12**  |  up $pbs_uptime"
  echo "  \`v$pbs_ver\`  |  Load: $pbs_load  |  Mem: $pbs_mem"
  echo ""

  # ZFS Pool info
  if [ -n "$pbs_zpool" ]; then
    pool_name=$(echo "$pbs_zpool" | awk '{print $1}')
    pool_size=$(echo "$pbs_zpool" | awk '{print $2}')
    pool_alloc=$(echo "$pbs_zpool" | awk '{print $3}')
    pool_cap=$(echo "$pbs_zpool" | awk '{print $4}')
    pool_health=$(echo "$pbs_zpool" | awk '{print $5}')
    echo "  **🗄️ ZFS Pool:** ${pool_name}  |  ${pool_size} total, ${pool_alloc} used (${pool_cap})  |  **${pool_health}**"
  fi
  echo ""

  # Drive breakdown
  echo "  **💽 Drives:**"
  while IFS= read -r disk; do
    [ -z "$disk" ] && continue
    # Split fixed columns: name, size, smart, then rest is model
    d_name=$(echo "$disk" | awk '{print $1}')
    d_size=$(echo "$disk" | awk '{print $2}')
    d_smart=$(echo "$disk" | awk '{print $3}')
    d_model=$(echo "$disk" | awk '{for(i=4;i<=NF;++i) printf "%s ", $i;}' | sed 's/ $//')
    smart_icon="✅"
    [ "$d_smart" != "PASSED" ] && smart_icon="⚠️"
    echo "    ${smart_icon} /dev/${d_name}  ${d_size}  —  ${d_model}"
  done <<< "$pbs_disks"
  echo "  OS: ${pbs_root_disk}"
  echo ""

  # Updates
  if [ "$pbs_updates" -gt 0 ] 2>/dev/null; then
    echo "  🔄 **$pbs_updates** updates available"
  else
    echo "  ✅ All packages up to date"
  fi
  [ "$pbs_reboot" = "YES" ] && echo "  ⚠️  **Reboot required** (kernel updated)"
else
  echo "**🔴 PBS — 10.0.0.12** — SSH connection failed"
fi

exit 0
