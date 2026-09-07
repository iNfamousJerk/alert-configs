#!/usr/bin/env python3
"""
Network Device Connection Alerter

Polls OPNsense ARP table via SSH, detects new/unrecognized MAC addresses,
looks up manufacturer info, and sends Discord alerts.

Run via cron (every 5-10 minutes):
  automation-agent cron create --schedule "*/10 * * * *" --script network-device-alert.py --name "Network Device Alerts"
"""

import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

# ── Configuration ──────────────────────────────────────────────────────────
OPNSENSE_HOST = "10.0.0.1"
OPNSENSE_USER = "root"
OPNSENSE_PASS = "YOUR_OPNSENSE_ROOT_PASSWORD"

DISCORD_WEBHOOK_URL = "https://YOUR_DISCORD_WEBHOOK_URL"

KNOWN_DEVICES_PATH = os.path.expanduser("~/.automation-agent/scripts/known_devices.json")
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# ── VLAN Bridge Config ─────────────────────────────────────────────────────
# Map OPNsense interface names to friendly VLAN names
IFACE_TO_VLAN = {
    "re0":      "LAN",
    "vlan0.10": "VLAN 10",
    "vlan0.20": "VLAN 20",
    "vlan0.30": "VLAN 30",
}

# ── MAC OUI Database ───────────────────────────────────────────────────────
# Common manufacturers for OUI lookup (first 6 hex chars of MAC, lowercase)
# Source: IEEE OUI registry, curated for common home/consumer devices
MAC_OUI_DB = {
    # Apple
    "3c:22:fb": "Apple Inc.",
    "00:03:93": "Apple Inc.",
    "d0:23:db": "Apple Inc.",
    "f0:18:98": "Apple Inc.",
    "04:52:f3": "Apple Inc.",
    "70:14:a6": "Apple Inc.",
    "48:4d:7e": "Apple Inc.",
    "a8:16:9d": "Apple Inc.",  # Roku... actually let me check
    "c8:d3:ff": "Apple Inc.",
    # Samsung
    "00:23:d4": "Samsung Electronics",
    "58:a2:b5": "Samsung Electronics",
    "a4:5e:60": "Samsung Electronics",
    "8c:3c:4a": "Samsung Electronics",
    "08:71:90": "Samsung Electronics",
    # Google / Nest
    "18:6f:d3": "Google Inc.",
    "10:a8:f7": "Google Inc.",
    "e4:b9:7a": "Google Inc.",
    "d8:eb:97": "Google Inc.",
    "fc:4a:e9": "Google Inc.",
    # Amazon
    "74:75:48": "Amazon Technologies",
    "ac:63:be": "Amazon Technologies",
    "4c:ef:19": "Amazon Technologies",
    "50:f5:da": "Amazon Technologies",
    "8c:7b:9d": "Amazon Technologies",
    # Intel
    "00:16:ea": "Intel Corporate",
    "78:4b:87": "Intel Corporate",
    "24:0a:64": "Intel Corporate",
    "34:02:86": "Intel Corporate",
    # Realtek
    "00:e0:4c": "Realtek Semiconductor",
    "bc:24:11": "Realtek Semiconductor",  # Used by many Proxmox CT NICs
    # TP-Link
    "50:c7:bf": "TP-Link Technologies",
    "c0:4a:00": "TP-Link Technologies",
    "e8:de:27": "TP-Link Technologies",
    "30:b5:c2": "TP-Link Technologies",
    # Netgear
    "b8:fb:b3": "Netgear Inc.",
    "c4:4f:d5": "Netgear Inc.",
    # Roku
    "00:0d:4f": "Roku Inc.",
    "a8:16:9d": "Roku Inc.",
    # Microsoft / Xbox
    "00:50:f2": "Microsoft Corp.",
    "98:0d:2e": "Microsoft Corp.",
    "88:a4:c2": "Microsoft Corp.",
    # Sony / PlayStation
    "00:04:ed": "Sony Corp.",
    "34:71:dd": "Sony Corp.",
    # LG Electronics
    "00:1e:60": "LG Electronics",
    "84:dd:20": "LG Electronics",
    # Xiaomi
    "28:6c:07": "Xiaomi Communications",
    "78:9a:18": "Xiaomi Communications",
    # Huawei
    "30:fc:68": "Huawei Technologies",
    "64:bc:0c": "Huawei Technologies",
    # Raspberry Pi Foundation
    "b8:27:eb": "Raspberry Pi Foundation",
    "dc:a6:32": "Raspberry Pi Foundation",
    "e4:5f:01": "Raspberry Pi Foundation",
    # Cisco
    "00:1a:a1": "Cisco Systems",
    "70:ca:9b": "Cisco Systems",
    # VMware virtual
    "00:0c:29": "VMware Inc.",
    "00:50:56": "VMware Inc.",
    "0a:07:17": "Apple Inc.",
    "74:46:a0": "Intel Corporate",
}

