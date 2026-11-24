#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="/cloud/service/vpnProxy"
SERVER_DIR="${PROJECT_DIR}/server"
CLIENT_DIR="${PROJECT_DIR}/clients"
BACKUP_DIR="${PROJECT_DIR}/backups"
STATE_DIR="${PROJECT_DIR}/state"
LOG_DIR="${PROJECT_DIR}/logs"
CONFIG_PATH="${SERVER_DIR}/sing-box-config.json"
STATE_FILE="${STATE_DIR}/server.env"
CERT_DIR="${SERVER_DIR}/tls"
CERT_PATH="${CERT_DIR}/hysteria2.crt"
KEY_PATH="${CERT_DIR}/hysteria2.key"
INSTALL_LOG="${LOG_DIR}/deploy-$(date -u +%Y%m%dT%H%M%SZ).log"

SNI="${SNI:-YOUR_SNI}"
REALITY_DEST="${REALITY_DEST:-YOUR_SNI:443}"
REALITY_SERVER_PORT="${REALITY_SERVER_PORT:-443}"
HYSTERIA2_PORT="${HYSTERIA2_PORT:-443}"

export DEBIAN_FRONTEND=noninteractive

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    exec sudo -E bash "$0" "$@"
  fi
}

backup_path() {
  local path="$1"
  local name ts
  [ -e "$path" ] || return 0
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  name="$(basename "$path")"
  mkdir -p "${BACKUP_DIR}/${ts}"
  mv "$path" "${BACKUP_DIR}/${ts}/${name}"
  log "Backed up ${path} to ${BACKUP_DIR}/${ts}/${name}"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1
}

random_password() {
  openssl rand -base64 36 | tr -d '\n'
}

load_or_create_state() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"

  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    log "Loaded existing secrets from ${STATE_FILE}"
  fi

  UUID="${UUID:-$(sing-box generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)}"
  SHORT_ID="${SHORT_ID:-$(openssl rand -hex 8)}"
  HYSTERIA2_PASSWORD="${HYSTERIA2_PASSWORD:-$(random_password)}"

  if [ -z "${REALITY_PRIVATE_KEY:-}" ] || [ -z "${REALITY_PUBLIC_KEY:-}" ]; then
    local keypair private public
    keypair="$(sing-box generate reality-keypair)"
    private="$(printf '%s\n' "$keypair" | awk -F': ' '/PrivateKey|Private key|private_key/ {print $2; exit}')"
    public="$(printf '%s\n' "$keypair" | awk -F': ' '/PublicKey|Public key|public_key/ {print $2; exit}')"
    if [ -z "$private" ] || [ -z "$public" ]; then
      log "Could not parse sing-box REALITY keypair output:"
      printf '%s\n' "$keypair"
      exit 1
    fi
    REALITY_PRIVATE_KEY="$private"
    REALITY_PUBLIC_KEY="$public"
  fi

  SERVER_PUBLIC_IP="${SERVER_PUBLIC_IP:-$(detect_public_ip)}"

  cat > "$STATE_FILE.tmp" <<EOF
UUID='${UUID}'
REALITY_PRIVATE_KEY='${REALITY_PRIVATE_KEY}'
REALITY_PUBLIC_KEY='${REALITY_PUBLIC_KEY}'
SHORT_ID='${SHORT_ID}'
HYSTERIA2_PASSWORD='${HYSTERIA2_PASSWORD}'
SNI='${SNI}'
REALITY_DEST='${REALITY_DEST}'
REALITY_SERVER_PORT='${REALITY_SERVER_PORT}'
HYSTERIA2_PORT='${HYSTERIA2_PORT}'
SERVER_PUBLIC_IP='${SERVER_PUBLIC_IP}'
EOF
  install -m 600 "$STATE_FILE.tmp" "$STATE_FILE"
  rm -f "$STATE_FILE.tmp"
}

detect_public_ip() {
  curl -4fsS --max-time 8 https://ifconfig.me 2>/dev/null \
    || curl -4fsS --max-time 8 https://ipinfo.io/ip 2>/dev/null \
    || curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null \
    || hostname -I 2>/dev/null | awk '{print $1}' \
    || true
}

inspect_server() {
  log "Host inspection: uname -a"
  uname -a || true
  log "Host inspection: /etc/os-release"
  cat /etc/os-release || true
  log "Host inspection: ip route"
  ip route || true
  log "Host inspection: ss -lntup"
  ss -lntup || true
  log "Host inspection: systemctl status sing-box"
  systemctl status sing-box --no-pager || true
  log "Host inspection: project directory"
  ls -la "$PROJECT_DIR" || true
}

