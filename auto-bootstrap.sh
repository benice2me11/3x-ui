#!/usr/bin/env bash
set -euo pipefail
trap 'code=$?; printf "[ERROR] %s failed (line %s, code %s)\n" "${BASH_COMMAND}" "${LINENO}" "${code}" >&2; exit ${code}' ERR

XUIDB="/etc/x-ui/x-ui.db"
RELEASE_REPO="MHSanaei/3x-ui"
FORK_REPO="${FORK_REPO:-benice2me11/3x-ui}"
FORK_REF="${FORK_REF:-main}"
SKIP_FORK_OVERLAY="${SKIP_FORK_OVERLAY:-0}"

INSTALL_DEPS="y"
AUTODOMAIN="n"
DOMAIN=""
REALITY_DOMAIN=""
HY2_DOMAIN=""
CLIENT_NAME="first"

PKG_MGR="apt-get"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
plain='\033[0m'

msg_ok()  { printf "${green}%s${plain}\n" "$1"; }
msg_inf() { printf "${blue}%s${plain}\n" "$1"; }
msg_warn(){ printf "${yellow}%s${plain}\n" "$1"; }
msg_err() { printf "${red}%s${plain}\n" "$1" >&2; }
die()     { msg_err "$1"; exit "${2:-1}"; }

ensure_root() {
  if [[ ${EUID} -ne 0 ]]; then
    die "Run as root (sudo -i)."
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

arch_xui() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    i*86) echo "386" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7*|armv7|arm) echo "armv7" ;;
    armv6*) echo "armv6" ;;
    armv5*) echo "armv5" ;;
    s390x) echo "s390x" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

arch_hysteria() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    i*86) echo "386" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7*|armv7|arm) echo "arm" ;;
    s390x) echo "s390x" ;;
    riscv64) echo "riscv64" ;;
    *) die "Unsupported architecture for hysteria: $(uname -m)" ;;
  esac
}

gen_random_string() {
  local length="$1"
  local s
  set +o pipefail
  s="$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length")"
  set -o pipefail
  printf "%s" "$s"
}

is_port_in_use() {
  local p="$1"
  ss -lntup 2>/dev/null | awk -v re=":${p}$" '$5 ~ re {found=1} END {exit(found?0:1)}'
}

make_port() {
  local p
  while true; do
    p=$(( (RANDOM % 40000) + 20000 ))
    if ! is_port_in_use "$p"; then
      echo "$p"
      return 0
    fi
  done
}

is_domain() {
  [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+[A-Za-z]{2,}$ ]]
}

resolve_ipv4() {
  local host="$1"
  local ip
  ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
  [[ -n "$ip" ]] && echo "$ip" || return 1
}

detect_ip4() {
  local ip
  ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || true
  if [[ -z "$ip" ]]; then
    ip=$(curl -fsSL https://ipv4.icanhazip.com | tr -d '[:space:]')
  fi
  [[ -n "$ip" ]] || die "Cannot detect IPv4 address"
  echo "$ip"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -install)
        INSTALL_DEPS="$2"; shift 2 ;;
      -subdomain|-domain)
        DOMAIN="$2"; shift 2 ;;
      -reality_domain)
        REALITY_DOMAIN="$2"; shift 2 ;;
      -hy2_domain)
        HY2_DOMAIN="$2"; shift 2 ;;
      -fork_repo)
        FORK_REPO="$2"; shift 2 ;;
      -fork_ref)
        FORK_REF="$2"; shift 2 ;;
      -client_name)
        CLIENT_NAME="$2"; shift 2 ;;
      -auto_domain)
        AUTODOMAIN="$2"; shift 2 ;;
      -h|--help)
        cat <<USAGE
Usage:
  bash auto-bootstrap.sh [options]

Options:
  -install yes|no         Install apt dependencies (default: yes)
  -subdomain DOMAIN       Main domain for panel/sub/ws/grpc/xhttp
  -reality_domain DOMAIN  Separate REALITY domain
  -hy2_domain DOMAIN      Domain for HY2 cert/SNI (default: main domain)
  -fork_repo OWNER/REPO   Fork repository (default: benice2me11/3x-ui)
  -fork_ref REF           Fork branch/tag (default: main)
  -client_name NAME       Base subscription id / user (default: first)
  -auto_domain yes|no     Use cdn-one auto domains from server IPv4
