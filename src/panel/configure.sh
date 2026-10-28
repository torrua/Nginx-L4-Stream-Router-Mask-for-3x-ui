#!/usr/bin/env bash
# ==============================================================================
#  PANEL CONFIGURATION ENGINE
# ==============================================================================
#  Automated configuration, self-healing, and inbound reconciliation for 3X-UI.
#  Shared between configure-panel.sh entrypoint and setup.sh (fully autonomous).
# ==============================================================================

# @include "common/colors.sh"
# @include "common/logger.sh"
# @include "common/config.sh"
# @include "panel/node-token.sh"
# @include "common/backup.sh"
# @include "common/spinner.sh"

configure_3xui_panel() {
    show_configure_panel_help() {
        cat << 'EOF_HELP'
Использование: ./configure-panel.sh [ОПЦИИ]

Скрипт автоматического конфигурирования и самовосстановления базы 3X-UI (инбаунды, пути, подписки).
Безопасен для повторного запуска: сохраняет существующих клиентов, ключи и кастомные подписки.

Опции:
  -c, --config <FILE>     Путь к файлу параметров (.env) (по умолчанию: ./server-setup.env)
  --db <PATH>             Путь к файлу базы данных SQLite 3X-UI (по умолчанию: /etc/x-ui/x-ui.db)
  --dry-run               Только аудит и проверка (без внесения изменений)
  --force-sub             Принудительно перезаписать кастомные параметры подписки из .env
  --force-remarks         Принудительно сбросить названия инбаундов к стандартным из .env
  --warp                  Включить исходящий туннель Cloudflare WARP (обход капч и AI)
  --no-warp               Отключить исходящий туннель Cloudflare WARP
  --warp-key <KEY>        Указать лицензионный ключ WARP+
  --node-token            Создать API-токен для подключения сервера как узла (3X-UI Node)
  --no-node-token         Не создавать API-токен для подключения сервера как узла
  --node-token-name <NAME> Название API-токена ноды (по умолчанию: <SERVER_PREFIX>-Node)
  --node-token-scope <SCOPE> Тип API-токена ноды: node-sync (по умолчанию) или admin
  -y, --yes               Неинтерактивное выполнение (без подтверждений)
  -h, --help              Показать эту справку и выйти

Примеры использования:
  # 1. Обычная настройка / обновление:
  ./configure-panel.sh --config ./server-setup.env -y

  # 2. Безопасный аудит (посмотреть, что изменится, без записи):
  ./configure-panel.sh --dry-run
EOF_HELP
    }

    local CONFIG_FILE=""
    local DB_PATH="/etc/x-ui/x-ui.db"
    local DRY_RUN=0
    local FORCE_SUB=0
    local FORCE_REMARKS=0
    local NON_INTERACTIVE=0
    local CLI_ENABLE_WARP=""
    local CLI_WARP_KEY=""
    local CLI_ENABLE_NODE_TOKEN=""
    local CLI_NODE_TOKEN_NAME=""
    local CLI_NODE_TOKEN_SCOPE=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: путь к файлу конфигурации."
                CONFIG_FILE="$2"
                shift 2
                ;;
            --db)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: путь к базе данных x-ui.db."
                DB_PATH="$2"
                shift 2
                ;;
            --domain)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: домен."
                PRIMARY_DOMAIN="$2"
                shift 2
                ;;
            --sub-domain)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: домен подписок."
                SUB_DOMAIN="$2"
                shift 2
                ;;
            --panel-domain)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: домен панели."
                PANEL_DOMAIN="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --force-sub)
                FORCE_SUB=1
                shift
                ;;
            --force-remarks)
                FORCE_REMARKS=1
                shift
                ;;
            --warp)
                CLI_ENABLE_WARP="y"
                shift
                ;;
            --no-warp)
                CLI_ENABLE_WARP="n"
                shift
                ;;
            --warp-key)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: лицензионный ключ WARP+."
                CLI_WARP_KEY="$2"
                shift 2
                ;;
            --node-token)
                CLI_ENABLE_NODE_TOKEN="y"
                shift
                ;;
            --no-node-token)
                CLI_ENABLE_NODE_TOKEN="n"
                shift
                ;;
            --node-token-name)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: имя токена ноды."
                CLI_NODE_TOKEN_NAME="$2"
                shift 2
                ;;
            --node-token-scope)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: тип (scope) токена ноды."
                CLI_NODE_TOKEN_SCOPE="$2"
                shift 2
                ;;
            -y|--yes)
                NON_INTERACTIVE=1
                shift
                ;;
            -h|--help)
                show_configure_panel_help
                return 0
                ;;
            *)
                warn "Неизвестный параметр: $1"
                show_configure_panel_help
                return 1
                ;;
        esac
    done

    # Захват блокировки для изменяющих операций (T07)
    if [ "$DRY_RUN" -eq 0 ]; then
        acquire_stack_lock "${VPN_STACK_LOCK_TIMEOUT:-10}" "configure-panel" || exit $?
    fi

    # Поиск конфигурационного файла (.env)
    if [ -n "$CONFIG_FILE" ]; then
        if [ ! -f "$CONFIG_FILE" ]; then
            die "Указанный файл конфигурации не найден: $CONFIG_FILE"
        fi
    else
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo ".")"
        if CONFIG_FILE="$(find_config_file "$script_dir")"; then
            log "Обнаружен файл параметров: $CONFIG_FILE"
        else
            CONFIG_FILE=""
        fi
    fi

    if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
        log "Загрузка параметров из $CONFIG_FILE..."
        load_config_data_safe "$CONFIG_FILE" || die "Ошибка загрузки параметров из $CONFIG_FILE"
    fi

    # CLI-аргументы имеют наивысший приоритет над файлом конфигурации
    [ -n "$CLI_ENABLE_WARP" ] && ENABLE_WARP="$CLI_ENABLE_WARP"
    [ -n "$CLI_WARP_KEY" ] && WARP_LICENSE_KEY="$CLI_WARP_KEY"
    [ -n "$CLI_ENABLE_NODE_TOKEN" ] && ENABLE_NODE_TOKEN="$CLI_ENABLE_NODE_TOKEN"
    [ -n "$CLI_NODE_TOKEN_NAME" ] && NODE_TOKEN_NAME="$CLI_NODE_TOKEN_NAME"
    [ -n "$CLI_NODE_TOKEN_SCOPE" ] && NODE_TOKEN_SCOPE="$CLI_NODE_TOKEN_SCOPE"
    NODE_TOKEN_SCOPE="${NODE_TOKEN_SCOPE:-node-sync}"

    # Дефолтные значения переменных, если не определены в .env
    PRIMARY_DOMAIN="${PRIMARY_DOMAIN:-yourdomain.online}"
    PANEL_PORT="${PANEL_PORT:-10443}"
    PANEL_PATH="${PANEL_PATH:-}"
    SUB_PORT="${SUB_PORT:-55443}"
    SUB_PATH="${SUB_PATH:-}"
    SUB_CLASH_PATH="${SUB_CLASH_PATH:-${SUB_PATH%/}/clash}"
    if [ -n "${SERVER_PREFIX:-}" ] && [ "${SERVER_PREFIX,,}" = "auto" ]; then
        SERVER_PREFIX="$(detect_server_location_prefix 2>/dev/null || echo "$PRIMARY_DOMAIN")"
    fi
    SERVER_PREFIX="${SERVER_PREFIX:-$PRIMARY_DOMAIN}"
    ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
    NODE_TOKEN_NAME="${NODE_TOKEN_NAME:-${SERVER_PREFIX}-Node}"
    DIAG_TOKEN="${DIAG_TOKEN:-}"

    STEAL_PORT="${STEAL_PORT:-45443}"
    STEAL_SNI="${STEAL_SNI:-gateway.icloud.com}"
    STEAL_COMPAT_PORT="${STEAL_COMPAT_PORT:-47443}"
    STEAL_COMPAT_DOMAIN="${STEAL_COMPAT_DOMAIN:-static.${PRIMARY_DOMAIN:-}}"
    XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-${XHTTP_PORT:-50443}}"
    XHTTP_STREAM_PATH="${XHTTP_STREAM_PATH:-${XHTTP_PATH:-xhttp}}"
    XHTTP_PORT="$XHTTP_STREAM_PORT"
    XHTTP_PATH="$XHTTP_STREAM_PATH"
    XHTTP_SNI="${XHTTP_SNI:-gateway.icloud.com}"
    CLASSIC_PORT="${CLASSIC_PORT:-46443}"
    CLASSIC_SNI="${CLASSIC_SNI:-dl.google.com}"
    REALITY_FINGERPRINT="${REALITY_FINGERPRINT:-${FINGERPRINT:-firefox}}"
    HY2_PORT="${HY2_PORT:-443}"
    HY2_DOMAIN="${HY2_DOMAIN:-$PRIMARY_DOMAIN}"
    AWG_V3_PORT="${AWG_V3_PORT:-8443}"
    AWG_V2_PORT="${AWG_V2_PORT:-8444}"
    AWG_PRIMARY_DNS="${AWG_PRIMARY_DNS:-9.9.9.9}"
    AWG_SECONDARY_DNS="${AWG_SECONDARY_DNS:-76.76.2.0}"
    AWG_SUBNET_IP="${AWG_SUBNET_IP:-10.8.0.0}"
    AWG_SUBNET_CIDR="${AWG_SUBNET_CIDR:-22}"
    AWG_HEADER_PROTECTION_KEY="${AWG_HEADER_PROTECTION_KEY:-}"
    AWG_RANDOM_TRAILERS="${AWG_RANDOM_TRAILERS:-false}"
    AWG_I1="${AWG_I1:-}"
    SS2022_PORT="${SS2022_PORT:-8388}"
    SHADOWTLS_PORT="${SHADOWTLS_PORT:-8543}"
    SHADOWTLS_SNI="${SHADOWTLS_SNI:-gateway.icloud.com}"
    SHADOWTLS_PASSWORD="${SHADOWTLS_PASSWORD:-}"
    WSTUNNEL_PORT="${WSTUNNEL_PORT:-8080}"
    WSTUNNEL_PREFIX="${WSTUNNEL_PREFIX:-}"
    ZAPRET_QNUM="${ZAPRET_QNUM:-200}"
    ZAPRET_DESYNC="${ZAPRET_DESYNC:-split2}"
    ZAPRET_FOOLING="${ZAPRET_FOOLING:-md5sig,badseq}"
    NAIVE_PORT="${NAIVE_PORT:-8446}"
    NAIVE_DOMAIN="${NAIVE_DOMAIN:-$PRIMARY_DOMAIN}"
    NAIVE_USER="${NAIVE_USER:-user}"
    NAIVE_PASS="${NAIVE_PASS:-}"
    DNSTT_PORT="${DNSTT_PORT:-53053}"
    DNSTT_DOMAIN="${DNSTT_DOMAIN:-}"
    DNSTT_PUBKEY="${DNSTT_PUBKEY:-}"
    TUIC_PORT="${TUIC_PORT:-8448}"
    MTPROTO_PORT="${MTPROTO_PORT:-8444}"
    MTPROTO_FAKETLS_DOMAIN="${MTPROTO_FAKETLS_DOMAIN:-gateway.icloud.com}"
    MTPROTO_ADTAG="${MTPROTO_ADTAG:-}"
    ENABLE_MASQUE="${ENABLE_MASQUE:-n}"
    MASQUE_PORT="${MASQUE_PORT:-8449}"
    MASQUE_USER="${MASQUE_USER:-client}"
    MASQUE_PASSWORD="${MASQUE_PASSWORD:-}"
    REALITY_FALLBACK_PORT="${REALITY_FALLBACK_PORT:-9443}"
    STEAL_DOMAINS="${STEAL_DOMAINS[*]:-${STEAL_DOMAINS:-cdn.$PRIMARY_DOMAIN}}"
    SUB_TITLE="${SUB_TITLE:-${SERVER_PREFIX:-Server}}"
    CLIENT_EMAIL="${CLIENT_EMAIL:-${CLIENT_NAME:-}}"
    CLIENT_NAME="${CLIENT_NAME:-${CLIENT_EMAIL:-}}"

    ENABLE_STEAL="${ENABLE_STEAL:-y}"
    ENABLE_STEAL_COMPAT="${ENABLE_STEAL_COMPAT:-n}"
    ENABLE_XHTTP="${ENABLE_XHTTP:-y}"
    ENABLE_CLASSIC="${ENABLE_CLASSIC:-y}"
    ENABLE_HY2="${ENABLE_HY2:-y}"
    ENABLE_AWG_V3="${ENABLE_AWG_V3:-y}"
    ENABLE_AWG_V2="${ENABLE_AWG_V2:-n}"
    ENABLE_SS2022="${ENABLE_SS2022:-n}"
    ENABLE_SHADOWTLS="${ENABLE_SHADOWTLS:-n}"
    ENABLE_WSTUNNEL="${ENABLE_WSTUNNEL:-n}"
    ENABLE_ZAPRET="${ENABLE_ZAPRET:-n}"
    ENABLE_NAIVE="${ENABLE_NAIVE:-n}"
    ENABLE_DNSTT="${ENABLE_DNSTT:-n}"
    ENABLE_TUIC="${ENABLE_TUIC:-n}"
    ENABLE_MTPROTO="${ENABLE_MTPROTO:-n}"

    ENABLE_WARP="${ENABLE_WARP:-n}"
    WARP_LICENSE_KEY="${WARP_LICENSE_KEY:-}"
    TIME_LOCATION="${TIME_LOCATION:-Europe/Moscow}"
    SUB_UPDATES="${SUB_UPDATES:-1}"
    SUB_ENCRYPT="${SUB_ENCRYPT:-true}"
    BLOCK_SMTP="${BLOCK_SMTP:-true}"
    BLOCK_LAN="${BLOCK_LAN:-true}"
    ENABLE_AGH="${ENABLE_AGH:-n}"
    PORT_AGH_DNS="${PORT_AGH_DNS:-10053}"
    AGH_XRAY_DNS="${AGH_XRAY_DNS:-127.0.0.1:10053}"

    HAS_NGINX=0
    if command -v nginx >/dev/null 2>&1 && [ -d /etc/nginx ]; then
        HAS_NGINX=1
    fi

    if [ -n "${WEB_LISTEN:-}" ]; then
        WEB_LISTEN="$WEB_LISTEN"
    elif [ "$HAS_NGINX" -eq 1 ]; then
        WEB_LISTEN="127.0.0.1"
    else
        WEB_LISTEN=""
    fi

    if [ -n "${SUB_LISTEN:-}" ]; then
        SUB_LISTEN="$SUB_LISTEN"
    elif [ "$HAS_NGINX" -eq 1 ]; then
        SUB_LISTEN="127.0.0.1"
    else
        SUB_LISTEN=""
    fi

    resolve_ssl_cert_paths "$PRIMARY_DOMAIN" "SSL"
    resolve_ssl_cert_paths "${HY2_DOMAIN:-$PRIMARY_DOMAIN}" "HY2"
    resolve_ssl_cert_paths "${TUIC_DOMAIN:-$PRIMARY_DOMAIN}" "TUIC"

    # Определение работоспособной команды Python
    PYTHON_CMD=""
    for candidate in python3 python; do
        if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "import sys" >/dev/null 2>&1; then
            PYTHON_CMD="$candidate"
            break
        fi
    done

    if [ -z "$PYTHON_CMD" ]; then
        if [ "$DRY_RUN" -eq 0 ]; then
            log "Установка python3..."
            apt-get update -q && apt-get install -y python3 python3-bcrypt -q 2>/dev/null || apt-get install -y python3 -q || die "Не удалось установить python3."
            PYTHON_CMD="python3"
        else
            die "Работоспособный Python 3 не найден в системе. Необходим для анализа базы SQLite."
        fi
    elif [ "$DRY_RUN" -eq 0 ]; then
        if command -v apt-get >/dev/null 2>&1 && ! "$PYTHON_CMD" -c "import bcrypt" >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y python3-bcrypt -q 2>/dev/null || true
        fi
    fi

    # Проверка наличия базы данных 3X-UI
    IS_DOCKER_XUI=0
    if [ ! -f "$DB_PATH" ]; then
        alt_paths=("/usr/local/x-ui/bin/x-ui.db" "/etc/x-ui/db/x-ui.db")
        found=0
        for p in "${alt_paths[@]}"; do
            if [ -f "$p" ]; then
                DB_PATH="$p"
                found=1
                break
            fi
        done
        if [ "$found" -eq 0 ] && command -v docker >/dev/null 2>&1; then
            local doc_vol=""
            doc_vol=$(docker volume ls -q 2>/dev/null | grep 'xui_data' | head -n1 || true)
            if [ -n "$doc_vol" ]; then
                local mnt=""
                mnt=$(docker volume inspect "$doc_vol" --format '{{.Mountpoint}}' 2>/dev/null || true)
                if [ -n "$mnt" ] && [ -f "$mnt/x-ui.db" ]; then
                    DB_PATH="$mnt/x-ui.db"
                    found=1
                    IS_DOCKER_XUI=1
                    ok "Обнаружена база данных 3X-UI в Docker Volume ($doc_vol): $DB_PATH"
                fi
            fi
        fi
        if [ "$found" -eq 0 ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                die "База данных 3X-UI ($DB_PATH) не найдена. Убедитесь, что панель 3X-UI установлена."
            fi
            log "Служба 3X-UI не обнаружена на сервере. Автоматическая установка..."
            install_3xui_task() {
                export DEBIAN_FRONTEND=noninteractive
                curl -Ls --connect-timeout 15 https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o /tmp/install_3xui.sh
                printf "n\n" | bash /tmp/install_3xui.sh
            }
            run_with_spinner "Установка официального ядра 3X-UI (mhsanaei)" install_3xui_task
            for p in "$DB_PATH" "/usr/local/x-ui/bin/x-ui.db" "/etc/x-ui/db/x-ui.db"; do
                if [ -f "$p" ]; then
                    DB_PATH="$p"
                    found=1
                    break
                fi
            done
            if [ "$found" -eq 0 ]; then
                die "Не удалось найти базу данных 3X-UI после установки. Установите вручную: bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)"
            fi
            ok "Панель 3X-UI успешно установлена!"
            WAS_ACTIVE=1
        fi
    fi

    log "Используется база данных 3X-UI: $DB_PATH"

    if [ "$DRY_RUN" -eq 0 ]; then
        BACKUP_TS="$(date +%Y%m%d_%H%M%S)"
        BACKUP_DB="${DB_PATH}.bak.${BACKUP_TS}"
        if ! backup_sqlite_db "$DB_PATH" "$BACKUP_DB"; then
            die "Критическая ошибка: невозможно создать проверенную резервную копию базы данных $DB_PATH. Внесение изменений отменено во избежание повреждения данных."
        fi
    fi

    export DB_PATH
    export DRY_RUN
    export FORCE_SUB
    export PRIMARY_DOMAIN
    export SUB_DOMAIN="${SUB_DOMAIN:-}"
    export PANEL_DOMAIN="${PANEL_DOMAIN:-}"
    export PANEL_PORT
    export PANEL_PATH
    export SUB_PORT
    export SUB_PATH
    export SUB_CLASH_PATH
    export ENABLE_STEAL
    export ENABLE_STEAL_COMPAT
    export STEAL_PORT
    export STEAL_COMPAT_PORT
    export STEAL_COMPAT_DOMAIN
    export STEAL_SNI
    export ENABLE_XHTTP
    export XHTTP_PORT
    export XHTTP_PATH
    export XHTTP_STREAM_PORT
    export XHTTP_STREAM_PATH
    export XHTTP_SNI
    export ENABLE_CLASSIC
    export CLASSIC_PORT
    export CLASSIC_SNI
    export REALITY_FINGERPRINT
    export ENABLE_HY2
    export HY2_PORT
    export HY2_DOMAIN
    export HY2_CERT_PATH
    export HY2_KEY_PATH
    export ENABLE_AWG_V3
    export AWG_V3_PORT
    export ENABLE_AWG_V2
    export AWG_V2_PORT
    export AWG_PRIMARY_DNS
    export AWG_SECONDARY_DNS
    export AWG_SUBNET_IP
    export AWG_SUBNET_CIDR
    export AWG_HEADER_PROTECTION_KEY
    export AWG_RANDOM_TRAILERS
    export ENABLE_SS2022
    export SS2022_PORT
    export ENABLE_SHADOWTLS
    export SHADOWTLS_PORT
    export SHADOWTLS_SNI
    export SHADOWTLS_PASSWORD
    export ENABLE_NAIVE
    export NAIVE_PORT
    export NAIVE_DOMAIN
    export NAIVE_USER
    export NAIVE_PASS
    export ENABLE_DNSTT
    export DNSTT_PORT
    export DNSTT_DOMAIN
    export DNSTT_PUBKEY
    export ENABLE_TUIC
    export TUIC_PORT
    export TUIC_CERT_PATH
    export TUIC_KEY_PATH
    export ENABLE_MTPROTO
    export MTPROTO_PORT
    export MTPROTO_FAKETLS_DOMAIN
    export MTPROTO_ADTAG
    export SSL_CERT_PATH
    export SSL_KEY_PATH
    export ADMIN_USERNAME
    export ADMIN_PASSWORD
    export SERVER_PREFIX
    export SUB_TITLE
    export REALITY_FALLBACK_PORT
    export STEAL_DOMAINS
    export ENABLE_MASQUE
    export MASQUE_PORT
    export MASQUE_USER
    export MASQUE_PASSWORD
    export ENABLE_ZAPRET
    export ZAPRET_QNUM
    export ZAPRET_DESYNC
    export ZAPRET_FOOLING
    export AWG_I1
    export CLIENT_EMAIL
    export CLIENT_NAME
    export ENABLE_WARP
    export WARP_LICENSE_KEY
    export TIME_LOCATION
    export SUB_UPDATES
    export SUB_ENCRYPT
    export BLOCK_SMTP
    export ENABLE_WSTUNNEL="${ENABLE_WSTUNNEL:-n}"
    export WSTUNNEL_PREFIX="${WSTUNNEL_PREFIX:-}"
    export WSTUNNEL_PORT="${WSTUNNEL_PORT:-8080}"
    export ENABLE_MIERU="${ENABLE_MIERU:-n}"
    export MIERU_PORT="${MIERU_PORT:-8450}"
    export MIERU_PORT_MODE="${MIERU_PORT_MODE:-single}"
    export MIERU_TRANSPORT="${MIERU_TRANSPORT:-BOTH}"
    export MIERU_USER="${MIERU_USER:-}"
    export MIERU_PASS="${MIERU_PASS:-}"
    export BLOCK_LAN
    export WEB_LISTEN
    export SUB_LISTEN
    export ENABLE_AGH
    export PORT_AGH_DNS
    export AGH_XRAY_DNS
    export FORCE_REMARKS
    export INBOUND_TRAFFIC_RESET="${INBOUND_TRAFFIC_RESET:-monthly}"
    export INBOUND_TRAFFIC_RESET_DAY="${INBOUND_TRAFFIC_RESET_DAY:-1}"

    # Приостановка службы x-ui на время реальной транзакции во избежание блокировок SQLite
    WAS_ACTIVE=0
    cleanup_xui() {
        if [ "${WAS_ACTIVE:-0}" -eq 1 ]; then
            if [ "${IS_DOCKER_XUI:-0}" -eq 1 ]; then
                docker start 3x-ui-dokploy >/dev/null 2>&1 || true
            else
                svc_start x-ui 2>/dev/null || systemctl start x-ui 2>/dev/null || true
            fi
        fi
        command -v release_stack_lock >/dev/null 2>&1 && release_stack_lock
    }
    trap cleanup_xui EXIT

    if [ -f /etc/init.d/x-ui ] && ! grep -q 'directory=' /etc/init.d/x-ui 2>/dev/null; then
        sed -i '/command=/a directory="/usr/local/x-ui"' /etc/init.d/x-ui 2>/dev/null || true
    fi

    if [ "$DRY_RUN" -eq 0 ]; then
        if [ "${IS_DOCKER_XUI:-0}" -eq 1 ]; then
            log "Остановка контейнера 3X-UI на время обновления конфигурации базы..."
            docker stop 3x-ui-dokploy >/dev/null 2>&1 || true
            WAS_ACTIVE=1
        elif svc_is_active x-ui 2>/dev/null || (command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet x-ui 2>/dev/null); then
            log "Приостановка службы 3X-UI на время обновления конфигурации базы..."
            svc_stop x-ui 2>/dev/null || systemctl stop x-ui 2>/dev/null || true
            WAS_ACTIVE=1
        fi
    fi

    log "Конфигурирование таблиц settings и inbounds (Smart Reconcile Engine)..."

    "$PYTHON_CMD" - << 'EOF_PYTHON_CONFIG'
# @include "panel/reconcile.py"
EOF_PYTHON_CONFIG

    # Нормализация прав доступа и перезапуск служб (Hardened: chmod 600 для защиты от локальной утечки)
    if [ "$DRY_RUN" -eq 0 ]; then
        chmod 600 "$DB_PATH" 2>/dev/null || true

        # Обнаружение исполняемого файла CLI 3X-UI
        XUI_BIN=""
        for candidate in "/usr/local/x-ui/x-ui" "/usr/bin/x-ui" "/usr/local/bin/x-ui"; do
            if [ -x "$candidate" ]; then
                XUI_BIN="$candidate"
                break
            fi
        done
        if [ -z "$XUI_BIN" ] && command -v x-ui >/dev/null 2>&1; then
            XUI_BIN="$(command -v x-ui)"
        fi

        # Синхронизация учетных данных администратора через нативный CLI 3X-UI (bcrypt + сброс login_epoch)
        if [ -n "${ADMIN_USERNAME:-}" ] || [ -n "${ADMIN_PASSWORD:-}" ]; then
            if [ -n "$XUI_BIN" ]; then
                xui_user_args=()
                [ -n "${ADMIN_USERNAME:-}" ] && xui_user_args+=("-username" "$ADMIN_USERNAME")
                [ -n "${ADMIN_PASSWORD:-}" ] && xui_user_args+=("-password" "$ADMIN_PASSWORD")
                log "Синхронизация учетных данных администратора через '$XUI_BIN setting' (bcrypt)..."
                if "$XUI_BIN" setting "${xui_user_args[@]}" >/tmp/xui_setting.log 2>&1; then
                    ok "Учетные данные администратора успешно синхронизированы в 3X-UI (bcrypt)!"
                else
                    warn "Предупреждение при вызове '$XUI_BIN setting': $(cat /tmp/xui_setting.log 2>/dev/null)"
                fi
            fi
        fi

        ensure_node_token

        # Очистка устаревших/невалидных geosite меток в bin/config.json с помощью безопасного JSON парсера
        for cfg_candidate in "/usr/local/x-ui/bin/config.json" "/etc/x-ui/bin/config.json"; do
            if [ -f "$cfg_candidate" ]; then
                "$PYTHON_CMD" - "$cfg_candidate" << 'EOF_CLEAN_JSON' 2>/dev/null || true
import json, sys
cfg_path = sys.argv[1]
try:
    with open(cfg_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    bad_prefixes = ("geosite:ru", "geosite:yandex", "geosite:vk", "geosite:youtube",
                    "geosite:openai", "geosite:google-gemini", "geosite:anthropic", "geosite:cloudflare")
    def clean_obj(obj):
        if isinstance(obj, dict):
            return {k: clean_obj(v) for k, v in obj.items()}
        elif isinstance(obj, list):
            return [clean_obj(x) for x in obj if not (isinstance(x, str) and any(x.startswith(b) for b in bad_prefixes))]
        return obj
    cleaned = clean_obj(data)
    with open(cfg_path, 'w', encoding='utf-8') as f:
        json.dump(cleaned, f, indent=2, ensure_ascii=False)
except Exception:
    pass
EOF_CLEAN_JSON
            fi
        done

        # Обновление ядра Xray-core до последней актуальной версии (v26.10.21+)
        INSTALLED_XRAY_VER=""
        if [[ "${UPDATE_XRAY_CORE:-y}" =~ ^[Yy1] ]]; then
            XRAY_BIN_DIR="/usr/local/x-ui/bin"
            [ -d "$XRAY_BIN_DIR" ] || XRAY_BIN_DIR="/etc/x-ui/bin"
            
            ARCH=$(uname -m 2>/dev/null || echo "x86_64")
            case "$ARCH" in
                x86_64|amd64)   XRAY_ARCH="64"; BIN_NAME="xray-linux-amd64" ;;
                aarch64|arm64)  XRAY_ARCH="arm64-v8a"; BIN_NAME="xray-linux-arm64-v8a" ;;
                armv7*|armhf)   XRAY_ARCH="arm32-v7a"; BIN_NAME="xray-linux-arm32-v7a" ;;
                *)              XRAY_ARCH="64"; BIN_NAME="xray-linux-amd64" ;;
            esac
            
            TARGET_BIN="$XRAY_BIN_DIR/$BIN_NAME"
            [ -f "$TARGET_BIN" ] || TARGET_BIN="$XRAY_BIN_DIR/xray"
            
            CURRENT_VER=""
            if [ -x "$TARGET_BIN" ]; then
                CURRENT_VER=$("$TARGET_BIN" -version 2>/dev/null | { head -n 1 || true; } | { awk '{print $2}' || true; }) || CURRENT_VER=""
            fi

            LATEST_TAG=""
            if command -v curl >/dev/null 2>&1; then
                gh_resp=$(curl -fsSL --connect-timeout 5 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null || true)
                if [ -n "$gh_resp" ]; then
                    if command -v python3 >/dev/null 2>&1; then
                        LATEST_TAG=$(python3 -c 'import json, sys; print(json.loads(sys.stdin.read()).get("tag_name", ""))' <<< "$gh_resp" 2>/dev/null || true)
                    else
                        LATEST_TAG=$(sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$gh_resp" | head -n 1)
                    fi
                fi
            fi
            [ -n "$LATEST_TAG" ] || LATEST_TAG="v26.10.21"
            CLEAN_LATEST="${LATEST_TAG#v}"

            if [ -z "$CURRENT_VER" ] || [ "$CURRENT_VER" != "$CLEAN_LATEST" ]; then
                log "Обновление ядра Xray до последней версии ($CURRENT_VER -> $LATEST_TAG)..."
                TMP_XRAY_DIR="/tmp/xray_update_$$"
                mkdir -p "$TMP_XRAY_DIR"
                XRAY_ZIP="$TMP_XRAY_DIR/xray.zip"
                
                DL_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_TAG}/Xray-linux-${XRAY_ARCH}.zip"
                if curl -fsSL --connect-timeout 15 "$DL_URL" -o "$XRAY_ZIP" 2>/dev/null; then
                    python3 -c "import zipfile; zipfile.ZipFile('$XRAY_ZIP').extractall('$TMP_XRAY_DIR')" 2>/dev/null || true
                    if [ -f "$TMP_XRAY_DIR/xray" ]; then
                        chmod +x "$TMP_XRAY_DIR/xray"
                        if "$TMP_XRAY_DIR/xray" -version >/dev/null 2>&1; then
                            mkdir -p "$XRAY_BIN_DIR"
                            [ -f "$TARGET_BIN" ] && cp -f "$TARGET_BIN" "$TARGET_BIN.bak"
                            install -m 755 "$TMP_XRAY_DIR/xray" "$TARGET_BIN.tmp.$$"
                            mv -f "$TARGET_BIN.tmp.$$" "$TARGET_BIN"
                            
                            if "$TARGET_BIN" -version >/dev/null 2>&1; then
                                [ -f "$TARGET_BIN.bak" ] && rm -f "$TARGET_BIN.bak"
                                [ -f "$TMP_XRAY_DIR/geosite.dat" ] && cp -f "$TMP_XRAY_DIR/geosite.dat" "$XRAY_BIN_DIR/geosite.dat"
                                [ -f "$TMP_XRAY_DIR/geoip.dat" ] && cp -f "$TMP_XRAY_DIR/geoip.dat" "$XRAY_BIN_DIR/geoip.dat"
                                
                                INSTALLED_XRAY_VER="$LATEST_TAG"
                                ok "Ядро Xray успешно обновлено до последней версии $LATEST_TAG (было: ${CURRENT_VER:-неизвестно})!"
                            else
                                warn "Установленный бинарник Xray не запустился, выполняется откат."
                                [ -f "$TARGET_BIN.bak" ] && mv -f "$TARGET_BIN.bak" "$TARGET_BIN"
                                INSTALLED_XRAY_VER="${CURRENT_VER:-v26.7.28}"
                            fi
                        else
                            warn "Скачанный бинарник Xray $LATEST_TAG не прошел валидацию, сохранен текущий $CURRENT_VER."
                            INSTALLED_XRAY_VER="${CURRENT_VER:-v26.7.28}"
                        fi
                    fi
                else
                    warn "Не удалось скачать обновление Xray $LATEST_TAG с GitHub, используется $CURRENT_VER."
                    INSTALLED_XRAY_VER="${CURRENT_VER:-v26.7.28}"
                fi
                rm -rf "$TMP_XRAY_DIR"
            else
                INSTALLED_XRAY_VER="$LATEST_TAG"
                ok "Ядро Xray уже актуальной версии ($LATEST_TAG)."
            fi
        fi

        # Активация службы 3X-UI
        log "Активация службы 3X-UI..."
        if [ "${IS_DOCKER_XUI:-0}" -eq 1 ]; then
            (docker start 3x-ui-dokploy >/dev/null 2>&1 || docker start $(docker ps -aq --filter ancestor=ghcr.io/mhsanaei/3x-ui | head -n1) >/dev/null 2>&1) && ok "Контейнер 3X-UI успешно запущен." || warn "Не удалось запустить контейнер 3X-UI."
        else
            (svc_restart x-ui 2>/dev/null || svc_start x-ui 2>/dev/null || systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null || rc-service x-ui start 2>/dev/null) && ok "Служба 3X-UI успешно активирована." || warn "Не удалось активировать службу x-ui."
        fi
        sleep 2

        # Проверка Nginx на наличие мертвого SNI и мягкий reload
        if command -v nginx >/dev/null 2>&1; then
            if [ -d /etc/nginx ] && grep -rq "swdist\.microsoft\.com" /etc/nginx/ 2>/dev/null; then
                log "Обновление устаревшего SNI в конфигурационных файлах Nginx..."
                find /etc/nginx/ -type f -name "*.conf" -exec sed -i 's/swdist\.microsoft\.com/gateway\.icloud\.com/g' {} + 2>/dev/null || true
                ok "Nginx: SNI swdist.microsoft.com заменен на gateway.icloud.com."
            fi

            if nginx -t >/dev/null 2>&1; then
                systemctl reload nginx 2>/dev/null && ok "Nginx успешно применил конфигурацию (Zero Downtime reload)." || true
            fi
        fi
    fi

    # Чтение параметров единого клиента, экспортированных из Python
    UNIFIED_CLIENT_TAG=""
    UNIFIED_SUB_ID=""
    UNIFIED_VLESS_ENKEY=""
    SS2022_URI=""
    TUIC_URI=""
    MTPROTO_TG_URI=""
    MTPROTO_HTTPS_URI=""
    MTPROTO_SECRET=""
    MTPROTO_BOT_SECRET=""
    MASQUE_URI=""
    SHADOWTLS_URI=""
    SS_SHADOWTLS_URI=""
    WSTUNNEL_CLI=""
    WSTUNNEL_URI=""
    ZAPRET_INFO=""
    NAIVE_URI=""
    DNSTT_CLI=""
    DNSTT_PUBKEY=""
    for c_env in "/run/3xui_unified_client.env" "/tmp/3xui_unified_client.env"; do
        if [ -f "$c_env" ]; then
            # shellcheck disable=SC1090
            source "$c_env"
            break
        fi
    done

    if [ -z "${DNSTT_PUBKEY:-}" ] && [ -f "/etc/dnstt/server.pub" ]; then
        DNSTT_PUBKEY="$(cat /etc/dnstt/server.pub 2>/dev/null | tr -d '[:space:]')"
    fi
    if [ -n "${DNSTT_PUBKEY:-}" ]; then
        if [ -n "${DNSTT_CLI:-}" ] && [[ "$DNSTT_CLI" == *"-pubkey  "* ]]; then
            DNSTT_CLI="${DNSTT_CLI/-pubkey  /-pubkey ${DNSTT_PUBKEY} }"
        fi
    fi

    echo
    echo -e "${GREEN}=====================================================================${NC}"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "${YELLOW}               АУДИТ УСПЕШНО ЗАВЕРШЕН (DRY-RUN)                      ${NC}"
        echo -e "${CYAN}  Для применения изменений выполните:                                ${NC}"
        echo -e "  ${BOLD}./configure-panel.sh --config \"${CONFIG_FILE:-./server-setup.env}\" -y${NC}"
    else
        echo -e "${GREEN}      БАЗА ДАННЫХ 3X-UI УСПЕШНО СКОНФИГУРИРОВАНА И ИСЦЕЛЕНА!         ${NC}"
        echo -e "  - ${BOLD}Единый клиент:${NC}         ${GREEN}${UNIFIED_CLIENT_TAG:-Client}${NC} (объединяет до 9 протоколов в 1 профиль)"
        if [ -n "$INSTALLED_XRAY_VER" ]; then
            echo -e "  - ${BOLD}Ядро Xray-core:${NC}        ${GREEN}${INSTALLED_XRAY_VER}${NC} (Latest Official Release)"
        fi
        local disp_sub_host="${SUB_DOMAIN:-$PRIMARY_DOMAIN}"
        local disp_panel_host="${PANEL_DOMAIN:-$PRIMARY_DOMAIN}"
        local clean_p_path="${PANEL_PATH#/}"
        local clean_s_path="${SUB_PATH#/}"
        local clean_sc_path="${SUB_CLASH_PATH#/}"
        [ -n "$clean_p_path" ] && clean_p_path="${clean_p_path%/}/"
        [ -n "$clean_s_path" ] && clean_s_path="${clean_s_path%/}/"
        [ -n "$clean_sc_path" ] && clean_sc_path="${clean_sc_path%/}/"

        echo -e "  - ${BOLD}Панель управления:${NC}      ${CYAN}https://${disp_panel_host}/${clean_p_path}${NC}"
        echo -e "  - ${BOLD}Логин панели:${NC}           ${WHITE}${ADMIN_USERNAME:-admin}${NC}"
        if [ -n "${ADMIN_PASSWORD:-}" ]; then
            echo -e "  - ${BOLD}Пароль панели:${NC}          ${WHITE}${ADMIN_PASSWORD}${NC}"
        fi
        echo -e "  - ${BOLD}Канал подписок:${NC}        ${CYAN}https://${disp_sub_host}/${clean_s_path}${NC}"
        echo -e "  - ${BOLD}Канал подписок (Clash):${NC}  ${CYAN}https://${disp_sub_host}/${clean_sc_path}${NC}"
        if [ -n "${UNIFIED_SUB_ID:-}" ]; then
            echo -e "  - ${BOLD}Прямая подписка:${NC}       ${GREEN}https://${disp_sub_host}/${clean_s_path}${UNIFIED_SUB_ID}${NC}"
            echo -e "  - ${BOLD}Прямая подписка (Clash):${NC} ${GREEN}https://${disp_sub_host}/${clean_sc_path}${UNIFIED_SUB_ID}${NC}"
        fi
        if [ -n "${UNIFIED_VLESS_ENKEY:-}" ]; then
            echo -e "  - ${BOLD}VLESS xHTTP EnKey:${NC}     ${YELLOW}${UNIFIED_VLESS_ENKEY}${NC} (ML-KEM-768)"
        fi
        if [ -n "${UNIFIED_AWG_HPK:-}" ]; then
            echo -e "  - ${BOLD}AmneziaWG v3.1 HPK:${NC}     ${YELLOW}${UNIFIED_AWG_HPK}${NC} (UDP :${UNIFIED_AWG_PORT:-8443})"
        fi
        if [ -n "${SS2022_URI:-}" ]; then
            echo -e "  - ${BOLD}Shadowsocks 2022:${NC}    ${CYAN}${SS2022_URI}${NC}"
        fi
        if [ -n "${TUIC_URI:-}" ]; then
            echo -e "  - ${BOLD}TUIC v5 (QUIC+BBR):${NC}  ${CYAN}${TUIC_URI}${NC}"
        fi
        if [ -n "${MTPROTO_TG_URI:-}" ]; then
            echo -e "  - ${BOLD}Telegram MTProxy:${NC}     ${CYAN}${MTPROTO_TG_URI}${NC}"
            echo -e "  - ${BOLD}MTProxy Web Link:${NC}     ${CYAN}${MTPROTO_HTTPS_URI}${NC}"
            if [ -n "${MTPROTO_BOT_SECRET:-}" ]; then
                echo -e "  - ${BOLD}Ключ для @MTProxybot:${NC} ${YELLOW}${MTPROTO_BOT_SECRET}${NC} (боту передавать строго эти 32 символа!)"
            fi
        fi
        if [ -n "${MASQUE_URI:-}" ]; then
            echo -e "  - ${BOLD}MASQUE (RFC 9484):${NC}    ${CYAN}${MASQUE_URI}${NC}"
        fi
        if [ -n "${SHADOWTLS_URI:-}" ]; then
            echo -e "  - ${BOLD}ShadowTLS v4:${NC}         ${CYAN}${SHADOWTLS_URI}${NC}"
            echo -e "  - ${BOLD}ShadowTLS + SS-2022:${NC}  ${CYAN}${SS_SHADOWTLS_URI}${NC}"
        fi
        if [ -n "${WSTUNNEL_CLI:-}" ]; then
            echo -e "  - ${BOLD}Wstunnel CLI:${NC}         ${CYAN}${WSTUNNEL_CLI}${NC}"
        fi
        if [ -n "${ZAPRET_INFO:-}" ]; then
            echo -e "  - ${BOLD}Server-Side Zapret:${NC}   ${GREEN}${ZAPRET_INFO}${NC}"
        fi
        if [ -n "${NAIVE_URI:-}" ]; then
            echo -e "  - ${BOLD}NaïveProxy:${NC}          ${CYAN}${NAIVE_URI}${NC}"
        fi
        if [ -n "${DNSTT_CLI:-}" ]; then
            echo -e "  - ${BOLD}DNSTT DoH Tunnel:${NC}    ${CYAN}${DNSTT_CLI}${NC}"
        fi
        local _node_tok_en="${ENABLE_NODE_TOKEN:-n}"
        if [[ "${_node_tok_en,,}" == "y" || "${_node_tok_en}" == "1" ]] && [ -n "${NODE_TOKEN:-}" ]; then
            echo -e "  - ${BOLD}3X-UI Node API:${NC}         ${GREEN}${NODE_TOKEN_NAME:-Node}${NC} (Host: ${CYAN}${PRIMARY_DOMAIN}:443${NC}, Path: ${CYAN}/${PANEL_PATH#/}/${NC})"
            echo -e "  - ${BOLD}API Bearer Token:${NC}       ${YELLOW}${NODE_TOKEN}${NC}"
        fi
        if [ "${HAS_SELF_SIGNED_CERTS:-0}" -eq 1 ] || [ -f /etc/nginx/.self_signed_warning ]; then
            echo -e "  - ${BOLD}Статус SSL:${NC}             ${YELLOW}${BOLD}⚠️  ВРЕМЕННЫЙ САМОПОДПИСАННЫЙ (ТРЕБУЕТСЯ ЗАМЕНА!)${NC}"
        fi
    fi

    # Сохранение учетных данных в защищенный файл
    if [ "$DRY_RUN" -eq 0 ]; then
        CRED_FILE="/root/vpn_credentials.txt"
        if [ -n "${ADMIN_PASSWORD:-}" ]; then
            cat << EOF_CRED > "$CRED_FILE"
