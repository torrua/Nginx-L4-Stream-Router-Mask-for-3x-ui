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
# @include "common/backup.sh"
# @include "system/mieru-mgr.sh"


show_help() {
    cat << 'EOF_HELP'
Использование: ./maintain.sh [ОПЦИИ]

Утилита безопасного обновления и самовосстановления (Smart Reconcile) для Nginx L4 + 3X-UI.

Опции:
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
  -h, --help              Показать эту справку и выйти

Примеры использования:
  # 1. Предварительный безопасный аудит (посмотреть, что будет исправлено):
  ./maintain.sh --dry-run

  # 2. Выполнить обновление и исправление с авто-бэкапом:
  ./maintain.sh -y

  # 3. Мгновенный откат системы к состоянию до обновления:
  ./maintain.sh --rollback

  # 4. Управление пользователями Mieru:
  ./maintain.sh --mieru-list-users
  ./maintain.sh --mieru-add-user alice
  ./maintain.sh --mieru-del-user alice
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
        *)
            warn "Неизвестный параметр: $1"
            shift
            ;;
    esac
done

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
        systemctl stop x-ui 2>/dev/null || true
    fi
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
    re_dquote='^"(.*)"$'
    re_squote="^'(.*)'\$"
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            if [[ "$val" =~ $re_dquote ]] || [[ "$val" =~ $re_squote ]]; then
                val="${BASH_REMATCH[1]}"
            fi
            declare -g "$key=$val"
        fi
    done < "$CONFIG_FILE"
else
    warn "Конфигурационный файл .env не найден. Параметры будут считаны из базы данных 3X-UI."
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
export XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-50443}"
export XHTTP_STREAM_PATH="${XHTTP_STREAM_PATH:-}"
export ENABLE_STEAL="${ENABLE_STEAL:-y}"
export STEAL_PORT="${STEAL_PORT:-45443}"
export STEAL_DOMAINS="${STEAL_DOMAINS:-}"
export ENABLE_CLASSIC="${ENABLE_CLASSIC:-y}"
export CLASSIC_PORT="${CLASSIC_PORT:-46443}"
export CLASSIC_SNI="${CLASSIC_SNI:-avito.ru}"
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
import os
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

import sqlite3
import json
import uuid
import secrets
import base64

db_path = os.environ["DB_PATH"]
dry_run = os.environ.get("DRY_RUN", "0") == "1"

# Чтение и синхронизация параметров
conn = sqlite3.connect(db_path, timeout=30.0)
cur = conn.cursor()

# 1. Извлечение существующих параметров из таблицы settings
existing_settings = {}
try:
    cur.execute("SELECT key, value FROM settings")
    for k, v in cur.fetchall():
        existing_settings[k] = v
except Exception as e:
    print(f"[!] Ошибка чтения таблицы settings: {e}")

domain = os.environ.get("PRIMARY_DOMAIN") or existing_settings.get("subDomain") or "localhost"
panel_port = os.environ.get("PANEL_PORT") or existing_settings.get("webPort") or "10443"
# @include "xray/paths.py"

panel_path = resolve_panel_path(os.environ.get("PANEL_PATH"), existing_settings.get("webBasePath"))

sub_port = os.environ.get("SUB_PORT") or existing_settings.get("subPort") or "55443"
sub_path = os.environ.get("SUB_PATH") or existing_settings.get("subPath") or "my-post-key"
sub_path = sub_path.strip("/")
sub_clash_env = os.environ.get("SUB_CLASH_PATH", "").strip().strip("/")
if sub_clash_env:
    sub_clash_path = sub_clash_env
elif existing_settings.get("subClashPath") and existing_settings.get("subClashPath").strip("/") != f"{sub_path}clash":
    sub_clash_path = existing_settings.get("subClashPath").strip("/")
else:
    sub_clash_path = f"{sub_path}/clash"

xhttp_port = int(os.environ.get("XHTTP_STREAM_PORT") or "50443")
xhttp_raw_path = (os.environ.get("XHTTP_STREAM_PATH") or "").strip("/")
if not xhttp_raw_path or xhttp_raw_path == "Stream-One-Path" or xhttp_raw_path.startswith("vless-"):
    cur.execute("SELECT stream_settings FROM inbounds WHERE port = ?", (xhttp_port,))
    row_xh = cur.fetchone()
    found_p = None
    if row_xh and row_xh[0]:
        try:
            found_p = json.loads(row_xh[0]).get("xhttpSettings", {}).get("path", "").strip("/")
        except Exception:
            pass
    if found_p and found_p != "Stream-One-Path" and not found_p.startswith("vless-"):
        xhttp_raw_path = found_p
    else:
        import secrets
        xhttp_raw_path = secrets.token_hex(4)
xhttp_path = "/" + xhttp_raw_path.strip("/") + "/"

enable_steal = os.environ.get("ENABLE_STEAL", "y").lower() in ("1", "y", "true")
steal_port = int(os.environ.get("STEAL_PORT") or "45443")
steal_dom = os.environ.get("STEAL_DOMAINS") or f"cdn.{domain}"
steal_dom = steal_dom.split()[0] if steal_dom.strip() else f"cdn.{domain}"
reality_fallback_port = int(os.environ.get("REALITY_FALLBACK_PORT") or "9443")

enable_classic = os.environ.get("ENABLE_CLASSIC", "y").lower() in ("1", "y", "true")
classic_port = int(os.environ.get("CLASSIC_PORT") or "46443")
classic_sni = os.environ.get("CLASSIC_SNI") or "avito.ru"
classic_sni = classic_sni.split()[0] if classic_sni.strip() else "avito.ru"

enable_hy2 = os.environ.get("ENABLE_HY2", "y").lower() in ("1", "y", "true")
hy2_port = int(os.environ.get("HY2_PORT") or "443")

enable_awg_v3 = os.environ.get("ENABLE_AWG_V3", "y").lower() in ("1", "y", "true")
awg_v3_port = int(os.environ.get("AWG_V3_PORT") or "8443")
awg_hpk_env = os.environ.get("AWG_HEADER_PROTECTION_KEY", "").strip()
awg_random_trailers_env = os.environ.get("AWG_RANDOM_TRAILERS", "false").strip().lower() in ("1", "y", "true")
awg_primary_dns = os.environ.get("AWG_PRIMARY_DNS") or "9.9.9.9"
awg_secondary_dns = os.environ.get("AWG_SECONDARY_DNS") or "76.76.2.0"

enable_awg_v2 = os.environ.get("ENABLE_AWG_V2", "n").lower() in ("1", "y", "true")
awg_v2_port = int(os.environ.get("AWG_V2_PORT") or "8444")

enable_ss2022 = os.environ.get("ENABLE_SS2022", "n").lower() in ("1", "y", "true")
ss2022_port = int(os.environ.get("SS2022_PORT") or "8388")
enable_shadowtls = os.environ.get("ENABLE_SHADOWTLS", "n").lower() in ("1", "y", "true")
shadowtls_port = int(os.environ.get("SHADOWTLS_PORT") or "8543")

enable_tuic = os.environ.get("ENABLE_TUIC", "n").lower() in ("1", "y", "true")
tuic_port = int(os.environ.get("TUIC_PORT") or "8448")

enable_mtproto = os.environ.get("ENABLE_MTPROTO", "n").lower() in ("1", "y", "true")
mtproto_port = int(os.environ.get("MTPROTO_PORT") or "8444")
mtproto_faketls_domain = (os.environ.get("MTPROTO_FAKETLS_DOMAIN") or "gateway.icloud.com").strip()
mtproto_adtag = os.environ.get("MTPROTO_ADTAG", "").strip()

