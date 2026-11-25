# Select the fastest node and inbound profile

Run the selector on the Linux client whose network you want to measure. Give
it one standalone Kokoro client JSON for each candidate. Candidates can come
from different nodes or from different inbounds on one node. The first file
supplies the local SOCKS/HTTP listeners, DNS and routing policy. Each file
supplies its own transport and credentials. The selector runs Xray in the
foreground and sends new connections through the winning profile.

## Prepare candidates

On an XHTTP edge with TLS enabled, export a baseline and one or more split
profiles. Replace the documentation IP with the reachable origin address.

```bash
umask 077
kokoro-xray link --json xhttp-split direct-h2=192.0.2.42 > direct.json
kokoro-xray link --json xhttp-split cdn-h2 direct-h2=192.0.2.42 > cdn-up.json
kokoro-xray link --json xhttp-split direct-h2=192.0.2.42 cdn-h2 > cdn-down.json
```

On a node with Hysteria2 enabled, `kokoro-xray link --json hysteria > hy2.json`
exports another candidate. Standalone VLESS RAW/Vision exports also use the
same client format. Copy the desired exports privately to the client. Keep
the first file's policy in mind, particularly if putting a HY2 export first,
as its exported policy is a single catch-all.

Both legs of a split profile must reach **the same XHTTP session backend**.
The first leg carries uploads and the second carries downloads. Export both
orders if the selector should choose the direction automatically. Different
nodes compete as complete profiles. See the [split setup guide](xhttp-split.md).

## Run on the client

Use Python 3, curl with Unix socket support, and the project's Xray-core
v26.11.9 binary with its geodata. Free the SOCKS and HTTP ports from the
first export before starting. Run from this branch's source checkout.

```bash
bash ./kokoro-xray.sh speed \
    --download-url 'https://speed.cloudflare.com/__down?bytes=1048576' \
    --upload-url 'https://speed.cloudflare.com/__up' \
    direct.json cdn-up.json cdn-down.json hy2.json
```

These example URLs send the probes through each path to Cloudflare. To use
your own measurement origin, point the flags at a GET that returns exactly
1 MiB and a POST that reads the whole 1 MiB body before replying with a small
2xx response. HTTPS certificate verification stays enabled. Use an origin
that the first profile's routing policy permits. [Cloudflare measurement endpoints](https://github.com/cloudflare/speedtest#instantiation)

An installation made from this local revision also provides `kokoro-xray speed`.
The speed command runs without root or edge state. Use the first export's
normal SOCKS or HTTP proxy. With Kokoro defaults these
listen on `127.0.0.1:10808` and `127.0.0.1:10809`. The terminal maps each
`path-N` to its filename and prints measured rates and the active path. Set
`XRAY_BIN` or pass `--xray` for a binary outside PATH. Ctrl-C stops the client.

## How selection behaves

- Each round measures the candidates in sequence. Each successful candidate
  transfers 1 MiB down and 1 MiB up. Each transfer has a 15-second deadline.
  The rate includes connection setup and the origin response. Short downloads,
  redirects, HTTP errors and timeouts disqualify a candidate for the round.
- The score is the harmonic mean of the two rates. This ranks by the time
  needed to transfer an equal amount of data in each direction. A healthy
  incumbent stays selected until another scores at least 15% higher.
- When the active path fails a probe, the best remaining path wins at the
  end of the round. Traffic starts blocked and returns to `BLOCK` when all
  paths fail. A later successful round restores service. An unavailable probe
  origin can therefore interrupt routing across otherwise working nodes.
- New connections follow the selected Xray outbound. An open connection stays
  on its original path for its lifetime. Probe sockets and the Xray control
  socket live in a private temporary directory.
- The default pause after each round is 300 seconds. At this interval each
  continuously healthy candidate can use up to roughly 576 MiB/day in probe
  payload plus overhead. Use `--interval 1800` for a 30-minute pause.

Run `XRAY_BIN=/path/to/xray bash tests/xray-speed.sh` for the loopback
integration test with real XHTTP and HY2 nodes. It checks route switching,
split-leg byte counts, blocking, recovery and a connection held across a switch.
