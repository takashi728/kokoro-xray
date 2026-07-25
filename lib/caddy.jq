# kokoro-xray Caddyfile renderer
# Usage: jq -r -f caddy.jq --slurpfile cfg config.json --slurpfile sec secrets.json

def cfg: $cfg[0];
def sec: $sec[0];

def sni: cfg.inbound.reality.server_names[0];
def cdn: cfg.inbound.tls.cdn_domain;
def path: sec.inbound.xhttp_path;
def needs_l4:
  cfg.caddy.use_l4 and
  cfg.inbound.mode == "both";
def email:
  if cfg.inbound.tls.acme_email != "" then cfg.inbound.tls.acme_email
  else "admin@\(cdn)"
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

"{
\(l4_block)    email \(email)
}
\(tls_site)
:80 {
    redir https://{host}{uri} permanent
}
"
