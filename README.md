# kokoro-xray

Small shell manager for Xray edge/exit deployments.

The scripts keep state in JSON, render configs with `jq`, validate before reload, and avoid large framework dependencies.

## Supported Modes

- Edge single-node: VLESS XHTTP REALITY, TLS, or both
- Optional Hysteria2 edge inbound with port hopping and Gecko/Salamander obfuscation
- Edge + exit: edge forwards traffic to an exit over WireGuard
- TLS edge: Caddy handles ACME and HTTPS routing
- REALITY edge: Xray serves public `:443` directly

## Requirements

- Debian or Ubuntu
- Root access
- `443/tcp` open on edge nodes
- `80/tcp` open on TLS edge nodes for ACME
- Hysteria2 UDP ports open when enabled, default `443,20000-20020/udp`
- A direct, DNS-only domain for Hysteria2 certificate issuance
- Exit node UDP port open when using edge + exit, default `51820/udp`
- Xray-core `v26.7.11` or newer for Hysteria2

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/takashi728/kokoro-xray/feature/upstream-hardening-vless-encryption/install.sh | sudo bash
```

Set up an edge:

```bash
sudo kokoro-xray edge
```

Set up an exit:

```bash
sudo kokoro-xray exit
```

## Update

Normal update keeps existing state:

```bash
curl -fsSL https://raw.githubusercontent.com/takashi728/kokoro-xray/feature/upstream-hardening-vless-encryption/install.sh | sudo bash
sudo kokoro-xray apply
```

Clean reinstall removes `/opt/kokoro-xray` and keeps `~/.kokoro-xray`:

```bash
sudo kokoro-xray reinstall
sudo kokoro-xray apply
```

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

Hysteria2 output uses a broadly compatible `hysteria2://` URI on the first
configured UDP port with Gecko obfuscation parameters. The server still
accepts the configured hopping range. Its domain must point directly to the
VPS. Cloudflare's ordinary CDN proxy does not carry Hysteria2 UDP traffic.

Use the Xray JSON export when the client supports JSON import and should use
the full UDP hopping range:

```bash
kokoro-xray link --json hysteria
```

TLS XHTTP JSON export for clients that support full JSON import:

```bash
kokoro-xray link --json tls
```

Use JSON export for TLS mode when the client app does not preserve advanced XHTTP settings from URL subscriptions.
The JSON profile also requires ECH for the configured Cloudflare CDN domain,
obtaining its ECH configuration through Cloudflare DoH. Use a current Xray
client and keep that domain proxied with Cloudflare ECH enabled.

## Commands

| Command | Description |
| --- | --- |
| `edge [--keep-secrets]` | Install or update edge node |
| `exit [--keep-secrets]` | Install or update exit node |
| `apply` | Render, validate, and reload services |
| `pair` | Exchange edge/exit WireGuard peer info |
| `link [--json tls\|hysteria]` | Print client links or an Xray JSON profile |
| `status` | Show service and config status |
| `validate` | Validate rendered configs |
| `geodata` | Update geo data files |
| `firewall status` | Show UFW state |
| `firewall apply` | Re-apply configured UFW rules |
| `tune` | Apply optional network tuning |
| `reality scan` | Probe REALITY targets |
| `vless-encryption on\|off\|status` | Manage VLESS payload encryption |
| `tor on\|off` | Optional exit-node Tor routing |
| `reinstall [--branch BRANCH]` | Clean reinstall code, keep state and current branch |

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
- UDP port hopping across `443,20000-20020`
- Gecko, which wraps Salamander and fragments QUIC handshake packets
- BBR with the aggressive profile
- HTTP/3 masquerade proxying to the selected public website

Caddy disables its own HTTP/3 listener while Hysteria2 is enabled so Xray alone
owns UDP `443`. Hysteria Realm/NAT-to-NAT mode is intentionally not configured.

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

- Xray downloads are verified with upstream SHA256 digest files.
- Xray-core is pinned to the latest tested stable release.
- Caddy builds are pinned and rebuilt only when needed.
- If distro Go is too old, Caddy builds use a managed Go toolchain under `/usr/local/kokoro-go`.
- UFW defaults to deny incoming and allow outgoing when firewall support is enabled.

## License

MIT
