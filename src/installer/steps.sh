setup_zapret_service() {
    log "Настройка службы Server-Side Zapret nfqws..."
    local cur_arch
    cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
    local z_arch="x86_64"
    case "$cur_arch" in
        x86_64|amd64) z_arch="x86_64" ;;
        aarch64|arm64) z_arch="aarch64" ;;
        *) z_arch="x86_64" ;;
    esac

    local bin_dir="${LOCAL_BIN_DIR:-/usr/local/bin}"
    [ -d "$bin_dir" ] || mkdir -p "$bin_dir" 2>/dev/null || true

    if [ ! -x "${bin_dir}/nfqws" ]; then
        local z_ver="${ZAPRET_VERSION:-v69.2}"
        local z_tmp="/tmp/zapret_${z_ver}"
        mkdir -p "$z_tmp"
        if curl -fsSL --connect-timeout 15 "https://github.com/bol-van/zapret/releases/download/${z_ver}/zapret-${z_ver}.tar.gz" -o "$z_tmp/zapret.tar.gz" 2>/dev/null || \
           curl -fsSL --connect-timeout 15 "https://ghfast.top/https://github.com/bol-van/zapret/releases/download/${z_ver}/zapret-${z_ver}.tar.gz" -o "$z_tmp/zapret.tar.gz" 2>/dev/null; then
            tar -zxf "$z_tmp/zapret.tar.gz" -C "$z_tmp" --strip-components=1 2>/dev/null || true
            if [ -f "$z_tmp/binaries/${z_arch}/nfqws" ]; then
                cp "$z_tmp/binaries/${z_arch}/nfqws" "${bin_dir}/nfqws"
                chmod +x "${bin_dir}/nfqws"
            elif [ -n "$(find "$z_tmp" -name nfqws -type f 2>/dev/null)" ]; then
                cp "$(find "$z_tmp" -name nfqws -type f | grep "${z_arch}" | head -n1 || find "$z_tmp" -name nfqws -type f | head -n1)" "${bin_dir}/nfqws"
                chmod +x "${bin_dir}/nfqws"
            elif [ -d "$z_tmp/nfqws" ]; then
                make -C "$z_tmp/nfqws" >/dev/null 2>&1 || true
                if [ -f "$z_tmp/nfqws/nfqws" ]; then
                    cp "$z_tmp/nfqws/nfqws" "${bin_dir}/nfqws"
                    chmod +x "${bin_dir}/nfqws"
                fi
            fi
        fi
        rm -rf "$z_tmp" 2>/dev/null || true
    fi

    local qnum="${ZAPRET_QNUM:-200}"
    local desync="${ZAPRET_DESYNC:-split2}"
    local fooling="${ZAPRET_FOOLING:-md5sig,badseq}"
    local iptables_bin
    iptables_bin="$(command -v iptables 2>/dev/null || echo "/usr/sbin/iptables")"

    mkdir -p /etc/systemd/system
    cat << EOF > /etc/systemd/system/zapret-server.service
[Unit]
Description=Server-Side Zapret nfqws DPI Desync Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-${iptables_bin} -t mangle -D POSTROUTING -p tcp -m connbytes --connbytes 1:6 --connbytes-mode packets --connbytes-dir original -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num ${qnum} --queue-bypass
ExecStartPre=${iptables_bin} -t mangle -I POSTROUTING -p tcp -m connbytes --connbytes 1:6 --connbytes-mode packets --connbytes-dir original -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num ${qnum} --queue-bypass
ExecStart=${bin_dir}/nfqws --qnum=${qnum} --dpi-desync=${desync} --dpi-desync-fooling=${fooling}
ExecStopPost=-${iptables_bin} -t mangle -D POSTROUTING -p tcp -m connbytes --connbytes 1:6 --connbytes-mode packets --connbytes-dir original -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num ${qnum} --queue-bypass
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable zapret-server >/dev/null 2>&1 || true
        if [ -x "${bin_dir}/nfqws" ]; then
            systemctl restart zapret-server 2>/dev/null || true
            ok "Служба Server-Side Zapret активирована (NFQUEUE $qnum, desync: $desync)."
        else
            warn "Бинарник ${bin_dir}/nfqws не найден, запуск zapret-server отложен."
        fi
    fi
}

