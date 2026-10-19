#!/usr/bin/env bash
# ==============================================================================
# Nginx L4 Stream Router Mask for 3X-UI — Unified Master Installer
# GitHub: https://github.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui
# ==============================================================================

# Exit on severe unhandled errors
set -o pipefail

SCRIPT_VERSION="v8.2.0"

# Защита от аварийного обрыва SSH-сессии при установке
trap 'echo -e "\n[!] Внимание: получен сигнал SIGHUP, процесс установки продолжается в фоне..." >> "${INSTALL_LOG:-/var/log/nginx_mask_install.log}" 2>&1' SIGHUP

# Terminal Colors & Styles
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
MAGENTA=$'\033[0;35m'
CYAN=$'\033[0;36m'
WHITE=$'\033[1;37m'
DIM=$'\033[2m'
BOLD=$'\033[1m'
NC=$'\033[0m'
RESET=$'\033[0m'

# Status Symbols
CHECK="✔"
CROSS="✖"
ARROW="➜"
STAR="★"
INFO="ℹ"
LOCK="🔒"
SHIELD="🛡"
# Standard Logging Functions
log()  { echo -e "  ${CYAN}[+]${NC} $*"; }
ok()   { echo -e "  ${GREEN}${CHECK:-✔}${NC} $*"; }
warn() { echo -e "  ${YELLOW}[!]${NC} $*"; }
die()  { echo -e "  ${RED}${CROSS:-✖} $*${NC}" >&2; exit 1; }
# =============================================================
#  ФУНКЦИИ ДИАГНОСТИКИ, РЕЗЕРВНОГО КОПИРОВАНИЯ И SMOKE-TEST
# =============================================================

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
        nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
        ok "Конфигурация Nginx возвращена в исходное состояние."
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
    if systemctl list-unit-files 2>/dev/null | grep -q "^sshd\.service"; then
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
        local m_port="${MASQUE_PORT:-8445}"
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

# =============================================================
#  ФУНКЦИИ ФАЗЫ УСТАНОВКИ (определены до фазы для читаемости и --debug)
# =============================================================

apply_sysctl_and_limits() {
    # Загрузка модуля nf_conntrack и сохранение для автозагрузки при старте ОС
    modprobe nf_conntrack 2>/dev/null || true
    if [ -d /etc/modules-load.d ]; then
        echo "nf_conntrack" > /etc/modules-load.d/99-vless-conntrack.conf 2>/dev/null || true
    fi

    cat << 'EOF' > /etc/sysctl.d/99-vless-tuning.conf
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.ip_nonlocal_bind = 1
vm.swappiness = 10

# Отключение IPv6 (защита от утечек трафика)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# Защита таблицы conntrack от зависших сессий (разрывы ТСПУ/DPI без FIN/RST)
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

net.ipv4.ip_local_port_range = 1024 65535
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_max_tw_buckets = 524288
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_orphan_retries = 2
net.ipv4.tcp_slow_start_after_idle = 0

net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 212992
net.core.wmem_default = 212992
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 131072 16777216
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

vm.dirty_ratio = 6
vm.dirty_background_ratio = 3

net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_mtu_probe_floor = 1024

fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
net.ipv4.tcp_notsent_lowat = 16384
EOF

    sysctl --system >/dev/null 2>&1 || true

    # Оптимизация резолвера gai.conf (приоритет IPv4 для исключения таймаутов mtg/Go QUIC)
    if [ -f /etc/gai.conf ]; then
        sed -i 's/#precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf 2>/dev/null || true
    fi

    # Хранение системных логов journald в RAM (Storage=volatile, без записи на диск)
    mkdir -p /etc/systemd/journald.conf.d/
    cat << 'EOF' > /etc/systemd/journald.conf.d/00-volatile.conf
[Journal]
Storage=volatile
RuntimeMaxUse=64M
MaxRetentionSec=1day
EOF
    systemctl restart systemd-journald 2>/dev/null || true

    # Disable IPv6 immediately on all active interfaces (runtime)
    if [ -d /proc/sys/net/ipv6/conf ]; then
        for iface in $(ls /proc/sys/net/ipv6/conf/ 2>/dev/null); do
            sysctl -w net.ipv6.conf."$iface".disable_ipv6=1 >/dev/null 2>&1 || true
        done
    fi

    # Hardware/Kernel level disable via GRUB (survives cloud network resets upon reboot)
    if [ -f /etc/default/grub ]; then
        if ! grep -q "ipv6.disable=1" /etc/default/grub; then
            cp /etc/default/grub /etc/default/grub.bak 2>/dev/null || true
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1 /' /etc/default/grub
            sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT='/GRUB_CMDLINE_LINUX_DEFAULT='ipv6.disable=1 /" /etc/default/grub
            sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="ipv6.disable=1 /' /etc/default/grub
            sed -i "s/GRUB_CMDLINE_LINUX='/GRUB_CMDLINE_LINUX='ipv6.disable=1 /" /etc/default/grub
            if command -v update-grub &>/dev/null; then
                update-grub >/dev/null 2>&1 || true
            elif command -v grub-mkconfig &>/dev/null; then
                grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
            fi
        fi
    fi

    # Crontab guard against cloud-init / network daemon sysctl overrides on boot
    if command -v crontab &>/dev/null; then
        local cron_job="@reboot sleep 10 && sysctl --system"
        if ! crontab -l 2>/dev/null | grep -Fq "$cron_job"; then
            (crontab -l 2>/dev/null || true; echo "$cron_job") | crontab - 2>/dev/null || true
        fi
    fi

    # Disable IPv6 in UFW configuration
    if [ -f /etc/default/ufw ]; then
        if grep -q "^IPV6=" /etc/default/ufw; then
            sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw 2>/dev/null || true
        else
            echo "IPV6=no" >> /etc/default/ufw 2>/dev/null || true
        fi
    fi

    cat << 'EOF' > /etc/security/limits.d/99-proxy-limits.conf
* soft nofile 524288
* hard nofile 524288
root soft nofile 524288
root hard nofile 524288
www-data soft nofile 524288
www-data hard nofile 524288
nginx soft nofile 524288
nginx hard nofile 524288
EOF

    # TCP MSS Clamping — предотвращение PMTU Blackhole при блокировке ICMP (для ядро/TUN/FORWARD трафика)
    # Примечание: действует на маршрутизируемый трафик ядра Linux; не влияет на userspace gVisor в 3X-UI.
    if ! iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        if ! ip6tables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
            ip6tables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        fi
    fi

    # Персистентность MSS Clamping через /etc/ufw/before.rules и before6.rules
    if [ -f /etc/ufw/before.rules ] && ! grep -q 'TCPMSS --clamp-mss-to-pmtu' /etc/ufw/before.rules 2>/dev/null; then
        if ! grep -q '^\*mangle' /etc/ufw/before.rules 2>/dev/null; then
            sed -i '/^\*filter/i\# TCP MSS Clamping - prevents PMTU blackhole (added by setup_mask.sh)\n*mangle\n:FORWARD ACCEPT [0:0]\n-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\nCOMMIT\n' /etc/ufw/before.rules
        else
            sed -i '/^\*mangle/a\-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' /etc/ufw/before.rules
        fi
    fi
    if [ -f /etc/ufw/before6.rules ] && ! grep -q 'TCPMSS --clamp-mss-to-pmtu' /etc/ufw/before6.rules 2>/dev/null; then
        if ! grep -q '^\*mangle' /etc/ufw/before6.rules 2>/dev/null; then
            sed -i '/^\*filter/i\# TCP MSS Clamping IPv6 - prevents PMTU blackhole (added by setup_mask.sh)\n*mangle\n:FORWARD ACCEPT [0:0]\n-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\nCOMMIT\n' /etc/ufw/before6.rules
        else
            sed -i '/^\*mangle/a\-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' /etc/ufw/before6.rules
        fi
    fi
}

