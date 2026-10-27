# @include "panel/configure.sh"

install_step_panel() {
    # 1. Проверяем наличие ядра 3X-UI на сервере, если нет - устанавливаем автоматически
    if ! command -v x-ui >/dev/null 2>&1 && [ ! -f /etc/x-ui/x-ui.db ] && [ ! -f /usr/local/x-ui/bin/x-ui.db ]; then
        install_3xui_core_task() {
            export DEBIAN_FRONTEND=noninteractive
            curl -Ls --connect-timeout 15 https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o /tmp/install_3xui.sh
            printf "n\n" | bash /tmp/install_3xui.sh
        }
        run_with_spinner "Установка официального ядра 3X-UI (mhsanaei)" install_3xui_core_task || die "Ошибка установки ядра 3X-UI."
    fi

    # 2. Использование локальной версии configure-panel.sh или встроенного модуля (без сети)
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "/root")"
    CONFIG_EXEC="$script_dir/configure-panel.sh"
    if [ ! -f "$CONFIG_EXEC" ]; then
        CONFIG_EXEC=""
    else
        chmod +x "$CONFIG_EXEC" 2>/dev/null || true
    fi

    # Развертывание фоновых служб нового поколения (Zapret, MASQUE, ShadowTLS, Wstunnel, NaïveProxy, DNSTT)
    # Выполняется ДО configure-panel.sh, чтобы сгенерированные ключи и пароли попали в сводный отчет клиента
    if command -v deploy_native_nextgen_services >/dev/null 2>&1; then
        deploy_native_nextgen_services
        save_session_state "$SAVED_CONFIG_FILE"
    fi

    if [ -n "$CONFIG_EXEC" ] || command -v configure_3xui_panel >/dev/null 2>&1; then
        if is_true "${ENABLE_NODE_TOKEN:-y}"; then
            NODE_ENV_FILE="${NODE_ENV_FILE:-$(umask 077; mktemp "${TMPDIR:-/tmp}/3xui-node.XXXXXX")}"
        fi
        run_configure_3xui_task() {
            export ENABLE_WARP
            export WARP_LICENSE_KEY
            export TIME_LOCATION
            export INBOUND_TRAFFIC_RESET="${INBOUND_TRAFFIC_RESET:-monthly}"
            export INBOUND_TRAFFIC_RESET_DAY="${INBOUND_TRAFFIC_RESET_DAY:-1}"
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
            export NODE_ENV_FILE
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
            export ENABLE_NAIVE
            export NAIVE_PORT
            export NAIVE_DOMAIN
            export NAIVE_USER
            export NAIVE_PASS
            export ENABLE_DNSTT
            export DNSTT_PORT
            export DNSTT_DOMAIN
            export DNSTT_PUBKEY
            if [ -n "${CONFIG_EXEC:-}" ] && [ -f "$CONFIG_EXEC" ]; then
                bash "$CONFIG_EXEC" --config "$SAVED_CONFIG_FILE" -y
            elif command -v configure_3xui_panel >/dev/null 2>&1; then
                configure_3xui_panel --config "$SAVED_CONFIG_FILE" -y
            else
                die "Модуль автонастройки 3X-UI недоступен."
            fi
        }
        run_with_spinner "Автоматическая настройка базы 3X-UI и создание инбаундов" run_configure_3xui_task || die "Ошибка настройки базы 3X-UI."

        if is_true "${ENABLE_NODE_TOKEN:-y}"; then
            load_node_token_result "$NODE_ENV_FILE" || die "API-ключ ноды не получен от 3X-UI."
            rm -f -- "$NODE_ENV_FILE"
            save_session_state "$SAVED_CONFIG_FILE"
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
svc_restart x-ui >/dev/null 2>&1 || systemctl restart x-ui >/dev/null 2>&1 || rc-service x-ui restart >/dev/null 2>&1 || true
EOF_GEO
            chmod +x /usr/local/bin/update-xray-geo.sh

            if is_openrc; then
                mkdir -p /etc/periodic/weekly 2>/dev/null || true
                cat << 'EOF_GEOCRON' > /etc/periodic/weekly/xray-geo-update
#!/bin/sh
/usr/local/bin/update-xray-geo.sh >/dev/null 2>&1
EOF_GEOCRON
                chmod +x /etc/periodic/weekly/xray-geo-update 2>/dev/null || true
            else
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
            fi
        }
        run_with_spinner "Активация таймера еженедельного обновления geosite.dat и geoip.dat" setup_xray_geo_timer_task
    else
        die "Missing configure-panel.sh"
    fi
}
