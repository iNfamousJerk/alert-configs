#!/bin/bash
# DVD watchdog v4 — runs on the optical-drive host
# Polls every 30s for DVD → triggers rip → ejects on completion
# v4: Handles unsupported discs (Blu-ray, etc.) — tracks rejections to avoid re-ripping loops

LOGFILE="/var/log/dvd-watchdog.log"
CT="103"
DEVICE="/dev/sr0"
RIP_LOG_CT="/var/log/rip-dvd-auto.log"
COOLDOWN_FILE="/tmp/dvd-watchdog-cooldown"
REJECTION_DIR="/tmp/dvd-rejected"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"; }

has_disc()     { timeout 8 isoinfo -d -i "$DEVICE" &>/dev/null; }
disc_volume()  { timeout 6 isoinfo -d -i "$DEVICE" 2>/dev/null | grep "Volume id:" | sed 's/.*: //'; }
rip_running()  { pct exec "$CT" -- pgrep -f "HandBrakeCLI" &>/dev/null; return $?; }
rip_exited_unsupported() { pct exec "$CT" -- tail -5 "$RIP_LOG_CT" 2>/dev/null | grep -q "Unsupported Disc"; }

on_cooldown() {
  [ -f "$COOLDOWN_FILE" ] && [ "$(cat "$COOLDOWN_FILE")" -gt "$(date +%s)" ]
}

set_cooldown() {
  echo "$(($(date +%s) + $1))" > "$COOLDOWN_FILE"
  log "⏳ Cooldown for ${1}s"
}

is_rejected() {
  local vol="$1"
  [ -z "$vol" ] && return 1
  mkdir -p "$REJECTION_DIR"
  # Sanitize volume name for use as filename
  local safe=$(echo "$vol" | tr -dc '[:alnum:]_-')
  [ -z "$safe" ] && return 1
  local stamp="$REJECTION_DIR/$safe"
  [ -f "$stamp" ] && [ "$(cat "$stamp")" -gt "$(date +%s)" ]
}

mark_rejected() {
  local vol="$1"
  [ -z "$vol" ] && return
  mkdir -p "$REJECTION_DIR"
  local safe=$(echo "$vol" | tr -dc '[:alnum:]_-')
  [ -z "$safe" ] && return
  echo "$(($(date +%s) + 7200))" > "$REJECTION_DIR/$safe"  # 2-hour rejection
  log "🚫 Marked '$vol' as unsupported (2h cooldown)"
}

eject_disc() {
  # Skip eject if disc needs a manual name from web UI
  if pct exec "$CT" -- test -f /tmp/rip-needs-name.json 2>/dev/null; then
    log "⏸️ Needs-name marker active — leaving disc in drive"
    return 0
  fi
  log "📀 Ejecting..."
  eject "$DEVICE" 2>/dev/null && log "✅ Ejected" || log "⚠️ Eject failed"
  set_cooldown 120
}

start_rip() {
  local title="$1"
  log "📀 Starting rip: $title"
  systemd-run --no-block --unit="rip-$(date +%s)" \
    bash -c "pct exec $CT -- /usr/local/bin/rip-dvd-auto \"$title\"" 2>/dev/null
}

# Clean stale rejection stamps on startup
mkdir -p "$REJECTION_DIR"
find "$REJECTION_DIR" -type f -mtime +1 -delete 2>/dev/null

log "=== DVD Watchdog v4 started ==="

was_ripping=0
while true; do
  # If needs-name marker exists, don't touch the disc — user will name via web UI
  if needs_name_pending; then
    was_ripping=0
    sleep 30
    continue
  fi

  if has_disc; then
    volume=$(disc_volume)
    rip_running
    is_rip=$?

    if [ "$is_rip" -eq 0 ]; then
      was_ripping=1
      [ -n "$volume" ] && log "⏳ Ripping: $volume"
    elif [ "$was_ripping" -eq 1 ]; then
      was_ripping=0
      sleep 5
      if rip_exited_unsupported; then
        log "🚫 Rip exited — unsupported disc detected"
        mark_rejected "$volume"
        eject_disc
      else
        log "🎬 Rip completed!"
        eject_disc
      fi
    elif on_cooldown; then
      :
    elif is_rejected "$volume"; then
      :
    elif [ -z "$volume" ]; then
      log "📀 Disc detected but no readable title — starting rip anyway"
      start_rip "Untitled_DVD_$(date +%Y%m%d)"
      was_ripping=1
    else
      safe_title=$(echo "$volume" | sed 's/_/ /g; s/  */ /g; s/^ *//; s/ *$//')
      safe_title=$(echo "$safe_title" | sed 's/ -[0-9][0-9]*$//; s/ [0-9][0-9]*$//')

      if pct exec "$CT" -- test -d "/media/movies/$safe_title" 2>/dev/null; then
        log "📂 $safe_title already exists — skipping"
        eject_disc
      else
        start_rip "$safe_title"
        was_ripping=1
      fi
    fi
  else
    if [ "$was_ripping" -eq 1 ]; then
      log "🎬 Rip done (disc ejected/removed)"
      was_ripping=0
    fi
  fi
  sleep 30
done
