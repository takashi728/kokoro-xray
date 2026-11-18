# kokoro-xray

Small shell manager for Xray edge/exit deployments.

The scripts keep state in JSON, render configs with `jq`, validate before reload, and avoid large framework dependencies.

[English](README.md) | [日本語 (猫娘)](README.ja.md)

## Supported Modes

- Edge single-node: VLESS XHTTP or RAW/Vision, with REALITY, TLS, or both
- Optional Hysteria2 edge inbound with port hopping and Salamander obfuscation
- Edge + exit: edge forwards traffic to an exit over WireGuard
- TLS edge: Caddy handles ACME and HTTPS routing
- RAW TLS edge: Caddy passes TLS through to Xray; PrivateBin in Podman serves web fallback
- REALITY edge: Xray serves public `:443` directly

## Requirements

- Debian or Ubuntu
- Root access
- `443/tcp` open on edge nodes
- `80/tcp` open on TLS edge nodes for ACME
- Hysteria2 UDP ports open when enabled, default `443,20000-20020/udp`
- A direct, DNS-only domain for Hysteria2 certificate issuance
- Exit node UDP port open when using edge + exit, default `51820/udp`
- Xray-core `v26.11.9` or newer for Hysteria2

## Install

The reviewed installer commit is
`b93c64b93550293e614086eaacca0f6bfeff651a`. Download the bootstrap from that
immutable revision and pass the same SHA to it:

```bash
commit=b93c64b93550293e614086eaacca0f6bfeff651a
curl -fsSL "https://raw.githubusercontent.com/takashi728/kokoro-xray/${commit}/install.sh" \
    -o /tmp/kokoro-install.sh
sudo env KOKORO_REPO_COMMIT="$commit" bash /tmp/kokoro-install.sh
```

The installer verifies the staged repository is exactly that commit before
replacing the live installation. A mismatch aborts before activation.

Set up an edge:

```bash
sudo kokoro-xray edge
```

Set up an exit:

```bash
sudo kokoro-xray exit
```

## Update

Normal update keeps existing state. Download and run a newly reviewed
immutable bootstrap shown in **Install**, then run:

```bash
sudo kokoro-xray apply
```

Clean reinstall removes `/opt/kokoro-xray` and keeps `~/.kokoro-xray`:

```bash
sudo kokoro-xray reinstall
sudo kokoro-xray apply
```

Installations created before commit pinning have no
`~/.kokoro-xray/installed-commit`. Rerun the pinned bootstrap once before using
`reinstall`; the bootstrap records the trusted revision without changing node
state.

## Basic Flow

Single edge:

```bash
sudo kokoro-xray edge
sudo kokoro-xray apply
kokoro-xray link
kokoro-xray status
```

Edge + exit:

```bash
# On exit
sudo kokoro-xray exit

# On edge
sudo kokoro-xray edge
sudo kokoro-xray pair
sudo kokoro-xray apply

# Back on exit, paste edge peer info when prompted
sudo kokoro-xray pair
sudo kokoro-xray apply
```

## Client Output

Standard share links:

```bash
kokoro-xray link
```

The selected transport is included in both URLs and JSON exports. RAW uses
`type=tcp` in share URLs and `network: "raw"` in native Xray JSON.

## RAW/Vision Performance Mode

Fresh interactive edge setup defaults to `raw` transport and `reality` mode
for domain-free direct operation. This is the CN performance preset, not a
guarantee about speed or censorship resistance on a particular network.
Existing state defaults to `xhttp` when migrated; it is never silently switched.
Choose `xhttp` to retain HTTP/CDN transport.

RAW uses `xtls-rprx-vision` on the server and
`xtls-rprx-vision-udp443` on the exported client. The latter permits proxied
UDP/443 instead of forcing QUIC traffic onto TCP. `xtls-rprx-udp443` is not a
valid Xray flow. RAW REALITY retains the existing VLESS payload encryption
setting. **RAW TLS with fallback must use VLESS `decryption: "none"`**: Xray
rejects protocol fallbacks combined with VLESS payload encryption. Its matching
client export uses `encryption: "none"`; TLS and Vision remain enabled. This
exception does not disable payload encryption on REALITY or XHTTP profiles.

