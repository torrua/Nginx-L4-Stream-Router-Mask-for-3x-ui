# =============================================================
#  ФУНКЦИИ ДИАГНОСТИКИ, РЕЗЕРВНОГО КОПИРОВАНИЯ И SMOKE-TEST
# =============================================================

backup_nginx_configs() {
    local bkp_dir="/var/backups/nginx_mask"
    mkdir -p "$bkp_dir"
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local bkp_file="$bkp_dir/nginx_conf_${ts}.tar.gz"

    local has_files=0
    if compgen -G "/etc/nginx/conf.d/*.conf" >/dev/null 2>&1 || compgen -G "/etc/nginx/stream.d/*.conf" >/dev/null 2>&1; then
        has_files=1
    fi

    if [ "$has_files" -eq 1 ]; then
        if tar -czf "$bkp_file" -C /etc/nginx conf.d stream.d 2>/dev/null; then
            local old_backups
            old_backups=$(ls -1t "$bkp_dir"/nginx_conf_*.tar.gz 2>/dev/null | tail -n +6 || true)
            if [ -n "$old_backups" ]; then
                echo "$old_backups" | xargs -r rm -f 2>/dev/null || true
            fi
            ok "Создана резервная копия конфигурации Nginx: $bkp_file (ротация: 5)"
        fi
    fi
}

determine_nginx_http2_mode() {
    local ver_raw=""
    if command -v nginx >/dev/null 2>&1; then
        ver_raw=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+' || true)
    fi
    [ -n "$ver_raw" ] || ver_raw="1.25.1"

    local is_modern=0
    local major minor patch
    major=$(echo "$ver_raw" | cut -d. -f1)
    minor=$(echo "$ver_raw" | cut -d. -f2)
    patch=$(echo "$ver_raw" | cut -d. -f3)
    major=${major:-0}; minor=${minor:-0}; patch=${patch:-0}

    if [ "$major" -gt 1 ] 2>/dev/null; then
        is_modern=1
    elif [ "$major" -eq 1 ] 2>/dev/null && [ "$minor" -gt 25 ] 2>/dev/null; then
        is_modern=1
    elif [ "$major" -eq 1 ] 2>/dev/null && [ "$minor" -eq 25 ] 2>/dev/null && [ "$patch" -ge 1 ] 2>/dev/null; then
        is_modern=1
    fi

    if [ "$is_modern" -eq 1 ]; then
        HTTP2_LISTEN_PARAM=""
        HTTP2_DIRECTIVE="http2 on;"
        HTTP2_HTTP_PARAMS=$'    http2_recv_buffer_size 16m;\n    http2_max_concurrent_streams 512;'
    else
        HTTP2_LISTEN_PARAM="http2 "
        HTTP2_DIRECTIVE="# http2 on; (legacy listen param)"
        HTTP2_HTTP_PARAMS=$'    # http2 buffers managed by legacy core'
    fi
}

get_port_listener_info() {
    local proto="$1"
    local port="$2"
    local raw=""
    local flag="-t"
    [ "$proto" = "udp" ] && flag="-u"

    if command -v ss >/dev/null 2>&1; then
        raw=$(ss -l -n -p "$flag" 2>/dev/null | grep -E ":${port}\b" || true)
    elif command -v netstat >/dev/null 2>&1; then
        raw=$(netstat -l -n -p "$flag" 2>/dev/null | grep -E ":${port}\b" || true)
    elif command -v lsof >/dev/null 2>&1; then
        raw=$(lsof -i "${proto}:${port}" -sTCP:LISTEN 2>/dev/null || lsof -i "${proto}:${port}" 2>/dev/null || true)
    fi

    local proc_info=""
    if [ -n "$raw" ]; then
        if echo "$raw" | grep -q 'users:('; then
            proc_info=$(echo "$raw" | grep -oP 'users:\(\(\K[^)]+' | head -n1 | tr -d '"' || true)
        elif echo "$raw" | grep -qE '[0-9]+/[-_a-zA-Z0-9]+'; then
            proc_info=$(echo "$raw" | grep -oE '[0-9]+/[-_a-zA-Z0-9]+' | head -n1 || true)
        fi
        [ -z "$proc_info" ] && proc_info=$(echo "$raw" | awk '{print $NF}' | head -n1 || true)
    fi
    echo "$proc_info"
}

