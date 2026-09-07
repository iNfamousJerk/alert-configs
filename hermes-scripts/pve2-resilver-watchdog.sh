#!/bin/bash
# PVE2 Media Pool Resilver Watchdog — one-shot notifier
# Silent until the resilver completes, then fires once.
set -euo pipefail

STATUS=$(ssh root@10.0.0.11 "zpool status media 2>/dev/null" || echo "UNREACHABLE")

if echo "$STATUS" | grep -q "resilver in progress"; then
    # Still going — stay silent
    exit 0
fi

# Resilver is done (or pool isn't in progress anymore)
if echo "$STATUS" | grep -q "FAULTED\|DEGRADED"; then
    echo "⚠️  PVE2 media pool resilver COMPLETE — but pool is still DEGRADED."
    echo ""
    echo "$STATUS" | grep -A1 "state:\|scan:\|errors:" || true
    echo ""
    echo "A drive may still need replacement."
elif echo "$STATUS" | grep -q "ONLINE"; then
    echo "✅ PVE2 media pool resilver COMPLETE — pool is HEALTHY (ONLINE)."
    echo ""
    echo "$STATUS" | grep -A1 "state:\|scan:\|errors:" || true
else
    echo "📡 PVE2 media pool status changed — check manually: ssh root@10.0.0.11 zpool status media"
    echo ""
    echo "$STATUS"
fi
