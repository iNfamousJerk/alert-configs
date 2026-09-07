# Alerts inventory

Every watchdog script and every Prometheus alerting rule in this repo, at a
glance. **Delivery** legend:

- **stdout → Discord** = silent normally; prints to stdout on a problem and a
  `no_agent`-style cron job delivers that stdout to a Discord channel.
- **webhook → Discord** = the script itself POSTs to a Discord webhook.
- **log only** = writes to a local log / takes a corrective action; no chat push.
- **Ticket (osTicket)** = opens a helpdesk ticket via the osTicket API.

## Cron watchdogs & agent scripts

| Script | Monitors | Cadence | Alert trigger | Delivery |
|---|---|---|---|---|
| `watchdogs/pve1/01-health-check.sh` | Uptime, package updates, reboot flag, memory/disk, LVM, SMART, container states on hypervisor hosts + backup server | every few minutes via cron | Always reports current state (a health *report*, not strictly a watchdog) | stdout → Discord |
| `watchdogs/pve1/02-health-check-cron.sh` | Wrapper that runs the health check and posts it | every few minutes via cron | Splits the check into per-node messages and posts them | webhook → Discord |
| `watchdogs/pve1/03-disk-health-check.sh` | Per-disk SMART health (boot + data), ZFS pool state across hosts | every few minutes via cron | Reports all drives/pools each run, one message per node; flags FAILED health / DEGRADED / FAULTED pools / high reallocated or pending sectors | webhook → Discord |
| `watchdogs/pve1/04-disk-failure-watchdog.sh` | ZFS pool health + SMART verdicts across hosts | every 5 minutes via cron | **State change only**: any pool leaves ONLINE or a drive reports FAILED (deduped by md5 state file) | webhook → Discord |
| `watchdogs/pve2/01-tdarr-watchdog.sh` | Tdarr container up/down | every 5 minutes via cron | Tdarr container missing → restart the compose stack | log only + auto-remediate |
| `watchdogs/pve2/02-dvd-watchdog.sh` | Optical drive: disc inserted, rip progress/completion, unsupported discs | continuous 30-second loop | Detects new disc → auto-rips → ejects on completion; handles unsupported discs without re-rip loops | log only + auto-remediate |
| `watchdogs/pve2/03-dvd-inserted.sh` | Disc-insert event | event-triggered (on insert) | Kicks off the auto-ripper | log only + auto-remediate |
| `hermes-scripts/check-ssd-wear.sh` | SSD wear-level (SMART) across hosts | daily | SSD life remaining < 50% (warn) or < 10% (critical); SSD without wear attributes | stdout → Discord |
| `hermes-scripts/daily-homelab-check.sh` | Host reachability, container states, Docker health, Prometheus targets, backup datastore usage, root disk usage | daily | Summarizes each area; flags unreachable hosts / stopped containers / unhealthy containers / down targets / disks > 85% | stdout → Discord |
| `hermes-scripts/daily-homelab-report.sh` | Per-node health report (version, uptime, load, mem, disk, ZFS, updates) | daily | Posts a report per node (informational) | webhook → Discord |
| `hermes-scripts/media-watchdog.sh` | Media-stack watchdog (remote) | periodic via agent cron | Wraps a remote watchdog and returns its output | stdout → Discord |
| `hermes-scripts/music-dedup-weekly.sh` | Music duplicate scan / deletion | weekly | Only reports when files were actually deleted | stdout → Discord |
| `hermes-scripts/network-device-alert.py` (+ `.sh` wrapper) | Router ARP table for new/unrecognised MAC addresses | every 10 minutes via cron | A MAC not in the known-device database appears | webhook → Discord |
| `hermes-scripts/pve2-resilver-watchdog.sh` | ZFS pool resilver completion | periodic via cron (one-shot notifier) | Fires once when a resilver finishes (healthy or still degraded/faulted) | stdout → Discord |
| `hermes-scripts/jellyfin_alerts.py` | Newly added media (movies / TV / music) | scheduled via agent cron (default scans last 2 hours) | New items not previously seen are announced | webhook → Discord |
| `hermes-scripts/alert-to-osticket.py` + `alert-osticket-cron.sh` | Alertmanager firing **critical** alerts | poller, frequent via agent cron | A new critical alert is active → opens an osTicket ticket (deduped by fingerprint until it resolves) | Ticket (osTicket) + stdout → Discord when tickets created |

## Prometheus alerting rules — `monitoring/homelab_alerts.yml`

Prometheus evaluates rules every ~30 seconds; firing alerts go through
Alertmanager → `webhook-receiver.py` → **Discord**. Grouped by rule group.