is_port_in_use() {
    local proto="$1"
    local port="$2"
    if command -v ss >/dev/null 2>&1; then
        local flag="-t"
        [ "$proto" = "udp" ] && flag="-u"
        ss -l -n "$flag" 2>/dev/null | grep -qE ":${port}\b" && return 0
    elif command -v netstat >/dev/null 2>&1; then
        local flag="-t"
        [ "$proto" = "udp" ] && flag="-u"
        netstat -l -n "$flag" 2>/dev/null | grep -qE ":${port}\b" && return 0
    elif timeout 1 bash -c "</dev/$proto/127.0.0.1/$port" 2>/dev/null; then
        return 0
    fi
    return 1
}

inspect_port_conflicts() {
    echo ""
    echo -e "  ${CYAN}${BOLD}🔎  УНИВЕРСАЛЬНЫЙ ИНСПЕКТОР СЕТЕВЫХ ПОРТОВ И СЛУЖБ (PREFLIGHT)${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"

    PORT_AGH_WEB="${PORT_AGH_WEB:-3000}"

    # 1. Проверка настраиваемого веб-порта AdGuard Home (по умолчанию 3000)
    if [[ "${ENABLE_AGH:-0}" == "1" || "${ENABLE_AGH,,}" == "y" ]]; then
        if is_port_in_use "tcp" "$PORT_AGH_WEB"; then
            local listener
            listener=$(get_port_listener_info "tcp" "$PORT_AGH_WEB")
            warn "Порт $PORT_AGH_WEB занят активным процессом: ${listener:-сторонней службой}."
            local candidate=3001
            while [ "$candidate" -le 3053 ]; do
                if ! is_port_in_use "tcp" "$candidate"; then
                    break
                fi
                candidate=$(( candidate + 1 ))
            done
            PORT_AGH_WEB="$candidate"
            ok "Автоматическое переназначение: веб-панель AdGuard Home перенесена на свободный порт ${WHITE}$PORT_AGH_WEB${NC} (конфликт устранен)."
        else
            ok "Порт $PORT_AGH_WEB (AdGuard Home Web) свободен."
        fi
    fi

    # 2. Проверка системного DNS-порта 53 (TCP/UDP)
    if [[ "${ENABLE_AGH:-0}" == "1" || "${ENABLE_AGH,,}" == "y" ]]; then
        if is_port_in_use "udp" 53 || is_port_in_use "tcp" 53; then
            local dns_owner
            dns_owner=$(get_port_listener_info "udp" 53)
            [ -z "$dns_owner" ] && dns_owner=$(get_port_listener_info "tcp" 53)
            if echo "$dns_owner" | grep -qi "systemd-resolve"; then
                ok "Обнаружен локальный systemd-resolved на порту 53 — будет безопасно отключен стаб-слушатель (DNSStubListener=no) с сохранением системного DNS хоста."
            else
                warn "Порт 53 занят процессом: ${dns_owner:-сторонним DNS-сервером}. AdGuard Home требует свободного порта 53."
            fi
        else
            ok "Порт 53 (DNS) свободен."
        fi
    fi

    # 3. Проверка внешних портов маршрутизации и маскирования (80 и 443 TCP)
    for p in 80 443; do
        if is_port_in_use "tcp" "$p"; then
            local w_owner
            w_owner=$(get_port_listener_info "tcp" "$p")
            if echo "$w_owner" | grep -qi "nginx"; then
                ok "Порт $p слушает Nginx (будет переконфигурирован в единый L4/L7 роутер маскирования)."
            else
                warn "Порт $p занят сторонним процессом: ${w_owner:-не Nginx}. Для сквозного TLS/HTTP маскирования требуется порт $p."
            fi
        else
            ok "Порт $p (Веб / Маскирование) свободен."
        fi
    done

    # 4. Проверка внутренних служебных портов стека
    local internal_ports=()
    [ -n "${PANEL_PORT:-}" ] && internal_ports+=("Панель 3X-UI:$PANEL_PORT")
    [ -n "${SUB_PORT:-}" ] && internal_ports+=("Канал подписок:$SUB_PORT")
    [ -n "${XHTTP_STREAM_PORT:-}" ] && internal_ports+=("xHTTP стрим:$XHTTP_STREAM_PORT")
    [ -n "${REALITY_FALLBACK_PORT:-}" ] && internal_ports+=("REALITY Fallback:$REALITY_FALLBACK_PORT")

    for item in "${internal_ports[@]}"; do
        local s_name="${item%%:*}"
        local s_port="${item##*:}"
        if is_port_in_use "tcp" "$s_port"; then
            local p_owner
            p_owner=$(get_port_listener_info "tcp" "$s_port")
            if echo "$p_owner" | grep -qiE "x-ui|xray|nginx"; then
                ok "Внутренний порт $s_port ($s_name) занят собственным сервисом ($p_owner) — готов к реконфигурации."
            else
                warn "Внутренний порт $s_port ($s_name) занят сторонним процессом: ${p_owner:-неизвестно}. Возможен конфликт."
            fi
        fi
    done

    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}\n"
}

