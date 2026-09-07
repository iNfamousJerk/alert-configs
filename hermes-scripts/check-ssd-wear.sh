#!/bin/bash
# SSD Wear-Level Monitoring — Daily Check
# Checks all SSDs across PVE1, PVE2, and PBS for wear indicators
# Silent when healthy — only outputs on warnings or errors
# Run via cron or manually
#
# Thresholds:
#   SSD_Life_Left / Percent_Lifetime_Remain < 50 → WARNING (yellow)
#   SSD_Life_Left / Percent_Lifetime_Remain < 10 → CRITICAL (red)

set -euo pipefail

WARN_THRESHOLD=50
CRIT_THRESHOLD=10
HAS_WARNINGS=0
REPORT=""

check_ssd() {
    local host="$1"
    local device="$2"
    local label="$3"

    # Get all wear-related SMART attributes
    local raw
    raw=$(ssh root@"$host" "smartctl -a $device 2>/dev/null" | grep -iE 'ssd_life_left|percent_lifetime_remain|wear_leveling_count|media_wearout' | head -5 || true)

    if [ -z "$raw" ]; then
        # SSD might not support wear attributes — check if it's an SSD at all
        local is_ssd
        is_ssd=$(ssh root@"$host" "smartctl -i $device 2>/dev/null | grep -c 'Solid State'" || true)
        if [ "$is_ssd" -gt 0 ]; then
            REPORT+="⚠️  $label ($host:$device) — SSD detected but no wear attribute found\n"
            HAS_WARNINGS=1
        fi
        return
    fi

    # Extract normalized value (second column after the attribute name)
    while IFS= read -r line; do
        local attr normalized_val
        attr=$(echo "$line" | awk '{print $1, $2}' | tr -d '\n')
        normalized_val=$(echo "$line" | awk '{print $4}')

        if [ -z "$normalized_val" ] || [ "$normalized_val" = "---" ]; then
            continue
        fi

        # Strip non-numeric
        normalized_val=$(echo "$normalized_val" | sed 's/[^0-9]//g')

        if [ "$normalized_val" -le "$CRIT_THRESHOLD" ] 2>/dev/null; then
            REPORT+="🔴 CRITICAL: $label ($host:$device) — $attr = $normalized_val (below $CRIT_THRESHOLD!)\n"
            HAS_WARNINGS=1
        elif [ "$normalized_val" -le "$WARN_THRESHOLD" ] 2>/dev/null; then
            REPORT+="🟡 WARNING: $label ($host:$device) — $attr = $normalized_val (below $WARN_THRESHOLD)\n"
            HAS_WARNINGS=1
        else
            # Healthy — silent per-device, aggregate only
            :
        fi
    done <<< "$raw"
}

# --- PVE1 ---
check_ssd "10.0.0.10" "/dev/sda" "PVE1 PNY CS900 1TB"

# --- PVE2 ---
check_ssd "10.0.0.11" "/dev/sde" "PVE2 Fikwot FS810 128GB"

# --- Backup server (via the first Proxmox host — agent can't reach it directly) ---
check_ssd_pbs() {
    # Multi-hop: agent → first Proxmox host → backup server
    local raw
    raw=$(ssh root@10.0.0.10 "ssh root@10.0.0.12 'smartctl -a /dev/sdb 2>/dev/null'" | grep -iE 'ssd_life_left|percent_lifetime_remain|wear_leveling_count|media_wearout' | head -5 || true)

    if [ -z "$raw" ]; then
        REPORT+="⚠️  PBS SK hynix SC308 256GB — no wear attribute found or unreachable\n"
        HAS_WARNINGS=1
        return
    fi

    while IFS= read -r line; do
        local attr normalized_val
        attr=$(echo "$line" | awk '{print $1, $2}' | tr -d '\n')
        normalized_val=$(echo "$line" | awk '{print $4}')
        normalized_val=$(echo "$normalized_val" | sed 's/[^0-9]//g')

        if [ -z "$normalized_val" ] || [ "$normalized_val" = "---" ]; then
            continue
        fi

        if [ "$normalized_val" -le "$CRIT_THRESHOLD" ] 2>/dev/null; then
            REPORT+="🔴 CRITICAL: PBS SK hynix ($host:$device) — $attr = $normalized_val (below $CRIT_THRESHOLD!)\n"
            HAS_WARNINGS=1
        elif [ "$normalized_val" -le "$WARN_THRESHOLD" ] 2>/dev/null; then
            REPORT+="🟡 WARNING: PBS SK hynix — $attr = $normalized_val (below $WARN_THRESHOLD)\n"
            HAS_WARNINGS=1
        fi
    done <<< "$raw"
}

check_ssd_pbs


# --- Output ---
if [ "$HAS_WARNINGS" -eq 1 ]; then
    echo -e "🧠 SSD Wear Report — $(date '+%Y-%m-%d %H:%M')"
    echo -e "$REPORT"
    exit 1
else
    # Silent when healthy — cron only alerts on problems
    exit 0
fi