install_packages() {
  log "Installing required Debian packages"
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release openssl iproute2 iptables nftables
}

install_sing_box() {
  if require_cmd sing-box; then
    log "sing-box exists, official APT repository will upgrade if needed"
  else
    log "Installing sing-box with the official SagerNet APT repository"
  fi

  mkdir -p /etc/apt/keyrings
  curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
  chmod a+r /etc/apt/keyrings/sagernet.asc
  cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
  apt-get update
  apt-get install -y sing-box

  if ! require_cmd sing-box; then
    log "sing-box was not installed successfully"
    exit 1
  fi
}

ensure_cert() {
  mkdir -p "$CERT_DIR"
  chmod 700 "$CERT_DIR"
  if [ ! -s "$CERT_PATH" ] || [ ! -s "$KEY_PATH" ]; then
    log "Generating self-signed TLS certificate for Hysteria2"
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
      -keyout "$KEY_PATH" \
      -out "$CERT_PATH" \
      -subj "/CN=${SNI}" \
      -addext "subjectAltName=DNS:${SNI},IP:${SERVER_PUBLIC_IP:-127.0.0.1}"
  fi
  chmod 600 "$KEY_PATH"
  chmod 644 "$CERT_PATH"
}

write_config() {
  mkdir -p "$SERVER_DIR"
  chmod 700 "$SERVER_DIR"
  if [ -f "$CONFIG_PATH" ]; then
    cp -a "$CONFIG_PATH" "${BACKUP_DIR}/sing-box-config.$(date -u +%Y%m%dT%H%M%SZ).json"
  fi

  local users_flow='"flow": "xtls-rprx-vision"'
  if ! sing-box version 2>/dev/null | grep -Eq 'version (1\.[8-9]|[2-9]\.)'; then
    users_flow='"flow": "xtls-rprx-vision",'
  fi

  cat > "$CONFIG_PATH.tmp" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "listen_port": 443,
      "users": [
        {
          "name": "primary",
          "uuid": "${UUID}",
          ${users_flow}
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SNI}",
            "server_port": ${REALITY_SERVER_PORT}
          },
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2-in",
      "listen": "0.0.0.0",
      "listen_port": ${HYSTERIA2_PORT},
      "users": [
        {
          "name": "secondary",
          "password": "${HYSTERIA2_PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT_PATH}",
        "key_path": "${KEY_PATH}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF
  install -m 600 "$CONFIG_PATH.tmp" "$CONFIG_PATH"
  rm -f "$CONFIG_PATH.tmp"
}

validate_config_or_retry_without_flow() {
  log "Validating sing-box config"
  if sing-box check -c "$CONFIG_PATH"; then
    return 0
  fi

  log "Config check failed. Retrying without xtls-rprx-vision flow for version compatibility."
  sed -i.bak -E 's/("uuid": "[^"]+"),/\1/' "$CONFIG_PATH"
  sed -i.bak '/"flow": "xtls-rprx-vision",/d' "$CONFIG_PATH"
  sed -i '/"flow": "xtls-rprx-vision"/d' "$CONFIG_PATH"
  if sing-box check -c "$CONFIG_PATH"; then
    log "Config is valid without xtls-rprx-vision flow"
    return 0
  fi

  log "sing-box config is invalid after compatibility retry"
  sing-box check -c "$CONFIG_PATH" || true
  exit 1
}

configure_systemd() {
  log "Configuring systemd service"
  mkdir -p /etc/systemd/system/sing-box.service.d

  if [ ! -f /etc/systemd/system/sing-box.service ] && [ ! -f /lib/systemd/system/sing-box.service ] && [ ! -f /usr/lib/systemd/system/sing-box.service ]; then
    cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
ExecStart=/usr/bin/sing-box run -c /cloud/service/vpnProxy/server/sing-box-config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
  else
    cat > /etc/systemd/system/sing-box.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/sing-box run -c ${CONFIG_PATH}
Restart=on-failure
RestartSec=10s
EOF
  fi

  systemctl daemon-reload
  systemctl enable sing-box
}

configure_firewall() {
  log "Configuring local firewall rules where tooling is active"

  if require_cmd ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 22/tcp
    ufw allow 443/tcp
    ufw allow "${HYSTERIA2_PORT}/udp"
    log "Applied ufw allow rules for 22/tcp, 443/tcp, ${HYSTERIA2_PORT}/udp"
    return 0
  fi

  if systemctl is-active --quiet nftables 2>/dev/null && require_cmd nft; then
    log "nftables is active; leaving rules unchanged to avoid disrupting SSH. Ensure 22/tcp, 443/tcp, and ${HYSTERIA2_PORT}/udp are allowed."
    return 0
  fi

  if require_cmd iptables; then
    iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 22 -j ACCEPT
    iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 443 -j ACCEPT
    iptables -C INPUT -p udp --dport "$HYSTERIA2_PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$HYSTERIA2_PORT" -j ACCEPT
    log "Applied runtime iptables allow rules for 22/tcp, 443/tcp, ${HYSTERIA2_PORT}/udp"
  fi
}

restart_service() {
  log "Starting/restarting sing-box"
  systemctl restart sing-box
}

write_clients() {
  if [ -d "$CLIENT_DIR" ]; then
    backup_path "$CLIENT_DIR"
  fi
  mkdir -p "$CLIENT_DIR"

  local ip host vless_link hy2_link
  ip="${SERVER_PUBLIC_IP:-$(detect_public_ip)}"
  host="$ip"

  vless_link="vless://${UUID}@${host}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#sing-box-vless-reality"
  hy2_link="hysteria2://${HYSTERIA2_PASSWORD}@${host}:${HYSTERIA2_PORT}?insecure=1&sni=${SNI}#sing-box-hysteria2"

  cat > "${CLIENT_DIR}/sing-box-vless-reality-client.json" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 2080
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "${host}",
      "server_port": 443,
      "uuid": "${UUID}",
      "flow": "xtls-rprx-vision",
      "packet_encoding": "xudp",
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "${REALITY_PUBLIC_KEY}",
          "short_id": "${SHORT_ID}"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "proxy"
  }
}
EOF

  cat > "${CLIENT_DIR}/sing-box-hysteria2-client.json" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 2081
    }
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "proxy",
      "server": "${host}",
      "server_port": ${HYSTERIA2_PORT},
      "password": "${HYSTERIA2_PASSWORD}",
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "insecure": true
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "proxy"
  }
}
EOF

  cat > "${CLIENT_DIR}/vless-reality-share-link.txt" <<EOF
