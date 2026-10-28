#!/usr/bin/env bash
# ==============================================================================
# manage-services.sh - Next-Gen Inbounds & Protocols Manager for Dokploy
# ==============================================================================
# Управление протоколами нового поколения (MASQUE, ShadowTLS, NaiveProxy, Zapret, Wstunnel)
# и оркестрация интеграции со стеком Dokploy (Traefik).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
COMPOSE_DIR="${SCRIPT_DIR}/compose"
ENV_FILE="${COMPOSE_DIR}/.env"
ENV_EXAMPLE="${COMPOSE_DIR}/.env.example"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log()   { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
die()   { echo -e "${RED}[x] ОШИБКА:${NC} $*" >&2; exit 1; }

get_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        die "Docker Compose не найден. Установите Docker и Docker Compose."
    fi
}

# @include "common/config.sh"
# @include "common/secrets.sh"
# @include "common/lock.sh"

ensure_env() {
    if [ ! -f "$ENV_FILE" ]; then
        if [ -f "$ENV_EXAMPLE" ]; then
            log "Создание конфигурации ${ENV_FILE} из шаблона..."
            cp "$ENV_EXAMPLE" "$ENV_FILE"
            # Генерация криптографических паролей
            local rand_masque rand_stls rand_naive rand_ws
            rand_masque="$(generate_urlsafe_token 16)"
            rand_stls="$(generate_urlsafe_token 16)"
            rand_naive="$(generate_urlsafe_token 16)"
            rand_ws="$(generate_urlsafe_token 16)"

            sed -i "s/ChangeMeSecretMasquePass2026!/${rand_masque}/" "$ENV_FILE" 2>/dev/null || true
            sed -i "s/ChangeMeShadowTlsPassword2026!/${rand_stls}/" "$ENV_FILE" 2>/dev/null || true
            sed -i "s/ChangeMeNaivePassword2026!/${rand_naive}/" "$ENV_FILE" 2>/dev/null || true
            sed -i "s/ChangeMeWstunnelSecret2026!/${rand_ws}/" "$ENV_FILE" 2>/dev/null || true
            ok "Конфигурация инициализирована с новыми ключами безопасности."
        else
            die "Шаблон ${ENV_EXAMPLE} не найден."
        fi
    fi
}