=====================================================================
УЧЕТНЫЕ ДАННЫЕ ПАНЕЛИ И СЕРВИСОВ 3X-UI
Файл обновлен: $(date '+%Y-%m-%d %H:%M:%S')
=====================================================================
Панель управления:     https://${PRIMARY_DOMAIN}${PANEL_PATH}
$([ -n "${DIAG_TOKEN:-}" ] && echo "Веб-диагностика (SSO): https://${PRIMARY_DOMAIN}${PANEL_PATH}diag")
$([ -n "${DIAG_TOKEN:-}" ] && echo "Токен диагностики:     ${DIAG_TOKEN}")
Логин администратора:   ${ADMIN_USERNAME:-admin}
Пароль администратора:  ${ADMIN_PASSWORD}
$([ -n "$INSTALLED_XRAY_VER" ] && echo "Ядро Xray-core:        ${INSTALLED_XRAY_VER}")
$([ "${HAS_SELF_SIGNED_CERTS:-0}" -eq 1 ] || [ -f /etc/nginx/.self_signed_warning ] && echo "Статус SSL:            ⚠️ ВРЕМЕННЫЙ САМОПОДПИСАННЫЙ (ТРЕБУЕТСЯ ЗАМЕНА!)")

Единый клиент:          ${UNIFIED_CLIENT_TAG:-Client}
Канал подписок:        https://${PRIMARY_DOMAIN}/${SUB_PATH#/}/
Канал подписок (Clash): https://${PRIMARY_DOMAIN}/${SUB_CLASH_PATH#/}/
Прямая ссылка подписки: https://${PRIMARY_DOMAIN}/${SUB_PATH#/}/${UNIFIED_SUB_ID}
Прямая ссылка (Clash):  https://${PRIMARY_DOMAIN}/${SUB_CLASH_PATH#/}/${UNIFIED_SUB_ID}
$([ -n "${UNIFIED_VLESS_ENKEY:-}" ] && echo "VLESS xHTTP EnKey:     ${UNIFIED_VLESS_ENKEY} (ML-KEM-768)")
$([ -n "${UNIFIED_AWG_HPK:-}" ] && echo "AmneziaWG v3.1 HPK:    ${UNIFIED_AWG_HPK} (UDP :${UNIFIED_AWG_PORT:-8443})")
$([ -n "${SS2022_URI:-}" ] && printf "Shadowsocks 2022:       %s\n" "${SS2022_URI}")
$([ -n "${TUIC_URI:-}" ] && printf "TUIC v5 (QUIC+BBR):     %s\n" "${TUIC_URI}")
$([ -n "${MTPROTO_TG_URI:-}" ] && printf "Telegram MTProxy (Клиент): %s\nMTProxy Web Link:          %s\nMTProxy FakeTLS Secret:    %s\n$([ -n "${MTPROTO_BOT_SECRET:-}" ] && printf "MTProxy Key для @MTProxybot: %s (ВНИМАНИЕ: боту передавать строго эти 32 символа! Ссылку от бота клиентам не давать)\n" "${MTPROTO_BOT_SECRET}")" "${MTPROTO_TG_URI}" "${MTPROTO_HTTPS_URI}" "${MTPROTO_SECRET:-}")
$([ -n "${MASQUE_URI:-}" ] && printf "MASQUE (RFC 9484):       %s\n" "${MASQUE_URI}")
$([ -n "${SHADOWTLS_URI:-}" ] && printf "ShadowTLS v4:            %s\nShadowTLS + SS-2022:     %s\n" "${SHADOWTLS_URI}" "${SS_SHADOWTLS_URI}")
$([ -n "${WSTUNNEL_CLI:-}" ] && printf "Wstunnel Client CLI:     %s\n" "${WSTUNNEL_CLI}")
$([ -n "${ZAPRET_INFO:-}" ] && printf "Server-Side Zapret:      %s\n" "${ZAPRET_INFO}")
$([ -n "${NAIVE_URI:-}" ] && printf "NaïveProxy (Chrome HTTPS): %s\n" "${NAIVE_URI}")
$([ -n "${DNSTT_CLI:-}" ] && printf "DNSTT DoH Tunnel:        %s\nDNSTT Public Key:        %s\n" "${DNSTT_CLI}" "${DNSTT_PUBKEY}")
$([ -n "${MIERU_PORT:-}" ] && [ -n "${MIERU_USER:-}" ] && printf "Mieru Proxy (XChaCha20, :%s): user: %s, pass: %s (Клиентский конфиг: /root/mieru-client.json, управление: mieru-mgr)\n" "${MIERU_PORT}" "${MIERU_USER}" "${MIERU_PASS}")
$([ -n "${NODE_TOKEN:-}" ] && printf "3X-UI Node Token:      %s\nИмя ноды (Node Name):  %s (Host: %s:443, Path: /%s/)\n" "${NODE_TOKEN}" "${NODE_TOKEN_NAME}" "${PRIMARY_DOMAIN}" "${PANEL_PATH#/}")
(Объединяет все конфигурации: Steal REALITY, Classic REALITY, xHTTP, Hysteria 2, AWG v3, AWG v2, SS-2022, TUIC v5, MTProxy, MASQUE, ShadowTLS, Wstunnel, Zapret, NaïveProxy, DNSTT, Mieru)
Команда для удаления:  vpn-uninstall (или curl -sSL "https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/uninstall.sh" | sudo bash)
=====================================================================
EOF_CRED
            if [ "${HAS_SELF_SIGNED_CERTS:-0}" -eq 1 ] || [ -f /etc/nginx/.self_signed_warning ]; then
                cat << 'EOF_SSL_WARN_CRED' >> "$CRED_FILE"