post_install_sanity_check() {
    echo ""
    echo -e "  ${CYAN}${BOLD}🔍  ПРОВЕРКА РАБОТОСПОСОБНОСТИ СЕРВИСОВ (SMOKE TEST)${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"

    local all_ok=1

    # 1. Nginx служба и порт 443 TCP
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
        ok "Служба Nginx: активна (running)"
    else
        warn "Служба Nginx: НЕ АКТИВНА!"
        all_ok=0
    fi

    if timeout 2 bash -c '</dev/tcp/127.0.0.1/443' 2>/dev/null; then
        ok "Порт 443 TCP (Nginx Stream Router): отвечает"
    else
        warn "Порт 443 TCP (Nginx Stream Router): НЕ ОТВЕЧАЕТ на 127.0.0.1!"
        all_ok=0
    fi

    if timeout 2 bash -c '</dev/tcp/127.0.0.1/80' 2>/dev/null; then
        ok "Порт 80 TCP (HTTP / ACME Redirect): отвечает"
    else
        warn "Порт 80 TCP (HTTP): НЕ ОТВЕЧАЕТ на 127.0.0.1!"
    fi

    # 2. Xray / 3X-UI
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet x-ui 2>/dev/null; then
        ok "Служба 3X-UI: активна (running)"
    else
        warn "Служба 3X-UI: НЕ АКТИВНА!"
        all_ok=0
    fi

    local steal_p="${STEAL_PORTS_LIST[0]:-${STEAL_PORT:-45443}}"
    local classic_p="${CLASSIC_PORTS_LIST[0]:-${CLASSIC_PORT:-46443}}"
    local xhttp_p="${XHTTP_STREAM_PORT:-50443}"
    local panel_p="${PANEL_PORT:-10443}"
    local sub_p="${SUB_PORT:-55443}"

    if [[ "${ENABLE_STEAL,,}" == "y" || "${ENABLE_STEAL:-}" == "1" ]]; then
        if timeout 2 bash -c "</dev/tcp/127.0.0.1/$steal_p" 2>/dev/null; then
            ok "Подключение REALITY (свой сайт, порт $steal_p): отвечает"
        else
            warn "Подключение REALITY (свой сайт, порт $steal_p): НЕ ОТВЕЧАЕТ!"
            all_ok=0
        fi
    fi

    if [[ "${ENABLE_CLASSIC,,}" == "y" || "${ENABLE_CLASSIC:-}" == "1" ]]; then
        if timeout 2 bash -c "</dev/tcp/127.0.0.1/$classic_p" 2>/dev/null; then
            ok "Подключение REALITY (внешние сервисы, порт $classic_p): отвечает"
        else
            warn "Подключение REALITY (внешние сервисы, порт $classic_p): НЕ ОТВЕЧАЕТ!"
            all_ok=0
        fi
    fi

    if timeout 2 bash -c "</dev/tcp/127.0.0.1/$xhttp_p" 2>/dev/null; then
        ok "Инбаунд VLESS xHTTP (порт $xhttp_p): отвечает"
    else
        warn "Инбаунд VLESS xHTTP (порт $xhttp_p): НЕ ОТВЕЧАЕТ!"
        all_ok=0
    fi

    if timeout 2 bash -c "</dev/tcp/127.0.0.1/$panel_p" 2>/dev/null; then
        ok "Панель 3X-UI (порт $panel_p): отвечает"
    else
        warn "Панель 3X-UI (порт $panel_p): НЕ ОТВЕЧАЕТ!"
    fi

    if timeout 2 bash -c "</dev/tcp/127.0.0.1/$sub_p" 2>/dev/null; then
        ok "Канал подписок 3X-UI (порт $sub_p): отвечает"
    else
        warn "Канал подписок 3X-UI (порт $sub_p): НЕ ОТВЕЧАЕТ!"
    fi

    # 3. UDP сервисы (Hysteria 2 / AmneziaWG)
    if [[ "${ENABLE_HY2,,}" == "y" || "${ENABLE_HY2:-}" == "1" ]]; then
        if ss -ulpn 2>/dev/null | grep -q ":${HY2_PORT:-443} "; then
            ok "Hysteria 2 UDP (порт ${HY2_PORT:-443}): слушает"
        fi
    fi
    if [[ "${ENABLE_AWG_V3,,}" == "y" || "${ENABLE_AWG_V3:-}" == "1" ]]; then
        if ss -ulpn 2>/dev/null | grep -q ":${AWG_V3_PORT:-8443} "; then
            ok "AmneziaWG v3.1 UDP (порт ${AWG_V3_PORT:-8443}): слушает"
        fi
    fi

    # 4. AdGuard Home
    if [[ "${ENABLE_AGH,,}" == "y" || "${ENABLE_AGH:-}" == "1" ]]; then
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet AdGuardHome 2>/dev/null; then
            ok "Служба AdGuard Home: активна (running)"
        else
            warn "Служба AdGuard Home: НЕ АКТИВНА!"
        fi
        if timeout 2 bash -c '</dev/tcp/127.0.0.1/53' 2>/dev/null || ss -ulpn 2>/dev/null | grep -q ':53 '; then
            ok "AdGuard Home DNS (порт 53): слушает"
        fi
    fi

    # 5. SSL сертификат
    local main_cert=""
    if [ "${SSL_ENGINE_CHOICE:-1}" = "1" ]; then
        main_cert="/etc/letsencrypt/live/${PRIMARY_DOMAIN:-}/fullchain.pem"
    else
        main_cert="/etc/ssl/acme/${PRIMARY_DOMAIN:-}/fullchain.pem"
    fi
    if [ -f "$main_cert" ] && command -v openssl >/dev/null 2>&1; then
        local exp_date
        exp_date=$(openssl x509 -enddate -noout -in "$main_cert" 2>/dev/null | cut -d= -f2 || true)
        local exp_epoch
        exp_epoch=$(date -d "$exp_date" +%s 2>/dev/null || echo 0)
        local now_epoch
        now_epoch=$(date +%s)
        local days_left=$(( (exp_epoch - now_epoch) / 86400 ))
        if [ "$days_left" -gt 0 ]; then
            ok "SSL-сертификат $PRIMARY_DOMAIN: действителен (осталось $days_left дн., до $exp_date)"
        else
            warn "SSL-сертификат $PRIMARY_DOMAIN: ИСТЕК ИЛИ НЕВАЛИДЕН!"
            all_ok=0
        fi
    fi

    # 6. Decoy сайт
    if [ -n "${PRIMARY_DOMAIN:-}" ] && command -v curl >/dev/null 2>&1; then
        local http_code
        http_code=$(curl -sk -o /dev/null -w "%{http_code}" --resolve "${PRIMARY_DOMAIN}:443:127.0.0.1" "https://${PRIMARY_DOMAIN}/" 2>/dev/null || echo "ERR")
        if [ "$http_code" = "200" ]; then
            ok "Веб-маска (HTTPS GET /): HTTP $http_code OK"
        else
            warn "Веб-маска (HTTPS GET /): вернула код $http_code"
        fi
    fi

    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
    if [ "$all_ok" -eq 1 ]; then
        echo -e "  ${GREEN}${BOLD}✔ Все ключевые компоненты работают штатно!${NC}\n"
    else
        echo -e "  ${YELLOW}${BOLD}⚠️  Обнаружены предупреждения при проверке компонентов (см. выше).${NC}\n"
    fi
}

