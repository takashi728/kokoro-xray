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

## Inbound modes

| Mode | REALITY | TLS/CDN | :443 owner |
|------|---------|---------|------------|
| `reality` | Xray `0.0.0.0:443` | — | Xray |
| `tls` | — | Caddy L7 | Caddy |
| `both` | Xray `127.0.0.1:8443` | Caddy L4 SNI split | Caddy (xcaddy + caddy-l4) |

Caddy overwrites `Kokoro-Trusted-XFF` on TLS proxy requests. Xray trusts
`X-Forwarded-For` only when that marker arrives over its loopback listener.

## REALITY scan

`kokoro-xray reality scan` probes `data/reality-seeds.txt` plus optional `--domains` / `--file`.
Each host is validated (not bulk-imported): TLS 1.3, ALPN h2, cert SAN, redirect rules.
Rejects Apple/iCloud/Microsoft names and `.cn`/`.ru`/`.ir` TLDs per Xray-core.
Scores by latency + OCSP bonus.

## Multi-node pairing

1. Install **exit** → copy `exit_wg_pubkey`
2. Install **edge** with exit IP + pubkey, or run `kokoro-xray pair`
3. Paste `edge_wg_pubkey` back on exit → `kokoro-xray apply`
