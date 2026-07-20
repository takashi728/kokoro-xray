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
| `~/.kokoro-xray/secrets.json` | 600 | UUIDs and transport encryption keys |
| `~/.kokoro-xray/last-good/` | 700 | rollback snapshots |

## Apply pipeline

```
preflight.sh → render.jq + caddy.jq → validate.sh → firewall.sh → reload.sh
```

## Inbound modes

| Mode | REALITY | TLS/CDN | :443 owner |
|------|---------|---------|------------|
| `reality` | Xray `0.0.0.0:443` | — | Xray |
| `tls` | — | Caddy L7 | Caddy |
| `both` | Xray `127.0.0.1:8443` | Caddy L4 SNI split | Caddy (xcaddy + caddy-l4) |

Caddy overwrites `Kokoro-Trusted-XFF` on TLS proxy requests. Xray trusts
`X-Forwarded-For` only when that marker arrives over its loopback listener.

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

1. Install **exit** and copy its one-line relay bundle
2. Import that bundle on **edge** with `kokoro-xray pair`
3. Set the edge public IPv4 on **exit** with `kokoro-xray pair`
4. Apply the exit; UFW allows its relay port from that IPv4 only

The exit generates a dedicated UUID and the ML-KEM-768 authentication variant
from `xray vlessenc`. The edge holds the UUID and client encryption string.
The exit holds the UUID, client string, and server decryption string.

```
edge inbound
  -> VLESS_PQC_TO_EXIT (RAW, Vision/XUDP, ML-KEM-768 + X25519)
  -> VLESS_PQC_EXIT_IN
  -> exit routing
  -> Internet or Tor
```

The first connection performs the hybrid post-quantum handshake; tickets allow
subsequent 0-RTT connections. This branch intentionally avoids WireGuard and
additional VPN daemons.
