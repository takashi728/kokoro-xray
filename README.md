# kokoro-xray

Small shell manager for Xray edge/exit deployments.

The scripts keep state in JSON, render configs with `jq`, validate before reload, and avoid large framework dependencies.

## Supported Modes

- Edge single-node: VLESS XHTTP REALITY, TLS, or both
- Edge + exit: edge forwards traffic through post-quantum VLESS Encryption
- TLS edge: Caddy handles ACME and HTTPS routing
- REALITY edge: Xray serves public `:443` directly

## Requirements

- Debian or Ubuntu
- Root access
- `443/tcp` open on edge nodes
- `80/tcp` open on TLS edge nodes for ACME
- Exit node `51820/tcp` allowed from the edge public IPv4 only
- Xray-core `v26.3.27` or newer on REALITY clients

## Install

This branch is intentionally separate from the default WireGuard design:

```bash
curl -fsSL https://raw.githubusercontent.com/takashi728/kokoro-xray/feature/exit-vless-pqc/install.sh \
  | sudo bash -s -- --branch feature/exit-vless-pqc
```

Install and immediately start edge setup:

```bash
curl -fsSL https://raw.githubusercontent.com/takashi728/kokoro-xray/feature/exit-vless-pqc/install.sh \
  | sudo bash -s -- --branch feature/exit-vless-pqc --edge
```

Install and immediately start exit setup:

```bash
curl -fsSL https://raw.githubusercontent.com/takashi728/kokoro-xray/feature/exit-vless-pqc/install.sh \
  | sudo bash -s -- --branch feature/exit-vless-pqc --exit
```

## Update

Normal update keeps existing state:

```bash
curl -fsSL https://raw.githubusercontent.com/takashi728/kokoro-xray/feature/exit-vless-pqc/install.sh \
  | sudo bash -s -- --branch feature/exit-vless-pqc
sudo kokoro-xray apply
```

Clean reinstall removes `/opt/kokoro-xray` and keeps `~/.kokoro-xray`:

```bash
sudo kokoro-xray reinstall --branch feature/exit-vless-pqc
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

# Copy the one-line exit relay bundle, then on edge
sudo kokoro-xray edge
sudo kokoro-xray pair
sudo kokoro-xray apply

# Back on exit, enter the edge public IPv4
sudo kokoro-xray pair
sudo kokoro-xray apply
```

The relay uses ML-KEM-768 authenticated VLESS Encryption over a direct RAW
transport. The edge routes TCP and UDP through the encrypted VLESS outbound;
XUDP carries UDP. The exit firewall does not expose the relay port globally:
UFW permits only the configured edge IPv4.

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
| `pair` | Exchange edge/exit PQ relay information |
| `link [--json tls]` | Print client links or TLS JSON |
| `status` | Show service and config status |
| `validate` | Validate rendered configs |
| `geodata` | Update geo data files |
| `firewall status` | Show UFW state |
| `firewall apply` | Re-apply configured UFW rules |
| `tune` | Apply optional network tuning |
| `reality scan` | Probe REALITY targets |
| `vless-encryption on\|off\|status` | Manage VLESS payload encryption |
| `tor on\|off` | Optional exit-node Tor routing |
| `reinstall --branch feature/exit-vless-pqc` | Clean reinstall code, keep state |

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
- This branch prioritizes post-quantum forward secrecy over gaming-specific UDP behavior.

## License

MIT
