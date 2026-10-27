# =============================================================
#  ФУНКЦИИ ДИАГНОСТИКИ, РЕЗЕРВНОГО КОПИРОВАНИЯ И SMOKE-TEST
# =============================================================
# @include "common/protocols.sh"

backup_nginx_configs() {
    local bkp_dir="/var/backups/nginx_mask"
    mkdir -p "$bkp_dir"
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local bkp_file="$bkp_dir/nginx_conf_${ts}.tar.gz"

    if [ -d /etc/nginx ]; then
        if tar -czf "$bkp_file" -C /etc nginx 2>/dev/null; then
            export LAST_NGINX_BACKUP="$bkp_file"
            local old_backups
            old_backups=$(ls -1t "$bkp_dir"/nginx_conf_*.tar.gz 2>/dev/null | tail -n +6 || true)
            if [ -n "$old_backups" ]; then
                echo "$old_backups" | xargs -r rm -f 2>/dev/null || true
            fi
            ok "Создана полная резервная копия конфигурации Nginx: $bkp_file (ротация: 5)"
        fi
    fi
}

restore_nginx_configs() {
    local bkp="${LAST_NGINX_BACKUP:-}"
    if [ -z "$bkp" ] || [ ! -f "$bkp" ]; then
        bkp=$(ls -1t /var/backups/nginx_mask/nginx_conf_*.tar.gz 2>/dev/null | head -n 1 || true)
    fi
    if [ -n "$bkp" ] && [ -f "$bkp" ]; then
        log "Откат конфигурации Nginx из резервной копии $bkp..."
        tar -xzf "$bkp" -C /etc 2>/dev/null || true
        nginx -t >/dev/null 2>&1 && { svc_reload nginx 2>/dev/null || systemctl reload nginx 2>/dev/null || true; }
        ok "Конфигурация Nginx возвращена в исходное состояние."
    fi
}

determine_nginx_http2_mode() {
    local ver_raw=""
    if command -v nginx >/dev/null 2>&1; then
        ver_raw=$(nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9.]*\).*/\1/p' || true)
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

detect_active_ssh_port() {
    local active_port=""
    if [ -n "${SSH_CONNECTION:-}" ]; then
        active_port=$(echo "$SSH_CONNECTION" | awk '{print $4}')
    fi
    if [ -z "$active_port" ] || ! [[ "$active_port" =~ ^[0-9]+$ ]]; then
        active_port=$(ss -tlnp 2>/dev/null | grep -E 'sshd|ssh' | grep -vE '127\.0\.0\.1|::1' | awk '{print $4}' | awk -F: '{print $NF}' | sort -n | tail -n1 || echo "")
    fi
    if [ -z "$active_port" ] || ! [[ "$active_port" =~ ^[0-9]+$ ]]; then
        active_port="22"
    fi
    echo "$active_port"
}

get_ssh_service_name() {
    if [ "${ID:-}" = "alpine" ] || [ -f /etc/alpine-release ] || [ -f /etc/init.d/sshd ] || { [ -f /etc/os-release ] && grep -qi "alpine" /etc/os-release; }; then
        echo "sshd"
    elif systemctl list-unit-files 2>/dev/null | grep -q "^sshd\.service"; then
        echo "sshd"
    else
        echo "ssh"
    fi
}

