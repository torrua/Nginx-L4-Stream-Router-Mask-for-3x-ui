#!/usr/bin/env bash
# ==============================================================================
#  SMART UPDATE & REPAIR TOOL: NGINX L4 ROUTER + 3X-UI
# ==============================================================================
#  Безопасное обновление и самовосстановление без потери подключений пользователей:
#    1. Сохранение существующих клиентов (UUID, пароли Hy2, ключи AWG, трафик);
#    2. Сохранение действующих серверных ключей шифрования REALITY и AWG;
#    3. Ремонт скрытых багов (realitySettings.settings.publicKey, мертвый SNI swdist);
#    4. Проверка и исправление externalProxy: 443 для всех ссылок подписок;
#    5. Проверка криптографии Curve25519 в AmneziaWG (валидация K_pub = K_priv * G);
#    6. Создание отсутствующих инбаундов под ключ;
#    7. Бэкап /etc/nginx и /etc/x-ui/x-ui.db с мягким reload без разрыва сессий;
#    8. Режим предварительного аудита (--dry-run) без внесения изменений.
# ==============================================================================

set -euo pipefail

# @include "common/colors.sh"
# @include "common/logger.sh"
# @include "common/config.sh"
# @include "common/lock.sh"
# @include "common/download.sh"
# @include "common/backup.sh"
# @include "system/mieru-mgr.sh"
# @include "system/benchmark.sh"


show_help() {
    cat << 'EOF_HELP'
Использование: ./maintain.sh [КОМАНДА | ОПЦИИ]

Утилита безопасного обновления, резервного копирования и восстановления для Nginx L4 + 3X-UI.

Команды резервного копирования и восстановления:
  backup, -b, --backup          Создать полный транзакционный бэкап стека (WAL-safe + селективный SSL)
  restore, --restore <АРХИВ>    Безопасно восстановить конфигурацию с валидацией SSL и автооткатом
  extract, --extract <АРХ> <DIR> Аварийно распаковать архив без прав root (PEP 706 Path Traversal safe)
  bench, --bench, --yabs [FLG]  Запустить тестирование производительности сервера (YABS)

Опции обслуживания:
  -c, --config <FILE>     Путь к файлу конфигурации (.env) (по умолчанию: ./server-setup.env)
  --db <PATH>             Путь к базе данных 3X-UI (по умолчанию: /etc/x-ui/x-ui.db)
  --dry-run               Только аудит и проверка (без внесения изменений)
  --force-sub             Принудительно перезаписать кастомные параметры подписки из .env
  --rollback              Мгновенный откат базы данных и Nginx к последнему бэкапу
  -y, --yes               Выполнить исправления без интерактивного подтверждения
  --mieru-list-users      Список всех пользователей Mieru Proxy
  --mieru-add-user <NAME> [PASS] Добавить пользователя Mieru и создать клиентский .json
  --mieru-del-user <NAME> Удалить пользователя Mieru
  --mieru-mgr <CMD> ...   Прямой вызов диспетчера пользователей Mieru (list, add, del)
  -v, --version           Показать версию утилиты и выйти
  -h, --help              Показать эту справку и выйти

Примеры использования:
  # 1. Создать резервную копию всей системы:
  ./maintain.sh backup

  # 2. Восстановить конфигурацию из бэкапа:
  ./maintain.sh restore /var/backups/vpn-stack/vpn-backup-20261021_120000.tar.gz

  # 3. Аварийно извлечь файлы бэкапа без root на любой машине:
  ./maintain.sh extract /var/backups/vpn-stack/vpn-backup-20261021_120000.tar.gz ./backup_files

  # 4. Предварительный аудит настроек сервера (без записи):
  ./maintain.sh --dry-run

  # 5. Запуск аудита напрямую через curl в 1 команду:
  curl -sSL https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/maintain.sh | sudo bash -s -- --dry-run
EOF_HELP
}

