#!/usr/bin/env python3
"""
Jellyfin Media Alert Script — no-agent mode.
Queries media directories for recently added files and sends Discord notifications.
Webhook delivery is built in; stdout is kept minimal for no-agent cron delivery.
"""

import os
import json
import hashlib
import argparse
import subprocess
import sys
from datetime import datetime, timezone, timedelta

# ─── Configuration ────────────────────────────────────────────────────────────
STATE_FILE = os.path.expanduser("~/.automation-agent/scripts/jellyfin_alerts_state.json")
MEDIA_BASE = "/data/media"
MEDIA_EXTS = ['.mkv', '.mp4', '.avi', '.m4v', '.mov', '.wmv', '.flv', '.webm']

PVE_HOST = "10.0.0.10"
PVE_PASS = "YOUR_PVE_ROOT_PASSWORD"
CT_ID = "103"

DEFAULT_WEBHOOK = (
    "YOUR_DISCORD_WEBHOOK_URL"
)


def run_docker_find(minutes_back):
    """Run find inside the jellyfin Docker container via PVE.
    Uses arg list (no bash -c) to avoid nested shell quoting issues."""
    # Build find name args: -name "*.mkv" -o -name "*.mp4" ...
    name_args = []
    for i, ext in enumerate(MEDIA_EXTS):
        if i > 0:
            name_args.append("-o")
        name_args.append("-name")
        name_args.append(f'"*{ext}"')

    # Full find command args (escaped for the remote SSH shell)
    cmd = [
        "docker", "exec", "jellyfin", "find", MEDIA_BASE,
        "-type", "f",
        "-mmin", f"-{minutes_back}",
        "\\(", *name_args, "\\)",
        "\\!", "-name", '".*"',
    ]

    full_cmd = [
        "sshpass", "-p", PVE_PASS,
        "ssh", "-o", "StrictHostKeyChecking=no",
        f"root@{PVE_HOST}", "--",
        "pct", "exec", CT_ID, "--",
    ] + cmd

    result = subprocess.run(full_cmd, capture_output=True, text=True, timeout=300)
    return result.stdout, result.stderr, result.returncode


def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_state(state):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, 'w') as f:
        json.dump(state, f, indent=2)


def get_recent_media(hours_back):
    minutes_back = hours_back * 60
    stdout, stderr, rc = run_docker_find(minutes_back)

    if rc != 0:
        print(f"Warning: find command rc={rc}: {stderr[:200]}", file=sys.stderr)

    files = [f.strip() for f in stdout.strip().split('\n') if f.strip().startswith('/')]
    return files


def categorize_files(files):
    items = {}
    for fpath in files:
        rel = fpath.replace(MEDIA_BASE, "").lstrip("/")
        parts = rel.split("/")
        if len(parts) < 2:
            continue
        library = parts[0]

        if library == "movies":
            title = parts[1] if len(parts) > 1 else "Unknown Movie"
            key = f"movie::{title}"
            if key not in items:
                items[key] = {"type": "movie", "title": title, "files": [], "library": library}
            items[key]["files"].append(fpath)

        elif library == "tv" and len(parts) >= 3:
            show_dir = parts[1]
            season_dir = parts[2]
            ep_file = parts[-1]
            key = f"tv::{show_dir}::{season_dir}"
            if key not in items:
                items[key] = {"type": "episode", "show": show_dir, "season": season_dir, "files": [], "library": library}
            items[key]["files"].append(ep_file)

        elif library == "music":
            album = parts[1] if len(parts) > 1 else "Unknown Album"
            key = f"music::{album}"
            if key not in items:
                items[key] = {"type": "music", "album": album, "files": [], "library": library}
            items[key]["files"].append(fpath)

    return items


def fingerprint_item(item):
    raw = json.dumps(item, sort_keys=True)
    return hashlib.md5(raw.encode()).hexdigest()


def send_discord_alert(webhook_url, emoji, name, items):
    if not items or not webhook_url:
        return
    lines = []
    for item in items:
        if item["type"] == "movie":
            lines.append(f"🎬 **{item['title']}**")
        elif item["type"] == "episode":
            lines.append(f"📺 **{item['show']}** — {item['season']} ({len(item['files'])} eps)")
        elif item["type"] == "music":
            lines.append(f"🎵 **{item['album']}** ({len(item['files'])} tracks)")

    for i in range(0, len(lines), 5):
        chunk = lines[i:i + 5]
        content = f"{emoji} **New {name} Added**\n\n" + "\n".join(chunk)
        cmd = [
            "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
            "-X", "POST", webhook_url,
            "-H", "Content-Type: application/json",
            "-d", json.dumps({"content": content})
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        status = result.stdout.strip()
        if status == "204":
            print(f"  ✅ Sent: {chunk[0][:50]}...")
        else:
            print(f"  ❌ Failed HTTP {status}")


def main():
    parser = argparse.ArgumentParser(description="Jellyfin media alert script")
    parser.add_argument("--hours", type=int, default=2, help="How far back to check (hours)")
    parser.add_argument("--discord-webhook", default=DEFAULT_WEBHOOK, help="Discord webhook URL")
    parser.add_argument("--dry-run", action="store_true", help="Don't send, just print")
    parser.add_argument("--no-deliver", action="store_true", help="Suppress stderr progress, only webhook output")
    args = parser.parse_args()

    quiet = args.no_deliver
    debug = lambda *a, **kw: print(*a, **kw, file=sys.stderr)

    debug(f"Scanning for media added in the last {args.hours} hours...")
    files = get_recent_media(args.hours)

    if not files:
        debug("No new media files found.")
        return

    debug(f"Found {len(files)} new media files")
    items = categorize_files(files)
    debug(f"Grouped into {len(items)} items")

    state = load_state()
    new_items = []
    for key, item in items.items():
        fp = fingerprint_item(item)
        if fp not in state:
            state[fp] = {
                "first_seen": datetime.now(timezone.utc).isoformat(),
                "title": item.get("title") or item.get("show") or item.get("album", "Unknown"),
                "type": item["type"],
            }
            new_items.append(item)

    if not new_items:
        debug("✅ No new items to report (all previously tracked).")
        save_state(state)
        return

    debug(f"🆕 {len(new_items)} new items to report!")

    if not args.dry_run:
        for lib_key, (emoji, name) in [("movies", ("🎬", "Movies")), ("tv", ("📺", "TV Shows")), ("music", ("🎵", "Music"))]:
            lib_items = [i for i in new_items if i.get("library") == lib_key]
            if lib_items:
                send_discord_alert(args.discord_webhook, emoji, name, lib_items)
    else:
        debug("\\n📋 DRY RUN — would send:")
        for item in new_items:
            if item["type"] == "movie":
                debug(f"  🎬 Movie: {item['title']}")
            elif item["type"] == "episode":
                debug(f"  📺 {item['show']} - {item['season']} ({len(item['files'])} eps)")
            elif item["type"] == "music":
                debug(f"  🎵 Album: {item['album']} ({len(item['files'])} tracks)")

    save_state(state)
    debug(f"💾 State saved ({len(state)} tracked items)")


if __name__ == "__main__":
    main()
