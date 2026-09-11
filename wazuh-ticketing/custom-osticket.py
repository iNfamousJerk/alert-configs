#!/usr/bin/env python3
"""
Wazuh -> osTicket integration.

Called by Wazuh's integratord as:
    custom-osticket.py <alert_json_file> <hook_url>

Receives ONE alert per invocation (per the Wazuh integration framework).
Filters by severity, de-duplicates repeat alerts, rate-limits floods, and
creates an osTicket ticket through the HTTP API.

Tuning knobs are all in the CONFIG block below.
"""

import json
import os
import sys
import time
import urllib.request
import urllib.error

# ─────────────────────────── CONFIG ───────────────────────────
API_URL      = "http://10.0.1.16:8081/api/tickets.json"
KEY_FILE     = "/var/ossec/integrations/.osticket_key"
# STATE must live somewhere the integratord user (wazuh) can WRITE.
# /var/ossec/integrations is `drwxr-x--- root:wazuh` -- readable but NOT
# creatable by the wazuh user, so a state file there only works if it already
# exists with 664 root:wazuh, and silently breaks if it's ever removed.
# /var/ossec/logs is `drwxrwx--- wazuh:wazuh`, so this path is always writable.
STATE_FILE   = "/var/ossec/logs/.osticket_state.json"
LOG_FILE     = "/var/ossec/logs/integrations.log"

# Only alerts at or above this level become tickets.
# 0-3 info | 4-7 warning | 8-10 suspicious | 11-14 attack | 15+ severe
MIN_LEVEL    = 10

# Suppress repeats of the same rule on the same agent within this window (sec).
# 0 disables de-duplication.
DEDUP_WINDOW = 3600

# Flood guard: max tickets created per RATE_WINDOW seconds. 0 disables.
MAX_PER_WINDOW = 30
RATE_WINDOW    = 3600

# Ticket fields
SENDER_NAME  = "Wazuh SIEM"
SENDER_EMAIL = "wazuh-alerts@gmail.com"   # must be a RESOLVABLE domain (see notes)
TOPIC_ID     = "12"                        # "Security Alert" help topic
# ──────────────────────────────────────────────────────────────


def log(msg):
    try:
        with open(LOG_FILE, "a") as f:
            f.write("custom-osticket: %s\n" % msg)
    except Exception:
        pass


def load_key():
    try:
        with open(KEY_FILE) as f:
            return f.read().strip()
    except Exception as e:
        log("cannot read API key file %s: %s" % (KEY_FILE, e))
        return None


def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {"dedup": {}, "sent": []}


def save_state(state):
    # NOTE: write directly to STATE_FILE, do NOT use tmp-then-rename.
    # The integrations dir is `drwxr-x--- root:wazuh`, so the wazuh user can
    # READ it but cannot CREATE new files in it -- an atomic .tmp write fails
    # with [Errno 13] Permission denied. STATE_FILE itself is 664 root:wazuh,
    # so overwriting it in place works.
    try:
        with open(STATE_FILE, "w") as f:
            json.dump(state, f)
    except Exception as e:
        log("cannot write state: %s" % e)


def priority_for(level):
    """Map a Wazuh rule level onto an osTicket priority id."""
    if level >= 13:
        return "4"   # emergency
    if level >= 11:
        return "3"   # high
    return "2"       # normal