ssl_engine = os.environ.get("SSL_ENGINE_CHOICE", "1")
if ssl_engine == "1":
    ssl_cert = f"/etc/letsencrypt/live/{domain}/fullchain.pem"
    ssl_key = f"/etc/letsencrypt/live/{domain}/privkey.pem"
else:
    ssl_cert = f"/etc/ssl/acme/{domain}/fullchain.pem"
    ssl_key = f"/etc/ssl/acme/{domain}/privkey.pem"

# Определение ID администратора
cur.execute("SELECT id FROM users LIMIT 1")
user_row = cur.fetchone()
admin_id = user_row[0] if user_row else 1

# Curve25519 helper (RFC 7748) для валидации и починки ключей
P = 2**255 - 19
A24 = 121665

# Инспекция существующих таблиц и колонок для гарантированной синхронизации клиентов
cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
all_tables = set(r[0] for r in cur.fetchall())

def get_table_columns(tbl):
    if tbl not in all_tables:
        return set()
    cur.execute(f"PRAGMA table_info({tbl})")
    return set(r[1] for r in cur.fetchall())

client_traffics_cols = get_table_columns("client_traffics")
clients_cols = get_table_columns("clients")
client_inbounds_cols = get_table_columns("client_inbounds")

# @include "xray/clients.py"

# @include "xray/keys.py"

# --- 1. СИНХРОНИЗАЦИЯ НАСТРОЕК СИСТЕМЫ (SETTINGS) ---
print("\n[+] Проверка системных настроек панели и подписок...")

force_sub = os.environ.get("FORCE_SUB", "0") == "1"

# ЗАЩИТА 1: Детектирование и сохранение существующей кастомной подписки
old_sub_domain = existing_settings.get("subDomain", "").strip()
old_sub_uri = existing_settings.get("subURI", "").strip()
old_sub_path = existing_settings.get("subPath", "").strip()

is_custom_sub = bool(old_sub_uri and (old_sub_domain != domain or old_sub_path.strip("/") != sub_path))

if is_custom_sub and not force_sub:
    print(f"  [СОХРАНЕНО] Обнаружена существующая кастомная подписка: {old_sub_uri}")
    print(f"    -> subDomain: '{old_sub_domain}', subPath: '{old_sub_path}' сохранены без изменений.")
    target_sub_uri = old_sub_uri
    target_sub_domain = old_sub_domain
    target_sub_path = old_sub_path
    target_sub_json_path = existing_settings.get("subJsonPath") or f"/{sub_path.strip('/')}/json/"
    target_sub_json_uri = existing_settings.get("subJsonURI") or f"https://{domain}{target_sub_json_path}"
    target_sub_clash_path = existing_settings.get("subClashPath") or f"/{sub_clash_path.strip('/')}/"
    if target_sub_clash_path.strip("/") == f"{sub_path}clash":
        target_sub_clash_path = f"/{sub_clash_path.strip('/')}/"
    target_sub_clash_uri = existing_settings.get("subClashURI") or f"https://{domain}{target_sub_clash_path}"
    if target_sub_clash_uri.endswith(f"{sub_path}clash/"):
        target_sub_clash_uri = f"https://{domain}{target_sub_clash_path}"
else:
    target_sub_uri = f"https://{domain}/{sub_path}/"
    target_sub_domain = domain
    target_sub_path = f"/{sub_path}/"
    target_sub_json_path = f"/{sub_path.strip('/')}/json/"
    target_sub_json_uri = f"https://{domain}{target_sub_json_path}"
    target_sub_clash_path = f"/{sub_clash_path.strip('/')}/"
    target_sub_clash_uri = f"https://{domain}{target_sub_clash_path}"

time_location = os.environ.get("TIME_LOCATION", "Europe/Moscow").strip()
sub_updates = os.environ.get("SUB_UPDATES", "1").strip()
sub_encrypt = os.environ.get("SUB_ENCRYPT", "true").strip().lower()
block_smtp = os.environ.get("BLOCK_SMTP", "y").strip().lower() in ("1", "y", "true")
block_lan = os.environ.get("BLOCK_LAN", "y").strip().lower() in ("1", "y", "true")
web_listen = os.environ.get("WEB_LISTEN", "").strip()
sub_listen = os.environ.get("SUB_LISTEN", "").strip()
sub_title = os.environ.get("SUB_TITLE", "").strip()
if not sub_title:
    srv_prefix = os.environ.get("SERVER_PREFIX", "").strip()
    if srv_prefix and srv_prefix.lower() not in ("-", "none", "off", "no"):
        sub_title = srv_prefix
if not sub_title:
    sub_title = existing_settings.get("subTitle", "").strip()
if not sub_title and domain and domain not in ("localhost", "127.0.0.1", "0.0.0.0"):
    sub_title = domain

settings_updates = {
    "webPort": panel_port,
    "webBasePath": f"/{panel_path}/",
    "subEnable": "true",
    "subPort": sub_port,
    "subPath": target_sub_path,
    "subURI": target_sub_uri,
    "subJsonPath": target_sub_json_path,
    "subJsonURI": target_sub_json_uri,
    "subJsonEnable": "true",
    "subClashPath": target_sub_clash_path,
    "subClashURI": target_sub_clash_uri,
    "subClashEnable": "true",
    "subDomain": target_sub_domain,
    "subCertFile": "",
    "subKeyFile": "",
    "timeLocation": time_location,
    "subUpdates": sub_updates,
    "subEncrypt": sub_encrypt
}

if sub_title:
    settings_updates["subTitle"] = sub_title

if web_listen:
    settings_updates["webListen"] = web_listen
if sub_listen:
    settings_updates["subListen"] = sub_listen

for k, v in settings_updates.items():
    current_val = existing_settings.get(k)
    if current_val != v:
        if not dry_run:
            cur.execute("SELECT id FROM settings WHERE key = ?", (k,))
            if cur.fetchone():
                cur.execute("UPDATE settings SET value = ? WHERE key = ?", (str(v), k))
            else:
                cur.execute("INSERT INTO settings (key, value) VALUES (?, ?)", (k, str(v)))
        print(f"  [ИСПРАВЛЕНО] Настройка {k}: '{current_val}' -> '{v}'")
    else:
        print(f"  [В ПОРЯДКЕ] Настройка {k}: '{v}'")

# --- 1.1. АУДИТ И ТЮНИНГ ШАБЛОНА XRAY (XRAYTEMPLATECONFIG) ---
print("\n[+] Аудит шаблона конфигурации Xray (DNS, безопасность и защита от спама)...")
raw_tpl = existing_settings.get("xrayTemplateConfig")
tpl = None
if raw_tpl:
    try:
        tpl = json.loads(raw_tpl)
    except Exception:
        pass

