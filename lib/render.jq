# kokoro-xray declarative xray config renderer
# Usage: jq -f render.jq --slurpfile cfg config.json --slurpfile sec secrets.json

def cfg: $cfg[0];
def sec: $sec[0];
def mode: cfg.inbound.mode;
def transport: cfg.inbound.transport // "xhttp";
def raw: transport == "raw";
def flow: if raw then "xtls-rprx-vision" else "" end;
def role: cfg.role;
def hysteria_enabled: cfg.inbound.hysteria.enabled;
def vless_decryption:
  if cfg.inbound.vless_encryption.enabled
  then sec.inbound.vless_encryption.decryption
  else "none"
  end;

def log_block: { log: { loglevel: "warning" } };

def policy_block: {
  policy: { levels: { "0": { handshake: 2, connIdle: 120 } } }
};

def reality_listen: if mode == "reality" and (hysteria_enabled | not) then "0.0.0.0" else "127.0.0.1" end;
def reality_port: if mode == "reality" and (hysteria_enabled | not) then 443 else 8443 end;
def reality_sockopt: if reality_listen == "127.0.0.1" then { trustedXForwardedFor: ["Kokoro-Trusted-XFF"] } else {} end;
def tls_sockopt: { trustedXForwardedFor: ["Kokoro-Trusted-XFF"] };
def xhttp_base_settings: { path: sec.inbound.xhttp_path };
def xhttp_tls_settings: xhttp_base_settings + {
  mode: "auto",
  xmux: {
    maxConcurrency: "5-10",
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
  tag: (if raw then "REALITY_RAW_IN" else "REALITY_XHTTP_IN" end),
  listen: reality_listen,
  port: reality_port,
  protocol: "vless",
  settings: {
    clients: [{ id: sec.inbound.uuid, flow: flow }],
    decryption: vless_decryption
  },
  streamSettings: {
    network: transport,
    security: "reality",
    realitySettings: {
      show: false,
      dest: cfg.inbound.reality.dest,
      xver: 0,
      serverNames: cfg.inbound.reality.server_names,
      privateKey: sec.inbound.reality.private_key,
      shortIds: sec.inbound.reality.short_ids
    }
  } + (if raw then {} else {xhttpSettings: xhttp_base_settings, sockopt: reality_sockopt} end),
  sniffing: ({ enabled: true, destOverride: ["http", "tls", "quic"] }
    + if raw then {routeOnly: true} else {} end)
};

def tls_inbound: {
  tag: (if raw then "TLS_RAW_IN" else "TLS_XHTTP_IN" end),
  listen: "127.0.0.1",
  port: 8444,
  protocol: "vless",
  settings: {
    clients: [{ id: sec.inbound.uuid, flow: flow }],
    decryption: (if raw then "none" else vless_decryption end)
  } + (if raw then {fallbacks: [{dest: "127.0.0.1:8080", xver: 0}]} else {} end),
  streamSettings: (if raw then {
    network: "raw",
    security: "tls",
    tlsSettings: {
      alpn: ["h2", "http/1.1"],
      certificates: [{certificateFile: cfg.paths.tls_cert, keyFile: cfg.paths.tls_key}]
    }
  } else {
    network: transport,
    security: "none",
    xhttpSettings: xhttp_tls_settings,
    sockopt: tls_sockopt
  } end),
  sniffing: ({ enabled: true, destOverride: ["http", "tls", "quic"] }
    + if raw then {routeOnly: true} else {} end)
};

def hysteria_inbound: {
  tag: "HYSTERIA2_IN",
  listen: "0.0.0.0",
  port: cfg.inbound.hysteria.ports,
  protocol: "hysteria",
  settings: {
    version: 2,
    users: [{ auth: sec.inbound.hysteria.auth, level: 0 }]
  },
  streamSettings: {
    method: "hysteria",
    security: "tls",
    tlsSettings: {
      alpn: ["h3"],
      certificates: [{
        certificateFile: cfg.paths.hysteria_cert,
        keyFile: cfg.paths.hysteria_key
      }]
    },
    hysteriaSettings: {
      version: 2,
      udpIdleTimeout: 60,
      masquerade: {
        type: "proxy",
        url: "https://\(cfg.inbound.hysteria.masquerade)/",
        rewriteHost: true
      }
    },
    finalmask: {
      udp: [{
        type: "salamander",
        settings: {
          password: sec.inbound.hysteria.obfs_password
        }
      }],
      quicParams: {
        congestion: cfg.inbound.hysteria.congestion,
        bbrProfile: cfg.inbound.hysteria.bbr_profile
      }
    }
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

def wg_outbound: if cfg.multinode.enabled then
  [{
    tag: "WG_TO_EXIT",
    protocol: "wireguard",
    settings: {
      secretKey: sec.multinode.edge_wg_privkey,
      address: ["\((cfg.multinode.local_wg_ip))/32"],
      peers: [{
        publicKey: cfg.multinode.peer_exit_pubkey,
        endpoint: "\(cfg.multinode.exit_ip):\(cfg.multinode.exit_port)",
        allowedIPs: ["0.0.0.0/0", "::/0"]
      }]
    }
  } + if cfg.multinode.finalmask then
    { streamSettings: { finalmask: { udp: [{ type: "mkcp-legacy", settings: { header: "wireguard" } }] } } }
  else {} end]
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
    { type: "field", network: "tcp,udp", outboundTag: "WG_TO_EXIT" }
  ]
};

def edge_routing: if cfg.multinode.enabled then edge_multinode_routing else edge_single_routing end;

def edge_inbounds:
  (if mode == "reality" or mode == "both" then [reality_inbound] else [] end)
  + (if mode == "tls" or mode == "both" then [tls_inbound] else [] end)
  + (if hysteria_enabled then [hysteria_inbound] else [] end);

def edge_config: log_block + {
  inbounds: edge_inbounds,
  outbounds: (base_outbounds + wg_outbound),
  routing: edge_routing,
  policy: policy_block.policy
};

def exit_inbound: {
  tag: "WG_EXIT_IN",
  listen: "0.0.0.0",
  port: cfg.multinode.exit_port,
  protocol: "wireguard",
  settings: {
    secretKey: sec.multinode.exit_wg_privkey,
    mtu: 1420,
    peers: [{
      publicKey: cfg.multinode.peer_edge_pubkey,
      allowedIPs: ["\((cfg.multinode.peer_wg_ip))/32"]
    }]
  }
} + if cfg.multinode.finalmask then
  { streamSettings: { finalmask: { udp: [{ type: "mkcp-legacy", settings: { header: "wireguard" } }] } } }
else {} end;

def exit_config: log_block + {
  inbounds: [exit_inbound],
  outbounds: (base_outbounds + exit_tor_outbound),
  routing: {
    domainStrategy: "IPIfNonMatch",
    rules: (exit_tor_rules + [
      { type: "field", ip: ["geoip:private"], outboundTag: "BLOCK" },
      { type: "field", network: "tcp,udp", outboundTag: "DIRECT" }
    ])
  },
  policy: policy_block.policy
};

if role == "edge" then edge_config
elif role == "exit" then exit_config
else error("unknown role: \(role)")
end
