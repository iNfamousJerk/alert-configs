#!/bin/bash
# Daily Self-Hosted Health Check — runs once daily
# Silent when healthy, only reports issues or status.
set -uo pipefail

PVE1="10.0.0.10"
PVE2="10.0.0.11"
PBS="10.0.0.12"
PBS_PASS="YOUR_PBS_ROOT_PASSWORD"
OPN_PASS="YOUR_OPNSENSE_ROOT_PASSWORD"
PVE_PASS="YOUR_PVE_ROOT_PASSWORD"

SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no"

echo "━━━ ☀️ Daily Health Check — $(date '+%a %b %d, %Y  %I:%M %p PT') ━━━"
echo ""

# ── 1. Host Reachability ──
issues=0
for label in "PVE1" "PVE2" "PBS" "OPNsense"; do
  ip_var="${label}_IP"
  ip_var="${label}"  # Just use the var name directly
  case "$label" in
    PVE1) ip="$PVE1"; pass="$PVE_PASS";;
    PVE2) ip="$PVE2"; pass="$PVE_PASS";;
    PBS)  ip="$PBS";  pass="$PBS_PASS";;
    OPNsense) ip="10.0.0.1"; pass="$OPN_PASS";;
  esac
  if sshpass -p "$pass" ssh $SSH_OPTS root@"$ip" "hostname" >/dev/null 2>&1; then
    echo "✅ **$label** ($ip) — reachable"
  else
    echo "❌ **$label** ($ip) — UNREACHABLE"
    ((issues++))
  fi
done
echo ""

# ── 2. CT Status (both PVE hosts) ──
for host in "$PVE1" "$PVE2"; do
  label="PVE1"
  [ "$host" = "$PVE2" ] && label="PVE2"
  raw=$(sshpass -p "$PVE_PASS" ssh $SSH_OPTS root@"$host" "pct list | tail -n +2 | awk '{print \$1,\$2,\$3}'" 2>&1) || {
    echo "⚠️  Could not reach $label for CT check"
    continue
  }
  running=$(echo "$raw" | grep -c "running" || true)
  stopped=$(echo "$raw" | grep -c -v "running" || true)
  total=$((running + stopped))
  echo "🏠 **$label** — $running/$total CTs running"
  stopped_cts=$(echo "$raw" | grep -v "running" || true)
  if [ -n "$stopped_cts" ]; then
    echo "   ❌ Stopped:"
    echo "$stopped_cts" | while read -r ctid name status; do
      echo "      CT $ctid ($name) — $status"
    done
    ((issues++))
  fi
done
echo ""

# ── 3. Docker Stacks ──
# Monitoring stack (runs on a Docker host)
docker_host="10.0.1.7"
docker_raw=$(sshpass -p "$PVE_PASS" ssh $SSH_OPTS root@"$docker_host" "docker ps --format '{{.Names}} {{.Status}}' 2>&1") || {
  echo "⚠️  Could not reach Docker host ($docker_host)"
  ((issues++))
}
if [ -n "$docker_raw" ]; then
  unhealthy=$(echo "$docker_raw" | grep -v "Up " || true)
  total_containers=$(echo "$docker_raw" | wc -l)
  healthy=$(echo "$docker_raw" | grep "Up " | wc -l || true)
  echo "🐳 **Monitoring Stack** ($docker_host) — $healthy/$total_containers healthy"
  if [ -n "$unhealthy" ]; then
    echo "   ❌ Issues:"
    echo "$unhealthy" | while read -r line; do echo "      $line"; done
    ((issues++))
  fi
fi

# ── 4. Prometheus Targets ──
prom_targets=$(curl -s --connect-timeout 5 http://10.0.1.7:9090/api/v1/targets 2>/dev/null | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    for t in d['data']['activeTargets']:
        print(f\"{t['labels']['job']:30s} {t['health']:10s} {t['lastScrape']}\")
except: print('ERROR')
" 2>/dev/null) || prom_targets="ERROR"
if [ "$prom_targets" = "ERROR" ]; then
  echo "⚠️  Prometheus API unreachable"
else
  down=$(echo "$prom_targets" | grep -c "down" || true)
  total_targets=$(echo "$prom_targets" | wc -l)
  if [ "$down" -gt 0 ]; then
    echo "📊 **Prometheus** — $down/$total_targets targets DOWN"
    echo "$prom_targets" | grep "down" | while read -r line; do echo "      ❌ $line"; done
    ((issues++))
  else
    echo "📊 **Prometheus** — $total_targets targets all UP ✅"
  fi
fi
echo ""

# ── 5. PBS Backup Status ──
pbs_raw=$(sshpass -p "$PBS_PASS" ssh $SSH_OPTS root@"$PBS" '
  echo "===MAIN==="
  proxmox-backup-manager backup-job list 2>/dev/null | grep -A2 "main"
  echo "===MEDIA==="
  proxmox-backup-manager backup-job list 2>/dev/null | grep -A2 "media"
  echo "===DS==="
  df -h /backup | tail -1
' 2>&1) || pbs_raw="ERROR"

if [ "$pbs_raw" = "ERROR" ]; then
  echo "⚠️  PBS unreachable"
else
  ds_line=$(echo "$pbs_raw" | grep "/backup" | awk '{print "Used: "$3" / "$2" ("$5")"}')
  echo "💾 **PBS** — Datastore: $ds_line"
fi
echo ""

# ── 6. Disk Usage Alert ──
for host in "$PVE1" "$PVE2"; do
  label="PVE1"; [ "$host" = "$PVE2" ] && label="PVE2"
  disk=$(sshpass -p "$PVE_PASS" ssh $SSH_OPTS root@"$host" "df -h / | tail -1 | awk '{print \$5}' | tr -d '%'" 2>/dev/null || echo "0")
  if [ "$disk" -gt 85 ] 2>/dev/null; then
    echo "⚠️  **$label** disk at ${disk}% — getting full!"
    ((issues++))
  fi
done

# ── Summary ──
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$issues" -gt 0 ]; then
  echo "🔴 **$issues issue(s) found** — check above 👆"
else
  echo "✅ **All clear!** Everything looks good, Hermie."
fi
echo ""
echo "📋 For maintenance steps, see the private ops documentation repo."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
exit 0