supports_x86_64_v3() {
    local arch
    arch=$(uname -m 2>/dev/null || echo "unknown")
    if [ "$arch" != "x86_64" ]; then
        return 0
    fi
    if [ -x /lib64/ld-linux-x86-64.so.2 ]; then
        if /lib64/ld-linux-x86-64.so.2 --help 2>&1 | grep -E 'x86-64-v3' | grep -q 'supported'; then
            return 0
        fi
    fi
    if grep -q "avx2" /proc/cpuinfo 2>/dev/null && grep -q "bmi2" /proc/cpuinfo 2>/dev/null; then
        return 0
    fi
    return 1
}

# ==============================================================================
#  Подсистема безопасности хоста: SSH Hardening, SSH Keys, Dual-Port & Fail2ban
# ==============================================================================

WHITE="${WHITE:-}"
NC="${NC:-}"
YELLOW="${YELLOW:-}"
RED="${RED:-}"
GREEN="${GREEN:-}"
CYAN="${CYAN:-}"
BOLD="${BOLD:-}"
ARROW="${ARROW:-}"
DIM="${DIM:-}"

has_authorized_keys() {
    local target_user="${1:-root}"
    local user_home
    if [ "$target_user" = "root" ]; then
        user_home="/root"
    else
        user_home=$(eval echo "~$target_user" 2>/dev/null || echo "/home/$target_user")
    fi
    local auth_file="${user_home}/.ssh/authorized_keys"
    if [ -f "$auth_file" ] && [ -s "$auth_file" ]; then
        if grep -qE '^[[:space:]]*(ssh-rsa|ssh-ed25519|ecdsa-sha2-[a-z0-9]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-[a-z0-9]+@openssh\.com)' "$auth_file" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

add_authorized_key() {
    local key_data="$1"
    local target_user="${2:-root}"
    [ -n "$key_data" ] || return 1

    local user_home
    if [ "$target_user" = "root" ]; then
        user_home="/root"
    else
        user_home=$(eval echo "~$target_user" 2>/dev/null || echo "/home/$target_user")
    fi

    mkdir -p "${user_home}/.ssh"
    chmod 700 "${user_home}/.ssh" 2>/dev/null || true

    local auth_file="${user_home}/.ssh/authorized_keys"
    touch "$auth_file"
    chmod 600 "$auth_file" 2>/dev/null || true

    # Проверка, не добавлен ли уже этот ключ
    local clean_key
    clean_key=$(echo "$key_data" | awk '{print $1" "$2}')
    if [ -n "$clean_key" ] && grep -Fq "$clean_key" "$auth_file" 2>/dev/null; then
        ok "SSH-ключ уже присутствует в $auth_file."
        return 0
    fi

    echo "$key_data" >> "$auth_file"
    chmod 600 "$auth_file" 2>/dev/null || true
    if [ "$target_user" != "root" ] && command -v chown >/dev/null 2>&1; then
        chown -R "${target_user}:${target_user}" "${user_home}/.ssh" 2>/dev/null || true
    fi
    ok "SSH-ключ успешно добавлен в ${auth_file}."
    return 0
}

generate_ed25519_keypair() {
    local target_user="${1:-root}"
    local user_home
    if [ "$target_user" = "root" ]; then
        user_home="/root"
    else
        user_home=$(eval echo "~$target_user" 2>/dev/null || echo "/home/$target_user")
    fi

    mkdir -p "${user_home}/.ssh"
    chmod 700 "${user_home}/.ssh" 2>/dev/null || true

    local key_file="${user_home}/.ssh/id_ed25519_$(date +%Y%m%d_%H%M%S)"
    if ! ssh-keygen -t ed25519 -f "$key_file" -C "server-${target_user}-$(date +%Y%m%d)" -N "" -q 2>/dev/null; then
        warn "Не удалось сгенерировать пару ключей ssh-keygen."
        return 1
    fi

    local auth_file="${user_home}/.ssh/authorized_keys"
    cat "${key_file}.pub" >> "$auth_file"
    chmod 600 "$auth_file" "${key_file}" 2>/dev/null || true
    if [ "$target_user" != "root" ] && command -v chown >/dev/null 2>&1; then
        chown -R "${target_user}:${target_user}" "${user_home}/.ssh" 2>/dev/null || true
    fi

    echo
    echo -e "${RED}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║${NC}             ${WHITE}${BOLD}🔑 ВНИМАНИЕ: СОХРАНИТЕ ЭТОТ ПРИВАТНЫЙ КЛЮЧ ПРЯМО СЕЙЧАС!${NC}           ${RED}║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${YELLOW}Скопируйте всё содержимое между линиями и сохраните в файл на своем ПК${NC}"
    echo -e "  ${YELLOW}(например, ~/.ssh/server_key или puttygen -> id_ed25519.ppk):${NC}"
    echo -e "${CYAN}--------------------------------------------------------------------------------${NC}"
    cat "$key_file"
    echo -e "${CYAN}--------------------------------------------------------------------------------${NC}"
    echo
    if [ -t 0 ]; then
        local dummy=""
        read -r -p "  Нажмите [Enter] после того, как сохранили приватный ключ в надежном месте..." dummy </dev/tty 2>/dev/null || read -r -p "  Нажмите [Enter]..." dummy 2>/dev/null || true
    fi
    ok "SSH-ключ Ed25519 сгенерирован и добавлен в ${auth_file}."
    return 0
}

verify_ssh_local_port() {
    local port="$1"
    local timeout_sec="${2:-3}"

    # 1. Попытка чтения баннера SSH-2.0 через Bash /dev/tcp
    local banner=""
    banner=$(timeout "$timeout_sec" bash -c "exec 3<>/dev/tcp/127.0.0.1/$port; head -n 1 <&3" 2>/dev/null || true)
    if [[ "$banner" == *"SSH-2.0"* ]]; then
        return 0
    fi

    # 2. Попытка через nc
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w "$timeout_sec" 127.0.0.1 "$port" 2>/dev/null; then
            return 0
        fi
    fi

    # 3. Попытка через ss
    if command -v ss >/dev/null 2>&1; then
        if ss -tln sport = ":$port" 2>/dev/null | grep -q ":$port"; then
            return 0
        fi
    fi

    return 1
}

apply_ssh_configuration() {
    local target_port="${1:-22}"
    local active_port="${2:-22}"
    local disable_pwd="${3:-n}"

    local ssh_svc
    ssh_svc=$(get_ssh_service_name)

    # 1. Отключаем systemd socket-activation (Ubuntu 22.10+, Ubuntu 24.04 LTS),
    # чтобы служба корректно слушала кастомный порт через стандартный unit.
    systemctl stop ssh.socket 2>/dev/null || true
    systemctl disable ssh.socket 2>/dev/null || true
    systemctl enable "${ssh_svc}.service" 2>/dev/null || true

    # 2. Обновляем базовый /etc/ssh/sshd_config с гарантией директивы Include
    if [ -f /etc/ssh/sshd_config ]; then
        sed -i -E "s/^[#\s]*Port [0-9]+/Port ${target_port}/" /etc/ssh/sshd_config 2>/dev/null || true
        if ! grep -q "^Include /etc/ssh/sshd_config.d/\*\.conf" /etc/ssh/sshd_config 2>/dev/null; then
            sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config 2>/dev/null || true
        fi
    fi

    # 3. Drop-in конфигурация: ДВУХПОРТОВЫЙ РЕЖИМ при смене порта
    mkdir -p /etc/ssh/sshd_config.d/
    local dropin_file="/etc/ssh/sshd_config.d/99-hardening.conf"

    # Формируем директивы портов
    local port_directives="Port ${target_port}"
    if [ "$target_port" -ne "$active_port" ]; then
        port_directives="Port ${target_port}
Port ${active_port}"
    fi

    # Проверяем, можно ли отключить вход по паролю (ТОЛЬКО если есть валидные ключи)
    local pwd_directives=""
    if is_true "$disable_pwd"; then
        if has_authorized_keys "root"; then
            pwd_directives="PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes"
            ok "Вход по паролю будет отключен (авторизованные SSH-ключи подтверждены)."
        else
            warn "Внимание: в authorized_keys не найдено SSH-ключей! Вход по паролю оставлен включенным для предотвращения потери доступа."
        fi
    fi

    cat << EOF > "$dropin_file"
# Сгенерировано Nginx Stream Router Security Subsystem
${port_directives}
AddressFamily inet
PubkeyAuthentication yes
${pwd_directives}
EOF
    chmod 600 "$dropin_file" 2>/dev/null || true

    # 4. Проверяем валидность конфигурации sshd перед перезапуском
    mkdir -p /run/sshd 2>/dev/null || true
    if /usr/sbin/sshd -t 2>/dev/null; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl restart "${ssh_svc}.service" 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    else
        # При синтаксической ошибке — безопасный откат
        warn "Ошибка валидации sshd -t при настройке SSH! Выполнен откат изменений drop-in для предотвращения потери доступа."
        rm -f "$dropin_file"
        systemctl restart "${ssh_svc}.service" 2>/dev/null || true
        return 1
    fi

    # 5. Локальный тест ответа порта
    if [ "$target_port" -ne "$active_port" ]; then
        if verify_ssh_local_port "$target_port" 5; then
            ok "Служба SSH запущена в переходном режиме: слушает новый порт ${WHITE}${target_port}${NC} и резервный порт ${WHITE}${active_port}${NC}."
        else
            warn "Локальный тест порта $target_port не дал ответа! Выполняется откат на активный порт $active_port..."
            cat << EOF > "$dropin_file"
Port ${active_port}
AddressFamily inet
PubkeyAuthentication yes
EOF
            chmod 600 "$dropin_file" 2>/dev/null || true
            systemctl restart "${ssh_svc}.service" 2>/dev/null || true
            return 1
        fi
    else
        ok "Конфигурация SSH успешно применена (порт ${WHITE}${target_port}${NC})."
    fi

    return 0
}

deploy_ssh_transition_watcher() {
    local target_port="$1"
    local active_port="$2"
    local ttl_hours="${3:-24}"

    [ "$target_port" -eq "$active_port" ] && return 0

    local watcher_script="/usr/local/bin/ssh-transition-watcher.sh"
    local watcher_service="/etc/systemd/system/ssh-transition-watcher.service"
    local bin_dir="/usr/local/bin"
    [ -d "$bin_dir" ] || mkdir -p "$bin_dir" 2>/dev/null || true

    cat << 'EOF' > "$watcher_script"
#!/usr/bin/env bash
# SSH Port Transition Watcher — безопасное закрытие старого порта при первом успешном входе на новый
set -u
TARGET_PORT="${1:-2222}"
ACTIVE_PORT="${2:-22}"
TTL_HOURS="${3:-24}"

START_TIME=$(date +%s)
MAX_RUNTIME=$((TTL_HOURS * 3600))

logger -t ssh-watcher "Запущен безопасный монитор перехода SSH: цель=$TARGET_PORT, старый=$ACTIVE_PORT, TTL=${TTL_HOURS}ч."

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    if [ "$ELAPSED" -ge "$MAX_RUNTIME" ]; then
        logger -t ssh-watcher "Истек лимит времени ожидания (${TTL_HOURS}ч). Старый порт $ACTIVE_PORT оставлен для предотвращения потери доступа."
        exit 0
    fi

    # Ищем установленное внешнее соединение на целевой порт
    EST=$(ss -tn sport = ":${TARGET_PORT}" state established 2>/dev/null | grep -vE '127\.0\.0\.1|::1|Local Address' | wc -l)
    if [ "$EST" -gt 0 ]; then
        logger -t ssh-watcher "Обнаружено успешное подключение на порт $TARGET_PORT! Финализация перехода и закрытие порта $ACTIVE_PORT..."

        # 1. Удаляем старый порт из drop-in sshd
        if [ -f /etc/ssh/sshd_config.d/99-hardening.conf ]; then
            sed -i "/^Port ${ACTIVE_PORT}$/d" /etc/ssh/sshd_config.d/99-hardening.conf 2>/dev/null || true
        fi
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true

        # 2. Удаляем старый порт из UFW
        if command -v ufw >/dev/null 2>&1; then
            ufw delete allow "${ACTIVE_PORT}/tcp" >/dev/null 2>&1 || true
        fi

        # 3. Обновляем Fail2ban
        if [ -f /etc/fail2ban/jail.local ]; then
            sed -i "s/port = .*/port = ${TARGET_PORT}/" /etc/fail2ban/jail.local 2>/dev/null || true
            systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban 2>/dev/null || true
        fi

        logger -t ssh-watcher "Переход SSH успешно завершен. Порт $ACTIVE_PORT закрыт, активен только $TARGET_PORT."
        systemctl disable --now ssh-transition-watcher.service 2>/dev/null || true
        rm -f /etc/systemd/system/ssh-transition-watcher.service /usr/local/bin/ssh-transition-watcher.sh 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        exit 0
    fi

    sleep 5
done
EOF
    chmod +x "$watcher_script" 2>/dev/null || true

    mkdir -p /etc/systemd/system
    cat << EOF > "$watcher_service"
[Unit]
Description=SSH Port Transition Safe Watcher
After=network.target sshd.service ssh.service

[Service]
Type=simple
ExecStart=${watcher_script} ${target_port} ${active_port} ${ttl_hours}
Restart=no

[Install]
WantedBy=multi-user.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable --now ssh-transition-watcher.service >/dev/null 2>&1 || true
        ok "Развернут фоновый сторожевой сервис ${WHITE}ssh-transition-watcher.service${NC}."
    fi
}

finalize_ssh_transition() {
    local target_port="$1"
    local active_port="$2"
    local ssh_svc
    ssh_svc=$(get_ssh_service_name)

    [ "$target_port" -eq "$active_port" ] && return 0

    log "Финализация перехода SSH: закрытие резервного порта ${active_port}..."

    # 1. Удаляем старый порт из drop-in конфигурации
    if [ -f /etc/ssh/sshd_config.d/99-hardening.conf ]; then
        sed -i "/^Port ${active_port}$/d" /etc/ssh/sshd_config.d/99-hardening.conf 2>/dev/null || true
    fi

    # 2. Обновляем базовый /etc/ssh/sshd_config
    if [ -f /etc/ssh/sshd_config ]; then
        sed -i -E "s/^[#\s]*Port [0-9]+/Port ${target_port}/" /etc/ssh/sshd_config 2>/dev/null || true
    fi

    # 3. Валидация и перезагрузка sshd
    mkdir -p /run/sshd 2>/dev/null || true
    if /usr/sbin/sshd -t 2>/dev/null; then
        systemctl reload "${ssh_svc}.service" 2>/dev/null || systemctl restart "${ssh_svc}.service" 2>/dev/null || true
    fi

    # 4. Удаляем старый порт из UFW
    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "${active_port}/tcp" >/dev/null 2>&1 || true
    fi

    # 5. Обновляем Fail2ban
    if [ -f /etc/fail2ban/jail.local ]; then
        sed -i "s/port = .*/port = ${target_port}/" /etc/fail2ban/jail.local 2>/dev/null || true
        systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban 2>/dev/null || true
    fi

    # 6. Останавливаем и удаляем watcher
    systemctl disable --now ssh-transition-watcher.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/ssh-transition-watcher.service /usr/local/bin/ssh-transition-watcher.sh 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    ok "Резервный порт SSH ${active_port} закрыт. SSH теперь работает исключительно на порту ${WHITE}${target_port}${NC}."
}

wait_and_finalize_ssh_transition() {
    local target_port="$1"
    local active_port="$2"
    local timeout_sec="${3:-30}"

    [ "$target_port" -eq "$active_port" ] && return 0

    if is_true "${FORCE_CLOSE_OLD_SSH:-n}"; then
        ok "Включен режим принудительного закрытия (--force-close-old-ssh / FORCE_CLOSE_OLD_SSH=y)."
        finalize_ssh_transition "$target_port" "$active_port"
        return 0
    fi

    # Если скрипт выполняется не интерактивно (нет tty) — поднимаем watcher и выходим
    if [ ! -t 0 ] || [ "${NON_INTERACTIVE:-0}" -eq 1 ]; then
        log "Неинтерактивный запуск: активирован фоновый watcher перехода SSH."
        deploy_ssh_transition_watcher "$target_port" "$active_port" 24
        return 0
    fi

    local host_ip
    host_ip=$(get_wan_ip)

    echo
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║${NC}             ${WHITE}${BOLD}⚡ БЕЗОПАСНЫЙ ПЕРЕХОД SSH: ПОРТЫ ${target_port} (НОВЫЙ) И ${active_port} (СТАРЫЙ)${NC}            ${YELLOW}║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "  Служба SSH сейчас слушает ${GREEN}ОБА порта (${target_port} и ${active_port})${NC}. Ваша текущая сессия не прервана."
    echo -e "  Брандмауэр UFW и Fail2ban защищают оба порта."
    echo
    echo -e "  ${CYAN}${BOLD}ПРОВЕРЬТЕ ПОДКЛЮЧЕНИЕ В НОВОЙ ВКЛАДКЕ ТЕРМИНАЛА:${NC}"
    echo -e "    ${WHITE}ssh -p ${target_port} root@${host_ip}${NC}"
    echo
    echo -e "  ${WHITE}[1]${NC} Ожидать вашего подключения (${timeout_sec} сек, автозакрытие при успехе) ${GREEN}[Enter]${NC}"
    echo -e "  ${WHITE}[2]${NC} Оставить оба порта и передать контроль фоновому watcher (закроет старый порт позже)"
    echo -e "  ${WHITE}[3]${NC} Закрыть старый порт ${active_port} прямо сейчас"
    echo

    local choice=""
    echo -ne "  ${WHITE}${ARROW} Ваш выбор [1/2/3] (по умолчанию 1): ${NC}"
    read -r -t 10 choice </dev/tty || choice="1"
    choice="${choice:-1}"
    choice=$(echo "$choice" | tr -d '[:space:]')

    case "$choice" in
        2)
            deploy_ssh_transition_watcher "$target_port" "$active_port" 24
            ok "Оба порта (${target_port} и ${active_port}) остаются открытыми. Watcher закроет ${active_port} после входа."
            return 0
            ;;
        3)
            finalize_ssh_transition "$target_port" "$active_port"
            return 0
            ;;
        *)
            echo -e "  ${CYAN}Ожидание входящего подключения на порт ${target_port} (${timeout_sec} сек)...${NC}"
            local elapsed=0
            while [ "$elapsed" -lt "$timeout_sec" ]; do
                local est_count=0
                est_count=$(ss -tn sport = ":${target_port}" state established 2>/dev/null | grep -vE '127\.0\.0\.1|::1|Local Address' | wc -l)
                if [ "$est_count" -gt 0 ]; then
                    echo
                    ok "Успешное входящее подключение на порт ${target_port} обнаружено!"
                    finalize_ssh_transition "$target_port" "$active_port"
                    return 0
                fi
                sleep 1
                elapsed=$((elapsed + 1))
                echo -ne "\r  ${DIM}Осталось: $((timeout_sec - elapsed)) сек...${NC} "
            done
            echo
            warn "За ${timeout_sec} сек новых подключений не зафиксировано."
            ok "Для вашей безопасности старый порт ${active_port} пока оставлен открытым."
            deploy_ssh_transition_watcher "$target_port" "$active_port" 24
            return 0
            ;;
    esac
}

