# kokoro-xray Caddyfile renderer
# Usage: jq -r -f caddy.jq --slurpfile cfg config.json --slurpfile sec secrets.json

def cfg: $cfg[0];
def sec: $sec[0];

def sni: cfg.inbound.reality.server_names[0] | ascii_downcase;
def tls_enabled: cfg.inbound.mode == "tls" or cfg.inbound.mode == "both";
def raw_tls: (cfg.inbound.transport // "xhttp") == "raw" and tls_enabled;
def cdn: (if raw_tls then cfg.inbound.tls.domain else cfg.inbound.tls.cdn_domain end) // "" | ascii_downcase;
def path: sec.inbound.xhttp_path;
def hy_enabled: cfg.inbound.hysteria.enabled;
def hy_domain: cfg.inbound.hysteria.domain // "" | ascii_downcase;
def hy_masquerade: cfg.inbound.hysteria.masquerade | ascii_downcase | split(".") | map(@uri) | join(".");
def same_domain: tls_enabled and hy_enabled and cdn == hy_domain;
def needs_l4:
  cfg.caddy.use_l4 and
  (raw_tls or cfg.inbound.mode == "both" or (cfg.inbound.mode == "reality" and hy_enabled));
def email:
  if (cfg.inbound.tls.acme_email // "") != "" then cfg.inbound.tls.acme_email
  elif (cfg.inbound.hysteria.acme_email // "") != "" then cfg.inbound.hysteria.acme_email
  else "admin@\(if cdn != "" then cdn elif hy_domain != "" then hy_domain else sni end)"
  end;

def domain: type == "string" and (ascii_downcase | test("\\A([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,63}\\z"));
def absent: . == null or . == "";
def validate_inputs:
  cfg.inbound as $in |
  if (($in.reality.server_names // []) | type != "array" or any(.[]; domain | not)) or
     (($in.mode == "both" or $in.mode == "reality") and (($in.reality.server_names | length) == 0))
  then error("invalid REALITY server_names")
  elif any($in.tls.cdn_domain, $in.tls.domain; (absent or domain) | not) or
       (tls_enabled and (cdn | domain | not)) then error("invalid TLS domain")
  elif ($in.hysteria.domain | (absent or domain) | not) or
       (hy_enabled and ([$in.hysteria.domain, $in.hysteria.masquerade] | any(.[]; domain | not)))
  then error("invalid Hysteria2 domain")
  elif (path | absent) and ($in.transport // "xhttp") == "raw" then .
  elif (path | type != "string" or (test("\\A/[A-Za-z0-9_-]{1,128}\\z") | not))
  then error("invalid XHTTP path")
  else . end |
  if any($in.tls.acme_email, $in.hysteria.acme_email;
     (absent or (type == "string" and test("\\A[A-Za-z0-9_+%-]+(\\.[A-Za-z0-9_+%-]+)*@[^@]+\\z")
      and (split("@")[1] | domain))) | not)
  then error("invalid ACME email") else . end;

def l4_block: if needs_l4 then
  "
    servers :443 {
        protocols h1 h2
        listener_wrappers {
            layer4 {
\(if cfg.inbound.mode == "reality" or cfg.inbound.mode == "both" then "                @reality tls sni \(sni)
                route @reality {
                    proxy tcp/127.0.0.1:8443
                }
" else "" end)\(if raw_tls then "                @rawtls tls sni \(cdn)
                route @rawtls {
                    proxy tcp/127.0.0.1:8444
                }
" else "" end)
            }
            tls
        }
    }
"
else "" end;

def no_h3_block: if hy_enabled and (needs_l4 | not) then
"    servers :443 {
        protocols h1 h2
    }
"
else "" end;

def tls_site: if tls_enabled and (same_domain | not) and (raw_tls | not) then
"\(cdn) {
    handle \(path)* {
        reverse_proxy 127.0.0.1:8444 {
            header_up Kokoro-Trusted-XFF 1
            transport http {
                versions h2c
            }
        }
    }
    handle {
        respond \"ok\" 200
    }
}
"
else "" end;

def same_domain_site: if same_domain and (raw_tls | not) then
"\(cdn) {
    handle \(path)* {
        reverse_proxy 127.0.0.1:8444 {
            header_up Kokoro-Trusted-XFF 1
            transport http {
                versions h2c
            }
        }
    }
    handle {
        reverse_proxy https://\(hy_masquerade) {
            header_up Host \(hy_masquerade)
        }
    }
}
"
else "" end;

def hysteria_site: if hy_enabled and (same_domain | not) then
"\(hy_domain) {
    reverse_proxy https://\(hy_masquerade) {
        header_up Host \(hy_masquerade)
    }
}
"
else "" end;

def hysteria_global: if hy_enabled then
"    storage file_system /var/lib/kokoro-caddy
    acme_ca https://acme-v02.api.letsencrypt.org/directory
"
else "" end;

def raw_tls_global: if raw_tls then
"    storage file_system /var/lib/kokoro-caddy
    acme_ca https://acme-v02.api.letsencrypt.org/directory
    servers 127.0.0.1:8080 {
        protocols h1 h2c
    }
"
else "" end;

def raw_tls_sites: if raw_tls then
"\(cdn) {
    tls {
        issuer acme {
            disable_tlsalpn_challenge
        }
    }
    reverse_proxy 127.0.0.1:8081
}
http://:8080 {
    bind 127.0.0.1
    reverse_proxy 127.0.0.1:8081
}
"
else "" end;

validate_inputs | "{
\(l4_block)\(no_h3_block)    email \(email)
\(if raw_tls then raw_tls_global else hysteria_global end)
}
\(tls_site)\(same_domain_site)\(raw_tls_sites)\(hysteria_site)
:80 {
    redir https://{host}{uri} permanent
}
"