setup_masque_service() {
    log "Настройка службы Sing-box MASQUE (RFC 9484 / RFC 9298)..."
    local cur_arch
    cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
    local sb_arch="amd64"
    case "$cur_arch" in
        x86_64|amd64) sb_arch="amd64" ;;
        aarch64|arm64) sb_arch="arm64" ;;
        *) sb_arch="amd64" ;;
    esac

    local bin_dir="${LOCAL_BIN_DIR:-/usr/local/bin}"
    [ -d "$bin_dir" ] || mkdir -p "$bin_dir" 2>/dev/null || true

    if [ ! -x "${bin_dir}/sing-box" ]; then
        local sb_ver="1.11.4"
        local sb_tmp="/tmp/sing-box_${sb_ver}"
        mkdir -p "$sb_tmp"
        if curl -fsSL --connect-timeout 15 "https://github.com/SagerNet/sing-box/releases/download/v${sb_ver}/sing-box-${sb_ver}-linux-${sb_arch}.tar.gz" -o "$sb_tmp/sb.tar.gz" 2>/dev/null || \
           curl -fsSL --connect-timeout 15 "https://ghfast.top/https://github.com/SagerNet/sing-box/releases/download/v${sb_ver}/sing-box-${sb_ver}-linux-${sb_arch}.tar.gz" -o "$sb_tmp/sb.tar.gz" 2>/dev/null; then
            tar -zxf "$sb_tmp/sb.tar.gz" -C "$sb_tmp" --strip-components=1 2>/dev/null || true
            if [ -f "$sb_tmp/sing-box" ]; then
                cp "$sb_tmp/sing-box" "${bin_dir}/sing-box"
                chmod +x "${bin_dir}/sing-box"
            elif [ -n "$(find "$sb_tmp" -name sing-box -type f 2>/dev/null)" ]; then
                cp "$(find "$sb_tmp" -name sing-box -type f | head -n1)" "${bin_dir}/sing-box"
                chmod +x "${bin_dir}/sing-box"
            fi
        fi
        rm -rf "$sb_tmp" 2>/dev/null || true
    fi

    local masque_p="${MASQUE_PORT:-8449}"
    local masque_u="${MASQUE_USER:-client}"
    local masque_pw="${MASQUE_PASSWORD:-}"
    local cert_file="${SSL_BASE_DIR:-/etc/letsencrypt/live}/${PRIMARY_DOMAIN}/fullchain.pem"
    local key_file="${SSL_BASE_DIR:-/etc/letsencrypt/live}/${PRIMARY_DOMAIN}/privkey.pem"

    mkdir -p /etc/sing-box
    cat << EOF > /etc/sing-box/masque.json
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "masque",
      "tag": "masque-in",
      "listen": "::",
      "listen_port": ${masque_p},
      "tcp_fast_open": true,
      "sniff": true,
      "sniff_override_destination": true,
      "users": [
        {
          "username": "${masque_u}",
          "password": "${masque_pw}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${PRIMARY_DOMAIN}",
        "certificate_path": "${cert_file}",
        "key_path": "${key_file}",
        "alpn": ["h3"]
      },
      "connect_udp": {
        "enabled": true,
        "uri_template": "/.well-known/masque/udp/{target_host}/{target_port}/"
      },
      "connect_ip": {
        "enabled": true,
        "uri_template": "/.well-known/masque/ip/"
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
    "rules": [
      {
        "port": 25,
        "outbound": "block"
      },
      {
        "ip_is_private": true,
        "outbound": "block"
      }
    ],
    "final": "direct"
  }
}
EOF

    mkdir -p /etc/systemd/system
    cat << EOF > /etc/systemd/system/sing-box-masque.service
[Unit]
Description=Sing-box MASQUE (RFC 9484 / RFC 9298) Daemon
After=network.target network-online.target

[Service]
Type=simple
ExecStart=${bin_dir}/sing-box run -c /etc/sing-box/masque.json
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable sing-box-masque >/dev/null 2>&1 || true
        if [ -x "${bin_dir}/sing-box" ]; then
            systemctl restart sing-box-masque 2>/dev/null || true
            ok "Служба Sing-box MASQUE активирована (порт ${masque_p}/udp, H3/QUIC)."
        else
            warn "Бинарник ${bin_dir}/sing-box не найден, запуск sing-box-masque отложен."
        fi
    fi
}