# ── Known Devices Database ─────────────────────────────────────────────────
# Devices the user has already identified. These won't trigger alerts on first
# sighting, but will log last_seen timestamps for activity tracking.

DEFAULT_KNOWN_DEVICES = {
    "known_devices": {
        "aa:bb:cc:00:00:01": {
            "name": "Proxmox Host A",
            "ip": "10.0.0.10",
            "vlan": "LAN",
            "notes": "Primary Proxmox VE host"
        },
        "aa:bb:cc:00:00:02": {
            "name": "Backup Server",
            "ip": "10.0.0.12",
            "vlan": "LAN",
            "notes": "Proxmox Backup Server"
        },
        "aa:bb:cc:00:00:03": {
            "name": "Monitoring Host",
            "ip": "10.0.1.7",
            "vlan": "LAN",
            "notes": "Monitoring stack (Grafana, Prometheus, Gitea)"
        },
        "aa:bb:cc:00:00:04": {
            "name": "Security Host",
            "ip": "10.0.1.9",
            "vlan": "LAN",
            "notes": "SIEM / security monitoring"
        },
        "aa:bb:cc:00:00:05": {
            "name": "Container Manager",
            "ip": "10.0.1.10",
            "vlan": "LAN",
            "notes": "Docker container management"
        },
        "aa:bb:cc:00:00:06": {
            "name": "Edge Router",
            "ip": "10.0.0.1",
            "vlan": "LAN",
            "notes": "Router / firewall / gateway"
        },
        "aa:bb:cc:00:00:07": {
            "name": "Roku",
            "ip": "10.0.2.5",
            "vlan": "LAN",
            "notes": "Streaming device"
        },
        "aa:bb:cc:00:00:08": {
            "name": "Automation Agent Host",
            "ip": "10.0.1.6",
            "vlan": "LAN",
            "notes": "Automation agent host"
        },
        "aa:bb:cc:00:00:09": {
            "name": "Media Host",
            "ip": "10.0.1.8",
            "vlan": "LAN",
            "notes": "Media automation stack"
        },
        "aa:bb:cc:00:00:0a": {
            "name": "Pi-hole",
            "ip": "10.0.0.2",
            "vlan": "LAN",
            "notes": "DNS sinkhole / ad blocker"
        },
        "aa:bb:cc:00:00:0b": {
            "name": "Netgear Switch",
            "ip": "10.0.0.3",
            "vlan": "LAN",
            "notes": "Network switch"
        },
        "aa:bb:cc:00:00:0c": {
            "name": "Personal Laptop",
            "ip": "10.0.0.4",
            "vlan": "LAN",
            "notes": "Personal laptop"
        },
        "aa:bb:cc:00:00:0d": {
            "name": "LAN Scanner",
            "ip": "10.0.1.2",
            "vlan": "LAN",
            "notes": "Network device scanner"
        },
    }
}


def log(msg):
    """Simple timestamped log (stderr — invisible to cron delivery)."""
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", file=sys.stderr, flush=True)

