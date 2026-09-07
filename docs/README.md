# alert-configs

A curated, portable collection of alerting and monitoring configuration for a
small **self-hosted / private infrastructure** deployment. Everything in this
repo is driven through a single principle:

> **Be silent when healthy. Only make noise when something is actually wrong.**

This keeps alert fatigue near zero — most days these scripts run hundreds of
times and produce no output at all.

> **Sanitized for public release.** All real credentials, hostnames, MAC
> addresses and private addresses have been replaced with placeholders (see
> [CREDENTIALS-TEMPLATE.md](../CREDENTIALS-TEMPLATE.md)). Nothing here will run
> against a live environment without filling those in first.

---

## Repository layout

```
alert-configs/
├── docs/
│   ├── README.md               ← this file
│   ├── SETUP-WATCHDOG.md       ← how to add a new cron watchdog
│   └── ALERTS-INVENTORY.md     ← every script + alert rule, at a glance
├── hermes-scripts/             ← agent-cron alert scripts & integrations
├── monitoring/                 ← Prometheus / Alertmanager / Grafana stack files
├── watchdogs/
│   ├── pve1/                   ← shell watchdogs run on hypervisor host A
│   └── pve2/                   ← shell watchdogs run on hypervisor host B
└── CREDENTIALS-TEMPLATE.md     ← every placeholder used in this repo
```

### `watchdogs/` — shell scripts run by cron (silent unless a problem)

Plain Bash scripts installed into `/usr/local/bin/` and scheduled via cron (or
an agent's job scheduler). They are **silent by default**: a healthy run prints
nothing and exits 0. Only when a problem is detected do they emit output or
post a notification. This lets a dumb scheduler (cron's mail-to-user, or an
agent "deliver stdout only" job) become the notification channel for free.

Each numbered folder is named after the host class the script runs on
(`pve1`/`pve2` = the two hypervisor hosts). Scripts that are just the raw check
(`01-`, `02-`) and the cron/delivery wrappers are kept separate so the same
check can be reused.

- `watchdogs/pve1/` — health checks, disk health, and the disk-failure watchdog
  (the canonical example — see [SETUP-WATCHDOG.md](SETUP-WATCHDOG.md)).
- `watchdogs/pve2/` — service (Tdarr) watchdog plus the optical-disc / DVD
  ripping automators.

### `hermes-scripts/` — agent-cron alert scripts & integrations

Scripts and Python modules that are wired up through an **automation agent's
cron scheduler** (the "no_agent" job type) or are integrations with external
systems:

- `alert-to-osticket.py` + `alert-osticket-cron.sh` — polls Alertmanager for
  firing critical alerts and opens helpdesk tickets (osTicket) via its API.
- `alert-osticket-cron.sh` — wrapper that stays silent unless a ticket was
  actually created.
- `check-ssd-wear.sh` — daily SSD wear-level (SMART) sweep across hosts.
- `daily-homelab-check.sh` / `daily-homelab-report.sh` — daily summary checks
  and per-node Discord health reports.
- `jellyfin_alerts.py` — "new media added" notifications to Discord.
- `media-watchdog.sh`, `music-dedup-weekly.sh`, `pve2-resilver-watchdog.sh` —
  service- and media-specific watchdogs.
- `network-device-alert.py` / `network-device-alert.sh` — generic network
  device alerter: polls a router's ARP table and alerts on newly-seen MAC
  addresses.
- `check-ssd-wear.sh` and friends follow the same silent-when-healthy pattern.

### `monitoring/` — the Prometheus / Alertmanager / Grafana stack

The complete Prometheus stack definition, plus supporting exporters and a
dashboard:

- `prometheus.yml` — scrape config (node_exporter, cAdvisor, blackbox probes,
  NUT UPS exporter, and HTTP targets).
- `homelab_alerts.yml` — **24 alerting rules** across system / container /
  service / UPS groups (full inventory in
  [ALERTS-INVENTORY.md](ALERTS-INVENTORY.md)).
- `alertmanager.yml` — routing; everything goes to one Discord receiver.
- `webhook-receiver.py` — tiny HTTP bridge that turns Alertmanager webhooks
  into rich Discord embeds.
- `blackbox.yml`, `dashboards-provisioner.yml`, `*-datasource.yml` — blackbox
  modules, Grafana dashboard auto-provisioning, and datasource definitions.
- `docker-compose.yml` — runs Prometheus, Alertmanager, Grafana, cAdvisor,
  blackbox-exporter and the webhook receiver.
- `nut_exporter.py` — exports UPS metrics from a NUT server.
- `zfs-health-dashboard.json` — a Grafana dashboard for ZFS pool / disk health.

---

## How the alert layers fit together

There are **two independent delivery paths**, both landing in the same place
(Discord):

```
┌──────────────────────────── cron / scheduler layer ────────────────────────────┐
│  shell watchdogs + agent scripts  (run every N minutes)                        │
│  ─────────────────────────────────────────────                                  │
│  silent when healthy  ·  emit/post only on a problem                           │
│                                                                                │
│  delivery options:                                                             │
│    (a) print to stdout  → "no_agent" cron job delivers stdout to Discord       │
│    (b) script posts directly to a Discord webhook                              │
└────────────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────── Prometheus layer ────────────────────────────────┐
│  node/cAdvisor/UPS/HTTP exporters  →  Prometheus                               │
│     evaluation every ~30s  →  alerting rules fire                              │
│  →  Alertmanager (group/route/dedupe)  →  webhook-receiver.py  →  Discord      │
└─────────────────────────────────────────────────────────────────────────────────┘
```

The cron scripts handle things Prometheus can't see easily (smart cards, DVD
trays, osTicket tickets, ARP-table sweeps); Prometheus handles continuous,
metric-driven health. Both were wired so that the **Discord channel is the
single place you look** when something is wrong.

---

## Adding a new alert

Choose the layer that fits the thing you want to watch:

1. **A scheduled check / one-shot event** (smartctl, a log file, an API poll,
   "did X happen") → add a **cron watchdog**. Follow
   [SETUP-WATCHDOG.md](SETUP-WATCHDOG.md) — it walks through the whole pattern
   with a worked example.
2. **A continuously-exported metric** (CPU, memory, disk %, HTTP/TCP up, UPS) →
   add a **Prometheus alerting rule** in `homelab_alerts.yml`. Every alert fires
   into the existing Alertmanager → Discord path automatically — no extra wiring
   needed.

Either way the rule is the same: **detect the problem, fire once on the state
change, stay quiet the rest of the time.**