setup_shadowtls_service() {
    log "Настройка службы ShadowTLS v4..."
    local cur_arch
    cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
    local st_arch="x86_64"
    case "$cur_arch" in
        x86_64|amd64) st_arch="x86_64" ;;
        aarch64|arm64) st_arch="aarch64" ;;
        *) st_arch="x86_64" ;;
    esac

    local bin_dir="${LOCAL_BIN_DIR:-/usr/local/bin}"
    [ -d "$bin_dir" ] || mkdir -p "$bin_dir" 2>/dev/null || true

    if [ ! -x "${bin_dir}/shadow-tls" ]; then
        if curl -fsSL --connect-timeout 15 "https://github.com/ihciah/shadow-tls/releases/latest/download/shadow-tls-${st_arch}-unknown-linux-musl" -o "${bin_dir}/shadow-tls" 2>/dev/null || \
           curl -fsSL --connect-timeout 15 "https://ghfast.top/https://github.com/ihciah/shadow-tls/releases/latest/download/shadow-tls-${st_arch}-unknown-linux-musl" -o "${bin_dir}/shadow-tls" 2>/dev/null; then
            chmod +x "${bin_dir}/shadow-tls"
        fi
    fi

    local st_port="${SHADOWTLS_PORT:-8543}"
    local ss_backend_port="${SS2022_PORT:-8388}"
    local st_sni="${SHADOWTLS_SNI:-gateway.icloud.com}"
    local st_pwd="${SHADOWTLS_PASSWORD:-}"

    mkdir -p /etc/systemd/system
    cat << EOF > /etc/systemd/system/shadow-tls.service
[Unit]
Description=ShadowTLS v4 Stealth SNI Decoy Gateway
After=network.target network-online.target

[Service]
Type=simple
ExecStart=${bin_dir}/shadow-tls --v3 server --listen 127.0.0.1:${st_port} --server 127.0.0.1:${ss_backend_port} --tls ${st_sni}:443 --password ${st_pwd}
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable shadow-tls >/dev/null 2>&1 || true
        if [ -x "${bin_dir}/shadow-tls" ]; then
            systemctl restart shadow-tls 2>/dev/null || true
            ok "Служба ShadowTLS v4 активирована (порт ${st_port}, decoy: ${st_sni})."
        else
            warn "Бинарник ${bin_dir}/shadow-tls не найден, запуск shadow-tls отложен."
        fi
    fi
}

setup_wstunnel_service() {
    log "Настройка службы Wstunnel L7..."
    local cur_arch
    cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
    local ws_arch="amd64"
    case "$cur_arch" in
        x86_64|amd64) ws_arch="amd64" ;;
        aarch64|arm64) ws_arch="arm64" ;;
        *) ws_arch="amd64" ;;
    esac

    local bin_dir="${LOCAL_BIN_DIR:-/usr/local/bin}"
    [ -d "$bin_dir" ] || mkdir -p "$bin_dir" 2>/dev/null || true

    if [ ! -x "${bin_dir}/wstunnel" ]; then
        local ws_ver="11.0.0"
        local ws_tmp="/tmp/wstunnel_${ws_ver}"
        mkdir -p "$ws_tmp"
        if curl -fsSL --connect-timeout 15 "https://github.com/erebe/wstunnel/releases/download/v${ws_ver}/wstunnel_${ws_ver}_linux_${ws_arch}.tar.gz" -o "$ws_tmp/ws.tar.gz" 2>/dev/null || \
           curl -fsSL --connect-timeout 15 "https://ghfast.top/https://github.com/erebe/wstunnel/releases/download/v${ws_ver}/wstunnel_${ws_ver}_linux_${ws_arch}.tar.gz" -o "$ws_tmp/ws.tar.gz" 2>/dev/null; then
            tar -zxf "$ws_tmp/ws.tar.gz" -C "$ws_tmp" 2>/dev/null || true
            if [ -f "$ws_tmp/wstunnel" ]; then
                cp "$ws_tmp/wstunnel" "${bin_dir}/wstunnel"
                chmod +x "${bin_dir}/wstunnel"
            elif [ -n "$(find "$ws_tmp" -name wstunnel -type f 2>/dev/null)" ]; then
                cp "$(find "$ws_tmp" -name wstunnel -type f | head -n1)" "${bin_dir}/wstunnel"
                chmod +x "${bin_dir}/wstunnel"
            fi
        fi
        rm -rf "$ws_tmp" 2>/dev/null || true
    fi

    local ws_port="${WSTUNNEL_PORT:-8080}"
    local ws_prefix="${WSTUNNEL_PREFIX#/}"
    ws_prefix="${ws_prefix%/}"

    mkdir -p /etc/systemd/system
    cat << EOF > /etc/systemd/system/wstunnel.service
