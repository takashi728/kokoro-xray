# XHTTP and HY2 round robin

Combine three local Kokoro client exports. No VPS or DNS changes are needed.
Use Xray-core v26.11.9 and import the result as a custom Xray JSON profile.

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