apply_fail2ban_configuration() {
    local target_port="${1:-22}"
    local active_port="${2:-22}"

    # 1. Установка пакетов fail2ban и python3-systemd (для чтения journald в Ubuntu 24.04 / Debian 12)
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y >/dev/null 2>&1 || true
            apt-get install -y fail2ban python3-systemd >/dev/null 2>&1 || apt-get install -y fail2ban >/dev/null 2>&1 || true
        fi
    fi

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        warn "Пакет fail2ban не найден в системе и не может быть установлен."
        return 1
    fi

    # 2. Формируем список защищаемых портов (и активный, и целевой)
    local port_str="${active_port}"
    if [ "$target_port" -ne "$active_port" ]; then
        port_str="${active_port},${target_port}"
    fi

    mkdir -p /etc/fail2ban
    cat << EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ${port_str}
EOF
    chmod 644 /etc/fail2ban/jail.local 2>/dev/null || true

    # 3. Активация и запуск службы
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true

    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        ok "Служба Fail2ban успешно запущена и защищает SSH (порты: ${WHITE}${port_str}${NC})."
    else
        warn "Служба Fail2ban была установлена, но не смогла запуститься. Проверьте journalctl -u fail2ban."
        return 1
    fi
    return 0
}


# --- Global Paths & Logs ---
INSTALL_LOG="/var/log/nginx_mask_install.log"
CREDENTIALS_FILE="/root/vpn_credentials.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main"