def build_ticket(alert):
    rule    = alert.get("rule", {})
    agent   = alert.get("agent", {})
    level   = int(rule.get("level", 0))
    rid     = rule.get("id", "0000")
    desc    = rule.get("description", "No description")
    groups  = ", ".join(rule.get("groups", []) or []) or "n/a"
    aname   = agent.get("name", "unknown")
    aip     = agent.get("ip", "unknown")
    loc     = alert.get("location", "unknown")
    ts      = alert.get("timestamp", "")
    full    = alert.get("full_log", "(none)")
    data    = alert.get("data", {}) or {}
    mngr    = alert.get("manager", {}).get("name", "unknown")

    subject = "[Wazuh L%d] %s on %s" % (level, desc, aname)

    body = []
    body.append("SECURITY ALERT FROM WAZUH SIEM")
    body.append("=" * 60)
    body.append("")
    body.append("Severity      : %d/15  (%s)" % (level, severity_band(level)))
    body.append("Rule ID       : %s" % rid)
    body.append("Description   : %s" % desc)
    body.append("Rule groups   : %s" % groups)
    body.append("")
    body.append("Agent         : %s" % aname)
    body.append("Agent IP      : %s" % aip)
    body.append("Manager       : %s" % mngr)
    body.append("Log location  : %s" % loc)
    body.append("Event time    : %s" % ts)
    body.append("")

    keys = ["srcip", "dstip", "srcport", "dstport", "protocol", "user",
            "filename", "url", "status", "srcuser", "dstuser", "command"]
    extras = [(k, data[k]) for k in keys if k in data]
    if extras:
        body.append("Decoded fields")
        body.append("-" * 60)
        for k, v in extras:
            body.append("  %-12s: %s" % (k, v))
        body.append("")

    body.append("Raw log")
    body.append("-" * 60)
    body.append(str(full)[:2000])
    body.append("")
    body.append("-" * 60)
    body.append("Triage: verify scope, determine if expected, escalate or close.")
    body.append("Generated automatically by the Wazuh -> osTicket pipeline.")

    return {
        "alert": True,
        "autorespond": False,
        "source": "API",
        "name": SENDER_NAME,
        "email": SENDER_EMAIL,
        "subject": subject[:250],
        "message": "\n".join(body),
        "topicId": TOPIC_ID,
        "priorityId": priority_for(level),
    }


def severity_band(level):
    if level >= 15:
        return "severe"
    if level >= 11:
        return "attack"
    if level >= 8:
        return "suspicious"
    if level >= 4:
        return "warning"
    return "info"


def send_ticket(key, payload):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        API_URL, data=data,
        headers={
            "Content-Type": "application/json",
            "X-API-Key": key,
            "User-Agent": "Wazuh/4.14",
        },
        method="POST",
    )
    try:
        resp = urllib.request.urlopen(req, timeout=15)
        body = resp.read().decode("utf-8", "replace").strip()
        return True, body
    except urllib.error.HTTPError as e:
        return False, "HTTP %s: %s" % (e.code, e.read().decode("utf-8", "replace")[:300])
    except Exception as e:
        return False, str(e)


def main():
    if len(sys.argv) < 2:
        log("missing alert file argument")
        return 1

    alert_file = sys.argv[1]

    try:
        with open(alert_file) as f:
            raw = json.load(f)
    except Exception as e:
        log("cannot parse alert file: %s" % e)
        return 1

    # integratord normally sends a single object; tolerate a list.
    alerts = raw if isinstance(raw, list) else [raw]

    key = load_key()
    if not key:
        return 1

    state = load_state()
    now = time.time()

    # prune old state
    state["dedup"] = {k: v for k, v in state["dedup"].items()
                      if now - v < max(DEDUP_WINDOW, RATE_WINDOW)}
    state["sent"] = [t for t in state["sent"] if now - t < RATE_WINDOW]

    created = 0
    for alert in alerts:
        rule = alert.get("rule", {})
        level = int(rule.get("level", 0))
        rid = rule.get("id", "0000")
        aname = alert.get("agent", {}).get("name", "unknown")

        if level < MIN_LEVEL:
            continue

        dkey = "%s:%s" % (rid, aname)
        if DEDUP_WINDOW and dkey in state["dedup"]:
            age = int(now - state["dedup"][dkey])
            log("dedup suppressed rule %s on %s (seen %ds ago)" % (rid, aname, age))
            continue

        if MAX_PER_WINDOW and len(state["sent"]) >= MAX_PER_WINDOW:
            log("rate limit reached (%d/%ds) - suppressing rule %s on %s"
                % (MAX_PER_WINDOW, RATE_WINDOW, rid, aname))
            continue

        payload = build_ticket(alert)
        ok, detail = send_ticket(key, payload)

        if ok:
            created += 1
            state["dedup"][dkey] = now
            state["sent"].append(now)
            log("ticket created for rule %s (L%d) on %s -> %s"
                % (rid, level, aname, detail))
        else:
            log("ticket FAILED rule %s on %s: %s" % (rid, aname, detail))

    save_state(state)
    log("run complete: %d ticket(s) created" % created)
    return 0


if __name__ == "__main__":
    sys.exit(main())