- `raw` + `reality`: Xray listens directly on TCP/443 unless both mode or HY2
  requires Caddy routing. The standard REALITY target scan still applies.
- `raw` + `tls`: requires a direct domain in `.inbound.tls.domain`, DNS-only
  and pointing to this VPS. The setup checks the IPv4 records. Any IPv6 record
  must also point to this VPS. Ordinary HTTP CDN proxying cannot carry RAW/Vision.
- `raw` + `both`: Caddy routes REALITY SNI to Xray loopback TCP/8443 and the
  direct TLS SNI to loopback TCP/8444. Xray terminates RAW TLS itself; Caddy
  does not terminate the Vision transport.

For RAW TLS, Caddy obtains the public certificate via HTTP-01 on TCP/80.
Certificate files remain root-owned inside Caddy's certificate directory, and
a systemd watcher restarts Xray after renewal. Certificate bootstrapping
restores the previous Caddy configuration before the regular apply transaction.

RAW TLS browser traffic follows this path:

```text
Browser HTTPS / HTTP/2
  Caddy L4 :443 -> Xray RAW TLS :8444 -> Caddy h1/h2c 127.0.0.1:8080
    -> PrivateBin 127.0.0.1:8081 (Podman)
```

PrivateBin is a real encrypted-paste application, not a generated static page.
The filesystem-only official image is pinned by multi-architecture manifest
digest in `lib/fallback.sh`. Podman is installed only for RAW TLS. The container
has no runtime socket or host data mounted, runs non-root with capabilities
dropped, and uses a read-only root filesystem. It is limited to half a CPU,
192 MiB RAM, 64 processes, and 16 MiB temporary paste storage. Uploads and
comments are disabled; text pastes are limited to 64 KiB, expire within a day,
and have a 60-second creation interval. Pastes disappear on container restart.
These defaults are for a small fallback service, not durable paste hosting.
The internal ports bind only to loopback and are not opened in UFW.

REALITY unauthenticated traffic still reaches its selected remote certificate
target. A local PrivateBin instance cannot substitute that target while keeping
the borrowed-certificate behavior. A common web app can also be fingerprinted;
it is not proof that a proxy is undetectable.

Use `kokoro-xray link --json reality` or `--json tls` as before. Switching a
transport requires refreshing client profiles. The immutable installer pin
in the Install section is the last reviewed baseline and predates this
development feature; install a reviewed commit containing RAW support when
testing it.

OpenWrt TPROXY client deployment is a separate next step. This installer still
targets Debian/Ubuntu systemd hosts and does not configure router firewall rules.

## Client Profiles

Hysteria2 output uses a `hysteria2://` URI on the first configured UDP port
with standard Salamander obfuscation. It includes the `mport` parameter used by
v2rayN and the `port`/`mportHopInt` parameters used by Happ, without placing a
port range in the hostname. Its domain must point directly to the VPS.
Cloudflare's ordinary CDN proxy does not carry Hysteria2 UDP traffic.
It may be the same direct domain used by TLS XHTTP; Caddy keeps those TCP and
UDP services on their separate paths and protocols.

Use the Xray JSON export when the client supports JSON import and should use
the full UDP hopping range:

```bash
kokoro-xray link --json hysteria
```

TLS JSON export for the selected transport:

```bash
kokoro-xray link --json tls
```

Use JSON export for TLS mode when the client app does not preserve advanced
XHTTP settings from URL subscriptions. Use a current Xray client.

VLESS REALITY JSON export for the selected transport:

```bash
kokoro-xray link --json reality
```

The REALITY JSON profile uses the server's public IPv4 address, the configured
REALITY SNI, public key, short ID, and either RAW/Vision flow or XHTTP path
settings. Set `KOKORO_PUBLIC_ADDRESS` to override public-address detection.

## Commands

