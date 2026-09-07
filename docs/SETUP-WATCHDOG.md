# Setting up a cron watchdog

This guide explains the watchdog pattern used throughout this repo and shows
you how to add your own. The canonical reference implementation is
`watchdogs/pve1/04-disk-failure-watchdog.sh` — read it alongside this doc.

---

## 1. What a watchdog is

A **watchdog** is a small script that a scheduler (cron, or an agent's job
scheduler) runs every N minutes. Two rules make it usable at scale:

- **It is SILENT normally.** A healthy run produces no stdout and exits 0.
- **It only outputs or posts when it detects a problem.**

This is what lets you run a hundred checks on a short interval without flooding
your notification channel. cron (or a "deliver stdout" job) becomes your
notification pipeline for free: *no output ⇒ no message*.

```
run every 5 min ──► check ──► healthy? ──► silent, exit 0
                             └──── problem? ──► emit message (→ Discord)
```

## 2. The two delivery patterns

There are two ways a watchdog gets a message out. Pick whichever your setup
supports:

**Pattern A — deliver stdout via a `no_agent`-style cron job.**
The script only ever *prints* to stdout when there is a problem. The scheduler
is configured to deliver stdout (e.g. to a Discord channel) **only when the
job produces output**. Empty stdout = no delivery.

```bash
#!/bin/bash
problem_found=false
# ... checks, set problem_found=true on failure ...
if $problem_found; then
    echo "⚠️  Something is wrong on host $(hostname)"
fi
exit 0        # stdout empty when healthy → no notification
```

**Pattern B — the script posts directly to a Discord webhook.**
The script holds a webhook URL and POSTs a per-node message itself. Use this
when you want the script to control the message content / grouping (e.g. one
message per monitored node) rather than relying on scheduler delivery.

```bash
DISCORD_WEBHOOK="YOUR_DISCORD_WEBHOOK_URL"
post() {
  python3 - "$1" "$DISCORD_WEBHOOK" <<'EOF'
import json,sys,urllib.request
msg,hook=sys.argv[1],sys.argv[2]
urllib.request.urlopen(urllib.request.Request(hook,
    data=json.dumps({"content":msg}).encode(),
    headers={"Content-Type":"application/json"}), timeout=15)
EOF
}
```

For host health **reports** (that run on a schedule and always say something),
Pattern B posting one message per host is common — see
`watchdogs/pve1/03-disk-health-check.sh`. For true **watchdogs** (silent until a
problem) Pattern A via a `no_agent` cron job is the cleanest.

## 3. Write a health-check function that returns empty when healthy

Structure the script so that the "collect problems" step returns **nothing**
when all is well. A clean way is a function that only echoes problem lines:

```bash
check_host() {
  local ip="$1"
  ssh root@"$ip" '
    zpool list -H -o name,health 2>/dev/null | while read -r p h; do
      [ "$h" = "ONLINE" ] || echo "PROBLEM|pool $p is $h"
    done
  ' 2>/dev/null
}
```

If the collected output is empty the host is healthy — no notification needed.

## 4. The state-file dedup pattern

The cardinal sin of watchdogs is re-alerting every run. If a disk is failing and
the check runs every 5 minutes, you don't want 288 messages a day.

Fix: alert on **state change**, not on every run. Store a signature of the
current problem set in a state file; only post when the signature *changes*;
clear the file when everything is healthy again so a future problem re-alerts.

```bash
STATE=/var/lib/my-watchdog.state
all="$(collect_problems)"              # empty when healthy
if [ -z "$all" ]; then
    rm -f "$STATE"                      # healthy → allow future re-alert
    exit 0
fi
sig="$(printf '%s' "$all" | md5sum | cut -d' ' -f1)"
if [ "$(cat "$STATE" 2>/dev/null)" != "$sig" ]; then
    echo "$sig" > "$STATE"
    post "$all"                         # only on a (new) state change
fi
```

`04-disk-failure-watchdog.sh` implements exactly this.

## 5. Place the script in `/usr/local/bin/`

Copy the script to `/usr/local/bin/` and make it executable:

```bash
sudo install -m 0755 my-watchdog.sh /usr/local/bin/my-watchdog.sh
```

## 6. Add the cron entry

Add a file under `/etc/cron.d/` (note: the line needs a user field). For a
check that runs every 5 minutes:

```cron
*/5 * * * * root /usr/local/bin/my-watchdog.sh >/dev/null 2>&1
```

For a daily run at, say, 04:00, use:

```cron
0 4 * * * root /usr/local/bin/my-watchdog.sh
```

> The watchdogs in this repo are a mix of `*/5` (short-interval health) and
> `0 H`/daily schedules (reports and weekly jobs). Use the shortest interval
> your problem can tolerate — a disk can fill or a host can go down at any
> moment, but you don't need to check SSD wear more than daily.
>
> A **`no_agent` cron job** (Pattern A) *omits* the `root` field and instead
> delivers stdout to your channel — see your scheduler's docs for the exact
> syntax. Example of how these jobs are declared (as it appears in comments in
> this repo):
>
> ```text
> automation-agent cron create --schedule "*/10 * * * *" --script my-watchdog --name "My Watchdog"
> ```

## 7. Test it manually before trusting cron

Never add a watchdog to cron before running it by hand:

```bash
# healthy case — expect no output, exit 0
/usr/local/bin/my-watchdog.sh ; echo "exit=$?"

# force the problem, then run again — expect the alert
# (e.g. stop the service it watches, or point it at a host that is down)
```

Also run it **twice** with the problem still present and confirm it alerts only
once (that's the state-file dedup working). Then break it once more after
restoring health and confirm it re-alerts.

## 8. Worked minimal example

A minimal watchdog that emails/prints when a host is unreachable:

```bash
#!/bin/bash
# unreachable-watchdog.sh — run from cron on HOST_A every 5 min.
# Silent unless HOST_B stops answering SSH.
set -uo pipefail

HOST_B="10.0.0.5"                 # <your host>
STATE=/var/lib/unreachable.state

if timeout 15 ssh -o ConnectTimeout=10 root@"$HOST_B" true 2>/dev/null; then
    rm -f "$STATE"                # host is up → clear state, stay silent
    exit 0
fi

if [ ! -f "$STATE" ]; then        # first detection only
    echo "⚠️  HOST_B ($HOST_B) unreachable via SSH."
    date +%s > "$STATE"           # this run is now the "known" state
fi
exit 0
```

Key takeaways to copy from `04-disk-failure-watchdog.sh`, the canonical example:

- SSH host list + placeholder credentials at the top.
- One `post_discord()` helper using the Python heredoc webhook.
- Problem collection that returns **empty when healthy**.
- A `md5sum` signature + state file so it fires on **state change**, not every run.
- Logging each alert to `/var/log/`.
