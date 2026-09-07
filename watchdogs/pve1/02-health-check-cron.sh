#!/bin/bash
# Health check cron wrapper — run on the primary Proxmox host
# Runs the condensed health check, logs locally, and posts the result to Discord
# as SEPARATE messages (one per node: PVE1 / PVE2 / PBS) so none ever hits
# Discord's 2000-char limit and gets truncated.
# Change DISCORD_WEBHOOK below to re-target the channel.
DISCORD_WEBHOOK="https://YOUR_DISCORD_WEBHOOK_URL"
LOG=/var/log/health-check.log

OUT="$(/usr/local/bin/health-check.sh 2>&1)"
echo "$OUT" >> "$LOG"

# Split the combined health-check output into per-node sections (nodes are
# separated by a run of box-drawing characters) and post each section
# as its own Discord message. Each section stays well under 2000 chars.
DISCORD_WEBHOOK="$DISCORD_WEBHOOK" python3 - "$OUT" <<'EOF'
import json, os, re, sys, urllib.request

hook = os.environ["DISCORD_WEBHOOK"]
data = sys.argv[1]

# Split into sections on divider lines (runs of box-drawing / dash chars).
sections = re.split(r'\n[━─—=]{3,}\n', data)
sections = [s.strip("\n ") for s in sections if s.strip("\n ")]

def post(msg):
    if not msg:
        return
    if len(msg) > 1900:                      # defensive, should not trigger
        msg = msg[:1900] + "\n... (truncated)"
    body = json.dumps({"content": msg}).encode()
    req = urllib.request.Request(hook, data=body,
        headers={"Content-Type": "application/json", "User-Agent": "SelfHosted-HealthCheck/1.0"})
    try:
        urllib.request.urlopen(req, timeout=15)
        print("Discord post OK:", len(msg), "chars")
    except Exception as e:
        print(f"Discord post failed: {e}")

if not sections:
    post(data)                               # fallback: post whole thing
for s in sections:
    post(s)
EOF
exit 0