| Command | Description |
| --- | --- |
| `edge [--keep-secrets]` | Install or update edge node |
| `exit [--keep-secrets]` | Install or update exit node |
| `apply` | Render, validate, and reload services |
| `pair` | Exchange edge/exit WireGuard peer info |
| `link [--json tls\|reality\|hysteria]` | Print client links or an Xray JSON profile |
| `status` | Show service and config status |
| `validate` | Validate rendered configs |
| `geodata` | Update geo data files |
| `firewall status` | Show UFW state |
| `firewall apply` | Re-apply configured UFW rules |
| `tune` | Apply optional network tuning |
| `reality scan` | Probe REALITY targets |
| `vless-encryption on\|off\|status` | Manage VLESS payload encryption |
| `tor on\|off` | Optional exit-node Tor routing |
| `reinstall [--commit COMMIT]` | Clean reinstall the reviewed commit, keep state |

## VLESS Encryption

Fresh edge installs enable Xray-core VLESS Encryption. The official
`xray vlessenc` command generates one X25519-authenticated pair; ephemeral key
exchange remains post-quantum safe. Server and client strings stay in
`secrets.json`.

Existing nodes upgrade with encryption disabled to preserve current clients:

```bash
sudo kokoro-xray vless-encryption on
kokoro-xray link
```

Enabling or disabling changes every client profile. Refresh links afterward.
The VLESS layer protects payloads inside XHTTP; TLS or REALITY remains required
for transport security and censorship resistance.

## Hysteria2

Run `sudo kokoro-xray edge` and enable Hysteria2 during onboarding. It runs in
parallel with the selected VLESS mode and defaults to:

- Real Let's Encrypt certificate managed by Caddy
- Automatic Xray restart after Caddy renews that certificate
- UDP port hopping across `443,20000-20020`
- Salamander packet obfuscation (upstream's Gecko mode is not enabled)
- BBR with the aggressive profile
- HTTP/3 masquerade proxying to the selected public website

Caddy disables its own HTTP/3 listener while Hysteria2 is enabled so Xray alone
owns UDP `443`. Hysteria Realm/NAT-to-NAT mode is intentionally not configured.

## Custom Outbound Proxy

Interactive edge and exit setup offer an optional SOCKS5 or HTTP CONNECT
proxy. Enter its host, port, username, password, and comma-separated
destination domains. Each domain also matches its subdomains. Run setup again
to keep, edit, or remove the proxy.

Matching TCP uses the custom proxy ahead of the node's normal routes. Matching
UDP is blocked, so QUIC may need to fall back to TCP. Unmatched traffic keeps
its normal route. On a paired setup, configure the proxy on the exit to keep
the WireGuard hop. Configuring it on the edge sends matching traffic from
the edge itself. IP-only traffic without a sniffable hostname cannot match
a domain rule.

Credentials are stored in server secrets and excluded from client exports.
Use a proxy that requires authentication on a trusted or encrypted link.
Plain SOCKS5 and HTTP CONNECT do not encrypt the credentials on that link.

## REALITY Target Scan

```bash
kokoro-xray reality scan
kokoro-xray reality scan --domains www.sky.com,github.com
kokoro-xray reality scan --apply
sudo kokoro-xray apply
```

The scanner checks DNS, TLS 1.3, ALPN `h2`, certificate coverage, and redirect behavior.

## Files

- Install dir: `/opt/kokoro-xray`
- Command symlink: `/usr/local/bin/kokoro-xray`
- Settings: `~/.kokoro-xray/config.json`
- Secrets: `~/.kokoro-xray/secrets.json`
- Xray config: `/usr/local/etc/xray/config.json`
- Caddyfile: `/etc/caddy/Caddyfile`
- Hysteria2 certificates: `/var/lib/kokoro-caddy/certificates/`

## Notes

- Xray downloads are verified against repository-pinned SHA-256 hashes.
- Xray-core is pinned to the latest tested stable release.
- Caddy builds are pinned and rebuilt only when needed.
- If distro Go is too old, Caddy builds use a managed Go toolchain under `/usr/local/kokoro-go`.
- UFW defaults to deny incoming and allow outgoing when firewall support is enabled.
- XHTTP client JSON exports explicitly use the [Xray-core v26.3.27 XMUX defaults](https://github.com/XTLS/Xray-core/blob/v26.3.27/infra/conf/transport_internet.go#L391-L401), including `maxConcurrency: 1`. Each XMUX connection client handles one active proxied session at a time. Throughput depends on the network and workload.

## License

MIT