if tpl and isinstance(tpl, dict):
    tpl_modified = False

    # 1. DNS: UseIPv4 стратегия для предотвращения задержек AAAA
    dns_cfg = tpl.get("dns", {})
    if not isinstance(dns_cfg, dict):
        dns_cfg = {}
    if dns_cfg.get("queryStrategy") != "UseIPv4":
        dns_cfg["queryStrategy"] = "UseIPv4"
        tpl["dns"] = dns_cfg
        tpl_modified = True
        print("  [ИСПРАВЛЕНО] DNS queryStrategy: установлен 'UseIPv4' (устранение микрозадержек).")
    else:
        print("  [В ПОРЯДКЕ] DNS queryStrategy: 'UseIPv4'.")

    # 2. Логирование (тихий безопасный режим)
    log_cfg = tpl.get("log", {})
    if not isinstance(log_cfg, dict):
        log_cfg = {}
    if log_cfg.get("loglevel") != "warning" and not log_cfg.get("loglevel"):
        log_cfg["loglevel"] = "warning"
        log_cfg["dnsLog"] = False
        tpl["log"] = log_cfg
        tpl_modified = True

    # 3. Гарантия blackhole outbound 'blocked'
    outbounds = tpl.get("outbounds", [])
    if isinstance(outbounds, list):
        if not any(isinstance(ob, dict) and ob.get("tag") == "blocked" for ob in outbounds):
            outbounds.append({"protocol": "blackhole", "settings": {}, "tag": "blocked"})
            tpl["outbounds"] = outbounds
            tpl_modified = True
            print("  [СОЗДАНО] Outbound 'blocked' (blackhole) добавлен в шаблон.")

    # 4. Роутинг: Блокировка SMTP (порт 25), SSRF-защита, разделение RU и YouTube -> Direct
    routing = tpl.get("routing", {})
    if isinstance(routing, dict):
        rules = routing.get("rules", [])
        if isinstance(rules, list):
            bad_geosites = {
                "geosite:ru", "geosite:yandex", "geosite:vk", "geosite:youtube",
                "geosite:openai", "geosite:google-gemini", "geosite:anthropic", "geosite:cloudflare"
            }
            # Очистка от отсутствующих geosite меток
            for r in rules:
                if isinstance(r, dict) and "domain" in r and isinstance(r["domain"], list):
                    clean_d = [d for d in r["domain"] if d not in bad_geosites]
                    if len(clean_d) != len(r["domain"]):
                        r["domain"] = clean_d
                        tpl_modified = True

            if block_smtp:
                has_smtp = any(isinstance(r, dict) and r.get("outboundTag") == "blocked" and "25" in str(r.get("port", "")).split(",") for r in rules)
                if not has_smtp:
                    rules.insert(0, {"type": "field", "port": "25", "outboundTag": "blocked"})
                    tpl_modified = True
                    print("  [СОЗДАНО] Блокировка SMTP: исходящий порт 25 заблокирован (защита от бана хостером).")
                else:
                    print("  [В ПОРЯДКЕ] Блокировка SMTP: порт 25 защищен.")

            if block_lan:
                lan_ips = ["geoip:private", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "fc00::/7", "fe80::/10"]
                has_lan = any(isinstance(r, dict) and r.get("outboundTag") == "blocked" and any(ip_e in str(r.get("ip", [])) for ip_e in ["geoip:private", "127.0.0.0/8", "10.0.0.0/8"]) for r in rules)
                if not has_lan:
                    rules.insert(0, {"type": "field", "ip": lan_ips, "outboundTag": "blocked"})
                    tpl_modified = True
                    print("  [СОЗДАНО] SSRF-защита: доступ к приватным IP хоста заблокирован.")
                else:
                    print("  [В ПОРЯДКЕ] SSRF-защита: локальные сети изолированы.")

            yt_domains = [
                "domain:youtube.com", "domain:googlevideo.com", "domain:ytimg.com",
                "domain:youtu.be", "domain:youtubei.googleapis.com", "domain:yt.be"
            ]
            ru_domains = [
                "domain:ru", "domain:su", "domain:рф", "domain:xn--p1ai",
                "domain:yandex.ru", "domain:yandex.net", "domain:ya.ru",
                "domain:vk.com", "domain:vk.ru", "domain:vkvideo.ru", "domain:gosuslugi.ru",
                "domain:sberbank.ru", "domain:tbank.ru", "domain:tinkoff.ru", "domain:dzen.ru",
                "domain:mail.ru", "domain:rutube.ru", "domain:ozon.ru", "domain:wildberries.ru", "domain:avito.ru"
            ]
            warp_domains = [
                "domain:openai.com", "domain:chatgpt.com", "domain:oaistatic.com",
                "domain:oaiusercontent.com", "domain:anthropic.com", "domain:claude.ai",
                "domain:gemini.google.com", "domain:aistudio.google.com", "domain:deepmind.google",
                "domain:makersuite.google.com", "domain:generativelanguage.googleapis.com",
                "domain:ai.google.dev", "domain:google.com", "domain:cloudflare.com", "domain:challenges.cloudflare.com"
            ]

            # Исключаем YouTube домены из WARP правил
            for r in rules:
                if isinstance(r, dict) and r.get("outboundTag") == "warp":
                    if "domain" in r and isinstance(r["domain"], list):
                        clean_warp_d = [d for d in r["domain"] if not any(y in str(d).lower() for y in ["youtube", "googlevideo", "ytimg", "youtu.be"])]
                        if len(clean_warp_d) != len(r["domain"]):
                            r["domain"] = clean_warp_d
                            tpl_modified = True

            yt_rule = None
            ru_domain_rule = None
            ru_ip_rule = None
            cleaned_existing_rules = []

            for r in rules:
                if not isinstance(r, dict):
                    continue
                tag = r.get("outboundTag")
                # Direct-правило для YouTube
                if tag == "direct" and any("youtube" in str(d).lower() or "googlevideo" in str(d).lower() for d in r.get("domain", [])):
                    cur_domains = set(r.get("domain", [])) - bad_geosites
                    cur_domains.update(yt_domains)
                    r["domain"] = list(cur_domains)
                    yt_rule = r
                    continue
                # Direct-правило для RU: разделяем domain и ip (устранение AND бага Xray) с сохранением пользовательских ограничений
                if tag == "direct" and ("geoip:ru" in r.get("ip", []) or any("domain:ru" in str(d).lower() for d in r.get("domain", []))):
                    cur_d = [d for d in r.get("domain", []) if d not in bad_geosites]
                    cur_ip = list(r.get("ip", []))
                    has_custom_constraints = bool(
                        r.get("user") or r.get("inboundTag") or r.get("network") or r.get("port") or r.get("protocol") or
                        any(ip != "geoip:ru" for ip in cur_ip)
                    )
                    if has_custom_constraints:
                        # Пользовательское правило с ограничениями или кастомными сетями:
                        # сохраняем все ограничения и исходные IP, аккуратно разделяя domain и ip
                        if cur_d and cur_ip:
                            r_d = dict(r)
                            r_d["domain"] = cur_d
                            r_d.pop("ip", None)
                            cleaned_existing_rules.append(r_d)

                            r_ip = dict(r)
                            r_ip["ip"] = cur_ip
                            r_ip.pop("domain", None)
                            cleaned_existing_rules.append(r_ip)
                        else:
                            cleaned_existing_rules.append(r)
                        tpl_modified = True
                        continue

                    # Системное общее правило RU без ограничений:
                    if cur_d:
                        cur_d_set = set(cur_d)
                        cur_d_set.update(ru_domains)
                        ru_domain_rule = {
                            "type": "field",
                            "outboundTag": "direct",
                            "domain": list(cur_d_set)
                        }
                    if cur_ip:
                        cur_ip_set = set(cur_ip)
                        cur_ip_set.add("geoip:ru")
                        ru_ip_rule = {
                            "type": "field",
                            "outboundTag": "direct",
                            "ip": list(cur_ip_set)
                        }
                    else:
                        ru_ip_rule = {
                            "type": "field",
                            "outboundTag": "direct",
                            "ip": ["geoip:ru"]
                        }
                    tpl_modified = True
                    continue
                cleaned_existing_rules.append(r)

            has_warp_outbound = any(isinstance(ob, dict) and ob.get("tag") == "warp" for ob in tpl.get("outbounds", []))

            new_rules = []
            for r in cleaned_existing_rules:
                if r.get("outboundTag") in ("api", "blocked"):
                    new_rules.append(r)

            if not yt_rule:
                yt_rule = {
                    "type": "field",
                    "outboundTag": "direct",
                    "domain": yt_domains
                }
                tpl_modified = True
                print("  [СОЗДАНО] Маршрут YouTube -> DIRECT (без задержек и буферизации).")
            new_rules.append(yt_rule)

            if not ru_domain_rule:
                ru_domain_rule = {
                    "type": "field",
                    "outboundTag": "direct",
                    "domain": ru_domains
                }
                tpl_modified = True
            new_rules.append(ru_domain_rule)

            if not ru_ip_rule:
                ru_ip_rule = {
                    "type": "field",
                    "outboundTag": "direct",
                    "ip": ["geoip:ru"]
                }
                tpl_modified = True
            new_rules.append(ru_ip_rule)

            if has_warp_outbound:
                warp_rule = None
                for r in cleaned_existing_rules:
                    if r.get("outboundTag") == "warp":
                        cur_d = set(r.get("domain", [])) - bad_geosites
                        cur_d.update(warp_domains)
                        cur_d = {d for d in cur_d if not any(y in str(d).lower() for y in ["youtube", "googlevideo", "ytimg", "youtu.be"])}
                        r["domain"] = list(cur_d)
                        warp_rule = r
                        break
                if not warp_rule:
                    warp_rule = {
                        "type": "field",
                        "outboundTag": "warp",
                        "domain": [d for d in warp_domains if not any(y in str(d).lower() for y in ["youtube", "googlevideo", "ytimg", "youtu.be"])]
                    }
                    tpl_modified = True
                    print("  [СОЗДАНО] Маршрут Google, Gemini, OpenAI, Claude -> WARP (обход капч и AI).")
                new_rules.append(warp_rule)

            for r in cleaned_existing_rules:
                if r not in new_rules and r.get("outboundTag") != "warp":
                    new_rules.append(r)

            final_rules = []
            for r in new_rules:
                if "domain" in r and isinstance(r["domain"], list):
                    r["domain"] = [d for d in r["domain"] if d not in bad_geosites]
                    if not r["domain"] and not r.get("ip") and not r.get("port"):
                        continue
                final_rules.append(r)

            routing["rules"] = final_rules
            tpl["routing"] = routing

    if tpl_modified and not dry_run:
        new_tpl_json = json.dumps(tpl, indent=2, ensure_ascii=False)
        cur.execute("UPDATE settings SET value = ? WHERE key = 'xrayTemplateConfig'", (new_tpl_json,))
        print("  [ИСПРАВЛЕНО] Конфигурация xrayTemplateConfig обновлена в базе данных.")