USAGE
        exit 0 ;;
      *)
        die "Unknown argument: $1" ;;
    esac
  done
}

install_packages() {
  if [[ "${INSTALL_DEPS}" != *"y"* ]]; then
    msg_warn "Skipping dependency install (-install no)"
    return 0
  fi

  need_cmd apt-get
  export DEBIAN_FRONTEND=noninteractive
  ${PKG_MGR} update -y
  ${PKG_MGR} install -y \
    curl wget jq bash sudo nginx-full certbot python3-certbot-nginx \
    sqlite3 ufw git tar tzdata ca-certificates openssl lsof

  ${PKG_MGR} install -y build-essential
  if ! command -v go >/dev/null 2>&1; then
    ${PKG_MGR} install -y golang-go
  fi

  systemctl daemon-reload
  systemctl enable --now nginx
}

obtain_ssl() {
  local cert_domain="$1"
  msg_inf "Issuing certificate for ${cert_domain}"
  certbot certonly --standalone --non-interactive --agree-tos \
    --register-unsafely-without-email -d "${cert_domain}" >/dev/null
  # Use nginx authenticator for future automatic renewals while nginx is running.
  if [[ -f "/etc/letsencrypt/renewal/${cert_domain}.conf" ]]; then
    sed -i 's/^authenticator = .*/authenticator = nginx/' "/etc/letsencrypt/renewal/${cert_domain}.conf"
  fi
  [[ -d "/etc/letsencrypt/live/${cert_domain}" ]] || die "Failed to issue cert for ${cert_domain}"
}

