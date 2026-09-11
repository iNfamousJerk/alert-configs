# Wazuh → osTicket Ticketing Integration

Turns Wazuh SIEM alerts into helpdesk tickets, so alerts become a **prioritized triage
queue** instead of a dashboard you have to remember to open. Severity maps to ticket
priority, and repeated alerts are de-duplicated so a single incident doesn't spam the desk.

Deployed 2026-09-11. Validated end-to-end with live brute-force traffic.

```
Wazuh analysisd
   └─ alert level >= MIN_LEVEL
        └─ wazuh-integratord  (runs as user 'wazuh')
             └─ execs /var/ossec/integrations/custom-osticket <alert_file> <hook_url>
                  └─ custom-osticket.py → POST osTicket /api/tickets.json
```

## Files

| File | Destination | Purpose |
|------|-------------|---------|
| `custom-osticket` | `/var/ossec/integrations/` | Shell **wrapper**, no extension. This is what integratord execs. |
| `custom-osticket.py` | `/var/ossec/integrations/` | The Python logic. |
| `ossec.conf.snippet.xml` | merge into `<ossec_config>` | The `<integration>` block. |

Both files must be `root:wazuh` / mode `750` — see *Permissions* below.

**The API key is NOT in this repo.** It lives at
`/var/ossec/integrations/.osticket_key` (mode `640 root:wazuh`) and is read at runtime.
Supply your own value there — see `../CREDENTIALS-TEMPLATE.md`.

> `custom-osticket` (no extension) is required. integratord looks for a file named exactly
> as `<name>` appears in `ossec.conf`; if only the `.py` exists it logs
> `ERROR: Unable to enable integration for: 'custom-osticket'. File not found inside 'integrations'.`
> The wrapper is the shape Wazuh itself ships for the built-in integrations (maltiverse,
> pagerduty, slack, shuffle) — copy it rather than inventing one.

## Tuning

All knobs are at the top of `custom-osticket.py`:

| Constant | Default | Meaning |
|----------|---------|---------|
| `MIN_LEVEL` | `10` | Minimum Wazuh rule level to open a ticket. Raise to `12` if noisy. |
| `DEDUP_WINDOW` | `3600` | Seconds to suppress a repeat of the same rule+agent. `0` disables. |
| `MAX_PER_WINDOW` | `30` | Flood guard — max tickets per `RATE_WINDOW`. `0` disables. |
| `RATE_WINDOW` | `3600` | Window for the flood guard. |
| `TOPIC_ID` | `"12"` | osTicket help topic ("Security Alert"). |
| `SENDER_EMAIL` | — | **Must be a resolvable domain** — see Gotchas. |

Wazuh rule-level → osTicket priority: `>=13` emergency, `>=11` high, else normal.

## Deployment

```bash
VOL=/var/lib/docker/volumes/single-node_wazuh_integrations/_data

# 1. copy both files into the integrations volume
cp custom-osticket custom-osticket.py "$VOL/"

# 2. ownership/permissions — must match the built-ins
docker exec single-node-wazuh.manager-1 sh -c '
  chown root:wazuh /var/ossec/integrations/custom-osticket \
                    /var/ossec/integrations/custom-osticket.py
  chmod 750       /var/ossec/integrations/custom-osticket \
                    /var/ossec/integrations/custom-osticket.py'

# 3. write the API key (NOT in this repo)
printf '%s' '<32-hex-key>' > "$VOL/.osticket_key"
docker exec single-node-wazuh.manager-1 sh -c '
  chown root:wazuh /var/ossec/integrations/.osticket_key
  chmod 640       /var/ossec/integrations/.osticket_key'

# 4. merge ossec.conf.snippet.xml before the FIRST </ossec_config>, then restart
docker restart single-node-wazuh.manager-1
```

On a Docker stack, patch **both** the runtime volume copy
(`single-node_wazuh_etc/_data/ossec.conf`) **and** the startup template
(`<compose>/config/wazuh_cluster/wazuh_manager.conf`) — the manager regenerates the runtime
file from the template on init, so editing only the volume is lost on the next restart.

## Permissions (the two traps)

**1. integratord runs as user `wazuh` (uid 999), not root.** Files copied in as `root:root`
produce `ERROR: Couldn't execute command (...). Check file and permissions.` The `wazuh`
group exists **only inside the container**, so the `chown` must go through `docker exec` —
running it from the PVE host fails with `chown: invalid group: 'root:wazuh'`.

**2. The state file must live in a directory `wazuh` can write.**
`/var/ossec/integrations` is `drwxr-x--- root:wazuh` — group can *read* but cannot *create*.
A tmp-then-rename atomic write therefore fails:

```
cannot write state: [Errno 13] Permission denied: '.../.osticket_state.json.tmp'
```

Symptom: tickets still get created, but dedup/rate-limit silently reset every run, so each
alert burst opens N tickets instead of 1. The state file is kept in `/var/ossec/logs`
(`drwxrwx--- wazuh:wazuh`) and written **in place**.

## osTicket API gotchas

1. **URL is `/api/tickets.json`, not `/api/http.php/tickets.json`.** osTicket's nginx sets
   `$path_info` from an `if ($request_uri ~ "^/api(/[^\?]+)")` block; the `http.php` form
   returns `HTTP 400 URL not supported`.
2. **`source` must be a valid osTicket origin.** Use `"API"`.
   `"source": "Wazuh SIEM"` → `400 ... origin: Invalid ticket origin given`.
3. **osTicket does a LIVE DNS CHECK on the sender domain** when `verifyEmailAddrs` is on
   (`Validator::is_valid_email` → `is_email(..., $verify=true)`). The domain needs an MX
   **or** an A/AAAA record, or the ticket is rejected with the misleading
   `user: Incomplete client information`. Verify with:
   ```bash
   docker exec osticket-app php -r '
     foreach (array("mydomain.com") as $d)
       printf("%s -> MX:%d A/AAAA:%d\n", $d,
         count((array)@dns_get_record($d.".", DNS_MX)),
         count((array)@dns_get_record($d.".", DNS_A|DNS_AAAA)));'
   ```
   This affects *every* ticket from that domain, not just this pipeline.

4. **Senders are matched by email, not name.** Once an address exists in osTicket, new
   tickets attach to that original user record and the `name` in the payload is ignored —
   which is why tickets can appear under a stale sender name.

## Verification

```bash
# integration registered?
docker exec single-node-wazuh.manager-1 grep -i integrat /var/ossec/logs/ossec.log | tail -3
# expect: INFO: Enabling integration for: 'custom-osticket'.

# drive a real alert — repeated auth failures trip rule 5712/5763/5551 at L10
for i in $(seq 1 10); do
  sshpass -p "bad$i" ssh -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no root@<target> "echo x" >/dev/null 2>&1
done
sleep 75
tail -6 /var/lib/docker/volumes/single-node_wazuh_logs/_data/integrations.log
```

Success: `ticket created for rule 5763 (L10) on <agent> -> <number>`, then on a repeat burst
`dedup suppressed rule ...`.

**Test as the real user.** `docker exec -u wazuh ...` reproduces permission bugs that
`docker exec` (root) hides.

## Related

- `hermes-scripts/alert-to-osticket.py` — the *Prometheus/Alertmanager* → osTicket poller.
  Separately scoped (critical alerts only). Its cron job is **paused**; re-enable
  deliberately so the two pipelines don't both flood the helpdesk.
- osTicket runs in its own container (`/opt/osticket`, :8081). The Wazuh manager runs
  separately as a Docker single-node stack.