# Clear screen & display header banner
check_for_script_updates() {
    local remote_ver=""
    remote_ver=$(curl -fsSL --connect-timeout 2 "https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/VERSION?v=$(date +%s)" 2>/dev/null | tr -d '[:space:]' || true)
    if [ -n "$remote_ver" ]; then
        if [ "$remote_ver" != "$SCRIPT_VERSION" ]; then
            echo -e "  ${YELLOW}⚠️  Доступно обновление скрипта: ${GREEN}$remote_ver${YELLOW} (текущая версия: ${CYAN}$SCRIPT_VERSION${YELLOW})${RESET}"
            echo -e "  ${DIM}Обновить: curl -sSL "https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/install.sh?v=$(date +%s)" | sudo bash${RESET}\n"
        else
            echo -e "  ${DIM}Версия: ${GREEN}$SCRIPT_VERSION${DIM} (актуальная релизная сборка)${RESET}\n"
        fi
    else
        echo -e "  ${DIM}Версия: ${GREEN}$SCRIPT_VERSION${RESET}\n"
    fi
}

clear_banner() {
    clear 2>/dev/null || true
    echo -e "  ${CYAN}${BOLD}🛡️   Nginx Stream Router для 3X-UI [${SCRIPT_VERSION}]${RESET}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${RESET}"
    echo -e "  ${WHITE}Шлюз маскировки и защиты VPN-подключений:${RESET}"
    echo -e "  ${DIM}• Маскировка под реальный сайт (защита от сканирования и блокировок)${RESET}"
    echo -e "  ${DIM}• Поддержка протоколов: VLESS REALITY, Hysteria 2, AmneziaWG${RESET}"
    echo -e "  ${DIM}• Единый защищенный порт 443 для всех сервисов, панели и подписок${RESET}"
    echo -e "  ${DIM}• Обход капч Google и доступ к AI через Cloudflare WARP${RESET}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${RESET}"
    check_for_script_updates
}