| Rule group / alert | Monitors | Cadence | Alert trigger | Delivery |
|---|---|---|---|---|
| **system / `InstanceDown`** | node exporters | eval every 30s | an instance stops being scraped | Alertmanager → Discord |
| **system / `NodeExporterMissing`** | expected node exporter targets | eval every 30s | target absent from service discovery | Alertmanager → Discord |
| **system / `HighDiskUsage`** | node filesystem `usage > ~85%` | eval every 30s | disk crosses threshold | Alertmanager → Discord |
| **system / `DiskAlmostFull`** | node filesystem near capacity | eval every 30s | disk crosses higher threshold | Alertmanager → Discord |
| **system / `HighMemoryUsage` / `CriticalMemoryUsage`** | node memory | eval every 30s | memory crosses warn / critical | Alertmanager → Discord |
| **system / `HighCPUUsage`** | node CPU | eval every 30s | sustained CPU above threshold | Alertmanager → Discord |
| **system / `HighLoadAverage` / `ExtremeLoadAverage`** | node load average | eval every 30s | load crosses warn / extreme | Alertmanager → Discord |
| **containers / `ContainerOOM`** | cAdvisor container memory | eval every 30s | container OOM-killed | Alertmanager → Discord |
| **containers / `ContainerHighMemoryMB`** | cAdvisor container memory | eval every 30s | container memory crosses threshold | Alertmanager → Discord |
| **containers / `ContainerHighCPU`** | cAdvisor container CPU | eval every 30s | container CPU crosses threshold | Alertmanager → Discord |
| **containers / `ContainerDiskUsage`** | cAdvisor container disk | eval every 30s | container disk usage high | Alertmanager → Discord |
| **containers / `ContainerNetworkErrors`** | cAdvisor container network | eval every 30s | elevated network RX/TX errors | Alertmanager → Discord |
| **services / `PiholeStatus`** | Pi-hole DNS status | eval every 30s | Pi-hole disabled / not serving | Alertmanager → Discord |
| **services / `PiholeExporterDown`** | Pi-hole exporter | eval every 30s | exporter unreachable | Alertmanager → Discord |
| **services / `PiholeBlockRateDrop`** | Pi-hole block rate | eval every 30s | block rate abnormally low | Alertmanager → Discord |
| **services / `ServiceHTTPDown`** | blackbox HTTP probes | eval every 30s | an HTTP endpoint returns non-2xx / times out | Alertmanager → Discord |
| **services / `ServiceTCPDown`** | blackbox TCP probes | eval every 30s | a TCP endpoint unreachable | Alertmanager → Discord |
| **services / `CadvisorDown`** | cAdvisor | eval every 30s | cAdvisor unreachable | Alertmanager → Discord |
| **ups / `UPSOnBattery`** | NUT UPS status | eval every 30s | UPS on battery (mains loss) | Alertmanager → Discord |
| **ups / `UPSBatteryLow`** | NUT UPS charge | eval every 30s | battery charge low | Alertmanager → Discord |
| **ups / `UPSHighLoad`** | NUT UPS load | eval every 30s | UPS load above threshold | Alertmanager → Discord |
| **ups / `UPSLowRuntime`** | NUT UPS runtime | eval every 30s | estimated runtime low | Alertmanager → Discord |
| **ups / `NUTExporterDown`** | `nut_exporter.py` | eval every 30s | UPS exporter unreachable | Alertmanager → Discord |
| **ups / `UPSDisconnected`** | NUT UPS comms | eval every 30s | NUT reports UPS disconnected | Alertmanager → Discord |

## Supporting monitoring files (not alert rules)

| File | Purpose |
|---|---|
| `monitoring/prometheus.yml` | Scrape config: node, cAdvisor, blackbox, NUT; ~30s evaluation |
| `monitoring/alertmanager.yml` | Groups/routes all alerts to the Discord receiver; 4h repeat |
| `monitoring/webhook-receiver.py` | Converts Alertmanager webhooks into Discord embeds |
| `monitoring/nut_exporter.py` | Exposes UPS metrics (NUT) for Prometheus |
| `monitoring/blackbox.yml` | Blackbox modules for HTTP / TCP / ICMP probes |
| `monitoring/docker-compose.yml` | Runs the whole stack (Prometheus, Alertmanager, Grafana, cAdvisor, blackbox, webhook) |
| `monitoring/dashboards-provisioner.yml` + `*-datasource.yml` | Grafana datasources (Prometheus, Wazuh) + dashboard provisioning |
| `monitoring/zfs-health-dashboard.json` | Grafana dashboard for ZFS pool / disk health |