def out(msg):
    """Print to stdout — only use when there's something to deliver to Discord."""
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def get_opnsense_arp():
    """
    SSH into OPNsense and get the ARP table.
    Returns list of dicts: {ip, mac, iface}
    """
    cmd = [
        "sshpass", "-p", OPNSENSE_PASS,
        "ssh", "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=10",
        f"{OPNSENSE_USER}@{OPNSENSE_HOST}",
        "arp -a -n"
    ]

    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)

    if result.returncode != 0:
        log(f"SSH/ARP command failed (exit {result.returncode}): {result.stderr.strip()}")
        return []

    # Parse ARP output format:
    # ? (10.0.1.10) at 00:00:00:00:00:00 on re0 expires in 927 seconds [ethernet]
    # ? (GATEWAY) at 00:00:00:00:00:00 on vlan0.10 permanent [vlan]
    devices = []
    pattern = re.compile(
        r'\?\s+\(([\d.]+)\)\s+at\s+'
        r'(\(incomplete\)|([0-9a-fA-F:]{17}))\s+on\s+'
        r'(\S+)\s+'
        r'(permanent|expired|expires|expiring)'
    )

    for line in result.stdout.strip().split("\n"):
        line = line.strip()
        if not line or "incomplete" in line:
            continue
        m = pattern.search(line)
        if m:
            ip = m.group(1)
            mac = m.group(3)
            iface = m.group(4)
            if mac:
                devices.append({
                    "ip": ip,
                    "mac": mac.lower(),
                    "iface": iface
                })

    log(f"Fetched {len(devices)} devices from OPNsense ARP table")
    return devices


def lookup_oui(mac):
    """Look up manufacturer from MAC OUI prefix."""
    prefix = mac[:8].lower()  # e.g., "bc:24:11"
    return MAC_OUI_DB.get(prefix, "Unknown")


def get_vlan_name(iface):
    """Map interface name to friendly VLAN name."""
    return IFACE_TO_VLAN.get(iface, iface)


def load_known_devices():
    """Load the known devices database from disk, or create default."""
    # Start with defaults so we always have the infrastructure mapped
    default = dict(DEFAULT_KNOWN_DEVICES["known_devices"])

    if os.path.exists(KNOWN_DEVICES_PATH):
        try:
            with open(KNOWN_DEVICES_PATH, "r") as f:
                data = json.load(f)
            known = data.get("known_devices", {})
            # Merge defaults into loaded data (defaults act as baseline)
            # User-added entries take precedence for the same MAC
            merged = dict(default)
            for mac, info in known.items():
                if mac in merged:
                    # Preserve user updates but don't overwrite user's data
                    merged[mac].update(info)
                else:
                    merged[mac] = info
            return merged
        except (json.JSONDecodeError, OSError) as e:
            log(f"Error reading known_devices.json: {e}, using defaults")
            return default
    return default


def save_known_devices(known_devices):
    """Save the known devices database to disk."""
    # Merge timestamps back into data structure
    data = {"known_devices": known_devices}
    os.makedirs(os.path.dirname(KNOWN_DEVICES_PATH), exist_ok=True)
    with open(KNOWN_DEVICES_PATH, "w") as f:
        json.dump(data, f, indent=2)