# Interactive Terminal Spinner & Task Runner
# Supports:
#   - Animated spinner in interactive TTY
#   - Plain output in non-interactive / CI / piped runs
#   - DEBUG_MODE=1 passthrough (full stdout/stderr in real-time)
#   - Interactive failure recovery menu (Retry / Skip / Abort)

run_with_spinner() {
    local task_name="$1"
    shift
    local log_file="${SETUP_MASK_LOG:-${INSTALL_LOG:-${SPINNER_LOG_FILE:-/tmp/cmd_spinner.log}}}"

    while true; do
        local exit_code=0

        # ── DEBUG MODE: без фона, весь вывод сразу в stdout ──
        if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
            echo -e "\n  ${CYAN}[DEBUG]${NC} ${WHITE}▶ $task_name${NC}"
            echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            local _prev_e=0
            [[ "$-" =~ e ]] && _prev_e=1
            set +e
            if declare -f "$1" >/dev/null 2>&1; then
                ( shopt -s inherit_errexit 2>/dev/null || true; set -euo pipefail; "$@" )
                exit_code=$?
            else
                ( shopt -s inherit_errexit 2>/dev/null || true; set -euo pipefail; eval "$*" )
                exit_code=$?
            fi
            [ "$_prev_e" -eq 1 ] && set -e
            if [ $exit_code -eq 0 ]; then
                echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
                echo -e "  ${GREEN}${CHECK:-✔}${NC}  ${WHITE}$task_name${NC} ${GREEN}[ГОТОВО]${NC}\n"
                return 0
            else
                echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            fi
        else
            # ── Нормальный режим: фоновый процесс + спиннер ──
            local spin_chars=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
            local delay=0.08

            : > "$log_file"

            if declare -f "$1" >/dev/null 2>&1; then
                "$@" >> "$log_file" 2>&1 &
            else
                ( eval "$*" ) >> "$log_file" 2>&1 &
            fi
            local pid=$!

            if [ ! -t 1 ]; then
                echo -e "  ${CYAN}*${NC}  ${WHITE}${task_name}...${NC}"
                wait "$pid"
                exit_code=$?
            else
                tput civis 2>/dev/null || echo -ne "\033[?25l"
                local i=0
                while kill -0 "$pid" 2>/dev/null; do
                    i=$(( (i + 1) % 10 ))
                    printf "\r  ${CYAN}${spin_chars[$i]}${NC}  ${WHITE}%-54s${NC}" "$task_name..."
                    sleep "$delay"
                done
                wait "$pid"
                exit_code=$?
                tput cnorm 2>/dev/null || echo -ne "\033[?25h"
            fi

            if [ $exit_code -eq 0 ]; then
                if [ ! -t 1 ]; then
                    printf "  ${GREEN}${CHECK:-✔}${NC}  ${WHITE}%-54s${NC} ${GREEN}[ГОТОВО]${NC}\n" "$task_name"
                else
                    printf "\r  ${GREEN}${CHECK:-✔}${NC}  ${WHITE}%-54s${NC} ${GREEN}[ГОТОВО]${NC}\n" "$task_name"
                fi
                return 0
            fi

            if [ ! -t 1 ]; then
                printf "  ${RED}${CROSS:-✖}${NC}  ${WHITE}%-54s${NC} ${RED}[ОШИБКА]${NC}\n" "$task_name"
            else
                printf "\r  ${RED}${CROSS:-✖}${NC}  ${WHITE}%-54s${NC} ${RED}[ОШИБКА]${NC}\n" "$task_name"
            fi
            echo -e "\n  ${RED}${BOLD}Полный лог ошибки:${NC}"
            echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            [ -f "$log_file" ] && cat "$log_file" | sed 's/^/    /' || true
            echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            echo -e "  ${DIM}Совет: запустите с флагом ${WHITE}--debug${DIM} для подробного вывода в реальном времени.${NC}\n"
        fi

        # ── Интерактивная обработка сбоя (Retry / Skip / Abort) ──
        if [ "${NON_INTERACTIVE:-0}" -eq 0 ] && [ -t 1 ]; then
            echo -e "  ${YELLOW}${BOLD}Действия при сбое:${NC}"
            echo -e "    ${CYAN}${BOLD}[1] Повторить попытку (Retry)${NC} — после исправления причин (напр. DNS)"
            echo -e "    ${YELLOW}[2] Пропустить этот шаг и продолжить (Skip)${NC}"
            echo -e "    ${RED}[3] Прервать установку (Abort)${NC}"
            local retry_ans=""
            read -rp "  Ваш выбор [1/2/3] (по умолчанию: 1): " retry_ans </dev/tty || read -r retry_ans || retry_ans="1"
            retry_ans=$(echo "${retry_ans:-1}" | tr -d '[:space:]')
            case "$retry_ans" in
                2)
                    warn "Шаг '$task_name' пропущен по выбору пользователя."
                    return 0
                    ;;
                3)
                    die "Шаг завершился с ошибкой (exit $exit_code): $task_name"
                    ;;
                *)
                    echo -e "  ${CYAN}${ARROW:-➜} Повторная попытка: $task_name...${NC}\n"
                    continue
                    ;;
            esac
        else
            return $exit_code
        fi
    done
}


