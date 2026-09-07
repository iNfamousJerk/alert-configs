#!/usr/bin/env python3
"""
Automation alert-to-osTicket pipeline (poll-based).

Polls Alertmanager (v2 API) for FIRING CRITICAL alerts, deduplicates against
already-ticketed alerts, and opens a ticket in osTicket via its API.

Why poll instead of webhook: the automation host is an unprivileged LXC that
drops inbound connections on ports >1024, so Alertmanager cannot push to it.
Outbound polling works fine.

State: a JSON file tracks fingerprints that have already been ticketed, so a
firing alert is only ticketed once (until it resolves and re-fires).
"""
import json, os, sys, time, urllib.request, urllib.error
from datetime import datetime, timezone

# ── Config ──────────────────────────────────────────────────────────────────
ALERTMANAGER = "http://10.0.1.7:9093"
OSTICKET_URL = "http://10.0.1.16:8081"
STATE_FILE   = "/opt/automation-agent/alert_ticket_state.json"
# Read osTicket API key from a root-only file on the helpdesk host
KEY_FILE     = "/opt/automation-agent/alert_osticket_key.txt"
# Severities that warrant a helpdesk ticket (per user decision: critical only)
WATCHED_SEVERITIES = {"critical"}

# ── Alertmanager ────────────────────────────────────────────────────────────
def fetch_alerts():
    req = urllib.request.Request(f"{ALERTMANAGER}/api/v2/alerts")
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read().decode())

# ── osTicket ────────────────────────────────────────────────────────────────
def get_osticket_key():
    try:
        with open(KEY_FILE) as f:
            return f.read().strip()
    except FileNotFoundError:
        return ""

def open_ticket(alert):
    key = get_osticket_key()
    if not key:
        return None, "no API key"
    labels = alert.get("labels", {})
    ann    = alert.get("annotations", {})
    payload = {
        "name":  "Automation Monitoring",
        "email": "YOUR_OSTICKET_CLIENT_EMAIL",  # existing helpdesk client (new-user creation needs a full name object)
        "subject": f"[{labels.get('severity').upper()}] {labels.get('alertname')} on {labels.get('instance')}",
        "message": (
            f"Automated alert-to-ticket from automation monitoring.\n\n"
            f"Alert:      {labels.get('alertname')}\n"
            f"Severity:   {labels.get('severity')}\n"
            f"Instance:   {labels.get('instance')}\n"
            f"Job:        {labels.get('job', 'n/a')}\n"
            f"Summary:    {ann.get('summary', '')}\n"
            f"Detail:     {ann.get('description', '')}\n"
            f"Started:    {alert.get('startsAt', '')}\n"
            f"Generator:  {alert.get('generatorURL', '')}\n"
        ),
        "priority": 1,
        "topicId": 1,
    }
    req = urllib.request.Request(
        f"{OSTICKET_URL}/api/tickets.json",
        data=json.dumps(payload).encode(),
        headers={"X-API-Key": key, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            body = r.read().decode().strip()
            return r.status, body
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

# ── State / dedup ───────────────────────────────────────────────────────────
def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"ticketed": {}, "resolved_known": {}}

def save_state(state):
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)

def main():
    alerts = fetch_alerts()
    state = load_state()
    ticketed = state.setdefault("ticketed", {})
    now = datetime.now(timezone.utc).isoformat()

    created = []
    for a in alerts:
        if a.get("status", {}).get("state") != "active":
            continue
        labels = a.get("labels", {})
        sev = labels.get("severity", "info").lower()
        if sev not in WATCHED_SEVERITIES:
            continue
        fp = a.get("fingerprint") or labels.get("alertname", "") + labels.get("instance", "")
        if fp in ticketed:
            continue  # already has a ticket
        code, body = open_ticket(a)
        if code in (200, 201):
            ticketed[fp] = {"ticket": body, "opened": now,
                            "alertname": labels.get("alertname"),
                            "instance": labels.get("instance")}
            created.append((labels.get("alertname"), labels.get("instance"), body))
        else:
            print(f"ERROR opening ticket for {labels.get('alertname')}: HTTP {code} {body}")

    # Drop fingerprints for alerts that have resolved (so a re-fire re-tickets)
    active_fps = {a.get("fingerprint") for a in alerts}
    resolved = [fp for fp in ticketed if fp not in active_fps]
    for fp in resolved:
        del ticketed[fp]

    save_state(state)
    print(f"checked {len(alerts)} alerts | created {len(created)} tickets | "
          f"active-ticketed {len(ticketed)} | resolved-removed {len(resolved)}")
    for name, inst, tno in created:
        print(f"  TICKET {tno}: {name} on {inst}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