${vless_link}
EOF
  cat > "${CLIENT_DIR}/hysteria2-share-link.txt" <<EOF
${hy2_link}
EOF

  cat > "${CLIENT_DIR}/README.md" <<EOF
# Private sing-box Proxy/VPN

Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

## Server

- Public IPv4: ${ip}
- Server config: ${CONFIG_PATH}
- Primary: VLESS + REALITY over TCP 443
- Secondary: Hysteria2 over UDP ${HYSTERIA2_PORT}
- REALITY camouflage SNI/destination: ${SNI}:443
- REALITY flow: xtls-rprx-vision when supported by client/server

## VLESS + REALITY

- Address: ${host}
- Port: 443 TCP
- UUID: ${UUID}
- Security: reality
- SNI: ${SNI}
- Public key: ${REALITY_PUBLIC_KEY}
- Short ID: ${SHORT_ID}
- Fingerprint: chrome
- Flow: xtls-rprx-vision
- Transport: tcp
- Share link: see \`vless-reality-share-link.txt\`
- sing-box client: \`sing-box-vless-reality-client.json\`

## Hysteria2

- Address: ${host}
- Port: ${HYSTERIA2_PORT} UDP
- Password: ${HYSTERIA2_PASSWORD}
- TLS SNI: ${SNI}
- Certificate: self-signed
- Client TLS option required: \`insecure: true\`, \`allowInsecure: true\`, or equivalent
- Share link: see \`hysteria2-share-link.txt\`
- sing-box client: \`sing-box-hysteria2-client.json\`

## Client Import Notes

- sing-box: use the provided JSON files directly, or merge their outbounds into your existing config.
- Shadowrocket: import the VLESS share link if your version supports REALITY. For Hysteria2, import the Hysteria2 share link and enable insecure TLS because the cert is self-signed.
- Clash-compatible clients: support varies. Use Mihomo/Clash Meta builds with REALITY and Hysteria2 support, then map these values into their VLESS REALITY or Hysteria2 proxy fields.

## AWS Lightsail Firewall

Open these manually in the Lightsail console:

- Networking tab
- Keep SSH TCP 22 open
- Add custom TCP 443 from your allowed source IP, or 0.0.0.0/0 if needed
- Add custom UDP ${HYSTERIA2_PORT} from your allowed source IP, or 0.0.0.0/0 if needed

## Local Test Commands

Run these from your own computer after opening Lightsail firewall rules:

\`\`\`bash
nc -vz ${host} 443
nmap -sU -p ${HYSTERIA2_PORT} ${host}
sing-box check -c sing-box-vless-reality-client.json
sing-box run -c sing-box-vless-reality-client.json
curl -x socks5h://127.0.0.1:2080 https://ifconfig.me
sing-box check -c sing-box-hysteria2-client.json
sing-box run -c sing-box-hysteria2-client.json
curl -x socks5h://127.0.0.1:2081 https://ifconfig.me
\`\`\`

## Server Troubleshooting

\`\`\`bash
sudo sing-box version
sudo sing-box check -c ${CONFIG_PATH}
sudo systemctl status sing-box --no-pager
sudo journalctl -u sing-box -n 100 --no-pager
sudo ss -lntup | grep -E '(:443|:8443)'
curl -4 ifconfig.me || curl -4 ipinfo.io/ip || true
sudo systemctl restart sing-box
sudo systemctl stop sing-box
sudo systemctl disable --now sing-box
\`\`\`

## Uninstall

\`\`\`bash
sudo systemctl disable --now sing-box
sudo rm -f /etc/systemd/system/sing-box.service
sudo rm -rf /etc/systemd/system/sing-box.service.d
sudo systemctl daemon-reload
sudo apt-get remove -y sing-box
\`\`\`

Project files under ${PROJECT_DIR} are intentionally not removed by the uninstall commands.
EOF

  chown -R admin:admin "$CLIENT_DIR" 2>/dev/null || true
  chmod 700 "$CLIENT_DIR"
  chmod 600 "${CLIENT_DIR}"/*.json "${CLIENT_DIR}"/*.txt "${CLIENT_DIR}/README.md"
}

post_validation() {
  log "Post-deployment validation: sing-box version"
  sing-box version || true
  log "Post-deployment validation: sing-box check"
  sing-box check -c "$CONFIG_PATH" || true
  log "Post-deployment validation: systemctl status"
  systemctl status sing-box --no-pager || true
  log "Post-deployment validation: recent logs"
  journalctl -u sing-box -n 100 --no-pager || true
  log "Post-deployment validation: listening ports"
  ss -lntup | grep -E '(:443|:8443)' || true
  log "Post-deployment validation: public IPv4"
  curl -4 ifconfig.me || curl -4 ipinfo.io/ip || true
  printf '\n'
}

print_finish() {
  cat <<EOF

Deployment complete.

Manual AWS Lightsail console steps:
1. Open the instance Networking tab.
2. Keep SSH TCP 22 open.
3. Add custom TCP 443 from your allowed source IP, or 0.0.0.0/0 if necessary.
4. Add custom UDP ${HYSTERIA2_PORT} from your allowed source IP, or 0.0.0.0/0 if necessary.

Client files:
- ${CLIENT_DIR}/sing-box-vless-reality-client.json
- ${CLIENT_DIR}/sing-box-hysteria2-client.json
- ${CLIENT_DIR}/vless-reality-share-link.txt
- ${CLIENT_DIR}/hysteria2-share-link.txt
- ${CLIENT_DIR}/README.md

Local test commands:
nc -vz ${SERVER_PUBLIC_IP} 443
nmap -sU -p ${HYSTERIA2_PORT} ${SERVER_PUBLIC_IP}
sing-box check -c sing-box-vless-reality-client.json
sing-box run -c sing-box-vless-reality-client.json
curl -x socks5h://127.0.0.1:2080 https://ifconfig.me
sing-box check -c sing-box-hysteria2-client.json
sing-box run -c sing-box-hysteria2-client.json
curl -x socks5h://127.0.0.1:2081 https://ifconfig.me

EOF
}

main() {
  need_root "$@"
  mkdir -p "$SERVER_DIR" "$BACKUP_DIR" "$LOG_DIR"
  chmod 700 "$SERVER_DIR" "$BACKUP_DIR" "$LOG_DIR"
  exec > >(tee -a "$INSTALL_LOG") 2>&1

  inspect_server
  install_packages
  install_sing_box
  load_or_create_state
  ensure_cert
  write_config
  validate_config_or_retry_without_flow
  configure_systemd
  configure_firewall
  write_clients
  restart_service
  post_validation
  print_finish
}

main "$@"