# Step Progress Header
print_step() {
    local step_num="$1"
    local total_steps="$2"
    local step_title="$3"
    local progress_bar=""
    
    local percent=$(( step_num * 100 / total_steps ))
    local filled=$(( step_num * 15 / total_steps ))
    local empty=$(( 15 - filled ))
    
    for ((j=0; j<filled; j++)); do progress_bar+="█"; done
    for ((j=0; j<empty; j++)); do progress_bar+="░"; done
    
    echo ""
    echo -e "  ${BLUE}${BOLD}[Шаг $step_num из $total_steps]${RESET} ${WHITE}${BOLD}$step_title${RESET}"
    echo -e "  ${DIM}Прогресс: [${CYAN}$progress_bar${DIM}] ${percent}%${RESET}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${RESET}"
}

# Root and OS Check
check_prerequisites() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "  ${RED}${BOLD}${CROSS} Ошибка:${RESET} Этот скрипт должен быть запущен от имени ${YELLOW}root${RESET}."
        echo -e "  Запустите: ${CYAN}sudo bash $0${RESET}"
        exit 1
    fi

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME=$ID
        OS_VER=$VERSION_ID
    else
        echo -e "  ${YELLOW}${INFO} Предупреждение: Не удалось определить дистрибутив Linux. Рекомендуется Ubuntu/Debian.${RESET}"
    fi
    
    touch "$INSTALL_LOG"
    chmod 600 "$INSTALL_LOG"
}

# Mode Selection Screen

prompt_mode() {
    echo -e "  ${WHITE}${BOLD}Выберите режим развертывания:${RESET}\n"
    echo -e "    ${CYAN}${BOLD}[1] Express Режим (Рекомендуется)${RESET} — Запуск в 1 клик для новичков"
    echo -e "        ${DIM}• Всего 2 вопроса: ваш домен и email для SSL.${RESET}"
    echo -e "        ${DIM}• Оптимизация ядра (BBR, буферы, TCP), фаервол UFW.${RESET}"
    echo -e "        ${DIM}• Nginx mainline с поддержкой stream ssl_preread.${RESET}"
    echo -e "        ${DIM}• Официальный 3X-UI с автоматической генерацией надежных паролей.${RESET}"
    echo -e "        ${DIM}• Готовый сайт-приманка (Decoy) + готовая L4-маршрутизация.${RESET}\n"
    echo -e "    ${YELLOW}${BOLD}[2] Экспертный Режим${RESET} — Пошаговое меню (setup_mask.sh)"
    echo -e "        ${DIM}• Ручной выбор всех портов, путей и тонких настроек.${RESET}\n"
    
    while true; do
        echo -ne "  ${WHITE}${ARROW} Ваш выбор [1/2] (по умолчанию: 1): ${RESET}"
        read -r MODE_CHOICE </dev/tty || MODE_CHOICE="1"
        MODE_CHOICE=${MODE_CHOICE:-1}
        if [[ "$MODE_CHOICE" =~ ^[12]$ ]]; then
            break
        fi
        echo -e "  ${RED}Пожалуйста, введите 1 или 2.${RESET}"
    done
}

