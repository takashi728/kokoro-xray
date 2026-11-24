# XHTTP split upload and download

Experimental. Use Xray-core v26.11.9 on both ends. Import the full custom
Xray JSON in v2rayN; ordinary share links do not carry download settings.

Split chooses one route for upload payload and another for download payload.
Both still need two-way connectivity. If either leg fails, the session fails.
This is a route experiment, not a guarantee against blocking.

## Set up the edge

Install from a clean checkout of this branch on a test VPS:

```bash
sudo bash install.sh --local --commit "$(git rev-parse HEAD)"
```

On a fresh edge, run `sudo kokoro-xray edge` and choose **xhttp**. Use
**tls** for CDN only, **reality** for direct only, or **both** for mixed
profiles. For an existing XHTTP edge in the right mode, skip the wizard.

For a CDN leg, issue the origin certificate with the TLS domain DNS-only
first. Then enable Cloudflare proxying and **Full (strict)**. Keep HTTP/2
to Origin on. For `cdn-h3`, enable Cloudflare HTTP/3 too. H3 ends at the
Cloudflare edge. Do not open UDP 443 at the origin for this; existing HY2
can keep its UDP port. Keep a separate H2 profile for clients whose UDP path
doesn't work. [Cloudflare HTTP/3](https://developers.cloudflare.com/speed/optimization/protocol/http3/)

### Add a separate Cloudflare name with `cf`

Keep Cloudflare credentials on the operator machine. Use a new subdomain
in an active zone that already uses Full (strict):

```bash
bash tools/cf-xhttp-dns.sh prepare example.net split.example.net 192.0.2.42
```

On the VPS, add the name without replacing the existing TLS or HY2 name:

```bash
sudo kokoro-xray xhttp-split domain split.example.net
sudo kokoro-xray apply
```

When Caddy serves a valid origin certificate, run on the operator machine:

```bash
bash tools/cf-xhttp-dns.sh proxy example.net split.example.net 192.0.2.42
```

The helper manages one A or AAAA record, verifies origin HTTPS before
proxying, and refuses to overwrite unrelated records. It does not change
zone settings or touch HY2 DNS. To remove the VPS alias, set
`xhttp-split domain ""` and apply; manage the DNS record separately.

### Mix REALITY and TLS

For mixed REALITY and CDN legs only, enable the shared XHTTP backend:

```bash
sudo kokoro-xray xhttp-split on
sudo kokoro-xray apply
```

This requires **both** mode with Caddy L4. The REALITY server name must
differ from the TLS domain and any HY2 domain. The REALITY target stays
in place. Both entrances
now reach the same loopback XHTTP listener, so no new public ports are
needed. The backend ignores forwarded client IPs in this mode. TLS XHTTP
JSON stays compatible; **re-export existing REALITY JSON** after switching
because it now uses the shared padding settings. REALITY share URLs are
unavailable while split mode is on.

To revert, run `sudo kokoro-xray xhttp-split off` and
`sudo kokoro-xray apply`, then re-export the old-style REALITY JSON.
Turn split off before changing this edge to RAW or a single inbound mode.
Keep a known-good unsplit CDN profile while testing.

## Export a profile

```bash
umask 077
sudo kokoro-xray link --json xhttp-split cdn-h2 reality=2001:db8::42 > split.json
```

Upload comes first. Omit the second leg for an unsplit baseline. Replace
documentation IPs below with measured, reachable addresses. Do not paste
the generated file into chat or commit it; it contains credentials.

- `cdn-h2` or `cdn-h3` dials the split hostname if configured, otherwise the
  existing TLS hostname. Optional
  `=IP` pins the edge IP while retaining the configured TLS SNI and HTTP
  Host. Start with the hostname before trying a measured edge IP.
- `direct-h2=IP` dials the origin directly over TLS using the original TLS
  hostname for SNI and Host. Pair it with a CDN leg without enabling the
  REALITY bridge, for example `cdn-h3 direct-h2=2001:db8::42`.
- `reality=IP` dials the origin directly. Use an IPv4 literal or an
  unbracketed IPv6 literal. A VPS having an IPv6 address is not proof it is
  reachable from the client. Verify from the client network.
- TLS uploads use the pinned Xray's `packet-up`; split REALITY uploads
  use `stream-up`. Download uses a separate GET. No new XMUX tuning.

| Route case | Arguments after `--json xhttp-split` |
| --- | --- |
| 1. Direct v4 and v6 both poor | `cdn-h2` baseline, compare `cdn-h3`, then `cdn-h2 cdn-h3` and `cdn-h3 cdn-h2` if one directional result differs. |
| 2. Weak v4, premium v6 both ways | `reality=2001:db8::42` first. Keep `cdn-h2` or `cdn-h3` as a separate alternative for v4-only clients or degraded v6. |
| 3. Usable v4 upload, premium v6 download | Compare `reality=192.0.2.42 reality=2001:db8::42` with `cdn-h2 reality=2001:db8::42` and `cdn-h3 reality=2001:db8::42`. |
| 4. Premium v6 upload, usable v4 download | Compare `reality=2001:db8::42 reality=192.0.2.42` with `reality=2001:db8::42 cdn-h2` and `reality=2001:db8::42 cdn-h3`. |

## Pick by measurement

Test from the actual subscriber network at peak and off-peak hours. Use
the same large file or controlled upload/download endpoint for each profile.
Compare failures, time to first byte, upload and download goodput, and
stalls. Keep the best unsplit route when splitting does not improve it.
Client-to-CDN ping does not measure CDN-to-origin routing or goodput.

Run `XRAY_BIN=/path/to/xray bash tests/xhttp-split.sh` to check the rendered
profiles. With Caddy L4, Node.js, and curl with HTTP/2 and HTTP/3, run
`CADDY_BIN=/path/to/caddy bash tests/xhttp-split-integration.sh` for a
loopback payload test with an emulated CDN. That is not a mainland test.

See the [upstream research and measurement plan](xhttp-split-research.md)
for sources and details.

For an optional client-side profile that rotates HY2, direct XHTTP, and
split XHTTP, see the [round-robin experiment](xhttp-round-robin.md).
