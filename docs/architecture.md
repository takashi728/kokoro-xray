# kokoro-xray Architecture

## Design rules

1. **Shell dispatches, jq renders** — no `sed` on JSON, no imperative config patches in bash
2. **Every mutation ends in `apply`** — render → validate → reload (rollback on failure)
3. **Secrets live in `secrets.json` only** — `config.json` holds intent/settings
4. **Routing rule order is defined once** — in `lib/render.jq`

## State files

| File | Mode | Contents |
|------|------|----------|
| `~/.kokoro-xray/config.json` | 644 | role, mode, domains, routing preset |
| `~/.kokoro-xray/secrets.json` | 600 | uuid, keys, wg private keys |
| `~/.kokoro-xray/last-good/` | 700 | rollback snapshots |

## Apply pipeline

```
preflight.sh → render.jq + caddy.jq → validate.sh → firewall.sh → reload.sh
```

Service executables and configuration locations are fixed canonical system
paths. Preflight rejects unsafe or non-canonical values before either Xray or
Caddy can execute them. Hysteria2 certificate and key paths must resolve to
root-owned, non-writable regular files beneath the Caddy certificate root.
Generated systemd units are syntax-safe and verified before installation.

## Inbound modes

| Mode | REALITY | TLS/CDN | :443 owner |
|------|---------|---------|------------|
| `reality` | Xray `0.0.0.0:443` | — | Xray |
| `tls` | — | Caddy L7 | Caddy |
| `both` | Xray `127.0.0.1:8443` | Caddy L4 SNI split | Caddy (xcaddy + caddy-l4) |

`.inbound.transport` selects `xhttp` (migration default) or `raw` (interactive
CN performance preset). RAW REALITY shares the existing target selection and
public/loopback listener layout. RAW TLS always uses Caddy L4 SNI passthrough
to loopback Xray TLS on 8444; certificate automation remains in Caddy, while
Xray owns the TLS session required by Vision. Server users use
`xtls-rprx-vision`; client users use `xtls-rprx-vision-udp443`.

RAW TLS fallback sends decrypted HTTP/1.1 or HTTP/2 to Caddy's loopback h1/h2c
listener on 8080, then to the PrivateBin Podman service on loopback 8081.
REALITY fallback continues to use the verified remote target, never PrivateBin.
PrivateBin is a pinned, non-root, read-only container with bounded tmpfs data.
Separate TLS and HY2 certificate watchers restart Xray when their files change.

Caddy overwrites `Kokoro-Trusted-XFF` on TLS proxy requests. Xray trusts
`X-Forwarded-For` only when that marker arrives over its loopback listener.

Hysteria2 is an optional parallel UDP inbound, not another XHTTP mode. Xray
listens on its configured UDP port list. Caddy manages the public certificate,
serves the same domain over TCP, and disables its own HTTP/3 listener to avoid
contending for UDP `443`. REALITY-only mode moves behind Caddy L4 when
Hysteria2 is enabled so both domains can keep TCP `443`. The Hysteria2 direct
domain may also be the TLS XHTTP CDN domain; Caddy then sends the XHTTP path to
loopback Xray TLS and all other requests to the masquerade. A systemd path unit
restarts Xray after Caddy renews the certificate because Xray loads that
certificate only at startup.

## VLESS Encryption

Fresh edge installs generate one official X25519-authenticated VLESS Encryption
pair. Both REALITY and TLS inbounds use the same server decryption string, and
client exports use its matching encryption string. Existing `0.2.0` nodes
migrate with this layer disabled to avoid breaking deployed clients.

## REALITY scan

`kokoro-xray reality scan` probes `data/reality-seeds.txt` plus optional `--domains` / `--file`.
Each host is validated (not bulk-imported): TLS 1.3, ALPN h2, cert SAN, redirect rules.
Rejects Apple/iCloud/Microsoft names and `.cn`/`.ru`/`.ir` TLDs per Xray-core.
Scores by latency + OCSP bonus.

## Multi-node pairing

1. Install **exit** → copy `exit_wg_pubkey`
2. Install **edge** with exit IP + pubkey, or run `kokoro-xray pair`
3. Paste `edge_wg_pubkey` back on exit → `kokoro-xray apply`
