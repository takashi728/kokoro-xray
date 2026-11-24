# XHTTP and HY2 round robin

Install or update using the pinned installer in this branch's README. Updating
the program does not restart Xray or Caddy. On an already configured XHTTP TLS
edge with HY2 enabled, export a combined profile:

```bash
umask 077
sudo kokoro-xray link --json round-robin 192.0.2.42 cdn-h2 direct-h2=2001:db8::42 > round-robin.json
```

Replace the example addresses with reachable VPS IPs. The first argument
selects the standalone direct H2 route in streaming mode. The next two
arguments are the [split upload and download legs](xhttp-split.md#export-a-profile).
Use `cdn-h2=IP` to pin a measured Cloudflare address while preserving TLS SNI.
No new server listener or DNS record is needed for the balancer itself.
Import the result as a custom Xray JSON profile using Xray-core v26.11.9.

You can also combine three existing client exports without updating the VPS:

```bash
umask 077
bash tools/xhttp-round-robin.sh direct-xhttp.json split-xhttp.json hy2.json > round-robin.json
xray run -test -config round-robin.json
```

The direct profile supplies the local SOCKS/HTTP listeners, DNS, and policy.
Both XHTTP outbounds retain their own TLS and transport settings; HY2 keeps
its auth, obfuscation, and hopping settings. All rules that used the direct
XHTTP tunnel now use the balancer. The existing blocking rules still apply.

[Xray round robin](https://xtls.github.io/en/config/routing.html#strategyobject)
chooses one outbound per new routed connection. The split XHTTP outbound
counts as one choice; its two legs stay together. Round robin does not
combine the bandwidth of one download or move an existing connection.

[Observatory](https://xtls.github.io/en/config/observatory.html) probes each
path every 30 seconds, after the previous probe round finishes. A path with
no result yet is eligible. Once marked down, it is skipped for new
connections; if all paths are marked down, routing falls back to `BLOCK`.
The pinned [observer implementation](https://github.com/XTLS/Xray-core/blob/v26.11.9/app/observatory/observer.go#L128-L191)
checks HTTP reachability, not throughput or status code. A slow path can
still be eligible, and connections can fail before the next health check.

Use this for comparison, not peak throughput. A slow but reachable split
route still gets turns. All three profiles can share one VPS, so this is
not server redundancy. Keep the original profiles as fallbacks. The
combined JSON contains credentials from all three inputs; keep it owner-only.

Run `bash tests/xhttp-round-robin.sh` for the export regression test. To
also exercise rotation and failover in a local Xray process, run
`KOKORO_TEST_ROUND_ROBIN_RUNTIME=true bash tests/xhttp-round-robin.sh`.