get_wan_ip() {
    if [ -n "${WAN_IP:-}" ]; then
        echo "$WAN_IP"
        return 0
    fi
    local cache_file="/run/setup_mask_wan_ip"
    if [ ! -d /run ] || ! touch /run/.test_w 2>/dev/null; then
        cache_file="/tmp/setup_mask_wan_ip"
    else
        rm -f /run/.test_w 2>/dev/null || true
    fi

    if [ -f "$cache_file" ]; then
        local cached
        cached=$(cat "$cache_file" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$cached" ] && [[ "$cached" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            WAN_IP="$cached"
            echo "$WAN_IP"
            return 0
        fi
    fi

    local ip_val=""
    ip_val=$(curl -s4 --connect-timeout 3 icanhazip.com 2>/dev/null \
          || curl -s4 --connect-timeout 3 api.ipify.org 2>/dev/null \
          || curl -s4 --connect-timeout 3 ifconfig.me 2>/dev/null || true)
    ip_val=$(echo "$ip_val" | tr -d '[:space:]')

    if [ -z "$ip_val" ] || ! [[ "$ip_val" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip_val=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || echo "")
    fi

    if [ -n "$ip_val" ]; then
        WAN_IP="$ip_val"
        echo "$WAN_IP" > "$cache_file" 2>/dev/null || true
    fi
    echo "${WAN_IP:-127.0.0.1}"
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
            proc_info=$(echo "$raw" | sed -n 's/.*users:((\([^)]*\).*/\1/p' | head -n1 | tr -d '"' || true)
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
    elif [ "$proto" = "tcp" ] && timeout 1 bash -c "</dev/tcp/127.0.0.1/$port" 2>/dev/null; then
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
            if echo "$listener" | grep -qi "AdGuardHome"; then
                ok "Порт $PORT_AGH_WEB занят собственным сервисом AdGuard Home — порт сохранен."
            else
                warn "Порт $PORT_AGH_WEB занят активным процессом: ${listener:-сторонней службой}."
                local candidate=3001
                local candidate_found=0
                while [ "$candidate" -le 3053 ]; do
                    if ! is_port_in_use "tcp" "$candidate"; then
                        candidate_found=1
                        break
                    fi
                    candidate=$(( candidate + 1 ))
                done
                if [ "$candidate_found" -eq 1 ]; then
                    PORT_AGH_WEB="$candidate"
                    ok "Автоматическое переназначение: веб-панель AdGuard Home перенесена на свободный порт ${WHITE}$PORT_AGH_WEB${NC} (конфликт устранен)."
                    if declare -f invalidate_checkpoint >/dev/null 2>&1; then
                        invalidate_checkpoint 6 2>/dev/null || true
                    fi
                else
                    die "Все порты в диапазоне 3001–3053 заняты. AdGuard Home не может быть размещен автоматически. Освободите порт или задайте PORT_AGH_WEB вручную."
                fi
            fi
        else
            ok "Порт $PORT_AGH_WEB (AdGuard Home Web) свободен."
        fi
    fi

    # 2. Проверка изоляции DNS (systemd-resolved DoT на 53 / AdGuard Home на PORT_AGH_DNS)
    if [[ "${ENABLE_AGH:-0}" == "1" || "${ENABLE_AGH,,}" == "y" ]]; then
        local agh_dns_port="${PORT_AGH_DNS:-10053}"
        if is_port_in_use "udp" "$agh_dns_port" || is_port_in_use "tcp" "$agh_dns_port"; then
            warn "Порт $agh_dns_port (AdGuard Home DNS) уже используется. Рекомендуется освободить порт."
        else
            ok "Порт $agh_dns_port (AdGuard Home DNS изоляция) свободен. Системный порт 53 сохранен для systemd-resolved DoT."
        fi
    fi

    # 3. Проверка внешних портов маршрутизации и маскирования (80 и 443 TCP)
    local _web_stack="${ENABLE_WEB_STACK:-y}"
    local _dokploy_coexist="${DOKPLOY_COEXISTENCE:-n}"
    if [[ "${_dokploy_coexist,,}" == "y" || "${_dokploy_coexist}" == "1" || "${_dokploy_coexist,,}" == "true" || "${_web_stack,,}" == "dokploy" ]]; then
        ok "Режим бесконфликтного сосуществования с Dokploy активен: порты 80 и 443 зарезервированы для Traefik (проксирование через WebSocket / Docker Compose)."
    elif [[ "${_web_stack,,}" == "y" || "${_web_stack}" == "1" || "${_web_stack,,}" == "true" ]]; then
        for p in 80 443; do
            if is_port_in_use "tcp" "$p"; then
                local w_owner
                w_owner=$(get_port_listener_info "tcp" "$p")
                if echo "$w_owner" | grep -qi "nginx"; then
                    ok "Порт $p слушает Nginx (будет переконфигурирован в единый L4/L7 роутер маскирования)."
                else
                    die "Порт $p занят сторонним процессом: ${w_owner:-не Nginx}. Для сквозного TLS/HTTP маскирования требуется порт $p."
                fi
            else
                ok "Порт $p (Веб / Маскирование) свободен."
            fi
        done

        # 3.1. Проверка существующих сторонних сайтов на прямой listen 443
        local conflicting_vhosts=()
        for vf in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
            [ -f "$vf" ] || continue
            local b_name
            b_name=$(basename "$vf")
            case "$b_name" in
                default|default.conf|01-main.conf|02-*.conf|03-adguard.conf|vpn_mask.conf)
                    continue
                    ;;
            esac
            if grep -Eq 'listen[[:space:]]+([^;]*:)?443' "$vf" 2>/dev/null; then
                if ! grep -q 'listen[[:space:]]+unix:' "$vf" 2>/dev/null; then
                    conflicting_vhosts+=("$b_name")
                fi
            fi
        done
        if [ ${#conflicting_vhosts[@]} -gt 0 ]; then
            warn "Обнаружены существующие vhost с прямым слушанием порта 443: ${conflicting_vhosts[*]}"
            warn "Nginx Stream роутер использует порт 443. Такие vhost должны быть адаптированы под сокет unix:/dev/shm/nginx-http.sock."
        fi

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
    fi

    # 5. Проверка порта автономного AmneziaWG (UDP)
    local _awg_sa="${ENABLE_AWG_STANDALONE:-0}"
    if [[ "${_awg_sa,,}" == "y" || "${_awg_sa}" == "1" || "${_awg_sa,,}" == "true" ]]; then
        local awg_p="${AWG_STANDALONE_PORT:-8445}"
        if is_port_in_use "udp" "$awg_p"; then
            local awg_owner
            awg_owner=$(get_port_listener_info "udp" "$awg_p")
            if echo "$awg_owner" | grep -qiE "amnezia|wireguard"; then
                ok "UDP-порт $awg_p (AmneziaWG) занят собственной службой ($awg_owner)."
            else
                warn "UDP-порт $awg_p (AmneziaWG) занят сторонним процессом: ${awg_owner:-неизвестно}. Возможен конфликт."
            fi
        else
            ok "Порт $awg_p/udp (AmneziaWG Standalone) свободен."
        fi
    fi

    # 6. Проверка портов протоколов следующего поколения (MASQUE, ShadowTLS, NaïveProxy)
    local _masque_en="${ENABLE_MASQUE:-n}"
    if [[ "${_masque_en,,}" == "y" || "${_masque_en}" == "1" || "${_masque_en,,}" == "true" ]]; then
        local m_port="${MASQUE_PORT:-8449}"
        if [[ "${_awg_sa,,}" == "y" || "${_awg_sa}" == "1" || "${_awg_sa,,}" == "true" ]] && [ "$m_port" = "${AWG_STANDALONE_PORT:-8445}" ]; then
            warn "Коллизия портов: MASQUE и AmneziaWG Standalone используют один UDP-порт ($m_port)! Измените MASQUE_PORT или AWG_STANDALONE_PORT."
        fi
        if is_port_in_use "udp" "$m_port"; then
            local m_owner
            m_owner=$(get_port_listener_info "udp" "$m_port")
            warn "Порт $m_port/udp (MASQUE) занят: ${m_owner:-сторонней службой}."
        else
            ok "Порт $m_port/udp (MASQUE HTTP/3 Datagram) свободен."
        fi
    fi

    local _stls_en="${ENABLE_SHADOWTLS:-n}"
    if [[ "${_stls_en,,}" == "y" || "${_stls_en}" == "1" || "${_stls_en,,}" == "true" ]]; then
        local st_port="${SHADOWTLS_PORT:-8543}"
        if is_port_in_use "tcp" "$st_port"; then
            local st_owner
            st_owner=$(get_port_listener_info "tcp" "$st_port")
            warn "Порт $st_port/tcp (ShadowTLS v4) занят: ${st_owner:-сторонней службой}."
        else
            ok "Порт $st_port/tcp (ShadowTLS v4) свободен."
        fi
    fi

    local _naive_en="${ENABLE_NAIVE:-n}"
    if [[ "${_naive_en,,}" == "y" || "${_naive_en}" == "1" || "${_naive_en,,}" == "true" ]]; then
        local n_port="${NAIVE_PORT:-8446}"
        if is_port_in_use "tcp" "$n_port"; then
            local n_owner
            n_owner=$(get_port_listener_info "tcp" "$n_port")
            warn "Порт $n_port/tcp (NaïveProxy) занят: ${n_owner:-сторонней службой}."
        else
            ok "Порт $n_port/tcp (NaïveProxy) свободен."
        fi
    fi

    local _dnstt_en="${ENABLE_DNSTT:-n}"
    if [[ "${_dnstt_en,,}" == "y" || "${_dnstt_en}" == "1" || "${_dnstt_en,,}" == "true" ]]; then
        local d_port="${DNSTT_PORT:-53053}"
        if is_port_in_use "udp" "$d_port"; then
            local d_owner
            d_owner=$(get_port_listener_info "udp" "$d_port")
            warn "Порт $d_port/udp (DNSTT DoH Tunnel) занят: ${d_owner:-сторонней службой}."
        else
            ok "Порт $d_port/udp (DNSTT DoH Tunnel) свободен."
        fi
    fi

    local _mieru_en="${ENABLE_MIERU:-n}"
    if [[ "${_mieru_en,,}" == "y" || "${_mieru_en}" == "1" || "${_mieru_en,,}" == "true" ]]; then
        local mr_port="${MIERU_PORT:-8450}"
        local mr_trans="${MIERU_TRANSPORT:-BOTH}"
        local check_transports=()
        case "${mr_trans^^}" in
            TCP) check_transports=(tcp) ;;
            UDP) check_transports=(udp) ;;
            *) check_transports=(tcp udp) ;;
        esac

        local cur_t
        for cur_t in "${check_transports[@]}"; do
            if [[ "$mr_port" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                local r_start="${BASH_REMATCH[1]}" r_end="${BASH_REMATCH[2]}"
                local conflict_p="" p_owner="" p
                for (( p=r_start; p<=r_end; p++ )); do
                    if is_port_in_use "$cur_t" "$p"; then
                        conflict_p="$p"
                        p_owner=$(get_port_listener_info "$cur_t" "$p")
                        break
                    fi
                done
                if [ -n "$conflict_p" ]; then
                    warn "Порт $conflict_p/$cur_t из диапазона Mieru ($mr_port) занят: ${p_owner:-сторонней службой}."
                else
                    ok "Диапазон портов $mr_port/$cur_t (Mieru Proxy) свободен."
                fi
            else
                local mr_base="${mr_port%%[-:]*}"
                if is_port_in_use "$cur_t" "$mr_base"; then
                    local mr_owner
                    mr_owner=$(get_port_listener_info "$cur_t" "$mr_base")
                    warn "Порт $mr_port/$cur_t (Mieru Proxy) занят: ${mr_owner:-сторонней службой}."
                else
                    ok "Порт $mr_port/$cur_t (Mieru Proxy) свободен."
                fi
            fi
        done
    fi

    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}\n"
}

check_required_service() {
    if systemctl is-active --quiet "$1"; then ok "Service $1: active";
    else warn "Service $1: inactive"; return 1; fi
}

check_required_file() {
    [ -s "$1" ] || { warn "Missing required file: $1"; return 1; }
}

check_required_port() {
    local protocol="$1" port="$2" listeners
    local p_flag="-ltn"
    [ "$protocol" = udp ] && p_flag="-lun"

    if [[ "$port" =~ ^([0-9]+)[-:]+([0-9]+)$ ]]; then
        local p_start="${BASH_REMATCH[1]}" p_end="${BASH_REMATCH[2]}"
        p_start="$((10#$p_start))"
        p_end="$((10#$p_end))"
        if [ "$p_start" -gt "$p_end" ]; then
            local tmp="$p_start"
            p_start="$p_end"
            p_end="$tmp"
        fi
        local p missing_ports=()
        for (( p=p_start; p<=p_end; p++ )); do
            listeners=$(ss -H $p_flag "sport = :$p" 2>/dev/null) || true
            if [ -z "$listeners" ]; then
                missing_ports+=("$p")
            fi
        done
        if [ "${#missing_ports[@]}" -gt 0 ]; then
            warn "Port range $port/$protocol: not listening on port(s): ${missing_ports[*]}"
            return 1
        fi
        ok "Port range $port/$protocol: all listening (${p_start}..${p_end})"
        return 0
    fi

    local check_port="${port%%[-:]*}"
    listeners=$(ss -H $p_flag "sport = :$check_port" 2>/dev/null) || return 1
    [ -n "$listeners" ] || { warn "Port $port/$protocol is not listening"; return 1; }
    ok "Port $port/$protocol: listening"
}

post_install_sanity_check() {
    local all_ok=1 flag protocol variable fallback port
    local bin_dir="${LOCAL_BIN_DIR:-/usr/local/bin}"
    local -A checked_services=()
    if is_true "${ENABLE_WEB_STACK:-y}"; then
        check_required_service nginx || all_ok=0
        nginx -t >/dev/null 2>&1 || all_ok=0
        check_required_port tcp 443 || all_ok=0
        if is_true "${AUTO_SETUP_3XUI:-y}"; then
            check_required_service x-ui || all_ok=0
            check_required_port tcp "${PANEL_PORT:-10443}" || all_ok=0
            check_required_port tcp "${SUB_PORT:-55443}" || all_ok=0
            check_required_port tcp "${XHTTP_STREAM_PORT:-50443}" || all_ok=0
            if is_true "${ENABLE_STEAL:-n}"; then
                for port in "${STEAL_PORTS_LIST[@]:-${STEAL_PORT:-45443}}"; do
                    check_required_port tcp "$port" || all_ok=0
                done
            fi
            if is_true "${ENABLE_CLASSIC:-n}"; then
                for port in "${CLASSIC_PORTS_LIST[@]:-${CLASSIC_PORT:-46443}}"; do
                    check_required_port tcp "$port" || all_ok=0
                done
            fi
        fi
        while read -r flag protocol port; do
            [ "$flag" = AWG-standalone ] && continue
            case "$flag" in
                MASQUE)
                    if [ ! -x "${bin_dir}/sing-box" ] && ! command -v sing-box >/dev/null 2>&1; then
                        warn "Служба MASQUE: бинарник sing-box не установлен."
                        all_ok=0
                        continue
                    fi
                    if [ -z "${checked_services[sing-box-masque]:-}" ]; then
                        check_required_service sing-box-masque || all_ok=0
                        checked_services[sing-box-masque]=1
                    fi
                    ;;
                NaiveProxy)
                    if [ ! -x "${bin_dir}/caddy-naive" ] && [ ! -x "${bin_dir}/caddy" ] && ! command -v caddy-naive >/dev/null 2>&1 && ! command -v caddy >/dev/null 2>&1; then
                        warn "Служба NaiveProxy: бинарник caddy-naive не установлен."
                        all_ok=0
                        continue
                    fi
                    if [ -z "${checked_services[caddy-naive]:-}" ]; then
                        check_required_service caddy-naive || all_ok=0
                        checked_services[caddy-naive]=1
                    fi
                    ;;
                DNSTT)
                    if [ ! -x "${bin_dir}/dnstt-server" ] && ! command -v dnstt-server >/dev/null 2>&1; then
                        warn "Служба DNSTT: бинарник dnstt-server не установлен."
                        all_ok=0
                        continue
                    fi
                    if [ -z "${checked_services[dnstt-server]:-}" ]; then
                        check_required_service dnstt-server || all_ok=0
                        checked_services[dnstt-server]=1
                    fi
                    ;;
                Mieru)
                    if [ ! -x "${bin_dir}/mita" ] && ! command -v mita >/dev/null 2>&1; then
                        warn "Служба Mieru: бинарник mita не установлен."
                        all_ok=0
                        continue
                    fi
                    if [ -z "${checked_services[mita]:-}" ]; then
                        check_required_service mita || all_ok=0
                        checked_services[mita]=1
                    fi
                    ;;
                ShadowTLS)
                    if [ ! -x "${bin_dir}/shadow-tls" ] && ! command -v shadow-tls >/dev/null 2>&1; then
                        warn "Служба ShadowTLS: бинарник shadow-tls не установлен."
                        all_ok=0
                        continue
                    fi
                    if [ -z "${checked_services[shadow-tls]:-}" ]; then
                        check_required_service shadow-tls || all_ok=0
                        checked_services[shadow-tls]=1
                    fi
                    ;;
                Wstunnel)
                    if [ ! -x "${bin_dir}/wstunnel" ] && ! command -v wstunnel >/dev/null 2>&1; then
                        warn "Служба Wstunnel: бинарник wstunnel не установлен."
                        all_ok=0
                        continue
                    fi
                    if [ -z "${checked_services[wstunnel]:-}" ]; then
                        check_required_service wstunnel || all_ok=0
                        checked_services[wstunnel]=1
                    fi
                    ;;
            esac
            check_required_port "$protocol" "$port" || all_ok=0
        done < <(selected_protocol_ports)
        if is_true "${ENABLE_ZAPRET:-n}"; then
            check_required_service zapret-server || all_ok=0
        fi
        if is_true "${ENABLE_AGH:-n}"; then
            check_required_service AdGuardHome || all_ok=0
            check_required_port tcp "${PORT_AGH_WEB:-3000}" || all_ok=0
            local agh_dns_check="${PORT_AGH_DNS:-10053}"
            check_required_port udp "$agh_dns_check" || all_ok=0
        fi
        # curl validates the certificate and hostname as well as HTTPS availability.
        if ! curl -fLsS --connect-timeout 3 --max-time 10 -o /dev/null \
            --resolve "${PRIMARY_DOMAIN}:443:127.0.0.1" "https://${PRIMARY_DOMAIN}/"; then
            warn "HTTPS/certificate check failed: ${PRIMARY_DOMAIN}"
            all_ok=0
        fi
    fi
    if is_true "${ENABLE_AWG_STANDALONE:-n}"; then
        check_required_service awg-quick@awg0 || all_ok=0
        check_required_port udp "${AWG_STANDALONE_PORT:-8445}" || all_ok=0
        check_required_file /etc/amnezia/amneziawg/awg0.conf || all_ok=0
        check_required_file /root/awg/client-1.conf || all_ok=0
    fi
    if [ "$all_ok" -eq 1 ]; then
        ok "All selected components passed verification."
        return 0
    fi
    warn "Installation verification failed. Fix the reported services and resume installation."
    return 1
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
        local agh_dns_check="${PORT_AGH_DNS:-10053}"
        if ss -ulpn 2>/dev/null | grep -q ":${agh_dns_check} "; then
            echo -e "    • DNS Порт ${agh_dns_check}:    ${GREEN}СЛУШАЕТ${NC}"
        else
            echo -e "    • DNS Порт ${agh_dns_check}:    ${YELLOW}не слушает ${agh_dns_check}${NC}"
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

if [ "${CHECK_MODE:-0}" -eq 1 ]; then
    run_doctor_check
    exit 0
fi

if [ "${NON_INTERACTIVE:-0}" -eq 1 ]; then
    log "Включен НЕИНТЕРАКТИВНЫЙ режим (Ansible / Cloud-Init / CI)."
fi

if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
    warn "Включён режим отладки (--debug): спиннеры отключены, весь вывод команд виден напрямую."
fi

