# --- Installation Steps ---

step_os_hardening() {
    export DEBIAN_FRONTEND=noninteractive
    
    # Update package lists
    apt-get update -y
    
    local extra_pkgs=""
    if is_true "${ENABLE_ZAPRET:-0}"; then
        extra_pkgs="libnetfilter-queue1 iptables"
    fi

    # Install foundational tools (включая python3-systemd для fail2ban, python3-bcrypt для 3x-ui и sqlite3)
    apt-get install -y curl wget git jq ufw certbot fail2ban python3-systemd python3-bcrypt sqlite3 ca-certificates lsb-release gnupg sed coreutils $extra_pkgs

    # 0. Инициализация Swapfile для систем с малым объемом памяти (<= 2GB)
    local total_mem_kb
    total_mem_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    if [ "$total_mem_kb" -gt 0 ] && [ "$total_mem_kb" -lt 2500000 ]; then
        if ! swapon --show 2>/dev/null | grep -q "/swapfile" || [ ! -s /swapfile ]; then
            if [ -f /swapfile ] && [ ! -s /swapfile ]; then
                swapoff /swapfile >/dev/null 2>&1 || true
                rm -f /swapfile
            fi
            if [ ! -f /swapfile ]; then
                fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
                chmod 600 /swapfile
                mkswap /swapfile >/dev/null 2>&1 || true
                swapon /swapfile >/dev/null 2>&1 || true
                if ! grep -q "^/swapfile" /etc/fstab 2>/dev/null; then
                    echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
                fi
            fi
        fi
    fi
    
    # 1. Enable BBR, Conntrack, Socket Limits & System Network Tuning
    apply_sysctl_and_limits


    # 2. SSH Configuration & Fail2ban (защита от потери доступа)
    apply_ssh_configuration "$SSH_PORT" "$SSH_ACTIVE_PORT" "${DISABLE_PASSWORD_AUTH:-n}"
    apply_fail2ban_configuration "$SSH_PORT" "$SSH_ACTIVE_PORT"

    # 3. UFW Firewall Setup & Disable IPv6 in UFW (Non-destructive)
    # Сохраняем существующие правила брандмауэра и контейнерные цепочки (отказ от деструктивного ufw --force reset)
    if [ -f /etc/default/ufw ]; then
        sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
        if grep -q "^IPV6=" /etc/default/ufw; then
            sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw 2>/dev/null || true
        else
            echo "IPV6=no" >> /etc/default/ufw 2>/dev/null || true
        fi
    fi
    ufw default deny incoming >/dev/null 2>&1 || true
    ufw default allow outgoing >/dev/null 2>&1 || true

    # КРИТИЧЕСКАЯ ЗАЩИТА: Всегда разрешаем ТЕКУЩИЙ активный порт SSH
    ufw allow "${SSH_ACTIVE_PORT}/tcp" comment 'Current SSH Port' >/dev/null 2>&1 || true

    # Если задан новый целевой порт — разрешаем и его параллельно (защита от потери доступа)
    if [ "$SSH_PORT" -ne "$SSH_ACTIVE_PORT" ]; then
        ufw allow "${SSH_PORT}/tcp" comment 'Target SSH Port' >/dev/null 2>&1 || true
    fi
    if is_true "${ENABLE_WEB_STACK:-y}"; then
        ufw allow 80/tcp comment 'HTTP / ACME' >/dev/null 2>&1 || true
        ufw allow 443/tcp comment 'HTTPS / L4 Router' >/dev/null 2>&1 || true
        ufw allow 443/udp comment 'QUIC / H3 / Hysteria 2' >/dev/null 2>&1 || true
        if is_true "${ENABLE_AWG_V3:-n}"; then
            ufw allow "${AWG_V3_PORT:-8443}/udp" comment 'AmneziaWG v3' >/dev/null 2>&1 || true
        fi
        if is_true "${ENABLE_AWG_V2:-n}"; then
            ufw allow "${AWG_V2_PORT:-8444}/udp" comment 'AmneziaWG v2' >/dev/null 2>&1 || true
        fi
        if is_true "${ENABLE_AWG_STANDALONE:-0}"; then
            ufw allow "${AWG_STANDALONE_PORT:-8445}/udp" comment 'AmneziaWG Standalone Server' >/dev/null 2>&1 || true
        fi
        if is_true "${ENABLE_SS2022:-0}"; then
            local ss_p="${SS2022_PORT:-8388}"
            ufw allow "${ss_p}/tcp" comment 'Shadowsocks 2022 TCP' >/dev/null 2>&1 || true
            ufw allow "${ss_p}/udp" comment 'Shadowsocks 2022 UDP' >/dev/null 2>&1 || true
        fi
        if is_true "${ENABLE_TUIC:-0}"; then
            local tuic_p="${TUIC_PORT:-8448}"
            ufw allow "${tuic_p}/udp" comment 'TUIC v5 QUIC' >/dev/null 2>&1 || true
        fi
        if is_true "${ENABLE_MTPROTO:-0}"; then
            local mtp_p="${MTPROTO_PORT:-8444}"
            ufw allow "${mtp_p}/tcp" comment 'Telegram MTProxy FakeTLS' >/dev/null 2>&1 || true
        fi
        if is_true "${ENABLE_MASQUE:-0}"; then
            local masque_p="${MASQUE_PORT:-8445}"
            ufw allow "${masque_p}/udp" comment 'MASQUE RFC 9484' >/dev/null 2>&1 || true
        fi
        if [[ "${HY2_PORT_HOPPING,,}" == "y" || "${HY2_PORT_HOPPING:-}" == "1" ]] && [ -n "${HY2_PORT_HOPPING_RANGE:-}" ]; then
            ufw allow "${HY2_PORT_HOPPING_RANGE//:/ }/udp" comment 'Hysteria 2 Port Hopping' >/dev/null 2>&1 || true
        fi
        
        # Deny direct access to internal 3X-UI inbound ports
        ufw deny 10443/tcp comment 'VLESS Reality Internal' >/dev/null 2>&1 || true
        ufw deny 11443/tcp comment 'Anti-Loop Stub Internal' >/dev/null 2>&1 || true
        ufw deny 55443/tcp comment 'VLESS gRPC Internal' >/dev/null 2>&1 || true
        ufw deny 45443/tcp comment 'VLESS WS Internal' >/dev/null 2>&1 || true
        ufw deny 46443/tcp comment 'VLESS Classic Internal' >/dev/null 2>&1 || true
        ufw deny 50443/tcp comment 'VLESS xHTTP Internal' >/dev/null 2>&1 || true
        ufw deny 9443/tcp  comment 'Trojan Internal' >/dev/null 2>&1 || true
        ufw deny "${SHADOWTLS_PORT:-8543}/tcp" comment 'ShadowTLS Internal' >/dev/null 2>&1 || true
        ufw deny 8542/tcp comment 'ShadowTLS Stripper Internal' >/dev/null 2>&1 || true
        ufw deny "${WSTUNNEL_PORT:-8080}/tcp" comment 'Wstunnel Internal' >/dev/null 2>&1 || true
        ufw deny "$PANEL_INTERNAL_PORT"/tcp comment '3X-UI Panel Internal' >/dev/null 2>&1 || true
    else
        ufw allow "${AWG_STANDALONE_PORT:-8445}/udp" comment 'AmneziaWG Standalone Server' >/dev/null 2>&1 || true
    fi
    
    echo "y" | ufw enable >/dev/null 2>&1 || true

    # 4. Server-Side Zapret (DPI Desync nfqws)
    if is_true "${ENABLE_ZAPRET:-0}"; then
        setup_zapret_service
    fi
}

