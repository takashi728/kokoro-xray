# Upstream and deployment security review

Research cutoff: 2026-11-17 (Asia/Singapore)

Repository baseline reviewed: `3e2a745793cb542eed4e4f78b276f451bcb3c2ce`

This note separates verified upstream facts, applicability to Kokoro, and
deployment facts that could not be verified without access to the actual VPS
inventory. It is a review artifact; the concurrent implementation worktree is
described separately below.

## Immediate priorities

1. **Patch the kernel on every edge and exit host.** Upgrade to a distro kernel
   at or above the fixed version for CVE-2026-98432. Changing Xray alone reduces
   one attack surface but does not fix the kernel bug.
2. **Replace the withdrawn Xray-core `v26.10.29` pin.** The minimum safe
   replacement was `v26.10.31`; the current stable and recommended target is
   `v26.11.9`.
3. **Keep Hysteria2's implementation and documentation aligned.** The
   implementation emits plain Salamander, not Gecko. The client export carries
   the standalone `udphop` UDP mask; it is client-only and must not be added to
   the server inbound.
4. **Build Caddy 2.11.9.** The committed baseline pins 2.11.3. Other supported
   floors are below current upstream and have applicable advisories.
5. **Use a current, verified Go toolchain for Caddy.** The committed baseline
   defaulted to 1.26.5. The current worktree pins 1.26.11 with a 1.26.9 minimum,
   which is required by caddy-l4 `v0.1.3`.
6. **Pin the installer to an immutable commit or verify a signed release
   artifact.** A shallow clone of a mutable HTTPS branch is not a reproducible
   trust boundary.

## Verified upstream facts

### Linux CVE-2026-98432

The Xray `v26.10.31` release calls this an urgent Linux security update. Its
release note says listening IPv4 MPTCP traffic could be exploited to obtain
root remotely, that Go 1.24 and later enable MPTCP by default, and that users
must also update the Linux kernel:

- https://github.com/XTLS/Xray-core/releases/tag/v26.10.31
- https://ubuntu.com/security/CVE-2026-98432
- https://security-tracker.debian.org/tracker/CVE-2026-98432

Verified package floors:

| Distribution / release | Fixed kernel floor | Additional observation |
| --- | --- | --- |
| Ubuntu 24.04 | `6.8.0-149.149` | At or above this floor is fixed. |
| Ubuntu 22.04 | `5.15.0-203.213` | At or above this floor is fixed. |
| Ubuntu 20.04 | Not established | No floor is encoded in the status check. |
| Debian 12 Bookworm | `6.1.190-1` | The status check accepts the unadorned upstream floor `6.1.190`. |
| Debian 13 Trixie | `6.12.113-1` | The status check accepts the unadorned upstream floor `6.12.113`. |

Do not treat an nftables or IPv4-options workaround as equivalent to the kernel
fix. The Xray release describes the network-level mitigation as incomplete.

### Xray-core

The committed baseline used `lib/geodata.sh` to install `v26.10.29`.
`v26.10.29` was withdrawn as part of the MPTCP response. At the cutoff, its
release page returned 404. The withdrawn release commit identified during the
review was:

- `0afec66085a85191e9dd2a4a6646c7c9a94688d1`

`v26.10.31` replaced it and disabled MPTCP by default:

- Release: https://github.com/XTLS/Xray-core/releases/tag/v26.10.31
- Tag commit: `a4a3dff5b20c2faae567b742c172c7b95e75c083`
- Mitigation commit: `6ea0ab5d3ae0e9c7d252347fa9250273d54fb2e9`

That default is visible in the current stable source:

https://github.com/XTLS/Xray-core/blob/v26.11.9/transport/internet/system_listener.go#L91

The current stable at the cutoff was `v26.11.9`, published 2026-11-09:

- https://github.com/XTLS/Xray-core/releases/tag/v26.11.9
- Tag commit: `676eaf66f8f05d4d558ee7a74b4736623d3feeb9`

The security-relevant release between the old local default and current stable
also includes the urgent certificate handling work in `v26.10.21`:

- https://github.com/XTLS/Xray-core/releases/tag/v26.10.21
- Tag commit: `1b1647cd9ddf0abc34b981d4611fc03bcac1ca74`
- Root CA removal: https://github.com/XTLS/Xray-core/pull/7212
- Built-in RootCAs default: https://github.com/XTLS/Xray-core/pull/7105