[Unit]
Description=Wstunnel L7 WebSocket Tunnel Daemon
After=network.target network-online.target

[Service]
Type=simple
ExecStart=${bin_dir}/wstunnel server --restrict-http-upgrade-path-prefix ${ws_prefix} ws://127.0.0.1:${ws_port}
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable wstunnel >/dev/null 2>&1 || true
        if [ -x "${bin_dir}/wstunnel" ]; then
            systemctl restart wstunnel 2>/dev/null || true
            ok "Служба Wstunnel L7 активирована (порт ${ws_port}, prefix: /${ws_prefix}/)."
        else
            warn "Бинарник ${bin_dir}/wstunnel не найден, запуск wstunnel отложен."
        fi
    fi
}

setup_naive_service() {
    log "Настройка службы NaïveProxy (Caddy forwardproxy@naive)..."
    local cur_arch
    cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
    local caddy_arch="amd64"
    case "$cur_arch" in
        x86_64|amd64) caddy_arch="amd64" ;;
        aarch64|arm64) caddy_arch="arm64" ;;
        *) caddy_arch="amd64" ;;
    esac

    local bin_dir="${LOCAL_BIN_DIR:-/usr/local/bin}"
    [ -d "$bin_dir" ] || mkdir -p "$bin_dir" 2>/dev/null || true

    local caddy_bin="${bin_dir}/caddy-naive"
    if [ ! -x "$caddy_bin" ] && [ -x "${bin_dir}/caddy" ]; then
        caddy_bin="${bin_dir}/caddy"
    fi
    if [ ! -x "$caddy_bin" ] && command -v caddy-naive >/dev/null 2>&1; then
        caddy_bin="$(command -v caddy-naive)"
    fi
    if [ ! -x "$caddy_bin" ] && command -v caddy >/dev/null 2>&1; then
        caddy_bin="$(command -v caddy)"
    fi

    if [ ! -x "$caddy_bin" ]; then
        local caddy_tmp="/tmp/caddy_naive_$$"
        mkdir -p "$caddy_tmp"
        local rel_ver="${SCRIPT_VERSION:-v8.1.0}"
        [[ "$rel_ver" == "__VERSION__" ]] && rel_ver="v8.1.0"
        [[ "$rel_ver" != v* ]] && rel_ver="v${rel_ver}"
        local dl_url="https://github.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/releases/download/${rel_ver}/caddy-naive-linux-${caddy_arch}.tar.gz"
        local dl_mirror="https://ghfast.top/${dl_url}"
        if curl -fsSL --connect-timeout 15 "$dl_url" -o "$caddy_tmp/caddy.tar.gz" 2>/dev/null || \
           curl -fsSL --connect-timeout 15 "$dl_mirror" -o "$caddy_tmp/caddy.tar.gz" 2>/dev/null; then
            tar -zxf "$caddy_tmp/caddy.tar.gz" -C "$caddy_tmp" 2>/dev/null || true
            if [ -f "$caddy_tmp/caddy-naive" ]; then
                cp "$caddy_tmp/caddy-naive" "${bin_dir}/caddy-naive"
                chmod +x "${bin_dir}/caddy-naive"
                caddy_bin="${bin_dir}/caddy-naive"
            elif [ -f "$caddy_tmp/caddy" ]; then
                cp "$caddy_tmp/caddy" "${bin_dir}/caddy-naive"
                chmod +x "${bin_dir}/caddy-naive"
                caddy_bin="${bin_dir}/caddy-naive"
            fi
        fi
        rm -rf "$caddy_tmp" 2>/dev/null || true
    fi

    local naive_port="${NAIVE_PORT:-8446}"
    local naive_user="${NAIVE_USER:-user}"
    local naive_pass="${NAIVE_PASS:-}"
    if [ -z "$naive_pass" ]; then
        naive_pass="$(generate_urlsafe_token 16)"
        NAIVE_PASS="$naive_pass"
    fi
    export NAIVE_PASS="$naive_pass"

    local naive_domain="${NAIVE_DOMAIN:-naive.${PRIMARY_DOMAIN:-}}"
    if [ -z "$naive_domain" ] || [ "$naive_domain" = "${PRIMARY_DOMAIN:-}" ]; then
        if [ -n "${PRIMARY_DOMAIN:-}" ]; then
            naive_domain="naive.${PRIMARY_DOMAIN}"
        else
            naive_domain="localhost"
        fi
    fi
    NAIVE_DOMAIN="$naive_domain"
    export NAIVE_DOMAIN="$naive_domain"

    mkdir -p /etc/caddy /etc/naiveproxy /var/www/html 2>/dev/null || true
    if [ ! -f /var/www/html/index.html ]; then
        echo "<!DOCTYPE html><html><head><title>Welcome</title></head><body><h1>Welcome to Nginx Stream Mask</h1></body></html>" > /var/www/html/index.html 2>/dev/null || true
    fi

    local tls_directive="tls internal"
    local cert_candidates=()
    [ -n "$naive_domain" ] && [ "$naive_domain" != "localhost" ] && cert_candidates+=("$naive_domain")
    [ -n "${PRIMARY_DOMAIN:-}" ] && cert_candidates+=("${PRIMARY_DOMAIN}")
    [ -n "${DOMAIN:-}" ] && cert_candidates+=("${DOMAIN}")

    for c_dom in "${cert_candidates[@]}"; do
        if [ -f "/etc/letsencrypt/live/${c_dom}/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/${c_dom}/privkey.pem" ]; then
            tls_directive="tls /etc/letsencrypt/live/${c_dom}/fullchain.pem /etc/letsencrypt/live/${c_dom}/privkey.pem"
            break
        elif [ -f "/etc/ssl/acme/${c_dom}/fullchain.pem" ] && [ -f "/etc/ssl/acme/${c_dom}/privkey.pem" ]; then
            tls_directive="tls /etc/ssl/acme/${c_dom}/fullchain.pem /etc/ssl/acme/${c_dom}/privkey.pem"
            break
        fi
    done

    cat << EOF > /etc/caddy/Caddyfile
{
  order forward_proxy before reverse_proxy
  admin off
}