CONFIG_FILE=""
DB_PATH="/etc/x-ui/x-ui.db"
DRY_RUN=0
FORCE_SUB=0
ROLLBACK=0
NON_INTERACTIVE=0
MIERU_ACTION=""
MIERU_TARGET_USER=""
MIERU_TARGET_PASS=""
MIERU_MGR_ARGS=()
COMMAND=""
COMMAND_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        backup|-b|--backup)
            COMMAND="backup"
            shift
            ;;
        restore|--restore)
            COMMAND="restore"
            shift
            if [[ $# -gt 0 && "${1:0:1}" != "-" ]]; then
                COMMAND_ARGS+=("$1")
                shift
            fi
            ;;
        extract|--extract)
            COMMAND="extract"
            shift
            while [[ $# -gt 0 && "${1:0:1}" != "-" ]]; do
                COMMAND_ARGS+=("$1")
                shift
            done
            ;;
        bench|--bench|--yabs)
            COMMAND="bench"
            shift
            COMMAND_ARGS=("$@")
            break
            ;;
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
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --force-sub)
            FORCE_SUB=1
            shift
            ;;
        --rollback)
            ROLLBACK=1
            shift
            ;;
        -y|--yes|--non-interactive)
            NON_INTERACTIVE=1
            shift
            ;;
        --mieru-list-users)
            MIERU_ACTION="list"
            shift
            ;;
        --mieru-add-user)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: имя пользователя."
            MIERU_ACTION="add"
            MIERU_TARGET_USER="$2"
            shift 2
            if [[ $# -gt 0 && "${1:0:1}" != "-" ]]; then
                MIERU_TARGET_PASS="$1"
                shift
            fi
            ;;
        --mieru-del-user)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: имя пользователя."
            MIERU_ACTION="del"
            MIERU_TARGET_USER="$2"
            shift 2
            ;;
        --mieru-mgr)
            MIERU_ACTION="mgr"
            shift
            MIERU_MGR_ARGS=("$@")
            break
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "maintain.sh (Nginx L4 Stream Router Mask for 3X-UI) __VERSION__"
            exit 0
            ;;
        *)
            echo "Ошибка: Неизвестный параметр: $1. Используйте --help для вывода доступных опций." >&2
            exit 2
            ;;
    esac
done

if [ -n "$COMMAND" ]; then
    case "$COMMAND" in
        backup)
            if [ "$DRY_RUN" -eq 1 ]; then
                log "[DRY-RUN] Аудит готовности к созданию бэкапа..."
                get_sqlite_backup_python >/dev/null || die "Python sqlite3 не найден"
                ok "[DRY-RUN] Окружение SQLite валидно для создания бэкапа"
                exit 0
            fi
            acquire_stack_lock "${VPN_STACK_LOCK_TIMEOUT:-10}" "maintain-backup" || exit $?
            do_backup "${COMMAND_ARGS[@]}"
            exit $?
            ;;
        restore)
            if [ "$DRY_RUN" -eq 1 ]; then
                log "[DRY-RUN] Режим предварительного аудита архива перед восстановлением..."
                [[ -n "${COMMAND_ARGS[0]:-}" ]] || die "Укажите путь к архиву: ./maintain.sh --dry-run restore <архив.tar.gz>"
                audit_restore_archive "${COMMAND_ARGS[0]}"
                exit 0
            fi
            acquire_stack_lock "${VPN_STACK_LOCK_TIMEOUT:-10}" "maintain-restore" || exit $?
            do_restore "${COMMAND_ARGS[@]}"
            exit $?
            ;;
        extract)
            do_extract "${COMMAND_ARGS[@]}"
            exit $?
            ;;
        bench)
            bench_flags="${COMMAND_ARGS[*]:-}"
            if [ -n "$bench_flags" ]; then
                run_yabs_benchmark "$bench_flags"
            else
                offer_yabs_benchmark
            fi
            exit $?
            ;;
    esac
fi

if [ -n "$MIERU_ACTION" ]; then
    case "$MIERU_ACTION" in
        list)
            mieru_list_users
            exit 0
            ;;
        add)
            mieru_add_user "$MIERU_TARGET_USER" "${MIERU_TARGET_PASS:-}"
            exit 0
            ;;
        del)
            mieru_del_user "$MIERU_TARGET_USER"
            exit 0
            ;;
        mgr)
            mieru_mgr_main "${MIERU_MGR_ARGS[@]}"
            exit 0
            ;;
    esac