# --- 2. СМАРТ-СВЕРКА И РЕМОНТ ИНБАУНДОВ ---
print("\n[+] Аудит и согласование инбаундов (Inbounds Smart Reconcile)...")

# @include "xray/inbounds.py"

# --- Формирование эталонных конфигураций протоколов ---
def_uuid = str(uuid.uuid4())
def_reality_priv, def_reality_pub = generate_reality_keypair()
def_reality_sid = secrets.token_hex(8)
def_reality_sids = [def_reality_sid] + [secrets.token_hex(n) for n in (1, 2, 3, 6)]
def_hy2_pass = secrets.token_hex(12)
def_wg_s_priv, def_wg_s_pub = generate_wg_keypair()
def_wg_c_priv, def_wg_c_pub = generate_wg_keypair()
def_wg_hpk = awg_hpk_env or base64.b64encode(secrets.token_bytes(32)).decode()
def_ss_method = "2022-blake3-aes-256-gcm"
def_ss_server_pass = generate_ss2022_key(def_ss_method)
def_ss_client_pass = generate_ss2022_key(def_ss_method)
def_tuic_uuid, _ = generate_tuic_credentials()
def_tuic_pass = def_ss_client_pass
def_mtp_secret = generate_mtproto_secret(mtproto_faketls_domain)

cur.execute("SELECT port, protocol FROM inbounds")
existing_inbound_protos = {r[1] for r in cur.fetchall()}

# 1. VLESS REALITY (маскировка под свой сайт)
if enable_steal:
    s_set = {"clients": [{"id": def_uuid, "flow": "xtls-rprx-vision"}], "decryption": "none", "testseed": [900, 500, 900, 256]}
    s_str = {
        "network": "tcp",
        "tcpSettings": {"acceptProxyProtocol": True, "header": {"type": "none"}},
        "security": "reality",
        "realitySettings": {
            "show": False, "xver": 1, "dest": f"127.0.0.1:{reality_fallback_port}", "target": f"127.0.0.1:{reality_fallback_port}",
            "serverNames": [steal_dom], "privateKey": def_reality_priv, "minClientVer": "1.0.0",
            "shortIds": def_reality_sids,
            "settings": {"publicKey": def_reality_pub, "fingerprint": "firefox", "serverName": steal_dom, "spiderX": "/"}
        },
        "externalProxy": [{"dest": domain, "port": 443, "forceTls": "same", "sni": steal_dom, "fingerprint": "firefox", "remark": "VLESS_STEAL"}]
    }
    smart_reconcile_inbound(steal_port, "vless", "in-steal-reality", "VLESS_STEAL", s_set, s_str, listen="127.0.0.1")

# 2. VLESS REALITY (маскировка под внешние сервисы)
if enable_classic:
    c_set = {"clients": [{"id": def_uuid, "flow": "xtls-rprx-vision"}], "decryption": "none", "testseed": [900, 500, 900, 256]}
    c_str = {
        "network": "tcp",
        "tcpSettings": {"acceptProxyProtocol": True, "header": {"type": "none"}},
        "security": "reality",
        "realitySettings": {
            "show": False, "xver": 0, "dest": f"{classic_sni}:443", "target": f"{classic_sni}:443",
            "serverNames": [classic_sni], "privateKey": def_reality_priv, "minClientVer": "1.0.0",
            "shortIds": def_reality_sids,
            "settings": {"publicKey": def_reality_pub, "fingerprint": "firefox", "serverName": classic_sni, "spiderX": "/"}
        },
        "externalProxy": [{"dest": domain, "port": 443, "forceTls": "same", "sni": classic_sni, "fingerprint": "firefox", "remark": "VLESS_CLASSIC"}]
    }
    smart_reconcile_inbound(classic_port, "vless", "in-classic-reality", "VLESS_CLASSIC", c_set, c_str, listen="127.0.0.1")

# 3. VLESS xHTTP (Stream-One) - сохраняем или генерируем постквантовый ML-KEM-768
cur.execute("SELECT settings FROM inbounds WHERE port = ? OR tag = 'in-xhttp-stream'", (xhttp_port,))
row_xh = cur.fetchone()
prev_xh_dec = "none"
prev_xh_enc = None
if row_xh and row_xh[0]:
    try:
        prev_s = json.loads(row_xh[0])
        if prev_s.get("decryption") and prev_s["decryption"] != "none":
            prev_xh_dec = prev_s["decryption"]
            prev_xh_enc = prev_s.get("encryption")
            if not prev_xh_enc and prev_s.get("clients"):
                for _c in prev_s["clients"]:
                    if _c.get("encryption"):
                        prev_xh_enc = _c["encryption"]
                        break
    except Exception:
        pass