:${naive_port} {
  bind 127.0.0.1
  ${tls_directive}

  forward_proxy {
    basic_auth ${naive_user} ${naive_pass}
    hide_ip
    hide_via
    probe_resistance
  }

  file_server {
    root /var/www/html
  }
}
EOF
    cp -f /etc/caddy/Caddyfile /etc/naiveproxy/Caddyfile 2>/dev/null || true

    mkdir -p /etc/systemd/system
    cat << EOF > /etc/systemd/system/caddy-naive.service
[Unit]
Description=Caddy NaïveProxy Server Daemon
After=network.target network-online.target

[Service]
Type=simple
ExecStart=${caddy_bin} run --config /etc/caddy/Caddyfile --adapter caddyfile
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable caddy-naive >/dev/null 2>&1 || true
        if [ -x "$caddy_bin" ]; then
            systemctl restart caddy-naive 2>/dev/null || true
            ok "Служба NaïveProxy активирована (порт ${naive_port}, user: ${naive_user})."
        else
            warn "Бинарник ${caddy_bin} не найден, запуск caddy-naive отложен."
        fi
    fi
}

setup_dnstt_service() {
    log "Настройка службы DNSTT (DoH DNS Tunneling)..."
    local cur_arch
    cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
    local dnstt_arch="amd64"
    case "$cur_arch" in
        x86_64|amd64) dnstt_arch="amd64" ;;
        aarch64|arm64) dnstt_arch="arm64" ;;
        *) dnstt_arch="amd64" ;;
    esac

    local bin_dir="${LOCAL_BIN_DIR:-/usr/local/bin}"
    [ -d "$bin_dir" ] || mkdir -p "$bin_dir" 2>/dev/null || true

    local dnstt_bin="${bin_dir}/dnstt-server"
    if [ ! -x "$dnstt_bin" ] && command -v dnstt-server >/dev/null 2>&1; then
        dnstt_bin="$(command -v dnstt-server)"
    fi

    if [ ! -x "$dnstt_bin" ]; then
        local dnstt_tmp="/tmp/dnstt_$$"
        mkdir -p "$dnstt_tmp"
        local rel_ver="${SCRIPT_VERSION:-v8.1.0}"
        [[ "$rel_ver" == "__VERSION__" ]] && rel_ver="v8.1.0"
        [[ "$rel_ver" != v* ]] && rel_ver="v${rel_ver}"
        local dl_url="https://github.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/releases/download/${rel_ver}/dnstt-server-linux-${dnstt_arch}.tar.gz"
        local dl_mirror="https://ghfast.top/${dl_url}"
        if curl -fsSL --connect-timeout 15 "$dl_url" -o "$dnstt_tmp/dnstt.tar.gz" 2>/dev/null || \
           curl -fsSL --connect-timeout 15 "$dl_mirror" -o "$dnstt_tmp/dnstt.tar.gz" 2>/dev/null; then
            tar -zxf "$dnstt_tmp/dnstt.tar.gz" -C "$dnstt_tmp" 2>/dev/null || true
            if [ -f "$dnstt_tmp/dnstt-server" ]; then
                cp "$dnstt_tmp/dnstt-server" "${bin_dir}/dnstt-server"
                chmod +x "${bin_dir}/dnstt-server"
                dnstt_bin="${bin_dir}/dnstt-server"
            fi
        fi
        rm -rf "$dnstt_tmp" 2>/dev/null || true
    fi

    local dnstt_port="${DNSTT_PORT:-53053}"
    local ss_backend_port="${SS2022_PORT:-8388}"
    local dnstt_domain="${DNSTT_DOMAIN:-t.${PRIMARY_DOMAIN:-example.com}}"

    mkdir -p /etc/dnstt
    chmod 700 /etc/dnstt 2>/dev/null || true

    if [ ! -f /etc/dnstt/server.key ] || [ ! -f /etc/dnstt/server.pub ]; then
        if [ -x "$dnstt_bin" ]; then
            "$dnstt_bin" -gen-key -privkey-file /etc/dnstt/server.key -pubkey-file /etc/dnstt/server.pub 2>/dev/null || true
        fi
        if [ ! -f /etc/dnstt/server.key ] || [ ! -f /etc/dnstt/server.pub ]; then
            python3 -c "