fi

echo -e "${CYAN}=====================================================================${NC}"
echo -e "${GREEN}  Smart Update & Repair Tool: Nginx L4 + 3X-UI (Self-Healing Engine) ${NC}"
echo -e "${CYAN}=====================================================================${NC}"

# Проверка root
if [ "${EUID:-$(id -u)}" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    die "Для внесения изменений или отката требуются права суперпользователя (sudo)."
fi

# ОБРАБОТКА МГНОВЕННОГО ОТКАТА (--rollback)
if [ "$ROLLBACK" -eq 1 ]; then
    log "Запуск процедуры аварийного отката..."
    LATEST_DB_BAK=$(ls -t /etc/x-ui/x-ui.db.bak.* 2>/dev/null | head -n 1 || true)
    LATEST_NGINX_BAK=$(ls -td /etc/nginx.bak.* 2>/dev/null | head -n 1 || true)

    if [ -z "$LATEST_DB_BAK" ]; then
        die "Резервные копии базы данных /etc/x-ui/x-ui.db.bak.* не найдены."
    fi

    log "Восстановление базы данных 3X-UI из: $LATEST_DB_BAK"
    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl stop x-ui 2>/dev/null; then
            if systemctl is-active --quiet x-ui 2>/dev/null; then
                die "Критическая ошибка: невозможно остановить работающую службу x-ui перед откатом."
            fi
        fi
        if systemctl is-active --quiet x-ui 2>/dev/null; then
            die "Критическая ошибка: служба x-ui продолжает работать после команды остановки. Откат базы отменен."
        fi
    fi
    rm -f "$DB_PATH-wal" "$DB_PATH-shm" 2>/dev/null || true
    cp -a "$LATEST_DB_BAK" "$DB_PATH"
    chmod 600 "$DB_PATH"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl start x-ui 2>/dev/null || true
    fi
    ok "База данных 3X-UI успешно восстановлена!"

    if [ -n "$LATEST_NGINX_BAK" ] && [ -d "$LATEST_NGINX_BAK" ]; then
        log "Восстановление файлов Nginx из: $LATEST_NGINX_BAK"
        cp -a "$LATEST_NGINX_BAK"/* /etc/nginx/ 2>/dev/null || true
        if command -v nginx >/dev/null 2>&1; then
            nginx -t && systemctl reload nginx
        fi
        ok "Конфигурация Nginx успешно восстановлена!"
    fi

    echo -e "${GREEN}=====================================================================${NC}"
    echo -e "${GREEN}              ОТКАТ СИСТЕМЫ УСПЕШНО ЗАВЕРШЕН!                        ${NC}"
    echo -e "${GREEN}=====================================================================${NC}"
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${YELLOW}>>> РЕЖИМ ПРЕДВАРИТЕЛЬНОГО АУДИТА (--dry-run). ИЗМЕНЕНИЯ НЕ ЗАПИСЫВАЮТСЯ <<<${NC}\n"
fi

# Поиск файла конфигурации .env
if [ -z "$CONFIG_FILE" ]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /root)"
    CONFIG_FILE=$(find_config_file "$script_dir" || true)
fi

# Загрузка параметров
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    log "Загрузка конфигурации из: $CONFIG_FILE"
    load_config_data_safe "$CONFIG_FILE" || die "Ошибка загрузки параметров из $CONFIG_FILE"
else
    warn "Конфигурационный файл .env не найден. Параметры будут считаны из базы данных 3X-UI."
fi

# Захват блокировки для изменяющих операций обслуживания (T07)
if [ "$DRY_RUN" -eq 0 ]; then
    acquire_stack_lock "${VPN_STACK_LOCK_TIMEOUT:-10}" "maintain-repair" || exit $?
fi

# Поиск базы данных 3X-UI
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
    if [ "$found" -eq 0 ]; then
        die "База данных 3X-UI не найдена ($DB_PATH). Убедитесь, что панель установлена."
    fi
fi

log "Целевая база данных: $DB_PATH"

# Определение python команды с проверкой реальной работоспособности
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
        apt-get update -q && apt-get install -y python3 -q || die "Не удалось установить python3."
        PYTHON_CMD="python3"
    else
        die "Работоспособный Python 3 не найден в системе. Необходим для анализа базы SQLite."
    fi
fi

# --- ЭТАП 1: РЕЗЕРВНОЕ КОПИРОВАНИЕ ---
if [ "$DRY_RUN" -eq 0 ]; then
    BACKUP_TS="$(date +%Y%m%d_%H%M%S)"
    DB_BACKUP="${DB_PATH}.bak.${BACKUP_TS}"
    if ! backup_sqlite_db "$DB_PATH" "$DB_BACKUP"; then
        die "Критическая ошибка: невозможно создать проверенную резервную копию базы данных $DB_PATH. Модификация отменена во избежание повреждения данных."
    fi
    chmod 600 "$DB_BACKUP" 2>/dev/null || true
    ok "Создана проверенная резервная копия базы данных: $DB_BACKUP"

    if [ -d /etc/nginx ]; then
        NGINX_BACKUP="/etc/nginx.bak.${BACKUP_TS}"
        log "Создание резервной копии каталога Nginx..."
        cp -a /etc/nginx "$NGINX_BACKUP" 2>/dev/null || true
        ok "Бэкап Nginx создан: $NGINX_BACKUP"
    fi
fi

# Экспорт системных переменных для Python
export DB_PATH
export DRY_RUN
export FORCE_SUB
export PRIMARY_DOMAIN="${PRIMARY_DOMAIN:-}"
export PANEL_PORT="${PANEL_PORT:-10443}"
export PANEL_PATH="${PANEL_PATH:-}"
export SUB_PORT="${SUB_PORT:-55443}"
export SUB_PATH="${SUB_PATH:-}"
export SUB_CLASH_PATH="${SUB_CLASH_PATH:-}"
export SUB_TITLE="${SUB_TITLE:-${SERVER_PREFIX:-Server}}"
export SERVER_PREFIX="${SERVER_PREFIX:-}"
export XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-50443}"
export XHTTP_STREAM_PATH="${XHTTP_STREAM_PATH:-}"
export ENABLE_STEAL="${ENABLE_STEAL:-y}"
export STEAL_PORT="${STEAL_PORT:-45443}"
export STEAL_DOMAINS="${STEAL_DOMAINS:-}"
export ENABLE_STEAL_COMPAT="${ENABLE_STEAL_COMPAT:-n}"
export STEAL_COMPAT_PORT="${STEAL_COMPAT_PORT:-47443}"
export STEAL_COMPAT_DOMAIN="${STEAL_COMPAT_DOMAIN:-static.${PRIMARY_DOMAIN:-}}"
export ENABLE_CLASSIC="${ENABLE_CLASSIC:-y}"
export CLASSIC_PORT="${CLASSIC_PORT:-46443}"
export CLASSIC_SNI="${CLASSIC_SNI:-dl.google.com}"
export REALITY_FINGERPRINT="${REALITY_FINGERPRINT:-${FINGERPRINT:-firefox}}"
export ENABLE_HY2="${ENABLE_HY2:-y}"
export HY2_PORT="${HY2_PORT:-443}"
export ENABLE_AWG_V3="${ENABLE_AWG_V3:-y}"
export AWG_V3_PORT="${AWG_V3_PORT:-8443}"
export AWG_HEADER_PROTECTION_KEY="${AWG_HEADER_PROTECTION_KEY:-}"
export AWG_RANDOM_TRAILERS="${AWG_RANDOM_TRAILERS:-false}"
export ENABLE_AWG_V2="${ENABLE_AWG_V2:-n}"
export AWG_V2_PORT="${AWG_V2_PORT:-8444}"
export AWG_PRIMARY_DNS="${AWG_PRIMARY_DNS:-9.9.9.9}"
export AWG_SECONDARY_DNS="${AWG_SECONDARY_DNS:-76.76.2.0}"
export ENABLE_SS2022="${ENABLE_SS2022:-n}"
export SS2022_PORT="${SS2022_PORT:-8388}"
export ENABLE_SHADOWTLS="${ENABLE_SHADOWTLS:-n}"
export SHADOWTLS_PORT="${SHADOWTLS_PORT:-8543}"
export ENABLE_NAIVE="${ENABLE_NAIVE:-n}"
export NAIVE_PORT="${NAIVE_PORT:-8446}"
export NAIVE_DOMAIN="${NAIVE_DOMAIN:-}"
export NAIVE_USER="${NAIVE_USER:-user}"
export NAIVE_PASS="${NAIVE_PASS:-}"
export ENABLE_DNSTT="${ENABLE_DNSTT:-n}"
export DNSTT_PORT="${DNSTT_PORT:-53053}"
export DNSTT_DOMAIN="${DNSTT_DOMAIN:-}"
export DNSTT_PUBKEY="${DNSTT_PUBKEY:-}"
export ENABLE_TUIC="${ENABLE_TUIC:-n}"
export TUIC_PORT="${TUIC_PORT:-8448}"
export ENABLE_MTPROTO="${ENABLE_MTPROTO:-n}"
export MTPROTO_PORT="${MTPROTO_PORT:-8444}"
export MTPROTO_FAKETLS_DOMAIN="${MTPROTO_FAKETLS_DOMAIN:-gateway.icloud.com}"
export MTPROTO_ADTAG="${MTPROTO_ADTAG:-}"
export SSL_ENGINE_CHOICE="${SSL_ENGINE_CHOICE:-1}"

# Определение системного часового пояса
SYSTEM_TZ=""
if [ -f /etc/timezone ]; then
    SYSTEM_TZ="$(cat /etc/timezone 2>/dev/null | tr -d '[:space:]')"
elif command -v timedatectl >/dev/null 2>&1; then
    SYSTEM_TZ="$(timedatectl show --property=Timezone --value 2>/dev/null | tr -d '[:space:]')"
fi
if [ -z "$SYSTEM_TZ" ] && [ -L /etc/localtime ]; then
    SYSTEM_TZ="$(readlink /etc/localtime 2>/dev/null | sed -E 's/.*zoneinfo\///')"
fi
export TIME_LOCATION="${TIME_LOCATION:-${SYSTEM_TZ:-Europe/Moscow}}"
export SUB_UPDATES="${SUB_UPDATES:-1}"
export SUB_ENCRYPT="${SUB_ENCRYPT:-true}"
export BLOCK_SMTP="${BLOCK_SMTP:-y}"
export ENABLE_WSTUNNEL="${ENABLE_WSTUNNEL:-n}"
export WSTUNNEL_PREFIX="${WSTUNNEL_PREFIX:-}"
export WSTUNNEL_PORT="${WSTUNNEL_PORT:-8080}"
export BLOCK_LAN="${BLOCK_LAN:-y}"

HAS_NGINX=0
if command -v nginx >/dev/null 2>&1 && { systemctl is-active --quiet nginx 2>/dev/null || [ -d /etc/nginx/stream.d ]; }; then
    HAS_NGINX=1
fi
export WEB_LISTEN="${WEB_LISTEN:-$([ "$HAS_NGINX" -eq 1 ] && echo "127.0.0.1" || echo "")}"
export SUB_LISTEN="${SUB_LISTEN:-$([ "$HAS_NGINX" -eq 1 ] && echo "127.0.0.1" || echo "")}"

# Аварийная защита: гарантированный запуск x-ui при неожиданном падении скрипта
cleanup_xui() {
    local exit_code=$?
    if [ "${WAS_ACTIVE:-0}" -eq 1 ]; then
        if command -v systemctl >/dev/null 2>&1; then
            if ! systemctl is-active --quiet x-ui 2>/dev/null; then
                warn "Аварийное восстановление: перезапуск службы x-ui после сбоя скрипта..."
                systemctl start x-ui 2>/dev/null || true
            fi
        fi
    fi
    command -v release_stack_lock >/dev/null 2>&1 && release_stack_lock
    exit "$exit_code"
}
trap cleanup_xui EXIT INT TERM

# Остановка x-ui при реальном обновлении базы данных
WAS_ACTIVE=0
if [ "$DRY_RUN" -eq 0 ]; then
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet x-ui 2>/dev/null; then
        log "Временная приостановка службы 3X-UI на время обновления SQLite..."
        systemctl stop x-ui
        WAS_ACTIVE=1
    fi
fi

# --- ЭТАП 2: ВЫПОЛНЕНИЕ SMART RECONCILE ЧЕРЕЗ PYTHON ---
log "Запуск интеллектуального аудита и исправления инбаундов..."

"$PYTHON_CMD" - << 'EOF_PYTHON_RECONCILE'
# @include "panel/reconcile.py"
EOF_PYTHON_RECONCILE

# --- ЭТАП 3: ПРОВЕРКА И ПЕРЕЗАПУСК СЛУЖБ (Hardened: chmod 600 для защиты от локальной утечки) ---
if [ "$DRY_RUN" -eq 0 ]; then
    chmod 600 "$DB_PATH" 2>/dev/null || true
    
    # Запуск x-ui
    if [ "${WAS_ACTIVE:-0}" -eq 1 ] || (command -v systemctl >/dev/null 2>&1 && systemctl is-enabled --quiet x-ui 2>/dev/null); then
        log "Перезапуск службы 3X-UI..."
        systemctl restart x-ui && { ok "Служба 3X-UI успешно перезапущена."; WAS_ACTIVE=0; } || warn "Сбой перезапуска 3X-UI."
    fi

    # Проверка синтаксиса и мягкий reload Nginx
    if command -v nginx >/dev/null 2>&1; then
        log "Аудит файлов конфигурации Nginx..."
        if [ -d /etc/nginx ] && grep -rq "swdist\.microsoft\.com" /etc/nginx/ 2>/dev/null; then
            find /etc/nginx/ -type f -name "*.conf" -exec sed -i 's/swdist\.microsoft\.com/gateway\.icloud\.com/g' {} + 2>/dev/null || true
            ok "Nginx: Устаревший SNI swdist.microsoft.com заменен на gateway.icloud.com."
        fi

        log "Проверка конфигурации Nginx (nginx -t)..."
        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx && ok "Nginx успешно применил обновленную конфигурацию (Zero Downtime reload)."
        else
            warn "Внимание: nginx -t обнаружил предупреждения синтаксиса. Перезагрузка Nginx отложена."
        fi
    fi
else
    # Проверка в режиме DRY-RUN
    if [ -d /etc/nginx ] && grep -rq "swdist\.microsoft\.com" /etc/nginx/ 2>/dev/null; then
        warn "Nginx: В файлах /etc/nginx/ обнаружен устаревший SNI swdist.microsoft.com (будет заменен)."
    fi
fi

echo
echo -e "${GREEN}=====================================================================${NC}"
if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${YELLOW}               АУДИТ УСПЕШНО ЗАВЕРШЕН (DRY-RUN)                      ${NC}"
    echo -e "${CYAN}  Все найденные замечания выше будут исправлены при обычном запуске: ${NC}"
    echo -e "  ${BOLD}sudo ./maintain.sh -y${NC}"
else
    echo -e "${GREEN}      ОБНОВЛЕНИЕ И ВОССТАНОВЛЕНИЕ СИСТЕМЫ УСПЕШНО ЗАВЕРШЕНО!         ${NC}"
    for c_env in "/run/3xui_unified_client.env" "/tmp/3xui_unified_client.env"; do
        if [ -f "$c_env" ]; then
            source "$c_env" 2>/dev/null || true
            break
        fi
    done
    echo -e "  - ${BOLD}Подключения клиентов:${NC}   ${GREEN}Сохранены без разрыва и сброса ключей${NC}"
    echo -e "  - ${BOLD}Вход в панель 3X-UI:${NC}    ${CYAN}https://${PRIMARY_DOMAIN:-домен}/${PANEL_PATH:-}/${NC}"
    echo -e "  - ${BOLD}Ссылка на подписку:${NC}     ${CYAN}https://${PRIMARY_DOMAIN:-домен}/${SUB_PATH:-my-post-key}/${NC}"
    echo -e "  - ${BOLD}Ссылка (Clash):${NC}         ${CYAN}https://${PRIMARY_DOMAIN:-домен}/${SUB_CLASH_PATH:-${SUB_PATH:-my-post-key}/clash}/${NC}"


    if [ -z "${DNSTT_PUBKEY:-}" ] && [ -f "/etc/dnstt/server.pub" ]; then
        DNSTT_PUBKEY="$(cat /etc/dnstt/server.pub 2>/dev/null | tr -d '[:space:]')"
    fi
    if [ -n "${DNSTT_PUBKEY:-}" ]; then
        if [ -n "${DNSTT_CLI:-}" ] && [[ "$DNSTT_CLI" == *"-pubkey  "* ]]; then
            DNSTT_CLI="${DNSTT_CLI/-pubkey  /-pubkey ${DNSTT_PUBKEY} }"
        fi
    fi
    [ -n "${UNIFIED_VLESS_ENKEY:-}" ] && echo -e "  - ${BOLD}VLESS xHTTP EnKey:${NC}     ${YELLOW}${UNIFIED_VLESS_ENKEY}${NC} (ML-KEM-768)"
    [ -n "${SS2022_URI:-}" ] && echo -e "  - ${BOLD}Shadowsocks 2022:${NC}    ${CYAN}${SS2022_URI}${NC}"
    [ -n "${TUIC_URI:-}" ] && echo -e "  - ${BOLD}TUIC v5 (QUIC+BBR):${NC}  ${CYAN}${TUIC_URI}${NC}"
    [ -n "${MTPROTO_TG_URI:-}" ] && echo -e "  - ${BOLD}Telegram MTProxy:${NC}    ${CYAN}${MTPROTO_TG_URI}${NC}"
    [ -n "${MASQUE_URI:-}" ] && echo -e "  - ${BOLD}MASQUE (RFC 9484):${NC}    ${CYAN}${MASQUE_URI}${NC}"
    [ -n "${SHADOWTLS_URI:-}" ] && echo -e "  - ${BOLD}ShadowTLS v4:${NC}         ${CYAN}${SHADOWTLS_URI}${NC}"
    [ -n "${SS_SHADOWTLS_URI:-}" ] && echo -e "  - ${BOLD}ShadowTLS + SS-2022:${NC}  ${CYAN}${SS_SHADOWTLS_URI}${NC}"
    [ -n "${WSTUNNEL_CLI:-}" ] && echo -e "  - ${BOLD}Wstunnel CLI:${NC}         ${CYAN}${WSTUNNEL_CLI}${NC}"
    [ -n "${ZAPRET_INFO:-}" ] && echo -e "  - ${BOLD}Server-Side Zapret:${NC}   ${GREEN}${ZAPRET_INFO}${NC}"
    [ -n "${NAIVE_URI:-}" ] && echo -e "  - ${BOLD}NaïveProxy:${NC}          ${CYAN}${NAIVE_URI}${NC}"
    [ -n "${DNSTT_CLI:-}" ] && echo -e "  - ${BOLD}DNSTT DoH Tunnel:${NC}    ${CYAN}${DNSTT_CLI}${NC}"

    if [ -f "/root/vpn_credentials.txt" ]; then
        if [ -n "${UNIFIED_VLESS_ENKEY:-}" ]; then
            if grep -q "VLESS xHTTP EnKey:" /root/vpn_credentials.txt 2>/dev/null; then
                sed -i -E "s|^VLESS xHTTP EnKey:.*|VLESS xHTTP EnKey:     ${UNIFIED_VLESS_ENKEY} (ML-KEM-768)|" /root/vpn_credentials.txt 2>/dev/null || true
            else
                echo "VLESS xHTTP EnKey:     ${UNIFIED_VLESS_ENKEY} (ML-KEM-768)" >> /root/vpn_credentials.txt
            fi
        fi
        if [ -n "${SS2022_URI:-}" ] && ! grep -q "Shadowsocks 2022:" /root/vpn_credentials.txt 2>/dev/null; then
            echo "Shadowsocks 2022:       ${SS2022_URI}" >> /root/vpn_credentials.txt
        fi
        if [ -n "${TUIC_URI:-}" ] && ! grep -q "TUIC v5" /root/vpn_credentials.txt 2>/dev/null; then
            echo "TUIC v5 (QUIC+BBR):     ${TUIC_URI}" >> /root/vpn_credentials.txt
        fi
        if [ -n "${MTPROTO_TG_URI:-}" ] && ! grep -q "Telegram MTProxy" /root/vpn_credentials.txt 2>/dev/null; then
            echo "Telegram MTProxy (Клиент): ${MTPROTO_TG_URI}" >> /root/vpn_credentials.txt
            echo "MTProxy Web Link:          ${MTPROTO_HTTPS_URI:-}" >> /root/vpn_credentials.txt
            echo "MTProxy FakeTLS Secret:    ${MTPROTO_SECRET:-}" >> /root/vpn_credentials.txt
            [ -n "${MTPROTO_BOT_SECRET:-}" ] && echo "MTProxy Key для @MTProxybot: ${MTPROTO_BOT_SECRET}" >> /root/vpn_credentials.txt
        fi
        if [ -n "${MASQUE_URI:-}" ] && ! grep -q "MASQUE (RFC 9484):" /root/vpn_credentials.txt 2>/dev/null; then
            echo "MASQUE (RFC 9484):       ${MASQUE_URI}" >> /root/vpn_credentials.txt
        fi
        if [ -n "${SHADOWTLS_URI:-}" ] && ! grep -q "ShadowTLS v4:" /root/vpn_credentials.txt 2>/dev/null; then
            echo "ShadowTLS v4:            ${SHADOWTLS_URI}" >> /root/vpn_credentials.txt
            echo "ShadowTLS + SS-2022:     ${SS_SHADOWTLS_URI}" >> /root/vpn_credentials.txt
        fi
        if [ -n "${WSTUNNEL_CLI:-}" ] && ! grep -q "Wstunnel Client CLI:" /root/vpn_credentials.txt 2>/dev/null; then
            echo "Wstunnel Client CLI:     ${WSTUNNEL_CLI}" >> /root/vpn_credentials.txt
        fi
        if [ -n "${ZAPRET_INFO:-}" ] && ! grep -q "Server-Side Zapret:" /root/vpn_credentials.txt 2>/dev/null; then
            echo "Server-Side Zapret:      ${ZAPRET_INFO}" >> /root/vpn_credentials.txt
        fi
        if [ -n "${NAIVE_URI:-}" ] && ! grep -q "NaïveProxy (Chrome HTTPS):" /root/vpn_credentials.txt 2>/dev/null; then
            echo "NaïveProxy (Chrome HTTPS): ${NAIVE_URI}" >> /root/vpn_credentials.txt
        fi
        if [ -n "${DNSTT_CLI:-}" ] && ! grep -q "DNSTT DoH Tunnel:" /root/vpn_credentials.txt 2>/dev/null; then
            echo "DNSTT DoH Tunnel:        ${DNSTT_CLI}" >> /root/vpn_credentials.txt
            [ -n "${DNSTT_PUBKEY:-}" ] && echo "DNSTT Public Key:        ${DNSTT_PUBKEY}" >> /root/vpn_credentials.txt
        fi
        if [ -n "${MIERU_PORT:-}" ] && [ -n "${MIERU_USER:-}" ] && ! grep -q "Mieru Proxy" /root/vpn_credentials.txt 2>/dev/null; then
            echo "Mieru Proxy (XChaCha20, :${MIERU_PORT}): user: ${MIERU_USER}, pass: ${MIERU_PASS}" >> /root/vpn_credentials.txt
            echo "  Клиентский конфиг: /root/mieru-client.json (Управление пользователями: mieru-mgr list|add|del)" >> /root/vpn_credentials.txt
        fi
    fi
fi
echo -e "${GREEN}=====================================================================${NC}"
echo