def send_discord_alert(device):
    """Send a Discord webhook notification for a new device."""
    mac = device["mac"]
    ip = device["ip"]
    iface = device["iface"]
    vlan = get_vlan_name(iface)
    oui = lookup_oui(mac)
    hostname = device.get("hostname", "N/A")
    name = device.get("name", "Unidentified Device")

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    embed = {
        "embeds": [{
            "title": "🔔 New Network Device Detected",
            "color": 0x00bfff,  # Deep sky blue
            "fields": [
                {"name": "Device", "value": name, "inline": True},
                {"name": "Manufacturer", "value": oui, "inline": True},
                {"name": "MAC Address", "value": f"`{mac}`", "inline": False},
                {"name": "IP Address", "value": f"`{ip}`", "inline": True},
                {"name": "VLAN / Network", "value": vlan, "inline": True},
                {"name": "Hostname", "value": hostname, "inline": True},
            ],
            "footer": {"text": f"First seen: {now}"}
        }]
    }

    cmd = [
        "curl", "-s", "-X", "POST", DISCORD_WEBHOOK_URL,
        "-H", "Content-Type: application/json",
        "-H", "User-Agent: AutomationAgent-Network-Monitor/1.0",
        "-d", json.dumps(embed)
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if result.returncode == 0 and result.stdout.strip() == "":
            log(f"✅ Discord alert sent for {name} ({mac}) on {vlan}")
        else:
            log(f"⚠️ Discord response: {result.stdout.strip()[:200]} - {result.stderr.strip()[:200]}")
    except subprocess.TimeoutExpired:
        log(f"❌ Discord webhook timeout for {mac}")


def check_for_new_devices(current_devices, known_devices):
    """
    Compare current ARP entries against known devices.
    Alerts on unrecognized MACs and adds them.
    Updates last_seen for known devices.
    Returns list of new devices detected.
    """
    now = datetime.now(timezone.utc).isoformat()
    new_devices = []

    # Track MACs we've already seen in this poll cycle (one MAC can appear
    # on multiple interfaces — e.g., OPNsense gateway on every VLAN)
    seen_this_cycle = set()

    for dev in current_devices:
        mac = dev["mac"]
        ip = dev["ip"]
        iface = dev["iface"]

        # Skip WAN interface — these are upstream devices, not on our network
        if iface in ("bge0", "enc0", "pflog0", "pfsync0", "lo0"):
            continue

        # Skip permanent entries that are the router itself on each VLAN
        # (same MAC, IP == gateway IP of that VLAN)
        if iface.startswith("vlan") and ip.endswith(".1") and mac == "00:00:00:00:00:00":
            continue

        if mac in seen_this_cycle:
            continue
        seen_this_cycle.add(mac)

        if mac in known_devices:
            # Known device - update last_seen and IP if changed
            old_info = known_devices[mac]
            old_info["last_seen"] = now
            old_info["last_seen_iface"] = iface
            old_info["last_seen_vlan"] = get_vlan_name(iface)
            if old_info.get("ip") != ip:
                log(f"📍 {old_info['name']} changed IP: {old_info.get('ip','?')} → {ip}")
                old_info["ip"] = ip
            continue

        # New device detected!
        dev_info = {
            "name": f"Unknown Device",
            "ip": ip,
            "iface": iface,
            "vlan": get_vlan_name(iface),
            "mac": mac,
            "manufacturer": lookup_oui(mac),
            "first_seen": now,
            "last_seen": now,
            "notes": f"Automatically detected on {iface}",
            "alerted": True
        }

        known_devices[mac] = dev_info
        new_devices.append(dev_info)

        log(f"🚨 NEW DEVICE: {mac} ({dev_info['manufacturer']}) at {ip} on {dev_info['vlan']}")

    return new_devices


def main():
    log("=" * 50)
    log("Network Device Connection Alerter starting")
    log("=" * 50)

    # 1. Fetch ARP table from OPNsense
    current_devices = get_opnsense_arp()
    if not current_devices:
        log("⚠️ No devices found in ARP table — check OPNsense connectivity")
        sys.exit(1)

    # 2. Load known devices database
    known_devices = load_known_devices()
    log(f"Loaded {len(known_devices)} known devices")

    # 3. Check for new devices
    new_devices = check_for_new_devices(current_devices, known_devices)

    # 4. Alert on new devices — only stdout when there's actually something to report
    if new_devices:
        out(f"🚨 Detected {len(new_devices)} new device(s)! Sending Discord alert(s)...")
        for dev in new_devices:
            send_discord_alert(dev)
            time.sleep(1)  # Rate limit: 1s between webhook calls
    else:
        log("✅ No new devices detected — silent exit")

    # 5. Save updated database
    save_known_devices(known_devices)

    # 6. Summary
    known_count = sum(1 for m, info in known_devices.items() if info.get("last_seen"))
    active_count = len(current_devices)
    log(f"Summary: {active_count} active devices, {known_count} known in database")
    log("Network Device Connection Alerter complete")


if __name__ == "__main__":
    main()
