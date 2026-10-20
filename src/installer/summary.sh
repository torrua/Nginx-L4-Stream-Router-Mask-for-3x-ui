save_and_display_summary() {
    # Считываем актуальные примененные данные из конфигурационного файла (источник правды)
    local cfg_source=""
    [ -f "/root/nginx_mask_setup/setup_mask.env" ] && cfg_source="/root/nginx_mask_setup/setup_mask.env"
    [ -z "$cfg_source" ] && [ -f "/etc/setup_mask.env" ] && cfg_source="/etc/setup_mask.env"
    if [ -n "$cfg_source" ]; then
        local env_user env_pass env_path
        env_user=$(grep -E '^ADMIN_USERNAME=' "$cfg_source" 2>/dev/null | cut -d= -f2- | tr -d '"'\''')
        env_pass=$(grep -E '^ADMIN_PASSWORD=' "$cfg_source" 2>/dev/null | cut -d= -f2- | tr -d '"'\''')
        env_path=$(grep -E '^PANEL_PATH=' "$cfg_source" 2>/dev/null | cut -d= -f2- | tr -d '"'\''')
        [ -n "$env_user" ] && PANEL_USER="$env_user"
        [ -n "$env_pass" ] && PANEL_PASS="$env_pass"
        if [ -n "$env_path" ]; then
            PANEL_SECRET="${env_path#/}"
            PANEL_SECRET="${PANEL_SECRET%/}"
        fi
    fi

    # Чтение ссылок подписок из вывода configure_3xui.sh или базы данных SQLite
    local sub_link=""
    local clash_link=""
    if [ -f "$CREDENTIALS_FILE" ]; then
        sub_link=$(grep -E '^(Прямая ссылка подписки|Subscription Link):' "$CREDENTIALS_FILE" 2>/dev/null | awk '{print $NF}' | head -n 1)
        clash_link=$(grep -E '^(Прямая ссылка \(Clash\)|Clash Link):' "$CREDENTIALS_FILE" 2>/dev/null | awk '{print $NF}' | head -n 1)
    fi

    if [ -z "$sub_link" ] && [ -f "/etc/x-ui/x-ui.db" ] && command -v sqlite3 >/dev/null 2>&1; then
        local sub_path_val sub_clash_val client_sub_id
        sub_path_val=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key = 'subPath';" 2>/dev/null || echo "my-post-key")
        sub_clash_val=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key = 'subClashPath';" 2>/dev/null || echo "my-post-key/clash")
        client_sub_id=$(sqlite3 /etc/x-ui/x-ui.db "SELECT json_extract(client.value, '$.subId') FROM inbounds, json_each(json_extract(settings, '$.clients')) as client WHERE json_extract(client.value, '$.subId') IS NOT NULL LIMIT 1;" 2>/dev/null || true)
        
        [ -z "$sub_path_val" ] && sub_path_val="my-post-key"
        [ -z "$sub_clash_val" ] && sub_clash_val="${sub_path_val}/clash"
        
        if [ -n "$client_sub_id" ]; then
            sub_link="https://${PRIMARY_DOMAIN}/${sub_path_val#/}/${client_sub_id}"
            clash_link="https://${PRIMARY_DOMAIN}/${sub_clash_val#/}/${client_sub_id}"
        fi
    fi

    local client_env=""
    [ -f "/run/3xui_unified_client.env" ] && client_env="/run/3xui_unified_client.env"
    [ -z "$client_env" ] && [ -f "/tmp/3xui_unified_client.env" ] && client_env="/tmp/3xui_unified_client.env"
    if [ -n "$client_env" ]; then
        . "$client_env" 2>/dev/null || true
    fi

    if [ -z "${DNSTT_PUBKEY:-}" ] && [ -f "/etc/dnstt/server.pub" ]; then
        DNSTT_PUBKEY=$(head -n 1 "/etc/dnstt/server.pub" 2>/dev/null | tr -d '[:space:]')
    fi
    if [ -n "${DNSTT_PUBKEY:-}" ]; then
        if [ -n "${DNSTT_CLI:-}" ] && [[ "$DNSTT_CLI" == *"-pubkey  "* ]]; then
            DNSTT_CLI="${DNSTT_CLI/-pubkey  /-pubkey ${DNSTT_PUBKEY} }"
        elif [ -z "${DNSTT_CLI:-}" ] && [ "${ENABLE_DNSTT:-0}" = "1" ] && [ -n "${DNSTT_DOMAIN:-}" ]; then
            DNSTT_CLI="dnstt-client -doh https://dns.google/dns-query -pubkey ${DNSTT_PUBKEY} ${DNSTT_DOMAIN} 127.0.0.1:1080"
        fi
    fi

    if [ -z "${NAIVE_URI:-}" ] && [ "${ENABLE_NAIVE:-0}" = "1" ] && [ -n "${NAIVE_DOMAIN:-}" ]; then
        local naive_u="${NAIVE_USER:-user}"
        local naive_p="${NAIVE_PASS:-}"
        if [ -z "$naive_p" ] && [ -f "/etc/caddy/Caddyfile" ]; then
            naive_p=$(grep -E 'basic_auth' -A 1 /etc/caddy/Caddyfile 2>/dev/null | tail -n 1 | awk '{print $1}' | tr -d '[:space:]')
        fi
        [ -n "$naive_p" ] && NAIVE_URI="naive+https://${naive_u}:${naive_p}@${NAIVE_DOMAIN}:${NAIVE_PORT:-443}"
    fi

    local awg_vpnuri=""
    if [ -f "/root/awg/client-1.vpnuri" ]; then
        awg_vpnuri=$(head -n 1 "/root/awg/client-1.vpnuri" 2>/dev/null | tr -d '[:space:]')
    fi

    local ext_ports_list="80/tcp (HTTP), 443/tcp (HTTPS Stream Router)"
    if [ "${ENABLE_HY2:-1}" != "0" ] && [ "${ENABLE_HY2:-y}" != "n" ]; then
        ext_ports_list+=", 443/udp (Hysteria 2)"
    fi
    if [ "${ENABLE_MASQUE:-0}" = "1" ] || [ "${ENABLE_MASQUE:-}" = "y" ]; then
        ext_ports_list+=", ${MASQUE_PORT:-8445}/udp (MASQUE)"
    fi
    if [ "${ENABLE_TUIC:-0}" = "1" ] || [ "${ENABLE_TUIC:-}" = "y" ]; then
        ext_ports_list+=", ${TUIC_PORT:-8448}/udp (TUIC v5)"
    fi
    if [ "${ENABLE_AWG_V3:-1}" != "0" ] && [ "${ENABLE_AWG_V3:-y}" != "n" ]; then
        ext_ports_list+=", ${AWG_V3_PORT:-8443}/udp (AmneziaWG)"
    fi
    if [ "${ENABLE_DNSTT:-0}" = "1" ] || [ "${ENABLE_DNSTT:-}" = "y" ]; then
        ext_ports_list+=", ${DNSTT_PORT:-53053}/udp (DNSTT)"
    fi

    cat <<EOF > "$CREDENTIALS_FILE"
====================================================================
 NGINX L4 STREAM ROUTER & 3X-UI — УЧЕТНЫЕ ДАННЫЕ СЕРВЕРА
 Дата развертывания: $(date "+%Y-%m-%d %H:%M:%S %Z")
====================================================================

[ ВЕБ-ПАНЕЛЬ 3X-UI ]
URL Панели:     https://${PRIMARY_DOMAIN}/${PANEL_SECRET}/
Логин:          ${PANEL_USER}
Пароль:         ${PANEL_PASS}
Внутренний порт: 127.0.0.1:${PANEL_INTERNAL_PORT} (Закрыт извне фаерволом)

[ СЕТЕВЫЕ ПАРАМЕТРЫ ]
Основной домен: ${PRIMARY_DOMAIN}
SSL Сертификат: /etc/letsencrypt/live/${PRIMARY_DOMAIN}/
Внешние порты:  ${ext_ports_list}
SSH Порт:       ${SSH_PORT}

[ ПРЯМЫЕ ССЫЛКИ НА ПОДПИСКУ КЛИЕНТОВ ]
$( [ -n "$sub_link" ] && echo "Универсальная подписка (Base64): ${sub_link}" || echo "Универсальная подписка: В панели -> Подключения" )
$( [ -n "$clash_link" ] && echo "Подписка для Clash / Mihomo:   ${clash_link}" || true )
$([ -n "$awg_vpnuri" ] && printf "\n[ AMNEZIAWG 3.1 (Официальное приложение Amnezia VPN) ]\nСсылка Amnezia (vpn://): %s\nКонфиг файл (.conf):      /root/awg/client-1.conf\n" "$awg_vpnuri")
$([ -n "${MASQUE_URI:-}" ] && printf "\n[ MASQUE RFC 9484 (Sing-box) ]\nURI: %s\n" "${MASQUE_URI}")
$([ -n "${SHADOWTLS_URI:-}" ] && printf "\n[ SHADOWTLS v4 + SS-2022 ]\nShadowTLS URI:        %s\nShadowTLS + SS-2022:  %s\n" "${SHADOWTLS_URI}" "${SS_SHADOWTLS_URI:-}")
$([ -n "${WSTUNNEL_CLI:-}" ] && printf "\n[ WSTUNNEL (L7 Nginx WebSocket) ]\nClient CLI:           %s\n" "${WSTUNNEL_CLI}")
$([ -n "${ZAPRET_INFO:-}" ] && printf "\n[ SERVER-SIDE ZAPRET ]\nСтатус:               %s\n" "${ZAPRET_INFO}")
$([ -n "${NAIVE_URI:-}" ] && printf "\n[ NAÏVEPROXY (Chrome HTTPS Forward Proxy) ]\nNaïveProxy URI:       %s\n" "${NAIVE_URI}")
$([ -n "${DNSTT_CLI:-}" ] && printf "\n[ DNSTT (DoH DNS Tunneling) ]\nDNSTT Client CLI:     %s\nDNSTT Public Key:     %s\n" "${DNSTT_CLI}" "${DNSTT_PUBKEY:-}")

[ НАСТРОЙКА КЛИЕНТОВ ]
1. Добавьте ссылку на подписку в клиент:
   - Amnezia VPN (iOS / Android / Desktop)                      -> Ссылка Amnezia (vpn://)
   - Sing-box / v2rayN / v2rayNG / Streisand / FoXray / Nekoray -> Универсальная ссылка
   - Clash Verge Rev / Clash Nyanpasu / Mihomo Party           -> Ссылка Clash
2. Либо войдите в веб-панель https://${PRIMARY_DOMAIN}/${PANEL_SECRET}/ и скопируйте нужный Inbound.

Файл сохранен в: ${CREDENTIALS_FILE}
====================================================================
EOF
    chmod 600 "$CREDENTIALS_FILE"

    DASHBOARD_SUB_LINK="$sub_link"
    DASHBOARD_CLASH_LINK="$clash_link"
}

# Final Unicode Box Dashboard
print_dashboard() {
    echo ""
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════════════════════${RESET}"
    echo -e "  ${GREEN}${BOLD}       ${CHECK} РАЗВЕРТЫВАНИЕ СИСТЕМЫ УСПЕШНО ЗАВЕРШЕНО!                           ${RESET}"
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════════════════════${RESET}"
    echo -e "  ${WHITE}${BOLD}Панель управления 3X-UI:${RESET}"
    echo -e "    ${CYAN}${ARROW} URL:${RESET}      ${WHITE}${BOLD}https://${PRIMARY_DOMAIN}/${PANEL_SECRET}/${RESET}"
    echo -e "    ${CYAN}${ARROW} Логин:${RESET}    ${WHITE}${PANEL_USER}${RESET}"
    echo -e "    ${CYAN}${ARROW} Пароль:${RESET}   ${YELLOW}${BOLD}${PANEL_PASS}${RESET}"
    echo ""
    if [ -n "${DASHBOARD_SUB_LINK:-}" ]; then
        echo -e "  ${WHITE}${BOLD}Клиентские подписки (Автообновление всех протоколов):${RESET}"
        echo -e "    ${CYAN}${ARROW} Universal (Base64):${RESET} ${GREEN}${DASHBOARD_SUB_LINK}${RESET}"
        if [ -n "${DASHBOARD_CLASH_LINK:-}" ]; then
            echo -e "    ${CYAN}${ARROW} Clash / Mihomo:${RESET}     ${GREEN}${DASHBOARD_CLASH_LINK}${RESET}"
        fi
        echo ""
    fi
    if [ -f "/root/awg/client-1.vpnuri" ]; then
        local awg_vpnuri
        awg_vpnuri=$(head -n 1 "/root/awg/client-1.vpnuri" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$awg_vpnuri" ]; then
            echo -e "  ${WHITE}${BOLD}AmneziaWG 3.1 (Официальное приложение Amnezia VPN):${RESET}"
            echo -e "    ${CYAN}${ARROW} Ссылка в 1 клик (vpn://):${RESET} ${GREEN}${awg_vpnuri}${RESET}"
            echo -e "    ${DIM}• Конфиг файл (.conf):${RESET}    ${CYAN}/root/awg/client-1.conf${RESET}"
            echo ""
        fi
    fi
    echo -e "  ${WHITE}${BOLD}Архитектурная защита (L4 Stream Router):${RESET}"
    echo -e "    ${DIM}• Внешний фасад:${RESET}  ${GREEN}443 TCP (Nginx Stream ssl_preread)${RESET}"
    echo -e "    ${DIM}• Маскировка SNI:${RESET} ${WHITE}${PRIMARY_DOMAIN} ${DIM}➜${RESET} ${GREEN}Decoy Site (HTML5/Nginx)${RESET}"
    echo -e "    ${DIM}• Hysteria 2 UDP:${RESET} ${GREEN}443 UDP (QUIC / TLS SNI)${RESET}"
    echo -e "    ${DIM}• Фаервол UFW:${RESET}    ${GREEN}Внутренние сервисы и порты панели надежно изолированы на 127.0.0.1${RESET}"
    echo -e "    ${DIM}• Ядро Linux:${RESET}     ${GREEN}BBR активирован, IPv6 отключен (no leak)${RESET}"
    echo ""
    if [ -n "${MASQUE_URI:-}" ] || [ -n "${SHADOWTLS_URI:-}" ] || [ -n "${WSTUNNEL_CLI:-}" ] || [ -n "${ZAPRET_INFO:-}" ] || [ -n "${NAIVE_URI:-}" ] || [ -n "${DNSTT_CLI:-}" ]; then
        echo -e "  ${WHITE}${BOLD}Протоколы нового поколения (Next-Gen Protocols):${RESET}"
        [ -n "${MASQUE_URI:-}" ] && echo -e "    ${CYAN}${ARROW} MASQUE:${RESET}       ${GREEN}${MASQUE_URI}${RESET}"
        [ -n "${SHADOWTLS_URI:-}" ] && echo -e "    ${CYAN}${ARROW} ShadowTLS:${RESET}    ${GREEN}${SHADOWTLS_URI}${RESET}"
        [ -n "${WSTUNNEL_CLI:-}" ] && echo -e "    ${CYAN}${ARROW} Wstunnel:${RESET}     ${CYAN}${WSTUNNEL_CLI}${RESET}"
        [ -n "${ZAPRET_INFO:-}" ] && echo -e "    ${CYAN}${ARROW} Zapret:${RESET}       ${GREEN}nfqws активен (DPI Desync connbytes 1:6)${RESET}"
        [ -n "${NAIVE_URI:-}" ] && echo -e "    ${CYAN}${ARROW} NaïveProxy:${RESET}   ${GREEN}${NAIVE_URI}${RESET}"
        [ -n "${DNSTT_CLI:-}" ] && echo -e "    ${CYAN}${ARROW} DNSTT DoH:${RESET}    ${CYAN}${DNSTT_CLI}${RESET}"
        echo ""
    fi
    if [ "$SSH_PORT" -ne "${SSH_ACTIVE_PORT:-22}" ]; then
        echo -e "  ${YELLOW}${BOLD}⚠️  ВНИМАНИЕ: Порт SSH изменен на ${WHITE}${SSH_PORT}${YELLOW}!${RESET}"
        echo -e "    ${DIM}1. Проверьте вход в НОВОМ окне терминала:${RESET} ${CYAN}ssh -p ${SSH_PORT} root@${PRIMARY_DOMAIN}${RESET}"
        echo -e "    ${DIM}2. После успешной проверки закройте старый порт ${SSH_ACTIVE_PORT} в UFW:${RESET}"
        echo -e "       ${WHITE}ufw delete allow ${SSH_ACTIVE_PORT}/tcp${RESET}"
        echo ""
    fi
    echo -e "  ${WHITE}${BOLD}Безопасность учетных данных:${RESET}"
    echo -e "    ${DIM}Все доступы сохранены в защищенный файл:${RESET} ${YELLOW}${CREDENTIALS_FILE}${RESET}"
    echo -e "    ${DIM}Для повторного просмотра:${RESET} ${CYAN}cat /root/vpn_credentials.txt${RESET}"
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════════════════════${RESET}"
    echo ""
}