import os
P = 2**255 - 19
A24 = 121665
def clamp(k_bytes):
    b = bytearray(k_bytes)
    b[0] &= 248
    b[31] &= 127
    b[31] |= 64
    return int.from_bytes(b, 'little')
def x25519(k, u=9):
    x1, x2, z2, x3, z3 = u, 1, 0, u, 1
    for i in range(254, -1, -1):
        bit = (k >> i) & 1
        if bit: x2, x3 = x3, x2; z2, z3 = z3, z2
        A = (x2 + z2) % P; AA = (A * A) % P; B = (x2 - z2) % P; BB = (B * B) % P; E = (AA - BB) % P
        C = (x3 + z3) % P; D = (x3 - z3) % P; DA = (D * A) % P; CB = (C * B) % P
        x3 = pow(DA + CB, 2, P); z3 = (x1 * pow(DA - CB, 2, P)) % P; x2 = (AA * BB) % P; z2 = (E * (AA + A24 * E)) % P
        if bit: x2, x3 = x3, x2; z2, z3 = z3, z2
    return (x2 * pow(z2, P - 2, P)) % P
raw_priv = os.urandom(32)
k = clamp(raw_priv)
pub = ((x25519(k, 9)) % P).to_bytes(32, 'little').hex()
with open('/etc/dnstt/server.key', 'w') as kf:
    kf.write(raw_priv.hex() + '\n')
with open('/etc/dnstt/server.pub', 'w') as pf:
    pf.write(pub + '\n')