=====================================================================
⚠️  ВНИМАНИЕ: ИСПОЛЬЗУЕТСЯ ВРЕМЕННЫЙ САМОПОДПИСАННЫЙ SSL-СЕРТИФИКАТ
Для одного или нескольких доменов не удалось выпустить Let's Encrypt SSL.
• Браузер при входе в панель 3X-UI будет выдавать предупреждение безопасности.
• Клиентские подписки, VLESS xHTTP и Hysteria 2 не будут подключаться,
  пока не будет получен доверенный публичный сертификат.
• Инбаунды REALITY, AmneziaWG и Shadowsocks-2022 работают штатно.

КОМАНДА ДЛЯ ПЕРЕВЫПУСКА СЕРТИФИКАТА (после настройки DNS A-записей):
• Рекомендуемый быстрый способ (только SSL, без простоя VPN):
  bash maintain.sh -ssl
• Полный перезапуск мастера установки (если установка прерывалась):
  bash setup.sh -r
EOF_SSL_WARN_CRED
            fi
            echo -e "  - ${BOLD}Файл с паролями:${NC}        ${CYAN}$CRED_FILE${NC} (chmod 600)"
        elif [ -f "$CRED_FILE" ]; then
            if [ "${HAS_SELF_SIGNED_CERTS:-0}" -eq 1 ] || [ -f /etc/nginx/.self_signed_warning ]; then
                if ! grep -q "САМОПОДПИСАННЫЙ SSL-СЕРТИФИКАТ" "$CRED_FILE" 2>/dev/null; then
                    cat << 'EOF_SSL_WARN_CRED' >> "$CRED_FILE"
