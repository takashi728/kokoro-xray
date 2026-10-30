# kokoro-xray Caddyfile renderer
# Usage: jq -r -f caddy.jq --slurpfile cfg config.json --slurpfile sec secrets.json

def cfg: $cfg[0];
def sec: $sec[0];

def sni: cfg.inbound.reality.server_names[0];
def cdn: cfg.inbound.tls.cdn_domain;
def path: sec.inbound.xhttp_path;
def hy_enabled: cfg.inbound.hysteria.enabled;
def hy_domain: cfg.inbound.hysteria.domain;
def hy_masquerade: cfg.inbound.hysteria.masquerade;
def needs_l4:
  cfg.caddy.use_l4 and
  (cfg.inbound.mode == "both" or (cfg.inbound.mode == "reality" and hy_enabled));
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
                @reality tls sni \(sni)
                route @reality {
                    proxy tcp/127.0.0.1:8443
                }
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

def tls_site: if cfg.inbound.mode == "tls" or cfg.inbound.mode == "both" then
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

def hysteria_site: if hy_enabled then
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

"{
\(l4_block)\(no_h3_block)    email \(email)
\(hysteria_global)
}
\(tls_site)\(hysteria_site)
:80 {
    redir https://{host}{uri} permanent
}
"
