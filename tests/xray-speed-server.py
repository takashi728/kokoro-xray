"""Loopback benchmark origin and two counted TCP entrances to one XHTTP backend."""
import asyncio
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

directory = Path(sys.argv[1])
payload = os.urandom(1024 * 1024)
counts = {"up": [0, 0], "down": [0, 0]}


class Origin(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, body, code=200):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/who":
            self.reply(self.client_address[0].encode())
        elif self.path == "/counts":
            self.reply(json.dumps(counts).encode())
        elif self.path == "/hold":
            (directory / "holding").touch()
            for _ in range(200):
                if (directory / "release").exists():
                    break
                time.sleep(.1)
            self.reply(self.client_address[0].encode())
        else:
            self.reply(payload[:1] if (directory / "mode").read_text().strip() == "short" else payload)

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if self.path == "/echo":
            return self.reply(body)
        mode = (directory / "mode").read_text().strip()
        if (mode == "reject" or (mode == "xhttp-down" and self.client_address[0] == "127.0.0.2")
                or len(body) != len(payload)):
            return self.reply(b"", 503)
        if not mode.startswith("favor-") and mode != self.client_address[0]:
            time.sleep(0.65)
        self.reply(b"", 204)


async def relay(leg, reader, writer):
    upstream, target = await asyncio.open_connection("127.0.0.1", 18340)

    async def copy(source, dest, direction):
        try:
            while data := await source.read(65536):
                counts[leg][direction] += len(data)
                mode = (directory / "mode").read_text().strip()
                forward = (leg == "up") == (direction == 0)
                if mode in ("favor-forward", "favor-reverse") and forward != (mode == "favor-forward"):
                    await asyncio.sleep(len(data) / (2 * 1024 * 1024))
                dest.write(data)
                await dest.drain()
        finally:
            dest.close()

    await asyncio.gather(copy(reader, target, 0), copy(upstream, writer, 1), return_exceptions=True)


async def main():
    for port in (18343, 18347):
        origin = ThreadingHTTPServer(("127.0.0.1", port), Origin)
        threading.Thread(target=origin.serve_forever, daemon=True).start()
    up = await asyncio.start_server(lambda r, w: relay("up", r, w), "127.0.0.1", 18341)
    down = await asyncio.start_server(lambda r, w: relay("down", r, w), "127.0.0.1", 18342)
    async with up, down:
        await asyncio.gather(up.serve_forever(), down.serve_forever())


asyncio.run(main())
