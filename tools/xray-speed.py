#!/usr/bin/env python3
"""Run a Kokoro Xray client and select a path by measured bidirectional goodput."""

import argparse
import json
import os
import signal
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlsplit

SIZE = 1024 * 1024
GROUP = "kokoro-speed"
BLOCK = "BLOCK"


def probe_url(value):
    try:
        url = urlsplit(value)
        if (url.scheme in ("http", "https") and url.hostname and url.username is None
                and url.port != 0 and not url.fragment):
            return url
    except ValueError:
        pass
    raise argparse.ArgumentTypeError("expected an HTTP(S) URL without credentials or fragment")


def build_client(files, directory, urls):
    profiles = [json.loads(path.read_text()) for path in files]
    base = profiles[0]
    routes = base["routing"]["rules"]
    original = base["outbounds"][0]["tag"]
    if (not routes or routes[-1] != {"type": "field", "network": "tcp,udp", "outboundTag": original}
            or any(rule.get("outboundTag") not in (BLOCK, original) or "inboundTag" in rule
                   or "balancerTag" in rule for rule in routes)
            or base["routing"].get("balancers") or base["routing"].get("script")
            or any(key in base for key in ("api", "observatory", "burstObservatory"))):
        raise ValueError("first input must use standalone Kokoro client routing")
    candidates = []
    for path, profile in zip(files, profiles):
        tunnel, *others = profile["outbounds"]
        if (tunnel["protocol"] not in ("vless", "hysteria") or tunnel["tag"] in (BLOCK, "DIRECT")
                or any((ob["tag"], ob["protocol"]) not in
                       (("DIRECT", "freedom"), (BLOCK, "blackhole")) for ob in others)):
            raise ValueError(f"{path.name}: expected a standalone VLESS or HY2 client export")
        candidates.append(dict(tunnel, tag=f"path-{len(candidates) + 1}"))

    # BLOCK is also Xray's default when a request has no matching route.
    block = next((ob for ob in base["outbounds"] if ob["tag"] == BLOCK),
                 {"tag": BLOCK, "protocol": "blackhole"})
    base["outbounds"] = [block, *candidates]
    base["api"] = {"tag": "api", "listen": str(directory / "api"), "services": ["RoutingService"]}
    base["routing"]["balancers"] = [{"tag": GROUP, "selector": [BLOCK]}]
    probe_rules = []
    for candidate in candidates:
        tag = candidate["tag"]
        inbound_tags = []
        for direction, url in urls.items():
            name = f"{tag}-{direction}"
            inbound_tags.append(name)
            base["inbounds"].append({
                "tag": name, "listen": str(directory / name), "protocol": "tunnel",
                "settings": {"network": "tcp", "address": url.hostname,
                             "port": url.port or (443 if url.scheme == "https" else 80)},
            })
        probe_rules.append({"inboundTag": inbound_tags, "outboundTag": tag})

    # Keep each BLOCK rule at its original priority for probes and ordinary traffic.
    rules = []
    for rule in routes:
        if rule["outboundTag"] == BLOCK:
            rules.append(rule)
        else:
            match = {k: v for k, v in rule.items() if k != "outboundTag"}
            rules.extend(dict(match, **probe) for probe in probe_rules)
            rules.append(dict(match, balancerTag=GROUP))
    base["routing"]["rules"] = rules
    return base, [ob["tag"] for ob in candidates]


def measure(directory, tag, direction, url, payload):
    uploading = direction == "up"
    size_field = "size_upload" if uploading else "size_download"
    cmd = ["curl", "-q", "--silent", "--show-error", "--globoff", "--proxy", "",
           "--unix-socket", str(directory / f"{tag}-{direction}"), "--max-time", "15",
           "--max-filesize", str(SIZE), "--header", "Cache-Control: no-store",
           "--output", os.devnull, "--write-out", "%{http_code} %{" + size_field + "} %{time_total}"]
    if uploading:
        cmd += ["--data-binary", "@-", "--header", "Content-Type: application/octet-stream"]
    result = subprocess.run(cmd + ["--url", url.geturl()], input=payload if uploading else None,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise ValueError(f"curl exit {result.returncode}")
    code, size, elapsed = result.stdout.split()
    if not (200 <= int(code) < 300 and int(size) == SIZE and float(elapsed) > 0):
        raise ValueError(f"HTTP {int(code)}, {int(size)} bytes")
    return SIZE / float(elapsed)


def select(scores, current):
    if not scores:
        return BLOCK
    best = max(scores, key=scores.get)
    if current in scores and scores[best] < scores[current] * 1.15:
        return current
    return best


def run(args, directory):
    urls = {"down": args.download_url, "up": args.upload_url}
    config, tags = build_client(args.profiles, directory, urls)
    config_file = directory / "client.json"
    config_file.write_text(json.dumps(config))
    for tag, path in zip(tags, args.profiles):
        print(f"{tag} = {path.name}", flush=True)
    payload = os.urandom(SIZE)
    override = [args.xray, "api", "bo", f"--server=unix://{directory}/api", "-b", GROUP]
    client = subprocess.Popen([args.xray, "run", "-config", str(config_file)])
    try:
        current = BLOCK
        subprocess.run(override + ["-timeout", "15", BLOCK], check=True)
        while client.poll() is None:
            scores = {}
            for tag in tags:
                try:
                    down = measure(directory, tag, "down", urls["down"], payload)
                    up = measure(directory, tag, "up", urls["up"], payload)
                except ValueError as exc:
                    print(f"{tag} unavailable ({exc})", flush=True)
                    continue
                scores[tag] = 2 / (1 / down + 1 / up)
                print(f"{tag} up={up * 8 / 1e6:.2f} down={down * 8 / 1e6:.2f} Mbit/s", flush=True)
            chosen = select(scores, current)
            if chosen != current:
                subprocess.run(override + [chosen], check=True)
                current = chosen
            print(f"selected {current}", flush=True)
            try:
                client.wait(timeout=args.interval)
            except subprocess.TimeoutExpired:
                continue
        raise RuntimeError(f"Xray exited with status {client.returncode}")
    finally:
        client.terminate()
        client.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profiles", type=Path, nargs="+", help="standalone Kokoro client exports")
    parser.add_argument("--download-url", type=probe_url, required=True, help="GET exactly 1 MiB")
    parser.add_argument("--upload-url", type=probe_url, required=True, help="POST 1 MiB and await 2xx")
    parser.add_argument("--interval", type=int, default=300, help="seconds between rounds (default 300)")
    parser.add_argument("--xray", default=os.environ.get("XRAY_BIN", "xray"))
    args = parser.parse_args()
    if args.interval <= 0:
        parser.error("--interval must be positive")
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="kokoro-speed-") as temp:
        run(args, Path(temp).resolve())


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except (ValueError, KeyError, TypeError, IndexError, OSError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f"xray-speed: {error}")