if prev_xh_dec != "none" and prev_xh_enc:
    c_xh = {"id": def_uuid, "flow": "", "encryption": prev_xh_enc}
    x_set = {"clients": [c_xh], "decryption": prev_xh_dec, "encryption": prev_xh_enc}
else:
    vless_dekey, vless_enkey = generate_vlessenc_keypair()
    if vless_dekey and vless_enkey:
        x_set = {"clients": [{"id": def_uuid, "flow": "", "encryption": vless_enkey}], "decryption": vless_dekey, "encryption": vless_enkey}
    else:
        x_set = {"clients": [{"id": def_uuid, "flow": ""}], "decryption": "none"}
x_str = {
    "network": "xhttp",
    "xhttpSettings": {
        "path": f"/{xhttp_path.strip('/')}/", "host": domain, "mode": "stream-one",
        "noSSEHeader": True,
        "xPaddingBytes": "100-500", "xPaddingObfsMode": False, "xPaddingKey": "",
        "xmux": {
            "maxConcurrency": "0",
            "maxConnections": "1-3",
            "cMaxReuseTimes": "300-600",
            "hKeepAlivePeriod": 600,
            "hMaxRequestTimes": "1000-2000",
            "hMaxReusableSecs": "1200-2400"
        }
    },
    "security": "none",
    "externalProxy": [{"dest": domain, "port": 443, "forceTls": "tls", "sni": domain, "fingerprint": "firefox", "alpn": "h2", "remark": "VLESS_XHTTP"}]
}
smart_reconcile_inbound(xhttp_port, "vless", "in-xhttp-stream", "VLESS_XHTTP", x_set, x_str, listen="127.0.0.1")

unified_vless_enkey = ""
cur.execute("SELECT settings FROM inbounds WHERE port = ? OR tag = 'in-xhttp-stream'", (xhttp_port,))
_row_xh = cur.fetchone()
if _row_xh and _row_xh[0]:
    try:
        _s_xh = json.loads(_row_xh[0])
        unified_vless_enkey = _s_xh.get("encryption", "") or ""
        if not unified_vless_enkey and _s_xh.get("clients"):
            for _c in _s_xh["clients"]:
                if _c.get("encryption"):
                    unified_vless_enkey = _c["encryption"]
                    break
    except Exception:
        pass
if not unified_vless_enkey:
    unified_vless_enkey = prev_xh_enc or (vless_enkey if 'vless_enkey' in locals() else "") or ""

# 4. Hysteria 2
if enable_hy2:
    h_set = {"clients": [{"id": def_hy2_pass}], "version": 2}
    h_str = {
        "network": "hysteria",
        "hysteriaSettings": {"version": 2, "udpIdleTimeout": 60, "masquerade": {"type": "proxy", "url": "http://127.0.0.1:80"}},
        "security": "tls",
        "tlsSettings": {
            "serverName": domain, "minVersion": "1.3", "maxVersion": "1.3",
            "certificates": [{"certificateFile": ssl_cert, "keyFile": ssl_key}], "alpn": ["h3"]
        },
        "externalProxy": [{"dest": domain, "port": hy2_port, "forceTls": "tls", "remark": "Hysteria 2"}]
    }
    smart_reconcile_inbound(hy2_port, "hysteria", "in-hysteria2", "Hysteria 2", h_set, h_str, listen="0.0.0.0")

# 5. AmneziaWG v3.1
if enable_awg_v3:
    awg_i1_env = os.environ.get("AWG_I1", "").strip()
    if awg_i1_env.lower() == "dns":
        awg_i1_env = "<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>"
    a3_set = {
        "clients": [{
            "privateKey": def_wg_c_priv, "publicKey": def_wg_c_pub,
            "allowedIPs": ["10.8.1.2/32"], "email": "Client-1", "enable": True
        }],
        "server": {
            "disableCookies": False,
            "h1": "1", "h2": "2", "h3": "3", "h4": "4", "jc": 4, "jmax": 70, "jmin": 40,
            "keepaliveTimeout": "15-20", "maxHandshakeAttempts": "20-25", "mtu": 1280,
            "primaryDns": awg_primary_dns, "secondaryDns": awg_secondary_dns,
            "privateKey": def_wg_s_priv, "publicKey": def_wg_s_pub,
            "headerProtectionKey": def_wg_hpk,
            "randomTrailers": True,
            "rejectAfterTime": "180-210", "rekeyAfterTime": "120-170",
            "rekeyTimeout": "3-4", "s1": 16, "s2": 16, "s3": 16, "s4": 16,
            "subnetCidr": 22, "subnetIp": "10.8.0.0",
            "i1": awg_i1_env
        }
    }
    a3_str = {"externalProxy": [{"dest": domain, "port": awg_v3_port, "remark": "AmneziaWG v3.1"}]}
    smart_reconcile_inbound(awg_v3_port, "amneziawg", "in-8443-udp", "AmneziaWG v3.1", a3_set, a3_str, listen="0.0.0.0")

# 6. AmneziaWG v2.0
if enable_awg_v2:
    a2_set = {
        "clients": [{
            "privateKey": def_wg_c_priv, "publicKey": def_wg_c_pub,
            "allowedIPs": ["10.8.2.2/32"], "email": "Client-Router", "enable": True
        }],
        "server": {
            "h1": "149419586", "h2": "878791997", "h3": "1251051976", "h4": "1657628296",
            "jc": 2, "jmax": 50, "jmin": 20, "mtu": 1280, "primaryDns": awg_primary_dns, "secondaryDns": awg_secondary_dns,
            "privateKey": def_wg_s_priv, "publicKey": def_wg_s_pub,
            "s1": 16, "s2": 20, "s3": 24, "s4": 16, "subnetCidr": 24, "subnetIp": "10.8.2.0"
        }
    }
    a2_str = {"externalProxy": [{"dest": domain, "port": awg_v2_port, "remark": "AmneziaWG v2.0"}]}
    smart_reconcile_inbound(awg_v2_port, "amneziawg", "in-awg-v2", "AmneziaWG v2.0", a2_set, a2_str, listen="0.0.0.0")

# 7. Shadowsocks 2022
if enable_ss2022 or "shadowsocks" in existing_inbound_protos:
    ss_set = {
        "method": def_ss_method,
        "password": def_ss_server_pass,
        "network": "tcp,udp",
        "udpOverTcp": True,
        "udp_over_tcp": True,
        "clients": [{"email": "Client", "password": def_ss_client_pass, "enable": True}]
    }
    ss_ext_proxies = [{"dest": domain, "port": ss2022_port, "forceTls": "none", "remark": "Shadowsocks 2022"}]
    if enable_shadowtls:
        ss_ext_proxies.append({"dest": domain, "port": shadowtls_port, "forceTls": "tls", "remark": "ShadowTLS v4 + SS-2022"})
    ss_str = {
        "network": "tcp",
        "security": "none",
        "externalProxy": ss_ext_proxies
    }
    smart_reconcile_inbound(ss2022_port, "shadowsocks", "in-shadowsocks-2022", "Shadowsocks 2022", ss_set, ss_str, listen="0.0.0.0")