step_install_3xui() {
    export DEBIAN_FRONTEND=noninteractive
    
    # Kill any existing service if reinstalling
    systemctl stop x-ui >/dev/null 2>&1 || true
    
    # Download and run official 3x-ui release with default quick install
    # (Все параметры: логин, пароль, порт и webBasePath настраиваются через SQLite в configure_3xui.sh)
    local ui_installer="/tmp/3x-ui-install.sh"
    rm -f "$ui_installer"
    if ! curl -fsSL --connect-timeout 15 "https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh" -o "$ui_installer" 2>/dev/null; then
        curl -fsSL --connect-timeout 15 "https://ghfast.top/https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh" -o "$ui_installer" 2>/dev/null || true
    fi
    
    if [ -f "$ui_installer" ]; then
        printf "n\n" | bash "$ui_installer" >/dev/null 2>&1 || true
        rm -f "$ui_installer"
    else
        printf "n\n" | bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) >/dev/null 2>&1 || true
    fi

    # Allow service to settle
    sleep 2
    systemctl enable x-ui >/dev/null 2>&1 || true
    systemctl restart x-ui >/dev/null 2>&1 || true
}

step_install_nginx_and_mask() {
    # Download scripts from repository into /root if not present
    mkdir -p /root/nginx_mask_setup
    cd /root/nginx_mask_setup
    
    if [ -f "${SCRIPT_DIR}/setup_mask.sh" ]; then
        cp "${SCRIPT_DIR}/setup_mask.sh" ./setup_mask.sh
    else
        wget -qO setup_mask.sh "${REPO_URL}/setup_mask.sh"
    fi
    if [ -f "${SCRIPT_DIR}/configure_3xui.sh" ]; then
        cp "${SCRIPT_DIR}/configure_3xui.sh" ./configure_3xui.sh
    else
        wget -qO configure_3xui.sh "${REPO_URL}/configure_3xui.sh"
    fi
    chmod +x setup_mask.sh configure_3xui.sh
    
    # Download decoy template if needed
    if [ -f "${SCRIPT_DIR}/site.tar.gz" ]; then
        cp "${SCRIPT_DIR}/site.tar.gz" /root/nginx_mask_setup/
    fi

    # Run setup_mask.sh in automated mode with explicit admin credentials
    export ADMIN_USERNAME="$PANEL_USER"
    export ADMIN_PASSWORD="$PANEL_PASS"
    export PANEL_PORT="$PANEL_INTERNAL_PORT"
    export PANEL_PATH="/$PANEL_SECRET/"
    export SUB_PATH="/$SUB_SECRET/"
    export SUB_TITLE="${SUB_TITLE:-}"
    export XHTTP_STREAM_PATH="/$XHTTP_SECRET/"

    bash ./setup_mask.sh --auto \
        --domain "$PRIMARY_DOMAIN" \
        --email "$LE_EMAIL" \
        --no-www \
        --hy2 \
        --panel-port "$PANEL_INTERNAL_PORT" \
        --panel-path "/$PANEL_SECRET/" \
        --sub-path "/$SUB_SECRET/" \
        --sub-title "${SUB_TITLE:-}" \
        --xhttp-path "/$XHTTP_SECRET/" \
        --user "$PANEL_USER" \
        --pass "$PANEL_PASS" || die "Ошибка при развертывании маскировки Nginx (setup_mask.sh)."
}

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

    local masque_p="${MASQUE_PORT:-8445}"
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
}

step_configure_inbounds() {
    cd /root/nginx_mask_setup
    if [ -f "./configure_3xui.sh" ]; then
        export ADMIN_USERNAME="$PANEL_USER"
        export ADMIN_PASSWORD="$PANEL_PASS"
        export PANEL_PORT="$PANEL_INTERNAL_PORT"
        export PANEL_PATH="/$PANEL_SECRET/"
        export SUB_PATH="/$SUB_SECRET/"
        export SUB_TITLE="${SUB_TITLE:-}"
        export XHTTP_STREAM_PATH="/$XHTTP_SECRET/"
        local cfg_arg=()
        [ -f "/root/nginx_mask_setup/setup_mask.env" ] && cfg_arg=(--config "/root/nginx_mask_setup/setup_mask.env")
        bash ./configure_3xui.sh --non-interactive --domain "$PRIMARY_DOMAIN" "${cfg_arg[@]}" || true
    fi
    
    # Развертывание сервисов нового поколения (Zapret, MASQUE, ShadowTLS, Wstunnel)
    deploy_native_nextgen_services

    # Ensure Nginx is reloaded and active
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || systemctl restart nginx
}

# Save credentials and connection summary
