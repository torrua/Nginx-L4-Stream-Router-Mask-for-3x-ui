# --- Installation Steps ---

step_os_hardening() {
    export DEBIAN_FRONTEND=noninteractive
    
    # Update package lists
    apt-get update -y
    
    # Install foundational tools (включая python3-systemd для fail2ban, python3-bcrypt для 3x-ui и sqlite3)
    apt-get install -y curl wget git jq ufw certbot fail2ban python3-systemd python3-bcrypt sqlite3 ca-certificates lsb-release gnupg sed coreutils

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
    apply_ssh_configuration "$SSH_PORT" "$SSH_ACTIVE_PORT"

    cat << EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = ${SSH_ACTIVE_PORT},${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 1h
backend = systemd
EOF
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true

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
        ufw deny "$PANEL_INTERNAL_PORT"/tcp comment '3X-UI Panel Internal' >/dev/null 2>&1 || true
    else
        ufw allow "${AWG_STANDALONE_PORT:-8445}/udp" comment 'AmneziaWG Standalone Server' >/dev/null 2>&1 || true
    fi
    
    echo "y" | ufw enable >/dev/null 2>&1 || true
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
    
    # Ensure Nginx is reloaded and active
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || systemctl restart nginx
}

# Save credentials and connection summary
