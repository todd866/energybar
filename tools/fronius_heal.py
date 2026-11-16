#!/usr/bin/env python3
"""Keep Energybar pointed at the Fronius inverter when DHCP moves it.

Run every few minutes by launchd (local.energybar.fronius-heal). If the inverter
at FRONIUS_LOCAL_IP no longer reports FRONIUS_INVERTER_SERIAL, scan the home /24
for the device that does, rewrite the IP in .env (FRONIUS_LOCAL_IP and
FRONIUS_SOLAR_API), and relaunch Energybar, which reads .env only at launch.
Away from home (the serial is nowhere on the LAN) it changes nothing.
"""
from __future__ import annotations

import concurrent.futures as cf
import datetime as dt
import ipaddress
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request

ENV = os.path.expanduser("~/.config/energybar/.env")
PROBE = "/solar_api/v1/GetActiveDeviceInfo.cgi?DeviceClass=System"
APP = "/Applications/Energybar.app"


def log(msg: str) -> None:
    print(f"{dt.datetime.now().astimezone().isoformat(timespec='seconds')} {msg}", flush=True)


def env_value(text: str, key: str) -> str | None:
    m = re.search(rf"^{key}=(.*)$", text, re.M)
    return m.group(1).strip().strip("'\"") if m else None


def is_inverter(ip: str, serial: str, timeout: float = 3.0) -> bool:
    try:
        with urllib.request.urlopen(f"http://{ip}{PROBE}", timeout=timeout) as r:
            return serial in r.read(65536).decode("utf-8", "replace")
    except Exception:
        return False


def home_subnet() -> ipaddress.IPv4Network | None:
    out = subprocess.run(["/sbin/route", "-n", "get", "default"], capture_output=True, text=True).stdout
    m = re.search(r"gateway:\s*(\d+\.\d+\.\d+\.\d+)", out)
    if not m:
        return None
    net = ipaddress.ip_network(f"{m.group(1)}/24", strict=False)
    return net if net.is_private else None


def find(serial: str, net: ipaddress.IPv4Network) -> str | None:
    with cf.ThreadPoolExecutor(64) as pool:
        hosts = [str(h) for h in net.hosts()]
        for ip, ok in zip(hosts, pool.map(lambda h: is_inverter(h, serial, 2.0), hosts)):
            if ok:
                return ip
    return None


def rewrite_env(text: str, old: str, new: str) -> None:
    def fix(line: str) -> str:
        if line.startswith(("FRONIUS_LOCAL_IP=", "FRONIUS_SOLAR_API=")):
            return re.sub(rf"(?<![\d.]){re.escape(old)}(?![\d.])", new, line)
        return line
    body = "".join(fix(l) for l in text.splitlines(keepends=True))
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(ENV))
    with os.fdopen(fd, "w") as f:
        f.write(body)
    os.chmod(tmp, 0o600)
    os.replace(tmp, ENV)


def relaunch() -> None:
    if subprocess.run(["/usr/bin/pgrep", "-x", "Energybar"], capture_output=True).returncode != 0:
        return  # not running: it reads the new .env whenever it next starts
    subprocess.run(["/usr/bin/osascript", "-e", 'quit app "Energybar"'], capture_output=True, timeout=30)
    for _ in range(30):
        if subprocess.run(["/usr/bin/pgrep", "-x", "Energybar"], capture_output=True).returncode != 0:
            break
        time.sleep(1)
    subprocess.run(["/usr/bin/open", "-g", APP], capture_output=True)  # -g: no focus steal


def main() -> int:
    with open(ENV) as f:
        text = f.read()
    ip, serial = env_value(text, "FRONIUS_LOCAL_IP"), env_value(text, "FRONIUS_INVERTER_SERIAL")
    if not ip or not serial:
        return 0
    if is_inverter(ip, serial) or is_inverter(ip, serial):  # one retry before scanning
        return 0
    net = home_subnet()
    if net is None:
        return 0
    new = find(serial, net)
    if not new or new == ip:
        return 0  # away from home, or the inverter is off (night): leave .env alone
    rewrite_env(text, ip, new)
    log(f"inverter moved {ip} -> {new}; .env updated, relaunching Energybar")
    relaunch()
    return 0


if __name__ == "__main__":
    sys.exit(main())