# Collect Inputs for Express Mode
collect_express_inputs() {
    echo ""
    echo -e "  ${MAGENTA}${BOLD}Ввод основных параметров:${RESET}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${RESET}"
    
    # Автоопределение текущего активного порта SSH
    SSH_ACTIVE_PORT=$(detect_active_ssh_port)

    # Неинтерактивный режим: если параметры уже переданы через переменные окружения
    if [[ -n "${PRIMARY_DOMAIN:-}" && -n "${LE_EMAIL:-}" ]]; then
        PRIMARY_DOMAIN=$(echo "$PRIMARY_DOMAIN" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        LE_EMAIL=$(echo "$LE_EMAIL" | tr -d '[:space:]')
        SSH_PORT="${SSH_PORT:-$SSH_ACTIVE_PORT}"
        echo -e "  ${GREEN}${CHECK} Параметры приняты из переменных окружения:${RESET}"
        echo -e "    ${DIM}• Домен:${RESET}      ${WHITE}${BOLD}$PRIMARY_DOMAIN${RESET}"
        echo -e "    ${DIM}• Email:${RESET}      ${WHITE}$LE_EMAIL${RESET}"
        echo -e "    ${DIM}• SSH Порт:${RESET}   ${WHITE}$SSH_PORT${RESET} ${DIM}(активный: $SSH_ACTIVE_PORT)${RESET}"
        echo ""
        PANEL_USER="admin_$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
        PANEL_PASS="$(head /dev/urandom | tr -dc A-Za-z0-9_\- | head -c 16)"
        PANEL_SECRET="$(head /dev/urandom | tr -dc a-z0-9 | head -c 12)"
        SUB_SECRET="sub-$(head /dev/urandom | tr -dc a-z0-9 | head -c 8)"
        XHTTP_SECRET="$(head /dev/urandom | tr -dc a-z0-9 | head -c 8)"
        PANEL_INTERNAL_PORT="2053"
        return 0
    fi

    echo -e "  ${YELLOW}${INFO} ВАЖНО О DNS-ЗАПИСЯХ:${RESET}"
    echo -e "  ${DIM}Для работы веб-маскировки Nginx и VLESS REALITY в DNS нужны 2 A-записи:${RESET}"
    echo -e "    ${DIM}1) Основной домен (напр. domain.com)  ➜ IP вашего VPS (Сайт, Панель, VLESS xHTTP)${RESET}"
    echo -e "    ${DIM}2) Поддомен (напр. cdn.domain.com)     ➜ IP вашего VPS (Маскировка Reality под свой сайт)${RESET}
"

    # 1. Domain
    while true; do
        echo -ne "  ${WHITE}${ARROW} Введите ваш основной домен (напр. domain.com или vpn.domain.com): ${RESET}"
        read -r PRIMARY_DOMAIN </dev/tty 2>/dev/null || read -r PRIMARY_DOMAIN 2>/dev/null || true
        PRIMARY_DOMAIN=$(echo "${PRIMARY_DOMAIN:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        
        if [[ -z "$PRIMARY_DOMAIN" ]]; then
            echo -e "  ${RED}${CROSS} Домен не может быть пустым!${RESET}"
            continue
        fi
        
        if [[ ! "$PRIMARY_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
            echo -e "  ${RED}${CROSS} Некорректный формат домена. Попробуйте снова.${RESET}"
            continue
        fi
        break
    done
    
    # 2. Email
    while true; do
        echo -ne "  ${WHITE}${ARROW} Введите Email для сертификатов Let's Encrypt: ${RESET}"
        read -r LE_EMAIL </dev/tty 2>/dev/null || read -r LE_EMAIL 2>/dev/null || true
        LE_EMAIL=$(echo "${LE_EMAIL:-}" | tr -d '[:space:]')
        
        if [[ -z "$LE_EMAIL" ]]; then
            echo -e "  ${RED}${CROSS} Email не может быть пустым!${RESET}"
            continue
        fi
        
        if [[ ! "$LE_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            echo -e "  ${RED}${CROSS} Некорректный формат email. Попробуйте снова.${RESET}"
            continue
        fi
        break
    done

    # 3. Optional SSH port
    echo -ne "  ${WHITE}${ARROW} Оставить текущий порт SSH (${SSH_ACTIVE_PORT})? [Y/n]: ${RESET}"
    read -r KEEP_SSH </dev/tty 2>/dev/null || read -r KEEP_SSH 2>/dev/null || KEEP_SSH="y"
    KEEP_SSH=${KEEP_SSH:-y}
    if [[ "$KEEP_SSH" =~ ^[Nn]$ ]]; then
        while true; do
            echo -ne "  ${WHITE}${ARROW} Введите новый порт SSH (1024-65535): ${RESET}"
            read -r CUSTOM_SSH_PORT </dev/tty 2>/dev/null || read -r CUSTOM_SSH_PORT 2>/dev/null || true
            if [[ "$CUSTOM_SSH_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_SSH_PORT" -ge 1024 ] && [ "$CUSTOM_SSH_PORT" -le 65535 ]; then
                SSH_PORT=$CUSTOM_SSH_PORT
                break
            fi
            echo -e "  ${RED}${CROSS} Порт должен быть числом от 1024 до 65535.${RESET}"
        done
    else
        SSH_PORT="$SSH_ACTIVE_PORT"
    fi

    # Сохраняем существующие учетные данные при повторном запуске, чтобы не инвалидировать доступ
    local existing_env="/root/nginx_mask_setup/setup_mask.env"
    [ ! -f "$existing_env" ] && [ -f "/etc/setup_mask.env" ] && existing_env="/etc/setup_mask.env"
    if [ -f "$existing_env" ]; then
        local saved_user saved_pass saved_path saved_sub saved_xhttp
        saved_user=$(grep -E '^ADMIN_USERNAME=' "$existing_env" 2>/dev/null | cut -d= -f2- | tr -d '"'\''')
        saved_pass=$(grep -E '^ADMIN_PASSWORD=' "$existing_env" 2>/dev/null | cut -d= -f2- | tr -d '"'\''')
        saved_path=$(grep -E '^PANEL_PATH=' "$existing_env" 2>/dev/null | cut -d= -f2- | tr -d '"'\''')
        saved_sub=$(grep -E '^SUB_PATH=' "$existing_env" 2>/dev/null | cut -d= -f2- | tr -d '"'\''')
        saved_xhttp=$(grep -E '^XHTTP_STREAM_PATH=' "$existing_env" 2>/dev/null | cut -d= -f2- | tr -d '"'\''')
        [ -n "$saved_user" ] && PANEL_USER="$saved_user"
        [ -n "$saved_pass" ] && PANEL_PASS="$saved_pass"
        if [ -n "$saved_path" ]; then
            PANEL_SECRET="${saved_path#/}"
            PANEL_SECRET="${PANEL_SECRET%/}"
        fi
        if [ -n "$saved_sub" ] && [ "$saved_sub" != "my-post-key" ] && [ "$saved_sub" != "/my-post-key/" ]; then
            SUB_SECRET="${saved_sub#/}"
            SUB_SECRET="${SUB_SECRET%/}"
        fi
        if [ -n "$saved_xhttp" ] && [ "$saved_xhttp" != "Stream-One-Path" ] && [ "$saved_xhttp" != "/Stream-One-Path/" ] && [[ "$saved_xhttp" != *vless-* ]]; then
            XHTTP_SECRET="${saved_xhttp#/}"
            XHTTP_SECRET="${XHTTP_SECRET%/}"
        fi
    fi

    # Generate secure random credentials for 3X-UI if not restored
    [ -z "${PANEL_USER:-}" ] && PANEL_USER="admin_$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
    [ -z "${PANEL_PASS:-}" ] && PANEL_PASS="$(head /dev/urandom | tr -dc A-Za-z0-9_\- | head -c 16)"
    [ -z "${PANEL_SECRET:-}" ] && PANEL_SECRET="$(head /dev/urandom | tr -dc a-z0-9 | head -c 12)"
    [ -z "${SUB_SECRET:-}" ] && SUB_SECRET="sub-$(head /dev/urandom | tr -dc a-z0-9 | head -c 8)"
    [ -z "${XHTTP_SECRET:-}" ] && XHTTP_SECRET="$(head /dev/urandom | tr -dc a-z0-9 | head -c 8)"
    PANEL_INTERNAL_PORT="2053"

    echo ""
    echo -e "  ${GREEN}${CHECK} Параметры приняты:${RESET}"
    echo -e "    ${DIM}• Домен:${RESET}      ${WHITE}${BOLD}$PRIMARY_DOMAIN${RESET}"
    echo -e "    ${DIM}• Email:${RESET}      ${WHITE}$LE_EMAIL${RESET}"
    echo -e "    ${DIM}• SSH Порт:${RESET}   ${WHITE}$SSH_PORT${RESET} ${DIM}(активный: $SSH_ACTIVE_PORT)${RESET}"
    echo ""
    echo -ne "  ${WHITE}${ARROW} Начать автоматическое развертывание? [Y/n]: ${RESET}"
    read -r CONFIRM </dev/tty 2>/dev/null || read -r CONFIRM 2>/dev/null || CONFIRM="y"
    CONFIRM=${CONFIRM:-y}
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "  ${YELLOW}Установка отменена пользователем.${RESET}"
        exit 0
    fi
}


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
        if is_true "${ENABLE_DNSTT:-0}"; then
            local dnstt_p="${DNSTT_PORT:-53053}"
            ufw allow "${dnstt_p}/udp" comment 'DNSTT DoH Tunnel' >/dev/null 2>&1 || true
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
        ufw deny "${NAIVE_PORT:-8446}/tcp" comment 'NaïveProxy Internal' >/dev/null 2>&1 || true
        ufw deny 8447/tcp comment 'NaïveProxy Stripper Internal' >/dev/null 2>&1 || true
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
        [[ "$rel_ver" == "v8.2.0" ]] && rel_ver="v8.1.0"
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
        naive_pass=$(python3 -c "import secrets; print(secrets.token_urlsafe(16))" 2>/dev/null || openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' || echo "ChangeMeNaive2026")
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
        [[ "$rel_ver" == "v8.2.0" ]] && rel_ver="v8.1.0"
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
}

step_configure_inbounds() {
    # 1. Развертывание сервисов нового поколения (Zapret, MASQUE, ShadowTLS, Wstunnel, NaïveProxy, DNSTT)
    # Выполняется ДО configure_3xui.sh, чтобы сгенерированные ключи и пароли попали в сводный отчет клиента
    deploy_native_nextgen_services

    cd /root/nginx_mask_setup
    if [ -f "./configure_3xui.sh" ]; then
        export ADMIN_USERNAME="$PANEL_USER"
        export ADMIN_PASSWORD="$PANEL_PASS"
        export PANEL_PORT="$PANEL_INTERNAL_PORT"
        export PANEL_PATH="/$PANEL_SECRET/"
        export SUB_PATH="/$SUB_SECRET/"
        export SUB_TITLE="${SUB_TITLE:-}"
        export XHTTP_STREAM_PATH="/$XHTTP_SECRET/"
        export ENABLE_NAIVE="${ENABLE_NAIVE:-0}"
        export NAIVE_PORT="${NAIVE_PORT:-8446}"
        export NAIVE_DOMAIN="${NAIVE_DOMAIN:-}"
        export NAIVE_USER="${NAIVE_USER:-user}"
        export NAIVE_PASS="${NAIVE_PASS:-}"
        export ENABLE_DNSTT="${ENABLE_DNSTT:-0}"
        export DNSTT_PORT="${DNSTT_PORT:-53053}"
        export DNSTT_DOMAIN="${DNSTT_DOMAIN:-}"
        export DNSTT_PUBKEY="${DNSTT_PUBKEY:-}"
        local cfg_arg=()
        [ -f "/root/nginx_mask_setup/setup_mask.env" ] && cfg_arg=(--config "/root/nginx_mask_setup/setup_mask.env")
        bash ./configure_3xui.sh --non-interactive --domain "$PRIMARY_DOMAIN" "${cfg_arg[@]}" || true
    fi

    # Ensure Nginx is reloaded and active
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || systemctl restart nginx
}

# Save credentials and connection summary

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
    echo -e "    ${DIM}• Фаервол UFW:${RESET}    ${GREEN}Порты протоколов (10443, 55443 и др.) изолированы${RESET}"
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


# --- Main Flow ---
main() {
    if [[ "${1:-}" == "-v" || "${1:-}" == "--version" ]]; then
        echo "STREAM ROUTER $SCRIPT_VERSION"
        exit 0
    fi
    clear_banner
    check_prerequisites
    prompt_mode
    
    if [ "$MODE_CHOICE" == "2" ]; then
        echo -e "  ${YELLOW}${INFO} Запуск экспертного режима (setup_mask.sh)...${RESET}\n"
        echo -e "  ${CYAN}[i] Загрузка актуального установщика...${RESET}"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "${REPO_URL}/setup_mask.sh?v=$(date +%s)" -o /tmp/setup_mask.sh
        else
            wget -qO /tmp/setup_mask.sh "${REPO_URL}/setup_mask.sh?v=$(date +%s)"
        fi
        chmod +x /tmp/setup_mask.sh
        [ -f "$SCRIPT_DIR/setup_mask.sh" ] && cp /tmp/setup_mask.sh "$SCRIPT_DIR/setup_mask.sh" 2>/dev/null || true
        cp /tmp/setup_mask.sh "./setup_mask.sh" 2>/dev/null || true
        bash /tmp/setup_mask.sh --expert "$@"
        exit 0
    fi
    
    # Express Mode
    collect_express_inputs
    
    echo -e "\n  ${CYAN}${BOLD}${STAR} Начинаем сборку и настройку компонентов системы...${RESET}"
    
    # Step 1: OS, Sysctl, UFW
    print_step 1 4 "Подготовка ОС, BBR-оптимизация и настройка фаервола"
    run_with_spinner "Обновление репозиториев и установка базовых утилит" step_os_hardening
    
    # Step 2: 3X-UI Engine
    print_step 2 4 "Установка и запуск официального ядра 3X-UI"
    run_with_spinner "Развертывание 3X-UI и создание учетной записи администратора" step_install_3xui
    
    # Step 3: Nginx L4 Stream Router & SSL
    print_step 3 4 "Установка Nginx mainline, получение SSL и настройка L4 Router"
    run_with_spinner "Конфигурация SNI-роутера, сайта-маскировки и SSL Let's Encrypt" step_install_nginx_and_mask
    
    # Step 4: Database Reconcile & Lockdown
    print_step 4 4 "Синхронизация входящих подключений (Inbounds) и финализация"
    run_with_spinner "Инициализация профилей Xray и блокировка внутренних портов" step_configure_inbounds
    
    save_and_display_summary
    print_dashboard

    if [ "${SSH_PORT:-$SSH_ACTIVE_PORT}" -ne "${SSH_ACTIVE_PORT:-22}" ]; then
        wait_and_finalize_ssh_transition "${SSH_PORT:-$SSH_ACTIVE_PORT}" "${SSH_ACTIVE_PORT:-22}"
    fi
}

main "$@"
