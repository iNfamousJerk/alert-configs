#!/bin/bash
LOGFILE="/var/log/dvd-inserted.log"
echo "[$(date "+%Y-%m-%d %H:%M:%S")] DVD inserted — triggering ripper..." >> "$LOGFILE"
sleep 3
pct exec 103 -- /usr/local/bin/rip-dvd-auto >> "$LOGFILE" 2>&1
echo "[$(date "+%Y-%m-%d %H:%M:%S")] Rip process completed (exit: $?)" >> "$LOGFILE"
