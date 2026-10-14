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
Внешние порты:  80/tcp (HTTP), 443/tcp (HTTPS Stream Router), 443/udp (Hysteria 2)
SSH Порт:       ${SSH_PORT}

[ ПРЯМЫЕ ССЫЛКИ НА ПОДПИСКУ КЛИЕНТОВ ]
$( [ -n "$sub_link" ] && echo "Универсальная подписка (Base64): ${sub_link}" || echo "Универсальная подписка: В панели -> Подключения" )
$( [ -n "$clash_link" ] && echo "Подписка для Clash / Mihomo:   ${clash_link}" || true )

[ НАСТРОЙКА КЛИЕНТОВ ]
1. Добавьте ссылку на подписку в клиент:
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
    echo -e "  ${WHITE}${BOLD}Архитектурная защита (L4 Stream Router):${RESET}"
    echo -e "    ${DIM}• Внешний фасад:${RESET}  ${GREEN}443 TCP (Nginx Stream ssl_preread)${RESET}"
    echo -e "    ${DIM}• Маскировка SNI:${RESET} ${WHITE}${PRIMARY_DOMAIN} ${DIM}➜${RESET} ${GREEN}Decoy Site (HTML5/Nginx)${RESET}"
    echo -e "    ${DIM}• Hysteria 2 UDP:${RESET} ${GREEN}443 UDP (QUIC / TLS SNI)${RESET}"
    echo -e "    ${DIM}• Фаервол UFW:${RESET}    ${GREEN}Порты протоколов (10443, 55443 и др.) изолированы${RESET}"
    echo -e "    ${DIM}• Ядро Linux:${RESET}     ${GREEN}BBR активирован, IPv6 отключен (no leak)${RESET}"
    echo ""
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

