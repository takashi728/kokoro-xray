# kokoro-xray

Small shell manager for Xray edge/exit deployments.

The scripts keep state in JSON, render configs with `jq`, validate before reload, and avoid large framework dependencies.

[English](README.md) | [日本語 (猫娘)](README.ja.md)

## Supported Modes

- Edge single-node: VLESS XHTTP REALITY, TLS, or both
- Optional Hysteria2 edge inbound with port hopping and Salamander obfuscation
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

TLS XHTTP JSON export for clients that support full JSON import:

```bash
kokoro-xray link --json tls
```

Use JSON export for TLS mode when the client app does not preserve advanced
XHTTP settings from URL subscriptions. Use a current Xray client.

VLESS XHTTP REALITY JSON export:

```bash
kokoro-xray link --json reality
```

The REALITY JSON profile uses the server's public IPv4 address, the configured
REALITY SNI, public key, short ID, XHTTP path, and the same XHTTP client tuning
as the TLS profile. Set `KOKORO_PUBLIC_ADDRESS` to override public-address
detection.

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

Hysteria2 congestion control runs in userspace over QUIC/UDP, including its
Brutal algorithm. It does **not** need the Linux `tcp_brutal` kernel module.
[TCP Brutal](https://github.com/HyNetworks/tcp-brutal) is a separate TCP port of
that algorithm. Installing it, loading it, or enabling kernel TCP BBR does not
select a Hysteria2 congestion controller. The manager therefore does not install
or probe TCP Brutal for Hysteria2.

The managed server and exported Xray client JSON explicitly select QUIC BBR
with the aggressive profile. `status` shows that configured HY2 controller
separately from kernel TCP tuning; it does not inspect live QUIC sessions.
The manager currently does not render `brutalUp` / `brutalDown` bandwidth
parameters. In the pinned Xray version, setting `congestion` to `brutal` alone
falls back to BBR without the required rate negotiation; `force-brutal` without
an upload rate fails config validation. Enabling Brutal properly would require
bandwidth settings in both server/client config generation, not a kernel-module
check. See the pinned Xray [server](https://github.com/XTLS/Xray-core/blob/v26.11.9/transport/internet/hysteria/hub.go)
and [client](https://github.com/XTLS/Xray-core/blob/v26.11.9/transport/internet/hysteria/dialer.go)
controller selection.

## REALITY Target Scan

```bash
kokoro-xray reality scan
kokoro-xray reality scan --domains www.sky.com,github.com
kokoro-xray reality scan --apply
sudo kokoro-xray apply
```

The scanner requires the target's locally resolved addresses to announce from
the VPS's ASN. RIPEstat supplies BGP origin-ASN data over HTTPS. The VPS's public
IPv4 is detected over HTTPS; set `KOKORO_PUBLIC_ADDRESS` to its literal public IP
when detection does not represent the address clients use. A transit/upstream
ASN is not the same thing as the prefix's announcing ASN.

Candidates come from curated seeds, the current SNI, VPS PTR suffixes, and
`--domains` / `--file`. PTR names are hints, not proof. There is no complete
public ASN-to-website directory; a provider may have no suitable target among
these candidates. Supply known provider-hosted websites if discovery finds none.
You do not need to own those domains. Unknown, mixed, or mismatching ASNs stop
selection; the installer does not silently fall back to a popular CDN target.

Matching candidates must also pass TLS 1.3 with certificate/hostname verification,
ALPN `h2`, certificate SAN coverage, and redirect checks. Candidates are ranked
by measured TLS handshake latency, then score. Selecting a target rechecks it
and pins the tested IP as `dest`, keeping the domain as SNI. Manual onboarding
uses the same checks. Rescan when the target IP changes. Existing configurations
are not rewritten automatically; rerun `reality scan --select` and `apply` to
replace an older target. ASN lookups happen during selection, not on every apply.
Noninteractive `edge` setup also checks its configured SNI before installation;
preconfigure a suitable domain instead of relying on the generic default.

This follows [upstream REALITY target guidance](https://github.com/XTLS/Xray-docs-next/blob/main/docs/en/config/transports/reality.md).
Same-ASN selection reduces one inconsistency; it is not proof against GFW
detection or a guarantee that the SNI resolves identically inside China.
RIPEstat sees the queried public IPs. No credentials are sent.

CDN screening is independent of the ASN match. Targets are also rejected when
any locally resolved address matches a known CDN/WAF edge range, a DNS-chain
hostname matches a known CDN suffix, or the pinned HTTPS endpoint sends a known
CDN header. Cloudflare, Fastly, CloudFront, Akamai aliases, and other providers
are covered by the pinned ProjectDiscovery CDNCheck dataset in
`data/reality-cdn.json`. Its source revision, source checksum, review date, and
MIT license are recorded in the file. Only CDN/WAF ranges and CDN suffixes are
included; general cloud VM ranges are excluded. Using Cloudflare for DNS alone
does not cause rejection.

The installer installs the small `grepcidr` distro package for IPv4/IPv6 CIDR
matching. Existing installs need `apt install grepcidr` before scanning.
DNS-chain lookups use RIPEstat over HTTPS. Failed lookups, inconsistent local
and RIPEstat DNS answers, missing data, and checker errors reject the target.
Manual and noninteractive onboarding use exactly the same screening.

The output label is **cdn-screened**, not proof of a non-CDN origin. Providers
can hide their edge service or add ranges after the dataset was reviewed.
Choose a direct provider-hosted website; do not treat a clean result as a
bandwidth guarantee. Even an ordinary origin can serve large unauthenticated
REALITY fallback transfers. This change adds no fallback rate limits, which
have their own fingerprinting tradeoffs.

To refresh the dataset, review a new immutable CDNCheck source revision and
regenerate `ranges` from the union of its `cdn` and `waf` sections and `suffixes`
from its `common` section. Preserve the upstream license, record the new source
SHA-256 and review date, and run `tests/reality-cdn.sh` before committing.

The selection checks apply to REALITY independently of its transport. This
project currently emits XHTTP REALITY with an empty VLESS flow. A future RAW
profile can reuse selection, but must use the actual Vision flow names:
`xtls-rprx-vision` on the server and optionally `xtls-rprx-vision-udp443` on the
client to permit UDP/443. `xtls-rprx-upd443` is not a valid flow name.

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
- XMUX uses `maxConcurrency: "5-10"` for throughput. Xray-core v26.6.27+ changed the default to `maxConnections: 6` (anti-RKN), but that limits the HTTP/2 connection pool and bottlenecks large downloads. `maxConcurrency: "5-10"` allows multiplexing within connections while keeping randomized values to avoid fingerprinting.

## License

MIT
