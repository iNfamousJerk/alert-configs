# Credentials template

> ## ⚠️ NEVER commit real credentials.
> This repo is meant to be public. Every value below is a **placeholder**. Real
> passwords, webhook URLs, API keys and tokens must stay **out of git** — put
> them in an environment file (`.env`, ignored via `.gitignore`), a secrets
> manager, or a root-only file on the target host.

## Placeholders used in this repo

These `YOUR_*` tokens appear directly in the code. Before running anything,
replace them (via an ignored local config / `.env` — **not** by editing and
committing) with real values:

| Placeholder | What it is | Where it appears |
|---|---|---|
| `YOUR_PVE_ROOT_PASSWORD` | SSH root password for the primary/secondary Proxmox VE hypervisor hosts | host checks, disk health, disk-failure watchdog, SSD wear, daily checks/reports |
| `YOUR_PBS_ROOT_PASSWORD` | SSH root password for the Proxmox Backup Server host | backup server checks, disk health, disk-failure watchdog |
| `YOUR_OPNSENSE_ROOT_PASSWORD` | SSH/root password for the router/firewall (used to read the ARP table) | network-device-alert.py |
| `YOUR_DISCORD_WEBHOOK_URL` | Full Discord webhook URL for alert delivery | daily report, disk health, disk-failure watchdog, network-device alerts, webhook receiver, etc. |
| `YOUR_OSTICKET_CLIENT_EMAIL` | Email of an existing helpdesk (osTicket) client used when opening tickets | alert-to-osticket.py |
| `YOUR_OSTICKET_API_KEY` | 32-char hex osTicket API key, **IP-scoped** to the host that opens tickets | `wazuh-ticketing/` — read at runtime from `.osticket_key`, never embedded in the script |

## Tokens referenced by the surrounding tooling / CI (not embedded in scripts)

The alert scripts themselves do **not** embed these, but the repo lives inside
a workflow that uses them. Keep them out of git:

| Token | What it is |
|---|---|
| `YOUR_GITHUB_TOKEN` | A personal access token used to push/publish this public GitHub copy |
| `YOUR_GITEA_TOKEN` | A token for the self-hosted Gitea instance (private repo + Git tooling) |
| `YOUR_GITEA_PASSWORD` | Account password for the Gitea admin user (private tooling) |

## Other defaults worth overriding

| Value | What it is |
|---|---|
| `upsmonitor` | Fallback NUT monitor password in `monitoring/nut_exporter.py` (env `NUT_PASSWORD`). Override it — don't ship the default. |

## Env / key files referenced by the code (created at runtime, never committed)

- `~/.automation-agent/scripts/known_devices.json` — learned MAC / device database
  maintained by `network-device-alert.py`.
- `~/.automation-agent/alert_ticket_state.json` — osTicket dedup state.
- `~/.automation-agent/alert_osticket_key.txt` — osTicket API key (root-only copy on the
  host).
- `~/.automation-agent/scripts/jellyfin_alerts_state.json` — Jellyfin alert dedup state.
- `/var/lib/disk-failure-watchdog.state` — disk-failure watchdog dedup state.

## Git hygiene

- `.gitignore` blocks `.env`, logs, configs, `__pycache__` and secrets (see the
  repo root `.gitignore`).
- If you ever commit a secret, assume it is compromised: rotate it, then purge
  it from history.