" 2>/dev/null || {
                head /dev/urandom 2>/dev/null | tr -dc 0-9a-f | head -c 64 > /etc/dnstt/server.key 2>/dev/null || echo "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" > /etc/dnstt/server.key
                head /dev/urandom 2>/dev/null | tr -dc 0-9a-f | head -c 64 > /etc/dnstt/server.pub 2>/dev/null || echo "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210" > /etc/dnstt/server.pub
            }
        fi
        chmod 600 /etc/dnstt/server.key /etc/dnstt/server.pub 2>/dev/null || true
    fi

    DNSTT_PUBKEY="$(cat /etc/dnstt/server.pub 2>/dev/null | tr -d '[:space:]')"
    export DNSTT_PUBKEY

    mkdir -p /etc/systemd/system
    cat << EOF > /etc/systemd/system/dnstt-server.service
[Unit]
Description=DNSTT DNS Tunneling Server Daemon (DoH / UDP)
After=network.target network-online.target

[Service]
Type=simple
ExecStart=${dnstt_bin} -udp 0.0.0.0:${dnstt_port} -privkey-file /etc/dnstt/server.key ${dnstt_domain} 127.0.0.1:${ss_backend_port}
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable dnstt-server >/dev/null 2>&1 || true
        if [ -x "$dnstt_bin" ]; then
            systemctl restart dnstt-server 2>/dev/null || true
            ok "Служба DNSTT активирована (порт ${dnstt_port}/udp, домен: ${dnstt_domain})."
        else
            warn "Бинарник ${dnstt_bin} не найден, запуск dnstt-server отложен."
        fi
    fi
}

setup_mieru_service() {
    log "Настройка службы Mieru Proxy (mita)..."
    local cur_arch
    cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
    local mita_arch="amd64"
    case "$cur_arch" in
        x86_64|amd64) mita_arch="amd64" ;;
        aarch64|arm64) mita_arch="arm64" ;;
        *) mita_arch="amd64" ;;
    esac

    local bin_dir="${LOCAL_BIN_DIR:-/usr/local/bin}"
    [ -d "$bin_dir" ] || mkdir -p "$bin_dir" 2>/dev/null || true

    local mita_bin="${bin_dir}/mita"
    if [ ! -x "$mita_bin" ] && command -v mita >/dev/null 2>&1; then
        mita_bin="$(command -v mita)"
    fi

    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-ntp true 2>/dev/null || true
        systemctl restart systemd-timesyncd 2>/dev/null || true
    fi

    if [ ! -x "$mita_bin" ]; then
        local mita_ver="3.38.1"
        local mita_tmp="/tmp/mita_${mita_ver}_$$"
        mkdir -p "$mita_tmp"
        local dl_url="https://github.com/enfein/mieru/releases/download/v${mita_ver}/mita_${mita_ver}_linux_${mita_arch}.tar.gz"
        local dl_mirror="https://ghfast.top/${dl_url}"
        if curl -fsSL --connect-timeout 15 "$dl_url" -o "$mita_tmp/mita.tar.gz" 2>/dev/null || \
           curl -fsSL --connect-timeout 15 "$dl_mirror" -o "$mita_tmp/mita.tar.gz" 2>/dev/null; then
            tar -zxf "$mita_tmp/mita.tar.gz" -C "$mita_tmp" 2>/dev/null || true
            if [ -f "$mita_tmp/mita" ]; then
                cp "$mita_tmp/mita" "${bin_dir}/mita"
                chmod +x "${bin_dir}/mita"
                mita_bin="${bin_dir}/mita"
            fi
        fi
        rm -rf "$mita_tmp" 2>/dev/null || true
    fi

    if [ ! -x "$mita_bin" ]; then
        warn "Не удалось загрузить бинарник mita. Установка Mieru пропущена."
        return 0
    fi

    if ! id -u mita >/dev/null 2>&1; then
        useradd --system --no-create-home --user-group mita 2>/dev/null || true
    fi
    mkdir -p /etc/mita /var/lib/mita /var/run/mita
    chown -R mita:mita /etc/mita /var/lib/mita /var/run/mita 2>/dev/null || true
    chmod 775 /etc/mita /var/lib/mita /var/run/mita 2>/dev/null || true

    local m_port_mode="${MIERU_PORT_MODE:-single}"
    local m_port="${MIERU_PORT:-8450}"
    local m_user="${MIERU_USER:-user-default}"
    local m_pass="${MIERU_PASS:-pass-default}"
    local m_trans="${MIERU_TRANSPORT:-BOTH}"
    local m_mtu="${MIERU_MTU:-1400}"

    python3 -c "
