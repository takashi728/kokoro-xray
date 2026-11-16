# Xray-core upstream changes: v26.7.11 → v26.10.29

> **Superseded:** upstream withdrew `v26.10.29` during the
> CVE-2026-98432 response. Do not deploy it. The repository now pins
> `v26.11.9`; see `docs/upstream-security-research-2026-11-16.md`.

Scope: commits after v26.7.11 (exclusive) through v26.10.29 (inclusive) — 171 commits, 5 published releases (v26.7.28, v26.9.9, v26.9.30, v26.10.21, v26.10.29). Two releases (v26.10.10, v26.10.17) were withdrawn and no longer exist as git refs.
Method: GitHub compare API commit log (primary source), release bodies, and the cited PRs. Every claim below carries its PR or release citation.

## 1. Transport protocols & FinalMask

### FinalMask (new features and fixes)

- **Transport refactor onto FinalMask**: all transports were refactored to be built on FinalMask's dialer & listener (`DialTCP`, `Listen`, `DialUDP`, `ListenPacket`) with a mask `wrapclient` API; `HandleDial` masks no longer trust the upper-layer address. This is the architectural foundation everything else rides on. (PR #6754)
- **New inbound `filter` type (TCP & UDP source-IP filtering)**: `allowedSourceIPs`/`blockedSourceIPs` with geodata support (e.g. `geoip:cn`); both lists present → intersection passes. Native Go so it can also serve Hy2 and XHTTP/3. Motivation per the PR: blocking REALITY-neighbor traffic. (PR #7206)
- **XMC mask: default directional padding/keep-alive packets** matching Minecraft 26.1.2 login/join traffic shapes. (PR #6487)
- **`udpHop` promoted from a Noise knob to a standalone UDP mask** (WG hop / IP-pool hop); a follow-up fixed panics when udpHop or xicmp fail and restored udpHop's default interval. (PR #6327, PR #6808)
- **XDNS finalmask**: refactored with new parameters; config field renames (`types`; `name→names`; `type+addr→addrs`); fixed resolver close deadlock and socket leaks. (PR #6718, #7089, #7090)
- **XDNS finalmask: DoH support** — `https://` resolvers with `tlsConfig`, domain fronting, `quicConfig`, Chrome Client Hello by default, empty HTTP User-Agent. (PR #7140)
- **Noise finalmask**: `type` accepts `"exp"` (expression); Lua scripts now accepted. (PR #6862, #7124)
- **Deprecation signal**: Direct/Freedom outbounds now warn about migrating `fragment` and `noises` to FinalMask. (PR #7242)

### Major new protocols

- **MASQUE (IETF CONNECT-IP, RFC 9484) outbound and inbound** — the big protocol addition of this range:
  - Outbound: HTTP/3 proxy IP tunnel (Extended CONNECT, ADDRESS_REQUEST/ASSIGN, IP packets in HTTP Datagram per RFC 9297); splits into `"protocol": "masque"` + `"method": "masque"` transport like Hysteria. Client gained HTTP/2 Extended CONNECT (RFC 8441), WARP support, XMUX (default maxConnections 1, Chrome User-Agent). (PR #6807, #6810, #6878, #7121)
  - Inbound: CONNECT-IP server, h3 by default with h2 on the same port via ALPN, basic-auth users addable/removable via API (removal closes tunnels), per-family address pools from `address` (503 when exhausted), netstack like the WireGuard inbound so routing sniffing and per-user stats work. (PR #6844)
- **XDRIVE transport** — universal remote-storage/any-service-based proxy that ignores IP whitelists; backends: Google Drive (session carried in a ring of slots) and a two-step "template" backend; requires VLESS Multiplex+Encryption; h3 and h2 with Chrome Client Hello, h3+XMUX, stalled-request termination, and a new "s3" storage backend. (PR #5645, #6748, #7181–#7188, #7217, #7231)
- **Lua scripting for DNS and routing** (new subsystem; inline scripts, sandboxed by default with a whitelisted function set, inline scripts temporarily disabled for security, `./xray base64` encode/decode helper). (PR #6823, #7132, #7136)

### Per-transport protocol updates

- **XHTTP**: client default `maxConnections` 6→3 (anti-TSPU); race/data-race fixes; `Request.GetBody()` so h2 replays after GOAWAY; servers now get the accurate localAddr (also gRPC servers). (commits #6526 + client fixes, incl. #6632, #6665, #6694)
- **WebSocket**: normal close frames now treated as `io.EOF`; client no longer panics before real dialing. (PR #7236, #6544)
- **HTTPUpgrade transport**: sends some `Sec-WebSocket-*` headers. (PR #6835)
- **Hysteria**: upgraded to official v2.12.2; server Unix masquerade socket-path fix; client DATAGRAM truncation fix with ChromeParrot; conn lifecycle and cancellation fixes. (PR #6565, #6705, #6788, #7107/#7119/#7122/#7172)
- **Shadowsocks 2022 proxy**: refactored off sing-box dependencies, interrupt/UDP-conn corrections, early-return connection close. (PR #6831, #6866, #7143, #6698)
- **WireGuard**: outbound sendThrough fix, remoteDNS honors TTL (then the "local" mode + domainStrategy removed), endpoint IP fix, built-in lightweight TCP/IP stack replaces gVisor; inbound fake-pong ICMP reply, idle-UDP memory reduction, kernelTun IPv6 table index fix, startup-race and in-flight-write-panic fixes. (PR #6570, #6620, #6771, #6804, #7151, #7156, #6855, #6856, #6881, #6778, #6852, #6801)
- **Mux client**: race fix between Dispatch and SessionManager.Close; UDP frame overwrite fix. (PR #6871, #6822)
- **Direct/Freedom outbound**: compatibility work; sockopt.dialerProxy skips domain resolution + finalRules; blockDelay fix for DispatchLink inbounds (VLESS, Hysteria, ...). (PR #6058, #6742, #7238)
- **Sniffing**: QUICv2 support; `SniffUTP()` fix; QUIC sniffer handles zero-filled datagram tails. (PR #6695, #6667, #6882)
- **TUN inbound** (adjacent, for completeness): default name now `utunN` (10–1024); Windows `desc` (Wintun default); autoSystemRoutingTable on FreeBSD; Wintun reuse; autoSystemWfpBlockLeak; autoSystemDnsToGateway; lightweight TCP/IP stack. (PR #6485, #6486, #6576, #6579, #6733, #6740, #6743, #6799, #6935, #6936, #6937, #6941)
- **Routing**: `localOS`; iOS excluded from Darwin for `process`; Linux UDP/IPv6 process fix; process exclusion. (PR #6555, #6524, #6574, #6616)
- **Geodata**: prefilter regexp; memory reduction; private-IP-range updates; bounded download size/extension/frequency. (PR #6569, #6573, #6613, #7267)

## 2. Security improvements (CA-focused)

### CA changes — the core of this range

- **TLS client now uses Xray-core's built-in RootCAs by default** — previously it used the OS trust store, so a maliciously injected OS CA could MITM the client. Go's bundled RootCAs are now the default. (PR #7105, merged 2026-10-10)
- **Urgent security release v26.10.21**: after the private keys of Indian sub-CA intermediate certificates were broken (keys too simple, see the discussion on PR #7212), the bundled RootCAs dependency **removed three root certificates** and the build was recompiled with **Go 1.27.3** so the problem certs are filtered even if the OS CA store has not updated. The two releases that shipped the bad certs — **v26.10.10 and v26.10.17 — were withdrawn** (gone from git refs and the releases page). (release v26.10.21 note, 2026-10-29; PR #7212, merged 2026-10-21)
- **Reality library updates**: `github.com/xtls/reality` bumped twice in-range (20260908062103 → shipped in v26.9.9; 20261014101318 → shipped before v26.10.17) carrying the X25519/UTLS-side hardening; REALITY server config-parsing warnings refined. (commits "Update github.com/xtls/reality …", PR #6508)
- **XTLS Vision compatibility with Go 1.27.3+** — Vision's outer CloseNotify is suppressed after switching to direct copy, and the code was fixed to stay compatible with the Go 1.27.3 toolchain the CA build now requires. (PR #6834, #7176)
- **TLS ECH / DoH h2c**: `verifyPeerCertByName` gained a `"fromMitm"` mode usable after dialerProxy in RAW outbound's tlsSettings. (PR #6246)

### Other security/robustness

- **Lua sandboxing**: default whitelist of allowed functions, inline scripts disabled pending review, extra checks. (PR #7136)
- **File loader**: file-extension check no longer follows symlinks. (PR #7255)
- **Geodata downloads**: size, extension, and update-frequency limits. (PR #7267)
- **Docker**: log and config file permissions restricted. (PR #7204)
- **Router data race** fixed in API handling. (PR #6678)
- **Config**: inbound module initialization moved to the end (ordering fix). (PR #7284)
- **CI**: stricter checks on generated protobuf files. (PR #7263)

## 3. Operator impact for this repo (kokoro-xray)

- **Version bump**: the historical `v26.10.29` target was withdrawn. The
  repository now pins `v26.11.9` with per-architecture SHA-256 verification. The
  CA story alone (built-in RootCAs + the broken sub-CA removal) made this the
  security-critical upgrade of the half-year.
- **VLESS + Reality/XHTTP inbound templates**: no breaking config changes found in-range. Server-side localAddr accuracy (PR #6526) and refined REALITY parsing warnings (PR #6508) are behavioral improvements only; `inbound-reality.json` / `inbound-tls.json` shapes remain valid.
- **XTLS Vision flow (`xtls-rprx-vision`)**: shipped release binaries are precompiled, so Go 1.27.3+ compatibility (PR #7176) is already baked in — no template action; it only matters if the repo ever compiles Xray from source.
- **WG-PSK inbound**: the WireGuard-inbound fixes (fake-pong ICMP, idle-UDP memory, kernelTun IPv6, startup races, PR #6855/#6856/#6881/#6852) directly harden the exit WG inbound; no config changes.
- **vless-encryption feature**: PR #6741 fixes `validateOutboundTransportSecurity()` for outbound VLESS with re-parsed accounts — affects outbound VLESS config validation, worth a smoke test after the bump.
- **CA changes are client-side**: they change TLS *client* trust behavior. This toolkit's inbound surfaces (Reality/XHTTP/TLS) are unaffected; only client-bound features (e.g. an XDNS finalmask DoH resolver) would consume the new built-in RootCAs.
- **FinalMask**: the repo retired `.multinode.finalmask` (lib/migrate.sh). Upstream it grew substantially (inbound `filter`, XMC padding, udpHop as a mask, XDNS DoH). Reintroduction would be a fresh design decision, not an import — nothing in the current config schema breaks.
- **No field renames or deprecations** in VLESS/Reality/XHTTP/WG inbound configs within the range; the only rename found (XDNS finalmask `name→names` etc., PR #7090) is inside the retired FinalMask surface.

### Sources
- Compare log: `gh api repos/XTLS/Xray-core/compare/v26.7.11...v26.10.29` (171 commits)
- Urgent CA release note: https://github.com/XTLS/Xray-core/releases/tag/v26.10.21
- Verified PRs: #7105, #7212, #6754, #7206, #6327, #6807, #6844, #6741, #7176, #6834, #7140
