
from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import urllib.request
import time

DISCORD_WEBHOOK = "https://YOUR_DISCORD_WEBHOOK_URL"

def send_discord(embed):
    payload = {
        "username": "Monitoring Alerts",
        "avatar_url": "https://cdn3.emoji.gg/emojis/5280-alert.gif",
        "embeds": [embed]
    }
    req = urllib.request.Request(
        DISCORD_WEBHOOK,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "Monitoring Alerts"},
        method="POST"
    )
    try:
        urllib.request.urlopen(req)
        return True
    except Exception as e:
        print(f"Discord send failed: {e}")
        return False

def format_alert(alert):
    status = alert.get("status", "firing")
    labels = alert.get("labels", {})
    annotations = alert.get("annotations", {})
    starts_at = alert.get("startsAt", "")

    if status == "firing":
        color = 0xFF0000
        title = f"🚨 FIRING: {annotations.get('summary', labels.get('alertname', 'Unknown'))}"
    else:
        color = 0x00FF00
        title = f"✅ RESOLVED: {annotations.get('summary', labels.get('alertname', 'Unknown'))}"

    desc = annotations.get("description", "")

    embed = {
        "title": title,
        "description": desc,
        "color": color,
        "fields": [
            {"name": "Alert", "value": labels.get("alertname", "N/A"), "inline": True},
            {"name": "Severity", "value": labels.get("severity", "N/A"), "inline": True},
            {"name": "Job", "value": labels.get("job", "N/A"), "inline": True},
            {"name": "Instance", "value": labels.get("instance", "N/A"), "inline": True},
        ],
        "footer": {"text": f"Automation Monitoring • {starts_at[:19].replace('T', ' ')}"},
        "timestamp": starts_at
    }
    return embed

class AlertHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_len = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_len)
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(json.dumps({"error": "invalid json"}).encode())
            return

        alerts = data.get("alerts", [])
        print(f"Received {len(alerts)} alerts")

        for alert in alerts:
            try:
                embed = format_alert(alert)
                send_discord(embed)
                time.sleep(0.5)
            except Exception as e:
                print(f"Error processing alert: {e}")

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"status": "ok"}).encode())

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps({
            "service": "alert-webhook",
            "status": "running",
            "endpoints": {"POST /alert": "Receive Alertmanager webhooks"}
        }).encode())

    def log_message(self, fmt, *args):
        if args:
            print(f"[Webhook] {fmt % args}")
        else:
            print(f"[Webhook] {fmt}")

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 5000), AlertHandler)
    print("Webhook receiver listening on :5000")
    server.serve_forever()