import json
port_mode = '$m_port_mode'.lower()
port_val = '$m_port'.strip()
transport = '$m_trans'.upper()

protocols = ['TCP', 'UDP'] if transport == 'BOTH' else [transport]
port_bindings = []

for proto in protocols:
    if port_mode == 'range' or '-' in port_val:
        port_bindings.append({'portRange': port_val, 'protocol': proto})
    else:
        clean_p = int(port_val.split('-')[0].split(':')[0])
        port_bindings.append({'port': clean_p, 'protocol': proto})

config = {
    'portBindings': port_bindings,
    'users': [{
        'name': '$m_user',
        'password': '$m_pass'
    }],
    'loggingLevel': 'INFO',
    'mtu': int('$m_mtu'),
    'dns': {
        'dualStack': 'PREFER_IPv4'
    }
}

for path in ['/etc/mita/config.json', '/etc/mita_server_config.json']:
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(config, f, indent=2)
" 2>/dev/null || true

    chown mita:mita /etc/mita/config.json /etc/mita_server_config.json 2>/dev/null || true
    chmod 600 /etc/mita/config.json /etc/mita_server_config.json 2>/dev/null || true

    mkdir -p /etc/systemd/system
    cat << EOF > /etc/systemd/system/mita.service
[Unit]
Description=Mieru proxy server (mita)
After=network-online.target network.service systemd-timesyncd.service
Wants=network-online.target systemd-timesyncd.service
StartLimitBurst=5
StartLimitIntervalSec=60

[Service]
Type=exec
User=mita
Group=mita
AmbientCapabilities=CAP_NET_BIND_SERVICE
Environment="MITA_LOG_NO_TIMESTAMP=true"
ExecStartPre=+/bin/sh -c 'mkdir -p /var/run/mita && chown -R mita:mita /var/run/mita && chmod 775 /var/run/mita'
ExecStart=${mita_bin} run
Nice=-10
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    if command -v ufw >/dev/null 2>&1; then
        local ufw_m_port="${m_port//-/:}"
        if [ "$m_trans" = "BOTH" ] || [ "$m_trans" = "TCP" ]; then
            ufw allow "${ufw_m_port}/tcp" comment 'VPN: Mieru TCP' 2>/dev/null || true
        fi
        if [ "$m_trans" = "BOTH" ] || [ "$m_trans" = "UDP" ]; then
            ufw allow "${ufw_m_port}/udp" comment 'VPN: Mieru UDP' 2>/dev/null || true
        fi
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable mita >/dev/null 2>&1 || true
        if systemctl restart mita 2>/dev/null; then
            sleep 1
            if [ -x "$mita_bin" ] && [ -f /etc/mita_server_config.json ]; then
                "$mita_bin" apply config /etc/mita_server_config.json 2>/dev/null || true
            fi
            if systemctl is-active --quiet mita; then
                ok "Служба Mieru (mita) успешно запущена (порт ${m_port}, XChaCha20-Poly1305)."
            else
                warn "Служба Mieru не перешла в статус active. Проверьте: journalctl -u mita -n 20"
            fi
        else
            warn "Ошибка запуска службы mita.service. Проверьте: journalctl -u mita -n 20"
        fi
    fi
}

deploy_native_nextgen_services() {
    if is_true "${ENABLE_ZAPRET:-0}"; then
        setup_zapret_service
    fi
    if is_true "${ENABLE_MASQUE:-0}"; then
        setup_masque_service
    fi
    if is_true "${ENABLE_SHADOWTLS:-0}"; then
        setup_shadowtls_service
    fi
    if is_true "${ENABLE_WSTUNNEL:-0}"; then
        setup_wstunnel_service
    fi
    if is_true "${ENABLE_NAIVE:-0}"; then
        setup_naive_service
    fi
    if is_true "${ENABLE_DNSTT:-0}"; then
        setup_dnstt_service
    fi
    if is_true "${ENABLE_MIERU:-0}"; then
        setup_mieru_service
    fi
}
