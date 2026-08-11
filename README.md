# kokoro-xray

Small shell manager for Xray edge/exit deployments.

The scripts keep state in JSON, render configs with `jq`, validate before reload, and avoid large framework dependencies.

## Supported Modes

- Edge single-node: VLESS XHTTP REALITY, TLS, or both
- Edge + exit: edge forwards traffic to an exit over WireGuard
- TLS edge: Caddy handles ACME and HTTPS routing
- REALITY edge: Xray serves public `:443` directly

## Requirements

- Debian or Ubuntu
- Root access
- `443/tcp` open on edge nodes
- `80/tcp` open on TLS edge nodes for ACME
- Exit node UDP port open when using edge + exit, default `51820/udp`

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/takashi728/kokoro-xray/codebase-redesign-with-func/install.sh | sudo bash
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
curl -fsSL https://raw.githubusercontent.com/takashi728/kokoro-xray/codebase-redesign-with-func/install.sh | sudo bash
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

TLS XHTTP JSON export for clients that support full JSON import:

```bash
kokoro-xray link --json tls
```

Use JSON export for TLS mode when the client app does not preserve advanced XHTTP settings from URL subscriptions.

## Commands

| Command | Description |
| --- | --- |
| `edge [--keep-secrets]` | Install or update edge node |
| `exit [--keep-secrets]` | Install or update exit node |
| `apply` | Render, validate, and reload services |
| `pair` | Exchange edge/exit WireGuard peer info |
| `link [--json tls]` | Print client links or the Xray TLS JSON profile |
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

## Notes

- Xray downloads are verified with upstream SHA256 digest files.
- Xray-core is pinned to the latest tested stable release.
- Caddy builds are pinned and rebuilt only when needed.
- If distro Go is too old, Caddy builds use a managed Go toolchain under `/usr/local/kokoro-go`.
- UFW defaults to deny incoming and allow outgoing when firewall support is enabled.
- XMUX uses `maxConcurrency: "5-10"` for throughput. Xray-core v26.6.27+ changed the default to `maxConnections: 6` (anti-RKN), but that limits the HTTP/2 connection pool and bottlenecks large downloads. `maxConcurrency: "5-10"` allows multiplexing within connections while keeping randomized values to avoid fingerprinting.

## License

MIT
