#!/usr/bin/env bash
# Media Watchdog Wrapper - runs the watchdog on CT110 via PVE2
# This is called by the automation-agent cron (running on this host)
# It SSHes into PVE2, runs pct exec into CT110, and returns the output

ssh root@10.0.0.11 "pct exec 110 -- python3 /opt/media-watchdog.py" 2>&1
