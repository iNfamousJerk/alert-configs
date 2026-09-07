#!/bin/bash
# Alert-to-osTicket poller wrapper — run by the automation-agent cron (no_agent).
# Quiet when nothing new; prints when tickets are created (so cron delivers only real events).
OUT=$(python3 /opt/automation-agent/scripts/alert-to-osticket.py 2>&1)
code=$?
if [ $code -ne 0 ]; then
  echo "ALERT-POLLER ERROR: $OUT"
  exit 1
fi
# Only emit output when tickets were actually created
if echo "$OUT" | grep -q 'created [1-9]'; then
  echo "osTicket alerts:"
  echo "$OUT"
fi
# Silent (empty stdout) when nothing to report -> no cron delivery
exit 0