# 8. TUIC v5
if enable_tuic or "tuic" in existing_inbound_protos:
    tuic_set = {
        "certificate": ssl_cert,
        "private_key": ssl_key,
        "congestion_control": "bbr",
        "alpn": ["h3", "spdy/3.1"],
        "udp_relay_mode": "native",
        "zero_rtt_handshake": False,
        "max_idle_time": 15,
        "authentication_timeout": 3,
        "max_udp_relay_packet_size": 1500,
        "sni": domain,
        "clients": [{"uuid": def_tuic_uuid, "password": def_tuic_pass, "email": "Client", "enable": True}]
    }
    tuic_str = {
        "network": "quic",
        "security": "tls",
        "externalProxy": [{"dest": domain, "port": tuic_port, "forceTls": "tls", "remark": "TUIC v5"}]
    }
    smart_reconcile_inbound(tuic_port, "tuic", "in-tuic-v5", "TUIC v5", tuic_set, tuic_str, listen="0.0.0.0")

# 9. Telegram MTProxy FakeTLS
if enable_mtproto or "mtproto" in existing_inbound_protos:
    mtp_set = {
        "preferIp": "prefer-ipv4",
        "domainFronting": {"ip": mtproto_faketls_domain, "port": 443, "proxyProtocol": False},
        "clients": [{"email": "Client", "secret": def_mtp_secret, "adTag": mtproto_adtag, "enable": True}]
    }
    mtp_str = {
        "network": "tcp",
        "security": "none",
        "externalProxy": [{"dest": domain, "port": mtproto_port, "forceTls": "none", "remark": "Telegram MTProxy"}]
    }
    smart_reconcile_inbound(mtproto_port, "mtproto", "in-mtproto-faketls", "Telegram MTProxy", mtp_set, mtp_str, listen="0.0.0.0")

# --- Синхронизация реестра Hosts для персональных подписок 3X-UI ---
cur.execute("""
    CREATE TABLE IF NOT EXISTS hosts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        group_id TEXT DEFAULT '',
        inbound_id INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER DEFAULT 0,
        remark TEXT DEFAULT '',
        address TEXT DEFAULT '',
        port INTEGER DEFAULT 443,
        security TEXT DEFAULT 'same',
        sni TEXT DEFAULT '',
        host_header TEXT DEFAULT '',
        path TEXT DEFAULT '',
        alpn TEXT DEFAULT '',
        fingerprint TEXT DEFAULT '',
        allow_insecure INTEGER DEFAULT 0,
        is_disabled INTEGER DEFAULT 0,
        is_hidden INTEGER DEFAULT 0,
        tags TEXT DEFAULT '',
        ech_config_list TEXT DEFAULT '',
        mux_params TEXT DEFAULT '',
        sockopt_params TEXT DEFAULT '',
        final_mask TEXT DEFAULT '',
        exclude_from_sub_types TEXT DEFAULT ''
    )
""")
cur.execute("PRAGMA table_info(hosts)")
active_host_cols = {r[1] for r in cur.fetchall()}

def sync_host_entry(ib_id, host_remark, addr, host_port, sec, host_sni="", host_path="", host_alpn="", host_fp="firefox", sort_order=0):
    if ib_id is None:
        return
    cur.execute("SELECT id, remark FROM hosts WHERE inbound_id = ?", (ib_id,))
    h_row = cur.fetchone()
    if h_row:
        h_id, existing_rem = h_row
        final_h_remark = existing_rem if (existing_rem and existing_rem.strip()) else host_remark
        if not dry_run:
            cur.execute("""
                UPDATE hosts
                SET address = ?, port = ?, security = ?, sni = ?, path = ?, alpn = ?, fingerprint = ?, sort_order = ?, remark = ?
                WHERE id = ?
            """, (addr, host_port, sec, host_sni, host_path, host_alpn, host_fp, sort_order, final_h_remark, h_id))
    else:
        gid = str(uuid.uuid4())
        col_candidates = {
            "group_id": gid, "groupId": gid,
            "inbound_id": ib_id, "inboundId": ib_id,
            "sort_order": sort_order, "sortOrder": sort_order,
            "remark": host_remark, "address": addr, "port": host_port, "security": sec,
            "sni": host_sni, "host_header": "", "hostHeader": "", "path": host_path,
            "alpn": host_alpn, "fingerprint": host_fp, "allow_insecure": 0, "allowInsecure": 0,
            "is_disabled": 0, "isDisabled": 0, "is_hidden": 0, "isHidden": 0,
            "tags": "", "ech_config_list": "", "mux_params": "", "sockopt_params": "",
            "final_mask": "", "exclude_from_sub_types": ""
        }
        insert_data = {k: v for k, v in col_candidates.items() if k in active_host_cols}
        keys = list(insert_data.keys())
        vals = [insert_data[k] for k in keys]
        placeholders = ",".join(["?"] * len(keys))
        if not dry_run:
            cur.execute(f"INSERT INTO hosts ({','.join(keys)}) VALUES ({placeholders})", vals)

def lookup_inbound_id(tag_val, port_val):
    cur.execute("SELECT id FROM inbounds WHERE tag = ? OR port = ?", (tag_val, port_val))
    r = cur.fetchone()
    return r[0] if r else None

if enable_steal:
    s_iid = lookup_inbound_id("in-steal-reality", steal_port)
    if s_iid:
        cur.execute("SELECT remark FROM inbounds WHERE id = ?", (s_iid,))
        r_rem = cur.fetchone()
        s_rem = r_rem[0] if r_rem and r_rem[0] else "VLESS Steal"
        sync_host_entry(s_iid, s_rem, domain, 443, "same", host_sni=steal_dom, host_fp="firefox", sort_order=1)

if enable_classic:
    c_iid = lookup_inbound_id("in-classic-reality", classic_port)
    if c_iid:
        cur.execute("SELECT remark FROM inbounds WHERE id = ?", (c_iid,))
        r_rem = cur.fetchone()
        c_rem = r_rem[0] if r_rem and r_rem[0] else "VLESS Classic"
        sync_host_entry(c_iid, c_rem, domain, 443, "same", host_sni=classic_sni, host_fp="firefox", sort_order=1)

x_iid = lookup_inbound_id("in-xhttp-stream", xhttp_port)
if x_iid:
    cur.execute("SELECT remark FROM inbounds WHERE id = ?", (x_iid,))
    r_rem = cur.fetchone()
    x_rem = r_rem[0] if r_rem and r_rem[0] else "VLESS xHTTP"
    sync_host_entry(x_iid, x_rem, domain, 443, "tls", host_sni=domain, host_path=f"/{xhttp_path.strip('/')}/", host_alpn=json.dumps(["h2"]), host_fp="firefox", sort_order=2)