run_doctor_check() {
    clear 2>/dev/null || true
    echo -e "  ${CYAN}${BOLD}🩺  ДИАГНОСТИКА СИСТЕМЫ И СЕРВИСОВ (DOCTOR MODE)${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
    echo -e "  Дата проверки: ${WHITE}$(date '+%Y-%m-%d %H:%M:%S')${NC}\n"

    # 1. ОС и Ядро
    echo -e "  ${WHITE}${BOLD}[1/7] ОС и Сетевой стек ядра:${NC}"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo -e "    • Дистрибутив:       ${GREEN}${PRETTY_NAME:-$ID}${NC}"
    fi
    echo -e "    • Ядро Linux:         ${GREEN}$(uname -r)${NC}"

    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [ "$cc" = "bbr" ]; then
        echo -e "    • Алгоритм TCP:      ${GREEN}BBR (активен)${NC}"
    else
        echo -e "    • Алгоритм TCP:      ${YELLOW}$cc (рекомендуется bbr)${NC}"
    fi

    local qdisc
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    echo -e "    • Очередь qdisc:     ${GREEN}$qdisc${NC}"

    if iptables -t mangle -L -n -v 2>/dev/null | grep -q "TCPMSS.*clamp"; then
        echo -e "    • MSS Clamping:      ${GREEN}АКТИВЕН (iptables mangle TCPMSS clamp)${NC}"
    else
        echo -e "    • MSS Clamping:      ${YELLOW}не обнаружен в iptables mangle${NC}"
    fi

    local ipv6_all
    ipv6_all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    if [ "$ipv6_all" = "1" ] || [ ! -d /proc/sys/net/ipv6 ]; then
        echo -e "    • Статус IPv6:       ${GREEN}ОТКЛЮЧЕН (no leak)${NC}"
    else
        echo -e "    • Статус IPv6:       ${RED}АКТИВЕН (возможны утечки DNS/IPv6)${NC}"
    fi

    # 2. Nginx
    echo -e "\n  ${WHITE}${BOLD}[2/7] Веб-сервер Nginx (L4/L7 Router):${NC}"
    if command -v nginx >/dev/null 2>&1; then
        local ng_ver
        ng_ver=$(nginx -v 2>&1 | cut -d/ -f2 || true)
        echo -e "    • Версия Nginx:      ${GREEN}$ng_ver${NC}"
        if systemctl is-active --quiet nginx 2>/dev/null; then
            echo -e "    • Статус службы:     ${GREEN}active (running)${NC}"
        else
            echo -e "    • Статус службы:     ${RED}NOT RUNNING${NC}"
        fi
        if nginx -t >/dev/null 2>&1; then
            echo -e "    • Синтаксис конфига: ${GREEN}OK (nginx -t passed)${NC}"
        else
            echo -e "    • Синтаксис конфига: ${RED}ОШИБКА в конфигурации!${NC}"
        fi
        [ -f /etc/nginx/stream.d/00-stream.conf ] && echo -e "    • Stream Router:     ${GREEN}/etc/nginx/stream.d/00-stream.conf (присутствует)${NC}" || echo -e "    • Stream Router:     ${RED}00-stream.conf ОТСУТСТВУЕТ!${NC}"
        [ -f /etc/nginx/conf.d/01-main.conf ] && echo -e "    • Main HTTP Config:  ${GREEN}/etc/nginx/conf.d/01-main.conf (присутствует)${NC}" || echo -e "    • Main HTTP Config:  ${RED}01-main.conf ОТСУТСТВУЕТ!${NC}"
    else
        echo -e "    • Nginx:             ${RED}не установлен${NC}"
    fi

    # 3. Xray-core и 3X-UI
    echo -e "\n  ${WHITE}${BOLD}[3/7] Прокси-ядро Xray и панель 3X-UI:${NC}"
    if systemctl is-active --quiet x-ui 2>/dev/null; then
        echo -e "    • Статус 3X-UI:      ${GREEN}active (running)${NC}"
    else
        echo -e "    • Статус 3X-UI:      ${RED}NOT RUNNING${NC}"
    fi
    local xray_bin="/usr/local/x-ui/bin/xray-linux-amd64"
    [ -f "$xray_bin" ] || xray_bin="/usr/local/x-ui/bin/xray"
    [ -f "$xray_bin" ] || xray_bin="/etc/x-ui/bin/xray-linux-amd64"
    [ -f "$xray_bin" ] || xray_bin="/etc/x-ui/bin/xray"
    if [ -x "$xray_bin" ]; then
        local xv
        xv=$("$xray_bin" -version 2>/dev/null | head -n1 | awk '{print $2}' || true)
        echo -e "    • Ядро Xray-core:    ${GREEN}${xv:-найден}${NC}"
    fi
    if [ -f /etc/x-ui/x-ui.db ]; then
        echo -e "    • База SQLite:       ${GREEN}/etc/x-ui/x-ui.db (${WHITE}$(du -h /etc/x-ui/x-ui.db 2>/dev/null | awk '{print $1}')${GREEN})${NC}"
    fi
    if systemctl is-active --quiet xray-geo-update.timer 2>/dev/null; then
        echo -e "    • Таймер гео-баз:    ${GREEN}активен (еженедельное обновление)${NC}"
    fi

    # 4. Прослушиваемые порты
    echo -e "\n  ${WHITE}${BOLD}[4/7] Сетевые порты (Listening Sockets):${NC}"
    doctor_check_tcp() {
        local p="$1"
        local desc="$2"
        if timeout 1 bash -c "</dev/tcp/127.0.0.1/$p" 2>/dev/null; then
            echo -e "    • TCP :$p ($desc): ${GREEN}ОТКРЫТ (отвечает)${NC}"
        else
            echo -e "    • TCP :$p ($desc): ${RED}НЕ ОТВЕЧАЕТ${NC}"
        fi
    }
    doctor_check_tcp 443 "Nginx Stream Router"
    doctor_check_tcp 80 "HTTP Redirect / ACME"
    doctor_check_tcp 9443 "Anti-Loop Fallback"
    doctor_check_tcp "${STEAL_PORT:-45443}" "Xray REALITY (свой сайт)"
    doctor_check_tcp "${CLASSIC_PORT:-46443}" "Xray REALITY (внешние сервисы)"
    doctor_check_tcp "${XHTTP_STREAM_PORT:-50443}" "Xray VLESS xHTTP"
    doctor_check_tcp "${PANEL_PORT:-10443}" "3X-UI Web Panel"
    doctor_check_tcp "${SUB_PORT:-55443}" "3X-UI Subscriptions"

    # UDP
    if ss -ulpn 2>/dev/null | grep -q ":${HY2_PORT:-443} "; then
        echo -e "    • UDP :${HY2_PORT:-443} (Hysteria 2): ${GREEN}СЛУШАЕТ${NC}"
    else
        echo -e "    • UDP :${HY2_PORT:-443} (Hysteria 2): ${DIM}не активен или выключен${NC}"
    fi
    if ss -ulpn 2>/dev/null | grep -q ":${AWG_V3_PORT:-8443} "; then
        echo -e "    • UDP :${AWG_V3_PORT:-8443} (AmneziaWG v3): ${GREEN}СЛУШАЕТ${NC}"
    else
        echo -e "    • UDP :${AWG_V3_PORT:-8443} (AmneziaWG v3): ${DIM}не активен или выключен${NC}"
    fi

    # 5. AdGuard Home
    echo -e "\n  ${WHITE}${BOLD}[5/7] AdGuard Home DNS:${NC}"
    if [ -f /opt/AdGuardHome/AdGuardHome ]; then
        if systemctl is-active --quiet AdGuardHome 2>/dev/null; then
            echo -e "    • Статус:            ${GREEN}active (running)${NC}"
        else
            echo -e "    • Статус:            ${RED}NOT RUNNING${NC}"
        fi
        if ss -ulpn 2>/dev/null | grep -q ":53 "; then
            echo -e "    • DNS Порт 53:       ${GREEN}СЛУШАЕТ${NC}"
        else
            echo -e "    • DNS Порт 53:       ${YELLOW}не слушает 53${NC}"
        fi
    else
        echo -e "    • AdGuard Home:      ${DIM}не установлен на этом сервере${NC}"
    fi

    # 6. SSL сертификаты
    echo -e "\n  ${WHITE}${BOLD}[6/7] SSL-сертификаты:${NC}"
    local found_cert=0
    for cert_dir in "/etc/letsencrypt/live" "/etc/ssl/acme"; do
        if [ -d "$cert_dir" ]; then
            for c_path in "$cert_dir"/*/fullchain.pem; do
                if [ -f "$c_path" ]; then
                    found_cert=1
                    local c_dom
                    c_dom=$(basename "$(dirname "$c_path")")
                    local c_exp
                    c_exp=$(openssl x509 -enddate -noout -in "$c_path" 2>/dev/null | cut -d= -f2 || echo "unknown")
                    local exp_sec
                    exp_sec=$(date -d "$c_exp" +%s 2>/dev/null || echo 0)
                    local days_rem=$(( (exp_sec - $(date +%s)) / 86400 ))
                    if [ "$days_rem" -gt 15 ]; then
                        echo -e "    • Домен ${CYAN}$c_dom${NC}: ${GREEN}валиден${NC} (осталось ${GREEN}$days_rem дн.${NC}, до $c_exp)"
                    elif [ "$days_rem" -gt 0 ]; then
                        echo -e "    • Домен ${CYAN}$c_dom${NC}: ${YELLOW}скоро истекает${NC} (осталось $days_rem дн.!)"
                    else
                        echo -e "    • Домен ${CYAN}$c_dom${NC}: ${RED}ИСТЕК!${NC}"
                    fi
                fi
            done
        fi
    done
    [ "$found_cert" -eq 0 ] && echo -e "    • Сертификаты:       ${YELLOW}не найдены${NC}"

    # 7. Безопасность и Маскировка Censys
    echo -e "\n  ${WHITE}${BOLD}[7/7] Аудит маскировки и защита от активных сканеров:${NC}"
    local ip_resp
    ip_resp=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 2 "https://127.0.0.1:443/" 2>/dev/null || echo "DROP")
    if [ "$ip_resp" = "000" ] || [ "$ip_resp" = "DROP" ]; then
        echo -e "    • Запрос по IP (без SNI):   ${GREEN}СБРОС СОЕДИНЕНИЯ (TLS DROP) — Censys не увидит сертификат!${NC}"
    elif [ "$ip_resp" = "444" ]; then
        echo -e "    • Запрос по IP (без SNI):   ${GREEN}HTTP 444 (Сброс соединения)${NC}"
    else
        echo -e "    • Запрос по IP (без SNI):   ${YELLOW}Ответил код $ip_resp (рекомендуется сброс)${NC}"
    fi

    if [ -n "${PRIMARY_DOMAIN:-}" ]; then
        local dom_resp
        dom_resp=$(curl -sk -o /dev/null -w "%{http_code}" --resolve "${PRIMARY_DOMAIN}:443:127.0.0.1" --connect-timeout 2 "https://${PRIMARY_DOMAIN}/" 2>/dev/null || echo "ERR")
        if [ "$dom_resp" = "200" ]; then
            echo -e "    • Домен https://${PRIMARY_DOMAIN}/:  ${GREEN}HTTP 200 OK (Веб-маска активна)${NC}"
        else
            echo -e "    • Домен https://${PRIMARY_DOMAIN}/:  ${YELLOW}Код $dom_resp${NC}"
        fi
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
        echo -e "    • Файервол UFW:              ${GREEN}активен${NC}"
        local leak=0
        for lp in 9443 "${STEAL_PORT:-45443}" "${CLASSIC_PORT:-46443}" "${XHTTP_STREAM_PORT:-50443}"; do
            if ufw status | grep -E "^$lp/tcp.*ALLOW" >/dev/null 2>&1; then
                echo -e "    • ${RED}ВНИМАНИЕ: Порт $lp/tcp открыт в UFW наружу!${NC}"
                leak=1
            fi
        done
        [ "$leak" -eq 0 ] && echo -e "    • Изоляция локальных сокетов:  ${GREEN}OK (внутренние порты 9443, 45443, 46443, 50443 не открыты наружу)${NC}"
    else
        echo -e "    • Файервол UFW:              ${YELLOW}не активен или не установлен${NC}"
    fi

    echo -e "\n  ${DIM}────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${GREEN}Диагностика завершена.${NC}\n"
    exit 0
}

if [ "$CHECK_MODE" -eq 1 ]; then
    run_doctor_check
    exit 0
fi

if [ "$NON_INTERACTIVE" -eq 1 ]; then
    log "Включен НЕИНТЕРАКТИВНЫЙ режим (Ansible / Cloud-Init / CI)."
fi

if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
    warn "Включён режим отладки (--debug): спиннеры отключены, весь вывод команд виден напрямую."
fi

