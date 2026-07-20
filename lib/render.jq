# kokoro-xray declarative xray config renderer
# Usage: jq -f render.jq --slurpfile cfg config.json --slurpfile sec secrets.json

def cfg: $cfg[0];
def sec: $sec[0];
def mode: cfg.inbound.mode;
def role: cfg.role;
def vless_decryption:
  if cfg.inbound.vless_encryption.enabled
  then sec.inbound.vless_encryption.decryption
  else "none"
  end;

def log_block: { log: { loglevel: "warning" } };

def policy_block: {
  policy: { levels: { "0": { handshake: 2, connIdle: 120 } } }
};

def reality_listen: if mode == "reality" then "0.0.0.0" else "127.0.0.1" end;
def reality_port: if mode == "reality" then 443 else 8443 end;
def xhttp_sockopt: { trustedXForwardedFor: ["Kokoro-Trusted-XFF"] };
def xhttp_base_settings: { path: sec.inbound.xhttp_path };
def xhttp_tls_settings: xhttp_base_settings + {
  mode: "auto",
  xmux: {
    maxConnections: "6",
    hMaxRequestTimes: "600-900",
    hMaxReusableSecs: "1800-3000"
  },
  xPaddingKey: "v",
  xPaddingBytes: "16-96",
  xPaddingHeader: "Referer",
  xPaddingMethod: "tokenish",
  uplinkHTTPMethod: "POST",
  xPaddingObfsMode: true,
  xPaddingPlacement: "queryInHeader",
  scMaxEachPostBytes: 2000000,
  uplinkDataPlacement: "body",
  scMinPostsIntervalMs: 10
};

def reality_inbound: {
  tag: "REALITY_XHTTP_IN",
  listen: reality_listen,
  port: reality_port,
  protocol: "vless",
  settings: {
    clients: [{ id: sec.inbound.uuid, flow: "" }],
    decryption: vless_decryption
  },
  streamSettings: {
    network: "xhttp",
    security: "reality",
    realitySettings: {
      show: false,
      dest: cfg.inbound.reality.dest,
      xver: 0,
      serverNames: cfg.inbound.reality.server_names,
      privateKey: sec.inbound.reality.private_key,
      shortIds: sec.inbound.reality.short_ids
    },
    xhttpSettings: xhttp_base_settings,
    sockopt: xhttp_sockopt
  },
  sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
};

def tls_inbound: {
  tag: "TLS_XHTTP_IN",
  listen: "127.0.0.1",
  port: 8444,
  protocol: "vless",
  settings: {
    clients: [{ id: sec.inbound.uuid, flow: "" }],
    decryption: vless_decryption
  },
  streamSettings: {
    network: "xhttp",
    security: "none",
    xhttpSettings: xhttp_tls_settings,
    sockopt: xhttp_sockopt
  },
  sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
};

def base_outbounds: [
  { tag: "DIRECT", protocol: "freedom" },
  { tag: "BLOCK", protocol: "blackhole" }
];

def exit_tor_outbound: if cfg.tor.enabled then
  [{ tag: "TOR", protocol: "socks", settings: { servers: [{ address: "127.0.0.1", port: cfg.tor.socks_port }] } }]
else [] end;

def exit_relay_outbound: if cfg.multinode.enabled then
  [{
    tag: "VLESS_PQC_TO_EXIT",
    protocol: "vless",
    settings: {
      vnext: [{
        address: cfg.multinode.exit_ip,
        port: cfg.multinode.exit_port,
        users: [{
          id: sec.multinode.exit_vless_uuid,
          flow: "xtls-rprx-vision-udp443",
          encryption: sec.multinode.exit_vless_encryption
        }]
      }]
    },
    streamSettings: {
      network: "raw",
      security: "none"
    }
  }]
else [] end;

# Single-node: allow Google (incl. .cn) before CN/RU blocks
def google_direct_rules: [
  {
    type: "field",
    domain: [
      "geosite:google",
      "geosite:youtube",
      "domain:gmail.com",
      "domain:gemini.google.com",
      "domain:gemini.google",
      "domain:googleapis.cn",
      "domain:googleapis-cn.com",
      "domain:gstatic.cn",
      "domain:gstatic-cn.com"
    ],
    outboundTag: "DIRECT"
  }
];

def single_node_block_rules: [
  { type: "field", ip: ["geoip:private"], outboundTag: "BLOCK" },
  { type: "field", domain: ["geosite:private"], outboundTag: "BLOCK" },
  { type: "field", protocol: ["bittorrent"], outboundTag: "BLOCK" },
  {
    type: "field",
    domain: [
      "geosite:cn",
      "geosite:geolocation-cn",
      "regexp:.*\\.ru$",
      "regexp:.*\\.su$",
      "regexp:.*\\.xn--p1ai$"
    ],
    outboundTag: "BLOCK"
  },
  { type: "field", ip: ["geoip:cn"], outboundTag: "BLOCK" },
  { type: "field", ip: ["geoip:ru"], outboundTag: "BLOCK" }
];

def exit_tor_rules: if cfg.tor.enabled then
  [{ type: "field", domain: ["regexp:\\.onion$"], outboundTag: "TOR" }]
else [] end;

def edge_single_routing: {
  domainStrategy: "IPIfNonMatch",
  rules: (google_direct_rules + single_node_block_rules + [
    { type: "field", network: "tcp,udp", outboundTag: "DIRECT" }
  ])
};

def edge_multinode_routing: {
  domainStrategy: "IPIfNonMatch",
  rules: [
    { type: "field", network: "tcp,udp", outboundTag: "VLESS_PQC_TO_EXIT" }
  ]
};

def edge_routing: if cfg.multinode.enabled then edge_multinode_routing else edge_single_routing end;

def edge_inbounds:
  (if mode == "reality" or mode == "both" then [reality_inbound] else [] end)
  + (if mode == "tls" or mode == "both" then [tls_inbound] else [] end);

def edge_config: log_block + {
  inbounds: edge_inbounds,
  outbounds: (base_outbounds + exit_relay_outbound),
  routing: edge_routing,
  policy: policy_block.policy
};

def exit_inbound: {
  tag: "VLESS_PQC_EXIT_IN",
  listen: "0.0.0.0",
  port: cfg.multinode.exit_port,
  protocol: "vless",
  settings: {
    users: [{
      id: sec.multinode.exit_vless_uuid,
      flow: "xtls-rprx-vision"
    }],
    decryption: sec.multinode.exit_vless_decryption
  },
  streamSettings: {
    network: "raw",
    security: "none"
  },
  sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
};

def exit_config: log_block + {
  inbounds: [exit_inbound],
  outbounds: (base_outbounds + exit_tor_outbound),
  routing: {
    domainStrategy: "IPIfNonMatch",
    rules: (exit_tor_rules + [
      { type: "field", ip: ["geoip:private"], outboundTag: "BLOCK" },
      { type: "field", protocol: ["bittorrent"], outboundTag: "BLOCK" },
      { type: "field", network: "tcp,udp", outboundTag: "DIRECT" }
    ])
  },
  policy: policy_block.policy
};

if role == "edge" then edge_config
elif role == "exit" then exit_config
else error("unknown role: \(role)")
end