prepare_nginx_stream_support() {
  mkdir -p /etc/nginx/stream-enabled

  if ! grep -qF "include /etc/nginx/stream-enabled/*.conf" /etc/nginx/nginx.conf; then
    printf "\nstream { include /etc/nginx/stream-enabled/*.conf; }\n" >> /etc/nginx/nginx.conf
  fi

  if nginx -V 2>&1 | grep -q -- '--with-stream\b'; then
    return 0
  fi

  if ls /etc/nginx/modules-enabled/*stream* >/dev/null 2>&1; then
    return 0
  fi

  if [[ -f /usr/lib/nginx/modules/ngx_stream_module.so ]] \
    && ! grep -qF "ngx_stream_module" /etc/nginx/nginx.conf; then
    sed -i '1s|^|load_module /usr/lib/nginx/modules/ngx_stream_module.so;\n|' /etc/nginx/nginx.conf
  fi
}

install_panel_base() {
  local tag arch
  arch="$(arch_xui)"

  msg_inf "Installing base panel bundle from ${RELEASE_REPO}"
  tag=$(curl -fsSL "https://api.github.com/repos/${RELEASE_REPO}/releases/latest" | jq -r '.tag_name')
  [[ -n "$tag" && "$tag" != "null" ]] || die "Failed to get latest release tag from ${RELEASE_REPO}"

  curl -fL -o "/usr/local/x-ui-linux-${arch}.tar.gz" \
    "https://github.com/${RELEASE_REPO}/releases/download/${tag}/x-ui-linux-${arch}.tar.gz"

  curl -fL -o /usr/bin/x-ui-temp \
    "https://raw.githubusercontent.com/${RELEASE_REPO}/main/x-ui.sh"

  if systemctl list-unit-files | grep -q '^x-ui.service'; then
    systemctl stop x-ui || true
  fi

  rm -rf /usr/local/x-ui
  cd /usr/local
  tar zxf "x-ui-linux-${arch}.tar.gz"
  rm -f "x-ui-linux-${arch}.tar.gz"

  chmod +x /usr/local/x-ui/x-ui /usr/local/x-ui/x-ui.sh || true
  find /usr/local/x-ui/bin -maxdepth 1 -type f -name 'xray-linux-*' -exec chmod +x {} +

  mv -f /usr/bin/x-ui-temp /usr/bin/x-ui
  chmod +x /usr/bin/x-ui

  if [[ -f /usr/local/x-ui/x-ui.service.debian ]]; then
    cp -f /usr/local/x-ui/x-ui.service.debian /etc/systemd/system/x-ui.service
  elif [[ -f /usr/local/x-ui/x-ui.service.rhel ]]; then
    cp -f /usr/local/x-ui/x-ui.service.rhel /etc/systemd/system/x-ui.service
  else
    die "x-ui service unit file not found in bundle"
  fi

  systemctl daemon-reload
  systemctl enable x-ui
  systemctl start x-ui
}

install_fork_overlay() {
  if [[ "${SKIP_FORK_OVERLAY}" == "1" ]]; then
    msg_warn "Skipping fork overlay build (SKIP_FORK_OVERLAY=1)"
    return 0
  fi

  local src_dir="/tmp/3x-ui-fork-src"

  msg_inf "Overlaying fork sources from ${FORK_REPO}@${FORK_REF}"
  rm -rf "$src_dir"
  git clone --depth 1 --branch "$FORK_REF" "https://github.com/${FORK_REPO}.git" "$src_dir"

  if ! command -v go >/dev/null 2>&1; then
    die "Go toolchain is required to build fork binary"
  fi

  (
    cd "$src_dir"
    export GOTOOLCHAIN=auto
    go build -trimpath -ldflags='-s -w' -o /usr/local/x-ui/x-ui .
  )

  install -m 755 "$src_dir/x-ui.sh" /usr/local/x-ui/x-ui.sh
  install -m 755 "$src_dir/x-ui.sh" /usr/bin/x-ui

  systemctl restart x-ui
}

set_setting() {
  local key="$1"
  local value="$2"
  sqlite3 "$XUIDB" "DELETE FROM settings WHERE key='${key}'; INSERT INTO settings(key,value) VALUES('${key}','${value}');"
}

configure_panel_and_inbounds() {
  [[ -f "$XUIDB" ]] || die "x-ui database not found at ${XUIDB}"

  local xray_bin out private_key public_key
  local client_id client_id2 client_id3 trojan_pass
  local now_ms
  local sub_json_rules

  xray_bin=$(find /usr/local/x-ui/bin -maxdepth 1 -type f -name 'xray-linux-*' | head -n1)
  [[ -x "$xray_bin" ]] || die "xray core binary not found"

  out=$("$xray_bin" x25519)
  private_key=$(echo "$out" | awk -F': *' '/PrivateKey/ {print $2}' | tr -d '\r' | head -n1)
  public_key=$(echo "$out" | awk -F': *' '/PublicKey|Password/ {print $2}' | tr -d '\r' | head -n1)
  [[ -n "$private_key" && -n "$public_key" ]] || die "Failed to generate x25519 keypair"

  client_id=$("$xray_bin" uuid)
  client_id2=$("$xray_bin" uuid)
  client_id3=$("$xray_bin" uuid)
  trojan_pass="$(gen_random_string 14)"
  now_ms="$(( $(date +%s) * 1000 ))"

  short_ids=(
    "$(openssl rand -hex 8)"
    "$(openssl rand -hex 8)"
    "$(openssl rand -hex 8)"
    "$(openssl rand -hex 8)"
    "$(openssl rand -hex 8)"
    "$(openssl rand -hex 8)"
    "$(openssl rand -hex 8)"
    "$(openssl rand -hex 8)"
  )

  msg_inf "Configuring panel settings and creating auto inbounds"

  # Split-routing profile for JSON subscriptions:
  # RU/private destinations go direct, ads + bittorrent are blocked.
  sub_json_rules='[{"type":"field","domain":["geosite:private","geosite:category-ru","geosite:ru","regexp:(^|\\.)[a-z0-9-]+\\.ru$","regexp:(^|\\.)[a-z0-9-]+\\.su$","regexp:(^|\\.)[a-z0-9-]+\\.xn--p1ai$"],"outboundTag":"direct"},{"type":"field","ip":["geoip:private","geoip:ru"],"outboundTag":"direct"},{"type":"field","domain":["geosite:category-ads-all"],"outboundTag":"block"},{"type":"field","protocol":["bittorrent"],"outboundTag":"block"}]'

  /usr/local/x-ui/x-ui setting \
    -username "${PANEL_USERNAME}" \
    -password "${PANEL_PASSWORD}" \
    -port "${PANEL_PORT}" \
    -webBasePath "${PANEL_PATH}" >/dev/null

  set_setting "webListen" ""
  set_setting "webDomain" ""
  set_setting "webCertFile" ""
  set_setting "webKeyFile" ""

  set_setting "subEnable" "true"
  set_setting "subJsonEnable" "true"
  set_setting "subPort" "${SUB_PORT}"
  set_setting "subPath" "/${SUB_PATH}/"
  set_setting "subJsonPath" "/${JSON_PATH}/"
  set_setting "subURI" "https://${DOMAIN}/${SUB_PATH}/"
  set_setting "subJsonURI" "https://${DOMAIN}/${JSON_PATH}/"
  set_setting "subJsonRules" "${sub_json_rules}"
  set_setting "subEncrypt" "true"
  set_setting "subShowInfo" "true"

  sqlite3 "$XUIDB" <<SQL
DELETE FROM inbounds WHERE tag LIKE 'auto-mp-%';
DELETE FROM client_traffics WHERE email LIKE 'auto-mp-%';

INSERT INTO inbounds (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing)
VALUES (
  1,0,0,0,
  'AUTO-MP reality',1,0,'',8443,'vless',
  '{
    "clients": [{
      "id": "${client_id}",
      "flow": "xtls-rprx-vision",
      "email": "auto-mp-${CLIENT_NAME}",
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0,
      "enable": true,
      "tgId": "",
      "subId": "${CLIENT_NAME}",
      "reset": 0,
      "created_at": ${now_ms},
      "updated_at": ${now_ms}
    }],
    "decryption": "none",
    "fallbacks": []
  }',
  '{
    "network": "tcp",
    "security": "reality",
    "externalProxy": [{
      "forceTls": "same",
      "dest": "${DOMAIN}",
      "port": 443,
      "remark": ""
    }],
    "realitySettings": {
      "show": false,
      "xver": 0,
      "target": "127.0.0.1:9443",
      "serverNames": ["${REALITY_DOMAIN}"],
      "privateKey": "${private_key}",
      "minClient": "",
      "maxClient": "",
      "maxTimediff": 0,
      "shortIds": [
        "${short_ids[0]}",
        "${short_ids[1]}",
        "${short_ids[2]}",
        "${short_ids[3]}",
        "${short_ids[4]}",
        "${short_ids[5]}",
        "${short_ids[6]}",
        "${short_ids[7]}"
      ],
      "settings": {
        "publicKey": "${public_key}",
        "fingerprint": "random",
        "serverName": "",
        "spiderX": "/"
      }
    },
    "tcpSettings": {
      "acceptProxyProtocol": false,
      "header": {"type": "none"}
    }
  }',
  'auto-mp-reality',
  '{"enabled":false,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
);

INSERT INTO inbounds (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing)
VALUES (
  1,0,0,0,
  'AUTO-MP ws',1,0,'',${WS_PORT},'vless',
  '{
    "clients": [{
      "id": "${client_id2}",
      "flow": "",
      "email": "auto-mp-${CLIENT_NAME}-ws",
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0,
      "enable": true,
      "tgId": "",
      "subId": "${CLIENT_NAME}",
      "reset": 0,
      "created_at": ${now_ms},
      "updated_at": ${now_ms}
    }],
    "decryption": "none",
    "fallbacks": []
  }',
  '{
    "network": "ws",
    "security": "none",
    "externalProxy": [{
      "forceTls": "tls",
      "dest": "${DOMAIN}",
      "port": 443,
      "remark": ""
    }],
    "wsSettings": {
      "acceptProxyProtocol": false,
      "path": "/${WS_PORT}/${WS_PATH}",
      "host": "${DOMAIN}",
      "headers": {}
    }
  }',
  'auto-mp-ws-${WS_PORT}',
  '{"enabled":false,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
);

INSERT INTO inbounds (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing)
VALUES (
  1,0,0,0,
  'AUTO-MP xhttp',1,0,'/dev/shm/uds2023.sock,0666',0,'vless',
  '{
    "clients": [{
      "id": "${client_id3}",
      "flow": "",
      "email": "auto-mp-${CLIENT_NAME}-xhttp",
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0,
      "enable": true,
      "tgId": "",
      "subId": "${CLIENT_NAME}",
      "reset": 0,
      "created_at": ${now_ms},
      "updated_at": ${now_ms}
    }],
    "decryption": "none",
    "fallbacks": []
  }',
  '{
    "network": "xhttp",
    "security": "none",
    "externalProxy": [{
      "forceTls": "tls",
      "dest": "${DOMAIN}",
      "port": 443,
      "remark": ""
    }],
    "xhttpSettings": {
      "path": "/${XHTTP_PATH}",
      "host": "",
      "headers": {},
      "scMaxBufferedPosts": 30,
      "scMaxEachPostBytes": "1000000",
      "noSSEHeader": false,
      "xPaddingBytes": "100-1000",
      "mode": "packet-up"
    },
    "sockopt": {
      "acceptProxyProtocol": false,
      "tcpFastOpen": true,
      "mark": 0,
      "tproxy": "off",
      "tcpMptcp": true,
      "tcpNoDelay": true,
      "domainStrategy": "UseIP",
      "tcpMaxSeg": 1440,
      "dialerProxy": "",
      "tcpKeepAliveInterval": 0,
      "tcpKeepAliveIdle": 300,
      "tcpUserTimeout": 10000,
      "tcpcongestion": "bbr",
      "V6Only": false,
      "tcpWindowClamp": 600,
      "interface": ""
    }
  }',
  'auto-mp-xhttp',
  '{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
);

INSERT INTO inbounds (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing)
VALUES (
  1,0,0,0,
  'AUTO-MP trojan-grpc',1,0,'',${TROJAN_PORT},'trojan',
  '{
    "clients": [{
      "comment": "",
      "created_at": ${now_ms},
      "email": "auto-mp-${CLIENT_NAME}-grpc",
      "enable": true,
      "expiryTime": 0,
      "limitIp": 0,
      "password": "${trojan_pass}",
      "reset": 0,
      "subId": "${CLIENT_NAME}",
      "tgId": 0,
      "totalGB": 0,
      "updated_at": ${now_ms}
    }],
    "fallbacks": []
  }',
  '{
    "network": "grpc",
    "security": "none",
    "externalProxy": [{
      "forceTls": "tls",
      "dest": "${DOMAIN}",
      "port": 443,
      "remark": ""
    }],
    "grpcSettings": {
      "serviceName": "/${TROJAN_PORT}/${TROJAN_PATH}",
      "authority": "${DOMAIN}",
      "multiMode": false
    }
  }',
  'auto-mp-trojan-grpc-${TROJAN_PORT}',
  '{"enabled":false,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
);
SQL

  systemctl restart x-ui
}

setup_nginx() {
  msg_inf "Configuring nginx for stream+web"
  prepare_nginx_stream_support

  mkdir -p /etc/nginx/stream-enabled /etc/nginx/snippets

  local hy2_separate_vhost="0"
  local hy2_map_line=""
  local hy2_upstream_block=""
  if [[ "$HY2_DOMAIN" != "$DOMAIN" && "$HY2_DOMAIN" != "$REALITY_DOMAIN" ]]; then
    hy2_separate_vhost="1"
    hy2_map_line="    ${HY2_DOMAIN}         hy2web;"
    hy2_upstream_block=$'\nupstream hy2web {\n    server 127.0.0.1:7444;\n}\n'
  fi

  cat > /etc/nginx/stream-enabled/stream.conf <<EOF_STREAM
map \$ssl_preread_server_name \$sni_upstream {
    hostnames;
    ${REALITY_DOMAIN} xray;
    ${DOMAIN}         web;
${hy2_map_line}
    default           xray;
}

upstream xray {
    server 127.0.0.1:8443;
}

upstream web {
    server 127.0.0.1:7443;
}
${hy2_upstream_block}

server {
    listen 443;
    proxy_pass \$sni_upstream;
    ssl_preread on;
}
EOF_STREAM

  cat > /etc/nginx/snippets/includes-api-mask.conf <<'EOF_API'
add_header X-Request-Id $request_id always;
add_header X-Content-Type-Options nosniff always;
add_header Cache-Control "no-store" always;

location = / {
    default_type application/json;
    return 200 "{\"service\":\"edge-api\",\"status\":\"ok\",\"version\":\"1.0.0\",\"ts\":\"$time_iso8601\"}";
}

location = /api/v1/health {
    default_type application/json;
    return 200 "{\"ok\":true,\"status\":\"healthy\",\"request_id\":\"$request_id\",\"ts\":\"$time_iso8601\"}";
}

location = /api/v1/status {
    default_type application/json;
    return 200 "{\"code\":0,\"message\":\"ok\",\"data\":{\"cluster\":\"edge-gw\",\"transport\":\"mixed\"}}";
}

location = /openapi.json {
    default_type application/json;
    return 200 "{\"openapi\":\"3.0.3\",\"info\":{\"title\":\"Edge API\",\"version\":\"1.0.0\"},\"paths\":{\"/api/v1/health\":{\"get\":{\"responses\":{\"200\":{\"description\":\"OK\"}}}},\"/api/v1/status\":{\"get\":{\"responses\":{\"200\":{\"description\":\"OK\"}}}}}}";
}

location = /robots.txt {
    default_type text/plain;
    return 200 "User-agent: *\nDisallow: /\n";
}

location @api_not_found {
    default_type application/json;
    return 404 "{\"error\":\"not_found\",\"message\":\"resource not found\",\"request_id\":\"$request_id\"}";
}
EOF_API

  cat > /etc/nginx/snippets/includes-xui-pro.conf <<EOF_INC
location /${SUB_PATH} {
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_pass http://127.0.0.1:${SUB_PORT};
}

location /${SUB_PATH}/ {
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_pass http://127.0.0.1:${SUB_PORT};
}

location /${JSON_PATH} {
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_pass http://127.0.0.1:${SUB_PORT};
}

location /${JSON_PATH}/ {
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_pass http://127.0.0.1:${SUB_PORT};
}

location /${XHTTP_PATH} {
    grpc_pass grpc://unix:/dev/shm/uds2023.sock;
    grpc_buffer_size 16k;
    grpc_socket_keepalive on;
    grpc_read_timeout 1h;
    grpc_send_timeout 1h;
    grpc_set_header Connection "";
    grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    grpc_set_header X-Forwarded-Proto \$scheme;
    grpc_set_header X-Forwarded-Port \$server_port;
    grpc_set_header Host \$host;
    grpc_set_header X-Forwarded-Host \$host;
}

location ~ ^/(?<fwdport>\d+)/(?<fwdpath>.*)\$ {
    client_max_body_size 0;
    client_body_timeout 1d;
    grpc_read_timeout 1d;
    grpc_socket_keepalive on;
    proxy_read_timeout 1d;
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_socket_keepalive on;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

    if (\$content_type ~* "GRPC") {
        grpc_pass grpc://127.0.0.1:\$fwdport\$is_args\$args;
        break;
    }
    if (\$http_upgrade ~* "(WEBSOCKET|WS)") {
        proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
        break;
    }
    if (\$request_method ~* "^(PUT|POST|GET)\$") {
        proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
        break;
    }
}
EOF_INC

  cat > "/etc/nginx/sites-available/${DOMAIN}" <<EOF_WEB
server {
    listen 7443 ssl http2;
    listen [::]:7443 ssl http2;
    server_name ${DOMAIN};
    server_tokens off;
    error_page 404 = @api_not_found;

    root /var/www/html;
    index index.html;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    location /${PANEL_PATH}/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://127.0.0.1:${PANEL_PORT};
    }

    location /${PANEL_PATH} {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://127.0.0.1:${PANEL_PORT};
    }

    include /etc/nginx/snippets/includes-xui-pro.conf;
    include /etc/nginx/snippets/includes-api-mask.conf;

    location / {
        return 404;
    }
}
EOF_WEB

cat > "/etc/nginx/sites-available/${REALITY_DOMAIN}" <<EOF_REALITY
server {
    listen 9443 ssl http2;
    listen [::]:9443 ssl http2;
    server_name ${REALITY_DOMAIN};
    server_tokens off;
    error_page 404 = @api_not_found;

    root /var/www/html;
    index index.html;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_certificate /etc/letsencrypt/live/${REALITY_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${REALITY_DOMAIN}/privkey.pem;

    include /etc/nginx/snippets/includes-api-mask.conf;

    location / {
        return 404;
    }
}
EOF_REALITY

  if [[ "$hy2_separate_vhost" == "1" ]]; then
    cat > "/etc/nginx/sites-available/${HY2_DOMAIN}" <<EOF_HY2
server {
    listen 7444 ssl http2;
    listen [::]:7444 ssl http2;
    server_name ${HY2_DOMAIN};
    server_tokens off;
    error_page 404 = @api_not_found;

    root /var/www/html;
    index index.html;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_certificate /etc/letsencrypt/live/${HY2_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${HY2_DOMAIN}/privkey.pem;

    include /etc/nginx/snippets/includes-api-mask.conf;

    location / {
        return 404;
    }
}
EOF_HY2
  fi

  cat > /etc/nginx/sites-available/80-xui-pro.conf <<EOF_80
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} ${REALITY_DOMAIN} ${HY2_DOMAIN};
    return 301 https://\$host\$request_uri;
}
EOF_80

  rm -f /etc/nginx/sites-enabled/default
  ln -sf "/etc/nginx/sites-available/${DOMAIN}" /etc/nginx/sites-enabled/
  ln -sf "/etc/nginx/sites-available/${REALITY_DOMAIN}" /etc/nginx/sites-enabled/
  if [[ "$hy2_separate_vhost" == "1" ]]; then
    ln -sf "/etc/nginx/sites-available/${HY2_DOMAIN}" /etc/nginx/sites-enabled/
  else
    rm -f "/etc/nginx/sites-enabled/${HY2_DOMAIN}" || true
  fi
  ln -sf /etc/nginx/sites-available/80-xui-pro.conf /etc/nginx/sites-enabled/

  nginx -t
  systemctl restart nginx
}

setup_hysteria2() {
  local hyst_tag hyst_arch hyst_url
  local hy2_secret

  hyst_arch="$(arch_hysteria)"
  hyst_tag=$(curl -fsSL https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r '.tag_name')
  [[ -n "$hyst_tag" && "$hyst_tag" != "null" ]] || die "Failed to query hysteria latest release"

  hyst_url="https://github.com/apernet/hysteria/releases/download/${hyst_tag}/hysteria-linux-${hyst_arch}"

  msg_inf "Installing hysteria2 ${hyst_tag} (${hyst_arch})"
  curl -fL -o /usr/local/bin/hysteria "$hyst_url"
  chmod +x /usr/local/bin/hysteria

  mkdir -p /etc/hysteria
  hy2_secret="$(gen_random_string 24)"

  cat > /etc/hysteria/config.yaml <<EOF_HY2
listen: :443

auth:
  type: userpass
  userpass:
    ${CLIENT_NAME}: ${HY2_PASSWORD}

tls:
  cert: /etc/letsencrypt/live/${HY2_DOMAIN}/fullchain.pem
  key: /etc/letsencrypt/live/${HY2_DOMAIN}/privkey.pem
  sni: ${HY2_DOMAIN}

masquerade:
  type: proxy
  proxy:
    url: https://www.cloudflare.com

trafficStats:
  listen: 127.0.0.1:9088
  secret: ${hy2_secret}
EOF_HY2
  chmod 600 /etc/hysteria/config.yaml

  cat > /etc/systemd/system/hysteria2.service <<'EOF_UNIT'
[Unit]
Description=Hysteria2 Service
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_UNIT

  systemctl daemon-reload
  systemctl enable hysteria2
  systemctl restart hysteria2
}

setup_certbot_renewal() {
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx-hysteria2.sh <<'EOF_HOOK'
#!/usr/bin/env bash
set -euo pipefail

if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
  fi
  if systemctl list-unit-files | grep -q '^hysteria2\.service'; then
    if systemctl is-active --quiet hysteria2; then
      systemctl restart hysteria2
    fi
  fi
fi
EOF_HOOK
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx-hysteria2.sh
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
}

setup_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    msg_warn "ufw is not installed; skipping firewall setup"
    return 0
  fi

  ufw disable >/dev/null 2>&1 || true
  ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw allow 443/udp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
}

print_summary() {
  cat <<EOF

==================== DONE ====================
Fork repo:          ${FORK_REPO}@${FORK_REF}
Panel URL:          https://${DOMAIN}/${PANEL_PATH}/
Panel username:     ${PANEL_USERNAME}
Panel password:     ${PANEL_PASSWORD}

Subscription (base64):
  https://${DOMAIN}/${SUB_PATH}/${CLIENT_NAME}

Subscription (json):
  https://${DOMAIN}/${JSON_PATH}/${CLIENT_NAME}

HY2 direct link (fallback):
  hysteria2://${CLIENT_NAME}:${HY2_PASSWORD}@${HY2_DOMAIN}:443/?sni=${HY2_DOMAIN}#${CLIENT_NAME}

Protocols provisioned in one subId (${CLIENT_NAME}):
  vless-reality, vless-ws, vless-xhttp, trojan-grpc, hysteria2

Notes:
  - HY2 link is now appended automatically to subscription output
    when /etc/hysteria/config.yaml has auth.userpass.${CLIENT_NAME}
  - Open both TCP+UDP 443 on the VPS.
==============================================

EOF
}

main() {
  parse_args "$@"
  ensure_root

  local ip4
  ip4="$(detect_ip4)"

  if [[ "${AUTODOMAIN}" == *"y"* ]]; then
    DOMAIN="${ip4}.cdn-one.org"
    REALITY_DOMAIN="${ip4//./-}.cdn-one.org"
    HY2_DOMAIN="${DOMAIN}"
  fi

  while [[ -z "${DOMAIN}" ]]; do
    read -rp "Enter main domain (panel/ws/grpc/xhttp): " DOMAIN
  done
  while [[ -z "${REALITY_DOMAIN}" ]]; do
    read -rp "Enter reality domain: " REALITY_DOMAIN
  done
  if [[ -z "${HY2_DOMAIN}" ]]; then
    HY2_DOMAIN="${DOMAIN}"
  fi

  DOMAIN="$(echo "$DOMAIN" | tr -d '[:space:]')"
  REALITY_DOMAIN="$(echo "$REALITY_DOMAIN" | tr -d '[:space:]')"
  HY2_DOMAIN="$(echo "$HY2_DOMAIN" | tr -d '[:space:]')"
  CLIENT_NAME="$(echo "$CLIENT_NAME" | tr -d '[:space:]')"

  is_domain "$DOMAIN" || die "Invalid domain: $DOMAIN"
  is_domain "$REALITY_DOMAIN" || die "Invalid reality domain: $REALITY_DOMAIN"
  is_domain "$HY2_DOMAIN" || die "Invalid hy2 domain: $HY2_DOMAIN"
  [[ -n "$CLIENT_NAME" ]] || die "client_name cannot be empty"

  msg_inf "Checking DNS records"
  domain_ip="$(resolve_ipv4 "$DOMAIN" || true)"
  reality_ip="$(resolve_ipv4 "$REALITY_DOMAIN" || true)"
  hy2_ip="$(resolve_ipv4 "$HY2_DOMAIN" || true)"
  [[ "$domain_ip" == "$ip4" ]] || msg_warn "${DOMAIN} does not resolve to ${ip4} (continuing)"
  [[ "$reality_ip" == "$ip4" ]] || msg_warn "${REALITY_DOMAIN} does not resolve to ${ip4} (continuing)"
  [[ "$hy2_ip" == "$ip4" ]] || msg_warn "${HY2_DOMAIN} does not resolve to ${ip4} (continuing)"

  install_packages

  systemctl stop nginx >/dev/null 2>&1 || true
  fuser -k 80/tcp 443/tcp >/dev/null 2>&1 || true

  obtain_ssl "$DOMAIN"
  if [[ "$REALITY_DOMAIN" != "$DOMAIN" ]]; then
    obtain_ssl "$REALITY_DOMAIN"
  fi
  if [[ "$HY2_DOMAIN" != "$DOMAIN" && "$HY2_DOMAIN" != "$REALITY_DOMAIN" ]]; then
    obtain_ssl "$HY2_DOMAIN"
  fi

  install_panel_base
  install_fork_overlay

  SUB_PORT="$(make_port)"
  PANEL_PORT="$(make_port)"
  WS_PORT="$(make_port)"
  TROJAN_PORT="$(make_port)"

  SUB_PATH="$(gen_random_string 10)"
  JSON_PATH="$(gen_random_string 10)"
  PANEL_PATH="$(gen_random_string 10)"
  WS_PATH="$(gen_random_string 10)"
  TROJAN_PATH="$(gen_random_string 10)"
  XHTTP_PATH="$(gen_random_string 10)"

  PANEL_USERNAME="$(gen_random_string 10)"
  PANEL_PASSWORD="$(gen_random_string 14)"
  HY2_PASSWORD="$(gen_random_string 16)"

  configure_panel_and_inbounds
  setup_nginx
  setup_hysteria2
  setup_certbot_renewal
  setup_ufw

  systemctl restart x-ui
  systemctl restart nginx

  msg_ok "Bootstrap finished"
  print_summary
}

main "$@"