ensure_configs() {
    ensure_env

    local masque_tpl="${COMPOSE_DIR}/sing-box-masque/config.json.template"
    local masque_cfg="${COMPOSE_DIR}/sing-box-masque/config.json"
    local naive_tpl="${COMPOSE_DIR}/naiveproxy/Caddyfile.template"
    local naive_cfg="${COMPOSE_DIR}/naiveproxy/Caddyfile"

    # Чтение переменных окружения
    load_config_data_safe "$ENV_FILE" || die "Ошибка загрузки конфигурации из $ENV_FILE"

    # 1. Генерация sing-box MASQUE config.json при отсутствии
    if [ ! -f "$masque_cfg" ] && [ -f "$masque_tpl" ]; then
        log "Генерация конфигурации Sing-box MASQUE (${masque_cfg})..."
        local m_port="${MASQUE_PORT:-8449}"
        local m_user="${MASQUE_USER:-client}"
        local m_pass="${MASQUE_PASS:-ChangeMeSecretMasquePass2026!}"
        local m_dom="${PRIMARY_DOMAIN:-yourdomain.online}"
        local m_cert="${MASQUE_CERT_PATH:-/etc/ssl/certs/fullchain.pem}"
        local m_key="${MASQUE_KEY_PATH:-/etc/ssl/certs/privkey.pem}"

        if command -v python3 >/dev/null 2>&1; then
            python3 -c "
import json
with open('$masque_tpl', 'r', encoding='utf-8') as f:
    data = json.load(f)
for ib in data.get('inbounds', []):
    if ib.get('type') == 'masque':
        ib['listen_port'] = int('$m_port')
        if 'users' in ib and ib['users']:
            ib['users'][0]['username'] = '$m_user'
            ib['users'][0]['password'] = '$m_pass'
        if 'tls' in ib:
            ib['tls']['server_name'] = '$m_dom'
            ib['tls']['certificate_path'] = '$m_cert'
            ib['tls']['key_path'] = '$m_key'
with open('$masque_cfg', 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || cp "$masque_tpl" "$masque_cfg"
        else
            sed -e "s|\"listen_port\": 8449|\"listen_port\": ${m_port}|g" \
                -e "s|\"username\": \"client\"|\"username\": \"${m_user}\"|g" \
                -e "s|\"password\": \"CHANGE_ME_PASSWORD\"|\"password\": \"${m_pass}\"|g" \
                -e "s|\"server_name\": \"yourdomain.online\"|\"server_name\": \"${m_dom}\"|g" \
                -e "s|/etc/ssl/certs/fullchain.pem|${m_cert}|g" \
                -e "s|/etc/ssl/certs/privkey.pem|${m_key}|g" \
                "$masque_tpl" > "$masque_cfg"
        fi
        ok "Конфигурация Sing-box MASQUE инициализирована."
    fi

    # 2. Инициализация NaïveProxy Caddyfile при отсутствии
    if [ ! -f "$naive_cfg" ] && [ -f "$naive_tpl" ]; then
        log "Создание конфигурации NaïveProxy Caddyfile (${naive_cfg})..."
        cp "$naive_tpl" "$naive_cfg"
        ok "Конфигурация NaïveProxy Caddyfile инициализирована."
    fi
}

get_compose_file() {
    local dokploy_net_exists=0
    if command -v docker >/dev/null 2>&1; then
        docker network inspect dokploy-network >/dev/null 2>&1 && dokploy_net_exists=1 || true
    fi

    if [ "$dokploy_net_exists" -eq 1 ]; then
        echo "${COMPOSE_DIR}/docker-compose.dokploy.yml"
    else
        echo "${COMPOSE_DIR}/docker-compose.nextgen.yml"
    fi
}

cmd_status() {
    ensure_configs
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    local compose_file
    compose_file=$(get_compose_file)

    echo ""
    echo -e "${BOLD}${CYAN}=== СТАТУС СЕРВИСОВ СЛЕДУЮЩЕГО ПОКОЛЕНИЯ & DOKPLOY ===${NC}"
    echo -e "Используемый стек: ${YELLOW}${compose_file}${NC}"
    echo ""

    if docker network inspect dokploy-network >/dev/null 2>&1; then
        ok "Сеть Dokploy (dokploy-network): ${GREEN}ОБНАРУЖЕНА (Режим интеграции с Traefik)${NC}"
    else
        log "Сеть Dokploy (dokploy-network): ${YELLOW}Не обнаружена (Автономный режим)${NC}"
    fi

    $compose_cmd --env-file "$ENV_FILE" -f "$compose_file" ps
    echo ""

    # Проверка прослушивания ключевых портов
    echo -e "${BOLD}Прослушивание портов на хосте:${NC}"
    for proto_port in "UDP:8449:MASQUE" "TCP:8543:ShadowTLS" "TCP:8446:NaïveProxy" "TCP:8080:Wstunnel-Direct"; do
        IFS=":" read -r proto port name <<< "$proto_port"
        local flag="-t"
        [ "$proto" = "UDP" ] && flag="-u"
        if ss -l -n "$flag" 2>/dev/null | grep -q ":${port}\b"; then
            echo -e "  [+] ${GREEN}${name}${NC} (${proto} ${port}): ${GREEN}АКТИВЕН${NC}"
        else
            echo -e "  [-] ${YELLOW}${name}${NC} (${proto} ${port}): ${YELLOW}НЕ СЛУШАЕТ${NC}"
        fi
    done

    # Проверка правила iptables Zapret
    echo -e "${BOLD}Статус Server-Side Zapret (connbytes 1:6 NFQUEUE):${NC}"
    if iptables -t mangle -C POSTROUTING -p tcp -m connbytes --connbytes 1:6 --connbytes-mode packets --connbytes-dir original -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num 200 --queue-bypass 2>/dev/null; then
        echo -e "  [+] ${GREEN}iptables mangle правило NFQUEUE connbytes 1:6 активно${NC}"
    else
        echo -e "  [-] ${YELLOW}iptables mangle правило NFQUEUE не активно${NC}"
    fi
}

cmd_up() {
    ensure_configs
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    local compose_file
    compose_file=$(get_compose_file)
    local svc="${1:-}"

    log "Запуск сервисов из ${compose_file}..."
    if [ -n "$svc" ]; then
        $compose_cmd --env-file "$ENV_FILE" -f "$compose_file" up -d "$svc"
    else
        $compose_cmd --env-file "$ENV_FILE" -f "$compose_file" up -d
    fi
    ok "Сервисы успешно запущены."
}

cmd_down() {
    ensure_configs
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    local compose_file
    compose_file=$(get_compose_file)
    local svc="${1:-}"

    log "Остановка сервисов из ${compose_file}..."
    if [ -n "$svc" ]; then
        $compose_cmd --env-file "$ENV_FILE" -f "$compose_file" stop "$svc"
    else
        $compose_cmd --env-file "$ENV_FILE" -f "$compose_file" down
    fi
    ok "Сервисы остановлены."
}

cmd_restart() {
    ensure_configs
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    local compose_file
    compose_file=$(get_compose_file)
    local svc="${1:-}"

    log "Перезапуск сервисов..."
    if [ -n "$svc" ]; then
        $compose_cmd --env-file "$ENV_FILE" -f "$compose_file" restart "$svc"
    else
        $compose_cmd --env-file "$ENV_FILE" -f "$compose_file" restart
    fi
    ok "Перезапуск завершен."
}

cmd_logs() {
    ensure_configs
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    local compose_file
    compose_file=$(get_compose_file)
    local svc="${1:-}"

    $compose_cmd --env-file "$ENV_FILE" -f "$compose_file" logs -f ${svc:+"$svc"}
}

cmd_dokploy_export() {
    local dokploy_file="${COMPOSE_DIR}/docker-compose.dokploy.yml"
    if [ -f "$dokploy_file" ]; then
        cat "$dokploy_file"
    else
        die "Файл ${dokploy_file} не найден."
    fi
}

cmd_dokploy_all_in_one() {
    local aio_file="${COMPOSE_DIR}/docker-compose.dokploy-all-in-one.yml"
    if [ -f "$aio_file" ]; then
        cat "$aio_file"
    else
        die "Файл ${aio_file} не найден."
    fi
}

cmd_dokploy_traefik() {
    load_config_data_safe "$ENV_FILE" 2>/dev/null || true
    local py_script="${SCRIPT_DIR}/src/panel/dokploy_traefik.py"
    [ -f "$py_script" ] || py_script="${SCRIPT_DIR}/dokploy_traefik.py"
    local py_bin="python3"
    if command -v python >/dev/null 2>&1 && python -c "import sys" >/dev/null 2>&1; then
        py_bin="python"
    elif command -v python3 >/dev/null 2>&1; then
        py_bin="python3"
    fi
    if [ -f "$py_script" ]; then
        local extra_args=()
        [ -n "${PANEL_DOMAIN:-}" ] && extra_args+=(--panel-domain "$PANEL_DOMAIN")
        [ -n "${SUB_DOMAIN:-}" ] && extra_args+=(--sub-domain "$SUB_DOMAIN")
        [ -n "${VLESS_DOMAIN:-}" ] && extra_args+=(--vless-domain "$VLESS_DOMAIN")
        "$py_bin" "$py_script" --domain "${PRIMARY_DOMAIN:-example.com}" \
            "${extra_args[@]}" \
            --panel-port "${PANEL_PORT:-10443}" \
            --sub-port "${SUB_PORT:-55443}" \
            --xhttp-port "${XHTTP_STREAM_PORT:-50443}"
    else
        die "Скрипт генератора Traefik не найден: $py_script"
    fi
}

cmd_clients() {
    ensure_configs
    # Чтение переменных из .env
    load_config_data_safe "$ENV_FILE" || die "Ошибка загрузки конфигурации из $ENV_FILE"

    local dom="${PRIMARY_DOMAIN:-yourdomain.online}"
    local m_port="${MASQUE_PORT:-8449}"
    local m_user="${MASQUE_USER:-client}"
    local m_pass="${MASQUE_PASS:-password}"
    local stls_port="${SHADOWTLS_PORT:-8543}"
    local stls_pass="${SHADOWTLS_PASSWORD:-password}"
    local stls_sni="${SHADOWTLS_SNI:-gateway.icloud.com}"
    local ss_port="${SS2022_BACKEND_PORT:-8388}"
    local naive_port="${NAIVE_PORT:-8446}"
    local naive_dom="${NAIVE_DOMAIN:-naive.$dom}"
    local naive_user="${NAIVE_USER:-naiveuser}"
    local naive_pass="${NAIVE_PASS:-password}"
    local ws_dom="${WSTUNNEL_DOMAIN:-wstunnel.$dom}"

    echo ""
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo -e "${BOLD}${CYAN}  КЛИЕНТСКИЕ КОНФИГУРАЦИИ СЛЕДУЮЩЕГО ПОКОЛЕНИЯ & DOKPLOY    ${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo ""

    # 1. MASQUE (Sing-box Outbound)
    echo -e "${BOLD}${YELLOW}1. MASQUE (RFC 9484 / RFC 9298 HTTP/3 Datagram)${NC}"
    echo -e "   Клиенты: ${CYAN}Sing-box 1.14+, Happ Proxy, FoXray, iOS 17+ Network.framework${NC}"
    echo -e "   Конфиг Sing-box (outbound JSON):"
    cat << EOF_MASQUE
{
  "type": "masque",
  "tag": "masque-out",
  "server": "${dom}",
  "server_port": ${m_port},
  "username": "${m_user}",
  "password": "${m_pass}",
  "tls": {
    "enabled": true,
    "server_name": "${dom}",
    "alpn": ["h3"]
  },
  "connect_udp": {
    "enabled": true,
    "uri_template": "/.well-known/masque/udp/{target_host}/{target_port}/"
  }
}
EOF_MASQUE
    echo ""

    # 2. ShadowTLS v4 + Shadowsocks-2022 (with udp_over_tcp)
    echo -e "${BOLD}${YELLOW}2. ShadowTLS v4 + Shadowsocks-2022 (udp_over_tcp: true)${NC}"
    echo -e "   Клиенты: ${CYAN}Sing-box, Clsh/Mihomo, Shadowrocket, Loon, Surge${NC}"
    echo -e "   Схема подключения: ShadowTLS (${stls_port}/tcp, SNI: ${stls_sni}) -> Shadowsocks-2022 (${ss_port})"
    cat << EOF_STLS
{
  "outbounds": [
    {
      "type": "shadowtls",
      "tag": "shadowtls-out",
      "server": "${dom}",
      "server_port": ${stls_port},
      "version": 3,
      "password": "${stls_pass}",
      "tls": {
        "enabled": true,
        "server_name": "${stls_sni}"
      }
    },
    {
      "type": "shadowsocks",
      "tag": "ss-out",
      "detour": "shadowtls-out",
      "server": "${dom}",
      "server_port": ${stls_port},
      "method": "2022-blake3-aes-128-gcm",
      "password": "YOUR_SS2022_KEY_FROM_3XUI",
      "udp_over_tcp": true
    }
  ]
}
EOF_STLS
    echo ""

    # 3. NaïveProxy (Caddy)
    echo -e "${BOLD}${YELLOW}3. NaïveProxy (Chromium Network Stack Camouflage)${NC}"
    echo -e "   Клиенты: ${CYAN}NaïveProxy CLI, Sing-box, NekoBox, Clash Meta${NC}"
    echo -e "   URL подключения: ${GREEN}naive+https://${naive_user}:${naive_pass}@${naive_dom}:${naive_port}${NC}"
    echo ""

    # 4. Wstunnel over Dokploy Traefik
    echo -e "${BOLD}${YELLOW}4. Wstunnel over Dokploy Traefik (WebSocket / HTTP/3 over port 443)${NC}"
    echo -e "   Туннелирование WireGuard / AmneziaWG через Dokploy Traefik:"
    echo -e "   Команда запуска клиента wstunnel на ПК / роутере:"
    echo -e "   ${GREEN}wstunnel client -L udp://127.0.0.1:51820:host.docker.internal:51820 wss://${ws_dom}${NC}"
    echo -e "   (В клиенте WireGuard/AmneziaWG укажите Endpoint = 127.0.0.1:51820)"
    echo -e "   ${DIM}Примечание: host.docker.internal перенаправляет трафик из контейнера wstunnel на хост-сервис WireGuard.${NC}"
    echo ""

    # 5. Server-Side Zapret
    echo -e "${BOLD}${YELLOW}5. Server-Side Zapret (DPI Desynchronization)${NC}"
    echo -e "   Работает прозрачно на сервере через ${CYAN}iptables NFQUEUE connbytes 1:6${NC}."
    echo -e "   На стороне клиента дополнительных настроек не требуется."
    echo ""
}

case "${1:-status}" in
    status)
        cmd_status
        ;;
    up)
        acquire_stack_lock "${VPN_STACK_LOCK_TIMEOUT:-10}" "manage-services-up" || exit $?
        cmd_up "${2:-}"
        ;;
    down)
        acquire_stack_lock "${VPN_STACK_LOCK_TIMEOUT:-10}" "manage-services-down" || exit $?
        cmd_down "${2:-}"
        ;;
    restart)
        acquire_stack_lock "${VPN_STACK_LOCK_TIMEOUT:-10}" "manage-services-restart" || exit $?
        cmd_restart "${2:-}"
        ;;
    logs)
        cmd_logs "${2:-}"
        ;;
    dokploy-export)
        cmd_dokploy_export
        ;;
    dokploy-all-in-one)
        cmd_dokploy_all_in_one
        ;;
    dokploy-traefik|dokploy-hybrid)
        cmd_dokploy_traefik
        ;;
    clients)
        cmd_clients
        ;;
    *)
        echo "Использование: $0 {status|up|down|restart|logs|clients|dokploy-export|dokploy-all-in-one|dokploy-traefik} [service]"
        exit 1
        ;;
esac
