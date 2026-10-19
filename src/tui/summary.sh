# =============================================================
#  ФОРМИРОВАНИЕ ИТОГОВ И ИНСТРУКЦИИ ДЛЯ 3X-UI
# =============================================================
UFW_DENY_LIST=""
for port in "${ALL_REALITY_PORTS[@]:-}"; do
    if [ -n "$port" ]; then
        UFW_DENY_LIST="${UFW_DENY_LIST} && ufw deny ${port}/tcp"
    fi
done

UFW_ALLOW_LIST="ufw allow 80/tcp && ufw allow 443/tcp"
if [[ "${ENABLE_HY2:-}" == "1" || "${ENABLE_HY2,,}" == "y" ]] && [ -n "${HY2_PORT:-}" ]; then
    if [ "${HY2_PORT}" != "443" ]; then
        UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${HY2_PORT}/udp"
    else
        UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow 443/udp"
    fi
    # Port Hopping: открываем диапазон UDP-портов
    if [[ "${HY2_PORT_HOPPING,,}" == "y" || "${HY2_PORT_HOPPING:-}" == "1" ]] && [ -n "${HY2_PORT_HOPPING_RANGE:-}" ]; then
        UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${HY2_PORT_HOPPING_RANGE//:/ }/udp"
    fi
fi
if [[ "${ENABLE_AWG_V3:-}" == "1" || "${ENABLE_AWG_V3,,}" == "y" ]] && [ -n "${AWG_V3_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${AWG_V3_PORT}/udp"
fi
if [[ "${ENABLE_AWG_V2:-}" == "1" || "${ENABLE_AWG_V2,,}" == "y" ]] && [ -n "${AWG_V2_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${AWG_V2_PORT}/udp"
fi
if [[ "${ENABLE_AWG_STANDALONE:-}" == "1" || "${ENABLE_AWG_STANDALONE,,}" == "y" ]] && [ -n "${AWG_STANDALONE_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${AWG_STANDALONE_PORT}/udp"
fi
if [[ "${ENABLE_SS2022:-}" == "1" || "${ENABLE_SS2022,,}" == "y" ]] && [ -n "${SS2022_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${SS2022_PORT}/tcp && ufw allow ${SS2022_PORT}/udp"
fi
if [[ "${ENABLE_TUIC:-}" == "1" || "${ENABLE_TUIC,,}" == "y" ]] && [ -n "${TUIC_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${TUIC_PORT}/udp"
fi
if [[ "${ENABLE_MTPROTO:-}" == "1" || "${ENABLE_MTPROTO,,}" == "y" ]] && [ -n "${MTPROTO_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${MTPROTO_PORT}/tcp"
fi
if [[ "${ENABLE_MASQUE:-}" == "1" || "${ENABLE_MASQUE,,}" == "y" ]] && [ -n "${MASQUE_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${MASQUE_PORT}/udp"
fi

SSL_CERT_REPORT=""
for dom in "${ALL_DOMAINS[@]}"; do
    if [ -f "${SSL_BASE_DIR}/$dom/fullchain.pem" ]; then
        SSL_CERT_REPORT+="  - Домен: ${CYAN}${dom}${NC}\n"
        SSL_CERT_REPORT+="    Cert: ${GREEN}${SSL_BASE_DIR}/${dom}/fullchain.pem${NC}\n"
        SSL_CERT_REPORT+="    Key:  ${GREEN}${SSL_BASE_DIR}/${dom}/privkey.pem${NC}\n\n"
    fi
done

REALITY_INBOUNDS_REPORT=""
if is_true "${STEAL_ENABLED:-0}"; then
    REALITY_INBOUNDS_REPORT+="\n  ${BOLD}[Сценарий 1: VLESS REALITY (маскировка под свой сайт с защитой Anti-Loop)]${NC}\n"
    for port in "${STEAL_PORTS_LIST[@]}"; do
        p_doms=()
        for s_dom in "${STEAL_DOMAINS[@]}"; do
            [ -n "$s_dom" ] || continue
            if [ "${DOMAIN_TO_PORT[$s_dom]:-}" = "$port" ]; then
                p_doms+=("$s_dom")
            fi
        done
        [ ${#p_doms[@]} -gt 0 ] || continue

        REALITY_INBOUNDS_REPORT+="    - Инбаунд для порта ${GREEN}${port}${NC} (Домены: ${CYAN}${p_doms[*]}${NC}):
      * ${YELLOW}Вкладка «Основное»:${NC} Протокол: ${GREEN}vless${NC} | Адрес: ${GREEN}127.0.0.1${NC} | Порт: ${GREEN}${port}${NC}
      * ${YELLOW}Вкладка «Поток»:${NC} Транспорт: ${GREEN}RAW (tcp)${NC} | Accept Proxy Protocol: ${GREEN}Включить (xver: 1)${NC}
      * ${YELLOW}Вкладка «Безопасность»:${NC} ${GREEN}Reality${NC} | uTLS: ${GREEN}chrome / firefox${NC}
        - Dest (Anti-Loop Fallback): ${GREEN}127.0.0.1:${REALITY_FALLBACK_PORT}${NC}
        - Proxy Protocol для Dest: ${GREEN}Включить (xver: 1)${NC}
        - Server Names (SNI): ${CYAN}${p_doms[*]}${NC}
      * ${YELLOW}Вкладка «Сниффинг»:${NC} Включить (${GREEN}HTTP, TLS, QUIC, FAKEDNS${NC})\n\n"
    done
fi

if is_true "${CLASSIC_ENABLED:-0}"; then
    REALITY_INBOUNDS_REPORT+="\n  ${BOLD}[Сценарий 2: VLESS REALITY (маскировка под популярные внешние сервисы)]${NC}\n"
    for port in "${CLASSIC_PORTS_LIST[@]}"; do
        p_snis=()
        for ext_sni in "${!EXT_SNI_TO_PORT[@]}"; do
            if [ "${EXT_SNI_TO_PORT[$ext_sni]:-}" = "$port" ]; then
                p_snis+=("$ext_sni")
            fi
        done
        [ ${#p_snis[@]} -gt 0 ] || p_snis=("gateway.icloud.com")
        primary_ext="${p_snis[0]}"

        REALITY_INBOUNDS_REPORT+="    - Инбаунд для порта ${GREEN}${port}${NC} (SNI: ${CYAN}${p_snis[*]}${NC}):
      * ${YELLOW}Вкладка «Основное»:${NC} Протокол: ${GREEN}vless${NC} | Адрес: ${GREEN}127.0.0.1${NC} | Порт: ${GREEN}${port}${NC}
      * ${YELLOW}Вкладка «Поток»:${NC} Транспорт: ${GREEN}RAW (tcp)${NC} | Accept Proxy Protocol: ${GREEN}Включить (xver: 1)${NC}
      * ${YELLOW}Вкладка «Безопасность»:${NC} ${GREEN}Reality${NC} | uTLS: ${GREEN}chrome / firefox${NC}
        - Dest (Target): ${CYAN}${primary_ext}:443${NC}
        - Proxy Protocol для Dest: ${RED}Выключить (xver: 0)${NC}
        - Server Names (SNI): ${CYAN}${p_snis[*]}${NC}
      * ${YELLOW}Вкладка «Сниффинг»:${NC} Включить (${GREEN}HTTP, TLS, QUIC, FAKEDNS${NC})\n\n"
    done
fi

DECOY_NAME="Локальный Front"
if [ "$DECOY_MODE" = "1" ]; then DECOY_NAME="DataSphere Analytics";
elif [ "$DECOY_MODE" = "2" ]; then DECOY_NAME="CosmosCloud NextGen";
elif [ "$DECOY_MODE" = "3" ]; then DECOY_NAME="Default Nginx Stub";
fi

# --- Шаг 7: Автоматическая настройка 3X-UI через внешний скрипт configure_3xui.sh ---
if should_skip_step 7; then
    :
elif [[ "${AUTO_SETUP_3XUI,,}" != "y" && "${AUTO_SETUP_3XUI:-}" != "1" ]]; then
    step_begin 7
    ok "Шаг 7: Автоматическая настройка 3X-UI отключена в конфигурации — пропущено."
    step_finish 7
else
    step_begin 7

    # 1. Проверяем наличие ядра 3X-UI на сервере, если нет - устанавливаем автоматически
    if ! command -v x-ui >/dev/null 2>&1 && [ ! -f /etc/x-ui/x-ui.db ] && [ ! -f /usr/local/x-ui/bin/x-ui.db ]; then
        install_3xui_core_task() {
            export DEBIAN_FRONTEND=noninteractive
            curl -Ls --connect-timeout 15 https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o /tmp/install_3xui.sh
            printf "n\n" | bash /tmp/install_3xui.sh
        }
        run_with_spinner "Установка официального ядра 3X-UI (mhsanaei)" install_3xui_core_task || die "Ошибка установки ядра 3X-UI."
    fi

    # 2. Использование локальной версии configure_3xui.sh с сетевым fallback
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "/root")"
    CONFIG_EXEC="$script_dir/configure_3xui.sh"
    if [ ! -f "$CONFIG_EXEC" ]; then
        raw_url="https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/configure_3xui.sh?v=$(date +%s)"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "$raw_url" -o /tmp/configure_3xui.sh 2>/dev/null && chmod +x /tmp/configure_3xui.sh 2>/dev/null || true
        elif command -v wget >/dev/null 2>&1; then
            wget -qO /tmp/configure_3xui.sh "$raw_url" 2>/dev/null && chmod +x /tmp/configure_3xui.sh 2>/dev/null || true
        fi
        CONFIG_EXEC="/tmp/configure_3xui.sh"
    else
        chmod +x "$CONFIG_EXEC" 2>/dev/null || true
    fi

    if [ -f "$CONFIG_EXEC" ]; then
        run_configure_3xui_task() {
            export ENABLE_WARP
            export WARP_LICENSE_KEY
            export TIME_LOCATION
            export SUB_UPDATES
            export SUB_ENCRYPT
            export SUB_CLASH_PATH
            export BLOCK_SMTP
            export BLOCK_LAN
            export WEB_LISTEN
            export SUB_LISTEN
            export ENABLE_AGH
            export AGH_XRAY_DNS
            export UPDATE_XRAY_CORE="${UPDATE_XRAY_CORE:-y}"
            export ENABLE_NODE_TOKEN
            export NODE_TOKEN_NAME
            export AWG_PRIMARY_DNS
            export AWG_SECONDARY_DNS
            export AWG_SUBNET_IP
            export AWG_SUBNET_CIDR
            export AWG_RANDOM_TRAILERS
            export ENABLE_SS2022
            export SS2022_PORT
            export ENABLE_TUIC
            export TUIC_PORT
            export ENABLE_MTPROTO
            export MTPROTO_PORT
            export MTPROTO_FAKETLS_DOMAIN
            export MTPROTO_ADTAG
            export ENABLE_MASQUE
            export MASQUE_PORT
            export MASQUE_USER
            export MASQUE_PASSWORD
            export ENABLE_SHADOWTLS
            export SHADOWTLS_PORT
            export SHADOWTLS_SNI
            export SHADOWTLS_PASSWORD
            export ENABLE_WSTUNNEL
            export WSTUNNEL_PORT
            export WSTUNNEL_PREFIX
            export WSTUNNEL_SECRET
            export ENABLE_ZAPRET
            export ZAPRET_QNUM
            export ZAPRET_DESYNC
            export ZAPRET_FOOLING
            bash "$CONFIG_EXEC" --config "$SAVED_CONFIG_FILE" -y
        }
        run_with_spinner "Автоматическая настройка базы 3X-UI и создание инбаундов" run_configure_3xui_task || die "Ошибка настройки базы 3X-UI."

        token_file=""
        [ -f "/run/3xui_node_token.env" ] && token_file="/run/3xui_node_token.env"
        [ -z "$token_file" ] && [ -f "/tmp/3xui_node_token.env" ] && token_file="/tmp/3xui_node_token.env"
        if [ -n "$token_file" ]; then
            source "$token_file" 2>/dev/null || true
            rm -f "$token_file" 2>/dev/null || true
            save_session_state "$SAVED_CONFIG_FILE" >/dev/null 2>&1 || true
        fi

        # 3. Настройка службы и таймера автоматического еженедельного обновления geosite/geoip
        setup_xray_geo_timer_task() {
            cat << 'EOF_GEO' > /usr/local/bin/update-xray-geo.sh
#!/bin/bash
set -e
GEO_DIR="/usr/local/x-ui/bin"
[ -d "$GEO_DIR" ] || GEO_DIR="/etc/x-ui/bin"
mkdir -p "$GEO_DIR"

curl -fsSL --connect-timeout 15 "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat" -o "$GEO_DIR/geosite.dat.tmp" 2>/dev/null || true
curl -fsSL --connect-timeout 15 "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat" -o "$GEO_DIR/geoip.dat.tmp" 2>/dev/null || true

if [ -s "$GEO_DIR/geosite.dat.tmp" ]; then
    mv -f "$GEO_DIR/geosite.dat.tmp" "$GEO_DIR/geosite.dat"
fi
if [ -s "$GEO_DIR/geoip.dat.tmp" ]; then
    mv -f "$GEO_DIR/geoip.dat.tmp" "$GEO_DIR/geoip.dat"
fi
systemctl restart x-ui >/dev/null 2>&1 || true
EOF_GEO
            chmod +x /usr/local/bin/update-xray-geo.sh

            cat << 'EOF_GEOSVC' > /etc/systemd/system/xray-geo-update.service
[Unit]
Description=Weekly update of Xray GeoSite and GeoIP databases
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-xray-geo.sh
EOF_GEOSVC

            cat << 'EOF_GEOTMR' > /etc/systemd/system/xray-geo-update.timer
[Unit]
Description=Weekly timer for Xray GeoSite and GeoIP databases update

[Timer]
OnCalendar=Sun *-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF_GEOTMR

            systemctl daemon-reload
            systemctl enable --now xray-geo-update.timer >/dev/null 2>&1 || true
        }
        run_with_spinner "Активация таймера еженедельного обновления geosite.dat и geoip.dat" setup_xray_geo_timer_task
    else
        warn "Скрипт configure_3xui.sh не найден. Выполните настройку вручную."
    fi

    # Развертывание фоновых служб нового поколения (Zapret, MASQUE, ShadowTLS, Wstunnel)
    if command -v deploy_native_nextgen_services >/dev/null 2>&1; then
        deploy_native_nextgen_services
    fi

    step_finish 7
fi