The direct comparison from the older local floor is:

- https://github.com/XTLS/Xray-core/compare/v26.7.11...v26.11.9
- 205 commits

The certificate-pinning MITM advisory is not directly applicable to the current
Hysteria client export. That export does not set `pinnedPeerCertSha256` and does
set `serverName`. The advisory affects `>= v26.1.13` and was patched in
`>= v26.7.11`, so any modern upgrade is still required:

https://github.com/XTLS/Xray-core/security/advisories/GHSA-5wf9-h793-w73c

### Hysteria2 FinalMask

The committed README said Hysteria2 used Gecko and fragmented QUIC handshakes.
The renderer emitted plain Salamander:

```json
{
  "finalmask": {
    "udp": [
      {
        "type": "salamander",
        "settings": {
          "password": "..."
        }
      }
    ]
  }
}
```

Upstream creates `GeckoConfig` only when `packetSize.to > 0`; otherwise it
creates the ordinary `salamander.Config`:

https://github.com/XTLS/Xray-core/blob/v26.11.9/infra/conf/transport_finalmask.go#L768

Therefore the default deployment is **plain Salamander**, not Gecko. The review
snapshot's test asserted the absence of `packetSize` while the README claimed
the opposite:

- `lib/render.jq:117-123`
- `tests/hysteria.sh:38-45`
- `README.md:159-168`

Upstream moved `udpHop` out of the QUIC parameters into a standalone UDP
FinalMask. In `v26.11.9`, `QuicParamsConfig` has no `udpHop` field, while the
UDP mask loader accepts a mask type named `udphop`:

- https://github.com/XTLS/Xray-core/blob/v26.11.9/infra/conf/transport_finalmask.go#L1198
- https://github.com/XTLS/Xray-core/blob/v26.11.9/infra/conf/transport_finalmask.go#L86
- https://github.com/XTLS/Xray-core/pull/6327

The review snapshot's renderer and client JSON still used:

```json
{
  "finalmask": {
    "quicParams": {
      "udpHop": {
        "ports": "...",
        "interval": "..."
      }
    }
  }
}
```

The client export uses a standalone `udphop` UDP mask with
`mode: "intervalremote"`, `interval`, and `remotePorts`. It must not be added to
the server inbound: upstream's `WrapPacketConnServer` returns
`udphop: client only`. The server listens on the configured port list and uses
Salamander. Tests assert that `quicParams.udpHop` is absent server-side.
Structural validation does not prove live port hopping; a client handshake and
packet capture remain deployment verification.

The Hysteria2 URL still carries `mport` and related URI parameters, so URL-based
clients may implement hopping independently of the Xray JSON shape. This does
not repair the JSON export.

### Caddy

The committed baseline is 2.11.3. Current upstream at the cutoff was 2.11.9:

- https://github.com/caddyserver/caddy/releases/tag/v2.11.9
- https://github.com/caddyserver/caddy/releases/tag/v2.11.8

Caddy 2.11.3 is affected by fixes delivered in later patch releases. Relevant
examples:

| Advisory | Affected version | Fixed in |
| --- | --- | --- |
| [CVE-2026-77281](https://github.com/caddyserver/caddy/security/advisories/GHSA-j8px-rmrx-76h9), including an unbounded body-buffer DoS | `<= 2.11.3` | 2.11.4 |
| [CVE-2026-52846](https://github.com/caddyserver/caddy/security/advisories/GHSA-vcc4-2c75-vc9v), `stripHTML` bypass | `<= 2.11.3` | 2.11.4 |
| [CVE-2026-55458](https://github.com/caddyserver/caddy/security/advisories/GHSA-8qx7-j2v2-x6q5), hop-by-hop header handling | `<= 2.11.4` | 2.11.5 |
| [GHSA-6365-7ppr-5r92](https://github.com/caddyserver/caddy/security/advisories/GHSA-6365-7ppr-5r92), wrong-upstream connection for `forward_auth` plus `reverse_proxy` | `< 2.11.5` | 2.11.5 |
| [GHSA-r766-rf9f-588h](https://github.com/caddyserver/caddy/security/advisories/GHSA-r766-rf9f-588h), `{host}` file-root escape | `<= 2.11.7` | 2.11.8 |
| [GHSA-25cw-38mq-q7m6](https://github.com/caddyserver/caddy/security/advisories/GHSA-25cw-38mq-q7m6) and [GHSA-69hv-5jfc-mvmv](https://github.com/caddyserver/caddy/security/advisories/GHSA-69hv-5jfc-mvmv), file-match path bypasses | `<= 2.11.7` | 2.11.8 |
| [GHSA-jf74-f69g-hcj9](https://github.com/caddyserver/caddy/security/advisories/GHSA-jf74-f69g-hcj9), private-key exposure through `file_server` fallback | `<= 2.11.7` | 2.11.8 |
| [GHSA-f278-mgc7-46j3](https://github.com/caddyserver/caddy/security/advisories/GHSA-f278-mgc7-46j3), `php_fastcgi` authorization bypass | `<= 2.11.7` | 2.11.8 |

Advisory source:

https://github.com/caddyserver/caddy/security/advisories

Debian's tracker independently still marks CVE-2026-55458 vulnerable in its
packaged releases:

https://security-tracker.debian.org/tracker/source-package/caddy

Kokoro uses Caddy as a reverse proxy and with caddy-l4; it does not appear to
ship a config that uses `file_server`, `php_fastcgi`, or Caddy templates. That
reduces the likely applicability of several 2.11.8 advisories, but not the
benefit or the need to move to the current patched build. Exploitability of each
advisory against the deployed Caddyfile was not individually tested.

### Go, jq, nginx, curl, and bash

| Component | Local baseline | Review conclusion |
| --- | --- | --- |
| Go for Caddy | Baseline default 1.26.5; minimum 1.25.0 | Worktree pins 1.26.11 and requires at least 1.26.9 for caddy-l4. Caddy dependencies still resolve through Go modules. |
| jq | Installer accepts distro package | Debian Bookworm remains vulnerable to CVE-2026-40612; Trixie is fixed. Keep jq current and test the rendered outputs after changing major versions. |
| nginx | Not used to serve Kokoro | Debian Bookworm has numerous unresolved 2026 entries, but they apply only to a separately deployed nginx. |
| curl | Distro package | Numerous tracker entries exist, most feature-specific. Keep the distro package current; no Kokoro-specific remote exploit was established. |
| bash | Distro package | No current high-priority remote CVE was established. Normal distro updates apply. |

Sources:

- https://security-tracker.debian.org/tracker/source-package/golang-1.27
- https://security-tracker.debian.org/tracker/source-package/jq
- https://security-tracker.debian.org/tracker/source-package/nginx
- https://security-tracker.debian.org/tracker/source-package/curl
- https://security-tracker.debian.org/tracker/source-package/bash

## Supply-chain review

### Installer branch

`install.sh` defaults to the mutable HTTPS branch
`codebase-redesign-with-func`, performs `git clone --depth 1`, and does not
verify a signed tag or expected commit:

- `install.sh:6-9`
- `install.sh:137-143`
- `install.sh:151-165`

`--branch` selects another branch but does not make the result immutable.
A safer design records an expected commit, checks it after cloning, and refuses
installation on mismatch. A signed release archive with an independently
verified checksum is an acceptable alternative.

### Xray release archives

The committed baseline trusted `${zip}.dgst` downloaded from the same GitHub
release origin as the ZIP. That is integrity checking against transport or
partial corruption, but it does not make the same origin an independent trust
root.

The live worktree changed this to repository-pinned per-architecture SHA-256
values. At the cutoff, both matched the hashes published in the upstream GitHub
release metadata and one downloaded artifact:

| Archive | SHA-256 |
| --- | --- |
| `Xray-linux-64.zip` | `b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82` |
| `Xray-linux-arm64-v8a.zip` | `64ed6858982a7f5eb85d88b811089063bd4f17561f4c8f44e0f1dc8e6f6430be` |

Release:

https://github.com/XTLS/Xray-core/releases/tag/v26.11.9

Pinning the digest in the repository prevents a changed archive at the same URL
from silently passing. It still requires the repository commit itself to be
trusted. A release process should also publish the expected hashes through a
channel independent of the installer branch.

### Managed Go and xcaddy

The committed baseline downloads the Go tarball from `go.dev/dl` without an
additional pinned checksum and installs `xcaddy` with `go install ...@v0.4.6`.
Tag pinning is better than `@latest`, but remote module resolution still trusts
the Go module ecosystem and the selected toolchain.

The live worktree now pins and verifies the official Go archive checksum and
retains the xcaddy tag pin. The build still resolves xcaddy and caddy-l4 through
Go modules, so a production build should record the resolved module versions and
constrain module-proxy settings.

## Repository-specific observations

### REALITY X-Forwarded-For

The committed REALITY listener applied `trustedXForwardedFor` even when it was
the public listener. The live worktree now removes that setting unless REALITY
is loopback-only behind Caddy. This is a hardening improvement:

- Committed shape: `git show HEAD:lib/render.jq`
- Live conditional: `lib/render.jq:23`

It is concurrent worktree state, not an edit from this review.

### FinalMask validation

The live renderer was tested with the downloaded Xray 26.11.9 binary:

- `XRAY_BIN=/tmp/kokoro-upstream/xray-26.11.9/xray bash tests/hysteria.sh`
- `PATH=/tmp/kokoro-upstream/xray-26.11.9:$PATH bash .github/scripts/render-test.sh`
- `PATH=/tmp/kokoro-upstream/xray-26.11.9:$PATH bash .github/scripts/link-test.sh`

All returned `Configuration OK`. This verifies parser acceptance of the edge
Hysteria2 FinalMask, WireGuard FinalMask, exit configuration, TLS client export,
and Hysteria JSON export. It does **not** verify that unknown nested QUIC fields
have runtime effect, that traffic actually hops across UDP ports, or that a
client can establish a live Hysteria connection.

## Concurrent worktree state

This review did not modify any tracked implementation or configuration path.

The first five concurrent modifications observed were:

- `.github/scripts/download-verify-test.sh`
- `config.defaults.json`
- `lib/geodata.sh`
- `lib/render.jq`
- `secrets.defaults.json`

The worktree continued changing while the review ran. At the final snapshot it
also contained modifications to:

- `.github/scripts/link-test.sh`
- `.github/scripts/render-test.sh`
- `.github/scripts/vless-encryption-test.sh`
- `lib/caddy.sh`
- `lib/health.sh`
- `lib/link.sh`
- `lib/migrate.sh`
- `lib/preflight.sh`
- `tests/hysteria.sh`

Those changes are not authored by this review. The live worktree contains Xray
26.11.9, Caddy 2.11.9, Go 1.26.11, pinned Xray and Go hashes, the REALITY
X-Forwarded-For conditional, transactional replacement paths, and additional
tests. They still need their own review, commit, and deployment verification.

## Deployment checks still required

No VPS inventory was available, so the following remain unverified:

| Check | Required command or evidence |
| --- | --- |
| Installed kernel is fixed | `uname -r`, distro release, and the fixed-floor comparison above |
| Installed Xray is current | `xray version`, installed `/usr/local/bin/xray`, and package provenance |
| Caddy build is current and includes l4 | `caddy version` and `caddy list-modules \| grep layer4` |
| Go used for the build is current | Managed toolchain path/version, build log, and checksum verification |
| jq is acceptable | `jq --version` on each target OS |
| No unrelated nginx exposure | Process and package inventory, only if nginx is installed separately |
| Hysteria behavior | Real client handshake plus hop/obfuscation observation and server-side packet capture |
| Installer provenance | Installed commit, cloned remote, and signature/checksum verification record |
| Installer rollback | Failed clone leaves the existing install and symlink target intact |

## Verification boundary

Verified here:

- Upstream release/tag/commit identities and package floors listed above.
- Xray 26.11.9 archive digests against release metadata and a downloaded ZIP.
- Structural validation of rendered configs with the actual Xray 26.11.9 binary.
- Source-level behavior for MPTCP default, Salamander versus Gecko, and
  `udpHop` placement.

Not verified here:

- The actual VPS kernel, packages, installed Caddy/Go/Xray versions, firewall, or
  running service state.
- Live agreement between client and server or actual UDP port hopping.
- Exploitability of each Caddy advisory against the deployed Caddyfile.
- Whether a specific exploit has been observed against these deployments.
