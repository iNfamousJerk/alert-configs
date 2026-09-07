
#!/usr/bin/env python3
"""NUT Prometheus Exporter - exposes UPS metrics from NUT server"""
import http.server
import socket
import os

NUT_HOST = os.environ.get("NUT_HOST", "10.0.0.10")
NUT_PORT = int(os.environ.get("NUT_PORT", "3493"))
NUT_USER = os.environ.get("NUT_USER", "monitor")
NUT_PASS = os.environ.get("NUT_PASSWORD", "upsmonitor")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9999"))

VARS = [
    ("ups.status",    "nut_ups_status",      "UPS status (1=OL, 2=OB, 3=OB+LB, 4=OL+LB)",        "gauge"),
    ("battery.charge","nut_battery_charge",   "Battery charge percentage",                         "gauge"),
    ("battery.runtime","nut_battery_runtime", "Battery runtime remaining in seconds",               "gauge"),
    ("battery.voltage","nut_battery_voltage", "Battery voltage",                                   "gauge"),
    ("input.voltage", "nut_input_voltage",    "Input voltage",                                     "gauge"),
    ("output.voltage","nut_output_voltage",   "Output voltage",                                    "gauge"),
    ("ups.load",      "nut_ups_load",         "UPS load percentage",                               "gauge"),
]

def status_to_num(s):
    s = s.strip('"').strip()
    lb = "LB" in s or "LOW" in s
    if s.startswith("OB"):
        return 3.0 if lb else 2.0
    if s.startswith("OL"):
        return 4.0 if lb else 1.0
    return 0.0

def query_nuts(vars_list):
    results = {}
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect((NUT_HOST, NUT_PORT))
        def send(cmd):
            s.sendall((cmd + "\n").encode())
        def recv_line():
            data = b""
            while True:
                ch = s.recv(1)
                if not ch or ch == b"\n":
                    break
                data += ch
            return data.decode().strip()
        send(f"USERNAME {NUT_USER}"); recv_line()
        send(f"PASSWORD {NUT_PASS}"); recv_line()
        for var, prom_name, _, _ in vars_list:
            send(f"GET VAR cyberpower {var}")
            resp = recv_line()
            parts = resp.split()
            if len(parts) >= 4:
                val = " ".join(parts[3:])
                try:
                    if prom_name == "nut_ups_status":
                        results[prom_name] = status_to_num(val)
                    else:
                        results[prom_name] = float(val.strip('"'))
                except ValueError:
                    pass
        s.close()
    except Exception:
        pass
    return results

def collect_metrics():
    data = query_nuts(VARS)
    lines = []
    if not data:
        lines.append(f"# NUT exporter: no data from {NUT_HOST}:{NUT_PORT}")
    for var, prom_name, help_text, type_text in VARS:
        lines.append(f"# HELP {prom_name} {help_text}")
        lines.append(f"# TYPE {prom_name} {type_text}")
        if prom_name in data:
            lines.append(f"{prom_name} {data[prom_name]}")
        else:
            lines.append(f"{prom_name} -1")
    return "\n".join(lines) + "\n"

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(collect_metrics().encode())
        else:
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(b"<html><body><h1>NUT Exporter</h1><p><a href='/metrics'>/metrics</a></p></body></html>")
    def log_message(self, fmt, *args):
        pass

if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    print(f"NUT Exporter listening on :{LISTEN_PORT}", flush=True)
    server.serve_forever()