if not dry_run:
    import urllib.parse

    unified_email = os.environ.get("UNIFIED_CLIENT_TAG") or "Client"
    unified_uuid = def_uuid
    unified_sub_id = secrets.token_hex(8)
    unified_awg_hpk = def_wg_hpk
    ss_method = def_ss_method
    unified_ss_server_pass = def_ss_server_pass
    unified_ss_client_pass = def_ss_client_pass
    unified_tuic_uuid = def_tuic_uuid
    unified_tuic_pass = def_tuic_pass
    unified_mtp_secret = def_mtp_secret

    if "clients" in all_tables:
        try:
            cur.execute("SELECT uuid, sub_id, email FROM clients LIMIT 1")
            r_c = cur.fetchone()
            if r_c:
                if r_c[0]: unified_uuid = r_c[0]
                if r_c[1]: unified_sub_id = r_c[1]
                if r_c[2]: unified_email = r_c[2]
        except Exception:
            pass

    try:
        cur.execute("SELECT settings FROM inbounds WHERE protocol = 'shadowsocks' LIMIT 1")
        r_ss = cur.fetchone()
        if r_ss and r_ss[0]:
            s_ss = json.loads(r_ss[0])
            ss_method = s_ss.get("method", def_ss_method)
            if s_ss.get("password"): unified_ss_server_pass = s_ss["password"]
            c_ss = s_ss.get("clients", [])
            if c_ss and c_ss[0].get("password"): unified_ss_client_pass = c_ss[0]["password"]
    except Exception:
        pass

    try:
        cur.execute("SELECT settings FROM inbounds WHERE protocol = 'tuic' LIMIT 1")
        r_tu = cur.fetchone()
        if r_tu and r_tu[0]:
            s_tu = json.loads(r_tu[0])
            c_tu = s_tu.get("clients", [])
            if c_tu and c_tu[0].get("uuid"): unified_tuic_uuid = c_tu[0]["uuid"]
            if c_tu and c_tu[0].get("password"): unified_tuic_pass = c_tu[0]["password"]
    except Exception:
        pass

    try:
        cur.execute("SELECT settings FROM inbounds WHERE protocol = 'mtproto' LIMIT 1")
        r_mt = cur.fetchone()
        if r_mt and r_mt[0]:
            s_mt = json.loads(r_mt[0])
            c_mt = s_mt.get("clients", [])
            if c_mt and c_mt[0].get("secret"): unified_mtp_secret = c_mt[0]["secret"]
    except Exception:
        pass

    try:
        cur.execute("SELECT settings FROM inbounds WHERE protocol = 'amneziawg' LIMIT 1")
        r_awg = cur.fetchone()
        if r_awg and r_awg[0]:
            s_awg = json.loads(r_awg[0])
            srv_awg = s_awg.get("server", {})
            if srv_awg.get("headerProtectionKey"): unified_awg_hpk = srv_awg["headerProtectionKey"]
    except Exception:
        pass

    try:
        cur.execute("SELECT settings FROM inbounds WHERE protocol = 'vless' LIMIT 1")
        r_vl = cur.fetchone()
        if r_vl and r_vl[0]:
            s_vl = json.loads(r_vl[0])
            c_vl = s_vl.get("clients", [])
            if c_vl and c_vl[0].get("id"): unified_uuid = c_vl[0]["id"]
            if c_vl and c_vl[0].get("subId"): unified_sub_id = c_vl[0]["subId"]
    except Exception:
        pass

    raw_ss_userinfo = f"{ss_method}:{unified_ss_server_pass}:{unified_ss_client_pass}"
    b64_ss_userinfo = base64.urlsafe_b64encode(raw_ss_userinfo.encode("utf-8")).decode("utf-8").rstrip("=")
    ss2022_uri = f"ss://{b64_ss_userinfo}@{domain}:{ss2022_port}#{urllib.parse.quote('Shadowsocks 2022')}"
    tuic_uri = f"tuic://{unified_tuic_uuid}:{unified_tuic_pass}@{domain}:{tuic_port}?congestion_control=bbr&alpn=h3&udp_relay_mode=native&sni={domain}#{urllib.parse.quote('TUIC v5')}"
    mtproto_tg_uri = f"tg://proxy?server={domain}&port={mtproto_port}&secret={unified_mtp_secret}"
    mtproto_https_uri = f"https://t.me/proxy?server={domain}&port={mtproto_port}&secret={unified_mtp_secret}"
    mtproto_bot_secret = unified_mtp_secret[2:34] if len(unified_mtp_secret) >= 34 else unified_mtp_secret

    enable_masque = os.environ.get("ENABLE_MASQUE", "n").lower() in ("1", "y", "true")
    masque_port = int(os.environ.get("MASQUE_PORT") or "8449")
    masque_user = (os.environ.get("MASQUE_USER") or "client").strip()
    masque_password = os.environ.get("MASQUE_PASSWORD", "").strip() or unified_ss_client_pass
    masque_uri = f"masque://{masque_user}:{masque_password}@{domain}:{masque_port}?alpn=h3#{urllib.parse.quote('MASQUE RFC 9484')}"

    enable_shadowtls = os.environ.get("ENABLE_SHADOWTLS", "n").lower() in ("1", "y", "true")
    shadowtls_port = int(os.environ.get("SHADOWTLS_PORT") or "8543")
    shadowtls_sni = (os.environ.get("SHADOWTLS_SNI") or "gateway.icloud.com").strip()
    shadowtls_password = os.environ.get("SHADOWTLS_PASSWORD", "").strip()
    shadowtls_uri = f"shadowtls://{shadowtls_password}@{domain}:443?sni={shadowtls_sni}&version=4#{urllib.parse.quote('ShadowTLS v4')}"
    ss_shadowtls_uri = f"ss://{b64_ss_userinfo}@{domain}:443?plugin=shadow-tls;host={shadowtls_sni};password={shadowtls_password};version=4#{urllib.parse.quote('ShadowTLS + SS-2022')}"

    enable_wstunnel = os.environ.get("ENABLE_WSTUNNEL", "n").lower() in ("1", "y", "true")
    wstunnel_port = int(os.environ.get("WSTUNNEL_PORT") or "8080")
    wstunnel_prefix = resolve_wstunnel_prefix(os.environ.get("WSTUNNEL_PREFIX"))
    wstunnel_cli = f"wstunnel client -L socks5://127.0.0.1:1080 --http-upgrade-path-prefix {wstunnel_prefix} wss://{domain}:443"
    wstunnel_uri = f"wstunnel://{domain}:443/{wstunnel_prefix}"

    enable_zapret = os.environ.get("ENABLE_ZAPRET", "n").lower() in ("1", "y", "true")
    zapret_qnum = os.environ.get("ZAPRET_QNUM", "200").strip()
    zapret_desync = os.environ.get("ZAPRET_DESYNC", "split2").strip()
    zapret_fooling = os.environ.get("ZAPRET_FOOLING", "md5sig,badseq").strip()
    zapret_info = f"Active (NFQUEUE {zapret_qnum}, desync: {zapret_desync}, fooling: {zapret_fooling})"

    enable_naive = os.environ.get("ENABLE_NAIVE", "n").lower() in ("1", "y", "true")
    naive_port = int(os.environ.get("NAIVE_PORT") or "8446")
    naive_domain = (os.environ.get("NAIVE_DOMAIN") or (f"naive.{domain}" if domain else "localhost")).strip()
    naive_user = (os.environ.get("NAIVE_USER") or "user").strip()
    naive_pass = (os.environ.get("NAIVE_PASS") or "").strip()
    if not naive_pass and os.path.isfile("/etc/caddy/Caddyfile"):
        try:
            with open("/etc/caddy/Caddyfile", "r") as cf:
                for cline in cf:
                    if "basic_auth" in cline:
                        cparts = cline.strip().split()
                        if len(cparts) >= 3:
                            naive_user = cparts[1]
                            naive_pass = cparts[2]
                            break
        except Exception:
            pass
    if not naive_pass:
        naive_pass = unified_ss_client_pass
    naive_uri = f"naive+https://{naive_user}:{naive_pass}@{naive_domain}:443#{urllib.parse.quote('NaïveProxy')}"

    enable_dnstt = os.environ.get("ENABLE_DNSTT", "n").lower() in ("1", "y", "true")
    dnstt_port = int(os.environ.get("DNSTT_PORT") or "53053")
    dnstt_domain = (os.environ.get("DNSTT_DOMAIN") or (f"t.{domain}" if domain else "t.example.com")).strip()
    dnstt_pubkey = os.environ.get("DNSTT_PUBKEY", "").strip()
    if not dnstt_pubkey and os.path.isfile("/etc/dnstt/server.pub"):
        try:
            with open("/etc/dnstt/server.pub", "r") as pf:
                dnstt_pubkey = pf.read().strip()
        except Exception:
            pass
    if not dnstt_pubkey and enable_dnstt and not dry_run:
        try:
            _P = 2**255 - 19
            def _clamp(kb):
                b = bytearray(kb)
                b[0] &= 248; b[31] &= 127; b[31] |= 64
                return int.from_bytes(b, "little")
            def _x25519(k, u=9):
                x1, x2, z2, x3, z3 = u, 1, 0, u, 1
                for i in range(254, -1, -1):
                    bit = (k >> i) & 1
                    if bit: x2, x3 = x3, x2; z2, z3 = z3, z2
                    A = (x2 + z2) % _P; AA = (A * A) % _P; B = (x2 - z2) % _P; BB = (B * B) % _P; E = (AA - BB) % _P
                    x3 = ((x2 * x3 - z2 * z3)**2) % _P; z3 = (x1 * ((x2 * z3 - z2 * x3)**2)) % _P
                    x2 = (AA * BB) % _P; z2 = (E * (AA + ((121665 * E) % _P))) % _P
                    if bit: x2, x3 = x3, x2; z2, z3 = z3, z2
                return (x2 * pow(z2, _P - 2, _P)) % _P
            _raw_priv = os.urandom(32)
            _k = _clamp(_raw_priv)
            dnstt_pubkey = ((_x25519(_k, 9)) % _P).to_bytes(32, "little").hex()
            os.makedirs("/etc/dnstt", exist_ok=True)
            with open("/etc/dnstt/server.key", "w") as kf:
                kf.write(_raw_priv.hex() + "\n")
            with open("/etc/dnstt/server.pub", "w") as pf:
                pf.write(dnstt_pubkey + "\n")
            os.chmod("/etc/dnstt/server.key", 0o600)
            os.chmod("/etc/dnstt/server.pub", 0o600)
        except Exception:
            pass
    dnstt_cli = f"dnstt-client -doh https://dns.google/dns-query -pubkey {dnstt_pubkey} {dnstt_domain} 127.0.0.1:1080"

    enable_mieru = os.environ.get("ENABLE_MIERU", "n").lower() in ("1", "y", "true")
    mieru_port = (os.environ.get("MIERU_PORT") or "8450").strip()
    mieru_user = (os.environ.get("MIERU_USER") or "").strip()
    mieru_pass = (os.environ.get("MIERU_PASS") or "").strip()
    if (not mieru_user or not mieru_pass) and os.path.isfile("/etc/mita_server_config.json"):
        try:
            with open("/etc/mita_server_config.json", "r", encoding="utf-8") as mf:
                mdata = json.load(mf)
                if mdata.get("users") and len(mdata["users"]) > 0:
                    if not mieru_user: mieru_user = mdata["users"][0].get("name", "")
                    if not mieru_pass: mieru_pass = mdata["users"][0].get("password", "")
        except Exception:
            pass

    try:
        cur.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    except Exception:
        pass
    conn.commit()

    try:
        run_file = "/run/3xui_unified_client.env" if os.path.isdir("/run") else "/tmp/3xui_unified_client.env"
        old_umask = os.umask(0o077)
        with open(run_file, "w") as f:
            f.write(f"PRIMARY_DOMAIN={shlex.quote(domain)}\n")
            f.write(f"PANEL_PATH={shlex.quote(panel_path)}\n")
            f.write(f"UNIFIED_CLIENT_TAG='{unified_email}'\n")
            f.write(f"UNIFIED_SUB_ID='{unified_sub_id}'\n")
            f.write(f"UNIFIED_UUID='{unified_uuid}'\n")
            f.write(f"UNIFIED_AWG_HPK='{unified_awg_hpk}'\n")
            f.write(f"UNIFIED_AWG_PORT='{awg_v3_port}'\n")
            if unified_vless_enkey:
                f.write(f"UNIFIED_VLESS_ENKEY='{unified_vless_enkey}'\n")
            if enable_ss2022 or "shadowsocks" in existing_inbound_protos:
                f.write(f"SS2022_URI='{ss2022_uri}'\n")
                f.write(f"SS2022_PORT='{ss2022_port}'\n")
            if enable_tuic or "tuic" in existing_inbound_protos:
                f.write(f"TUIC_URI='{tuic_uri}'\n")
                f.write(f"TUIC_PORT='{tuic_port}'\n")
            if enable_mtproto or "mtproto" in existing_inbound_protos:
                f.write(f"MTPROTO_TG_URI='{mtproto_tg_uri}'\n")
                f.write(f"MTPROTO_HTTPS_URI='{mtproto_https_uri}'\n")
                f.write(f"MTPROTO_SECRET='{unified_mtp_secret}'\n")
                f.write(f"MTPROTO_BOT_SECRET='{mtproto_bot_secret}'\n")
                f.write(f"MTPROTO_PORT='{mtproto_port}'\n")
            if enable_masque or os.path.exists("/etc/sing-box/masque.json"):
                f.write(f"MASQUE_URI='{masque_uri}'\n")
                f.write(f"MASQUE_PORT='{masque_port}'\n")
            if enable_shadowtls or os.path.exists("/etc/systemd/system/shadow-tls.service"):
                f.write(f"SHADOWTLS_URI='{shadowtls_uri}'\n")
                f.write(f"SS_SHADOWTLS_URI='{ss_shadowtls_uri}'\n")
                f.write(f"SHADOWTLS_PORT='{shadowtls_port}'\n")
            if wstunnel_prefix and (enable_wstunnel or os.path.exists("/etc/systemd/system/wstunnel.service")):
                f.write(f"WSTUNNEL_CLI='{wstunnel_cli}'\n")
                f.write(f"WSTUNNEL_URI='{wstunnel_uri}'\n")
                f.write(f"WSTUNNEL_PORT='{wstunnel_port}'\n")
            if enable_zapret or os.path.exists("/etc/systemd/system/zapret-server.service"):
                f.write(f"ZAPRET_INFO='{zapret_info}'\n")
            if enable_naive or os.path.exists("/etc/systemd/system/caddy-naive.service"):
                f.write(f"NAIVE_URI='{naive_uri}'\n")
                f.write(f"NAIVE_PORT='{naive_port}'\n")
                f.write(f"NAIVE_USER='{naive_user}'\n")
                f.write(f"NAIVE_PASS='{naive_pass}'\n")
            if enable_dnstt or os.path.exists("/etc/systemd/system/dnstt-server.service"):
                f.write(f"DNSTT_CLI='{dnstt_cli}'\n")
                f.write(f"DNSTT_PORT='{dnstt_port}'\n")
                f.write(f"DNSTT_DOMAIN='{dnstt_domain}'\n")
                f.write(f"DNSTT_PUBKEY='{dnstt_pubkey}'\n")
            if (enable_mieru or os.path.exists("/etc/systemd/system/mita.service")) and mieru_user and mieru_pass:
                f.write(f"ENABLE_MIERU='1'\n")
                f.write(f"MIERU_PORT='{mieru_port}'\n")
                f.write(f"MIERU_USER='{mieru_user}'\n")
                f.write(f"MIERU_PASS='{mieru_pass}'\n")
        os.umask(old_umask)
        os.chmod(run_file, 0o600)
    except Exception:
        pass

conn.close()
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