=====================================================================
⚠️  ВНИМАНИЕ: ИСПОЛЬЗУЕТСЯ ВРЕМЕННЫЙ САМОПОДПИСАННЫЙ SSL-СЕРТИФИКАТ
Для одного или нескольких доменов не удалось выпустить Let's Encrypt SSL.
• Браузер при входе в панель 3X-UI будет выдавать предупреждение безопасности.
• Клиентские подписки, VLESS xHTTP и Hysteria 2 не будут подключаться,
  пока не будет получен доверенный публичный сертификат.
• Инбаунды REALITY, AmneziaWG и Shadowsocks-2022 работают штатно.

КОМАНДА ДЛЯ ПЕРЕВЫПУСКА СЕРТИФИКАТА (после настройки DNS A-записей):
• Рекомендуемый быстрый способ (только SSL, без простоя VPN):
  bash maintain.sh -ssl
• Полный перезапуск мастера установки (если установка прерывалась):
  bash setup.sh -r
EOF_SSL_WARN_CRED
                fi
            fi
            if [ -n "${MASQUE_URI:-}" ] && ! grep -q "MASQUE (RFC 9484):" "$CRED_FILE" 2>/dev/null; then
                echo "MASQUE (RFC 9484):       ${MASQUE_URI}" >> "$CRED_FILE"
            fi
            if [ -n "${SHADOWTLS_URI:-}" ] && ! grep -q "ShadowTLS v4:" "$CRED_FILE" 2>/dev/null; then
                echo "ShadowTLS v4:            ${SHADOWTLS_URI}" >> "$CRED_FILE"
                echo "ShadowTLS + SS-2022:     ${SS_SHADOWTLS_URI}" >> "$CRED_FILE"
            fi
            if [ -n "${WSTUNNEL_CLI:-}" ] && ! grep -q "Wstunnel Client CLI:" "$CRED_FILE" 2>/dev/null; then
                echo "Wstunnel Client CLI:     ${WSTUNNEL_CLI}" >> "$CRED_FILE"
            fi
            if [ -n "${ZAPRET_INFO:-}" ] && ! grep -q "Server-Side Zapret:" "$CRED_FILE" 2>/dev/null; then
                echo "Server-Side Zapret:      ${ZAPRET_INFO}" >> "$CRED_FILE"
            fi
            if [ -n "${NAIVE_URI:-}" ] && ! grep -q "NaïveProxy (Chrome HTTPS):" "$CRED_FILE" 2>/dev/null; then
                echo "NaïveProxy (Chrome HTTPS): ${NAIVE_URI}" >> "$CRED_FILE"
            fi
            if [ -n "${DNSTT_CLI:-}" ] && ! grep -q "DNSTT DoH Tunnel:" "$CRED_FILE" 2>/dev/null; then
                echo "DNSTT DoH Tunnel:        ${DNSTT_CLI}" >> "$CRED_FILE"
                echo "DNSTT Public Key:        ${DNSTT_PUBKEY}" >> "$CRED_FILE"
            fi
            if [ -n "${MIERU_PORT:-}" ] && [ -n "${MIERU_USER:-}" ] && ! grep -q "Mieru Proxy" "$CRED_FILE" 2>/dev/null; then
                echo "Mieru Proxy (XChaCha20, :${MIERU_PORT}): user: ${MIERU_USER}, pass: ${MIERU_PASS}" >> "$CRED_FILE"
                echo "  Клиентский конфиг: /root/mieru-client.json (Управление пользователями: mieru-mgr list|add|del)" >> "$CRED_FILE"
            fi
            echo -e "  - ${BOLD}Файл с паролями:${NC}        ${CYAN}$CRED_FILE${NC} (обновлен, chmod 600)"
        fi
        chmod 600 "$CRED_FILE" 2>/dev/null || true
    fi
    if [ "${HAS_SELF_SIGNED_CERTS:-0}" -eq 1 ] || [ -f /etc/nginx/.self_signed_warning ]; then
        echo -e "${YELLOW}┌────────────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}│  ⚠️  НАПОМИНАНИЕ: НЕОБХОДИМО ЗАМЕНИТЬ САМОПОДПИСАННЫЙ SSL-СЕРТИФИКАТ  │${NC}"
        echo -e "${YELLOW}├────────────────────────────────────────────────────────────────────────┤${NC}"
        echo -e "${YELLOW}│  Для работы подписок и VLESS xHTTP / Hysteria 2 на клиентах привяжите  │${NC}"
        echo -e "${YELLOW}│  домен и запустите перевыпуск:                                         │${NC}"
        echo -e "${YELLOW}│  • Быстро обновить SSL (без простоя VPN):  ${GREEN}bash maintain.sh -ssl${YELLOW}       │${NC}"
        echo -e "${YELLOW}│  • Перезапуск всей установки с чекпоинта:  ${GREEN}bash setup.sh -r${YELLOW}            │${NC}"
        echo -e "${YELLOW}└────────────────────────────────────────────────────────────────────────┘${NC}"
    fi
    echo -e "${GREEN}=====================================================================${NC}"
    echo
    return 0
}
