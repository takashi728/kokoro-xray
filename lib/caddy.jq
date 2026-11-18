# kokoro-xray Caddyfile renderer
# Usage: jq -r -f caddy.jq --slurpfile cfg config.json --slurpfile sec secrets.json

def cfg: $cfg[0];
def sec: $sec[0];

def sni: cfg.inbound.reality.server_names[0];
def tls_enabled: cfg.inbound.mode == "tls" or cfg.inbound.mode == "both";
def raw_tls: (cfg.inbound.transport // "xhttp") == "raw" and tls_enabled;
def cdn: (if raw_tls then cfg.inbound.tls.domain else cfg.inbound.tls.cdn_domain end) | ascii_downcase;
def path: sec.inbound.xhttp_path;
def hy_enabled: cfg.inbound.hysteria.enabled;
def hy_domain: cfg.inbound.hysteria.domain | ascii_downcase;
def hy_masquerade: cfg.inbound.hysteria.masquerade | ascii_downcase | split(".") | map(@uri) | join(".");
def same_domain: tls_enabled and hy_enabled and cdn == hy_domain;
def needs_l4:
  cfg.caddy.use_l4 and
  (raw_tls or cfg.inbound.mode == "both" or (cfg.inbound.mode == "reality" and hy_enabled));
def email:
  if cfg.inbound.tls.acme_email != "" then cfg.inbound.tls.acme_email
  elif cfg.inbound.hysteria.acme_email != "" then cfg.inbound.hysteria.acme_email
  else "admin@\(if cdn != "" then cdn else hy_domain end)"
  end;

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

"{
\(l4_block)\(no_h3_block)    email \(email)
\(if raw_tls then raw_tls_global else hysteria_global end)
}
\(tls_site)\(same_domain_site)\(raw_tls_sites)\(hysteria_site)
:80 {
    redir https://{host}{uri} permanent
}
"
