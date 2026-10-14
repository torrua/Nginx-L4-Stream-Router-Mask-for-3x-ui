#!/usr/bin/env bash
# ==============================================================================
#  CONFIGURE 3X-UI INBOUNDS & SETTINGS (v7.5.0 Universal Companion & Smart Reconcile)
# ==============================================================================
#  Скрипт автоматического конфигурирования и самовосстановления базы 3X-UI.
#  Безопасен для повторного запуска:
#    1. 100% сохранность существующих клиентов (UUID, пароли Hy2, ключи AWG, лимиты);
#    2. 100% сохранность действующих серверных ключей REALITY и AmneziaWG;
#    3. Самоисправление скрытых ошибок (reality settings.publicKey, мертвый SNI swdist);
#    4. Автоматическая настройка externalProxy :443 для корректных ссылок подписок;
#    5. Защита существующей кастомной подписки (не затирает кастомный домен/путь);
#    6. Режим безопасного аудита (--dry-run) и авто-бэкап базы перед записью.
# ==============================================================================

set -euo pipefail

# @include "common/colors.sh"
# @include "common/logger.sh"

# @include "common/backup.sh"


run_with_spinner() {
    local task_name="$1"
    shift
    local log_file="/tmp/configure_3xui_cmd.log"
    : > "$log_file"

    local spin_chars=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local delay=0.08

    if declare -f "$1" >/dev/null 2>&1; then
        "$@" >> "$log_file" 2>&1 &
    else
        ( eval "$*" ) >> "$log_file" 2>&1 &
    fi
    local pid=$!
    tput civis 2>/dev/null || echo -ne "\033[?25l"

    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % 10 ))
        printf "\r  ${CYAN}${spin_chars[$i]}${NC}  ${WHITE}%-54s${NC}" "$task_name..."
        sleep "$delay"
    done

    wait "$pid"
    local exit_code=$?
    tput cnorm 2>/dev/null || echo -ne "\033[?25h"

    if [ $exit_code -eq 0 ]; then
        printf "\r  ${GREEN}✔${NC}  ${WHITE}%-54s${NC} ${GREEN}[ГОТОВО]${NC}\n" "$task_name"
        return 0
    else
        printf "\r  ${RED}✖${NC}  ${WHITE}%-54s${NC} ${RED}[ОШИБКА]${NC}\n" "$task_name"
        [ -f "$log_file" ] && tail -n 25 "$log_file" | sed 's/^/    /' || true
        die "Шаг завершился с ошибкой: $task_name"
    fi
}


show_help() {
    cat << 'EOF_HELP'
Использование: ./configure_3xui.sh [ОПЦИИ]

Скрипт автоматического конфигурирования и самовосстановления базы 3X-UI (инбаунды, пути, подписки).
Безопасен для повторного запуска: сохраняет существующих клиентов, ключи и кастомные подписки.

Опции:
  -c, --config <FILE>     Путь к файлу параметров (.env) (по умолчанию: ./setup_mask.env)
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
  -y, --yes               Неинтерактивное выполнение (без подтверждений)
  -h, --help              Показать эту справку и выйти

Примеры использования:
  # 1. Обычная настройка / обновление:
  ./configure_3xui.sh --config ./setup_mask.env -y

  # 2. Безопасный аудит (посмотреть, что изменится, без записи):
  ./configure_3xui.sh --dry-run
EOF_HELP
}

CONFIG_FILE=""
DB_PATH="/etc/x-ui/x-ui.db"
DRY_RUN=0
FORCE_SUB=0
FORCE_REMARKS=0
NON_INTERACTIVE=0
CLI_ENABLE_WARP=""
CLI_WARP_KEY=""
CLI_ENABLE_NODE_TOKEN=""
CLI_NODE_TOKEN_NAME=""

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
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: имя API-токена ноды."
            CLI_NODE_TOKEN_NAME="$2"
            shift 2
            ;;
        -y|--yes|--non-interactive)
            NON_INTERACTIVE=1
            shift
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

# Проверка root
if [ "${EUID:-$(id -u)}" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    warn "Для записи в базу данных /etc/x-ui/x-ui.db могут потребоваться права суперпользователя (sudo)."
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${YELLOW}>>> РЕЖИМ ПРЕДВАРИТЕЛЬНОГО АУДИТА (--dry-run). ИЗМЕНЕНИЯ НЕ ЗАПИСЫВАЮТСЯ <<<${NC}\n"
fi

# Автопоиск конфигурационного файла, если не передан
if [ -z "$CONFIG_FILE" ]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "/root")"
    if [ -f "$script_dir/setup_mask.env" ]; then
        CONFIG_FILE="$script_dir/setup_mask.env"
    elif [ -f "./setup_mask.env" ]; then
        CONFIG_FILE="./setup_mask.env"
    elif [ -f "/root/setup_mask.env" ]; then
        CONFIG_FILE="/root/setup_mask.env"
    fi
fi

# Загрузка переменных из .env файла
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    log "Загрузка параметров из $CONFIG_FILE..."
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

# Дефолтные значения переменных, если не определены в .env
PRIMARY_DOMAIN="${PRIMARY_DOMAIN:-yourdomain.online}"
PANEL_PORT="${PANEL_PORT:-10443}"
PANEL_PATH="${PANEL_PATH:-my-3x-panel}"
SUB_PORT="${SUB_PORT:-55443}"
SUB_PATH="${SUB_PATH:-}"
SUB_CLASH_PATH="${SUB_CLASH_PATH:-${SUB_PATH%/}/clash}"
SUB_TITLE="${SUB_TITLE:-}"
XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-50443}"
XHTTP_STREAM_PATH="${XHTTP_STREAM_PATH:-}"

ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
SERVER_PREFIX="${SERVER_PREFIX:-Server}"

ENABLE_STEAL="${ENABLE_STEAL:-y}"
STEAL_PORT="${STEAL_PORT:-45443}"
STEAL_DOMAINS="${STEAL_DOMAINS:-cdn.$PRIMARY_DOMAIN}"

ENABLE_CLASSIC="${ENABLE_CLASSIC:-y}"
CLASSIC_PORT="${CLASSIC_PORT:-46443}"
CLASSIC_SNI="${CLASSIC_SNI:-gateway.icloud.com}"

ENABLE_HY2="${ENABLE_HY2:-y}"
HY2_PORT="${HY2_PORT:-443}"
HY2_DOMAIN="${HY2_DOMAIN:-$PRIMARY_DOMAIN}"

ENABLE_AWG_V3="${ENABLE_AWG_V3:-y}"
AWG_V3_PORT="${AWG_V3_PORT:-8443}"

ENABLE_AWG_V2="${ENABLE_AWG_V2:-y}"
AWG_V2_PORT="${AWG_V2_PORT:-8444}"

AWG_PRIMARY_DNS="${AWG_PRIMARY_DNS:-9.9.9.9}"
AWG_SECONDARY_DNS="${AWG_SECONDARY_DNS:-76.76.2.0}"
AWG_SUBNET_IP="${AWG_SUBNET_IP:-10.8.0.0}"
AWG_SUBNET_CIDR="${AWG_SUBNET_CIDR:-22}"
AWG_HEADER_PROTECTION_KEY="${AWG_HEADER_PROTECTION_KEY:-}"
AWG_RANDOM_TRAILERS="${AWG_RANDOM_TRAILERS:-false}"

ENABLE_WARP="${CLI_ENABLE_WARP:-${ENABLE_WARP:-n}}"
WARP_LICENSE_KEY="${CLI_WARP_KEY:-${WARP_LICENSE_KEY:-}}"

ENABLE_NODE_TOKEN="${CLI_ENABLE_NODE_TOKEN:-${ENABLE_NODE_TOKEN:-n}}"
NODE_TOKEN_NAME="${CLI_NODE_TOKEN_NAME:-${NODE_TOKEN_NAME:-}}"
NODE_TOKEN="${NODE_TOKEN:-}"

if [[ "${ENABLE_NODE_TOKEN,,}" == "y" || "${ENABLE_NODE_TOKEN:-}" == "1" ]]; then
    ENABLE_NODE_TOKEN="y"
    if [ -z "$NODE_TOKEN_NAME" ]; then
        local_prefix="${SERVER_PREFIX:-}"
        if [[ -z "$local_prefix" || "${local_prefix,,}" =~ ^(-|none|off|no)$ ]]; then
            NODE_TOKEN_NAME="Master-Node-Cluster"
        else
            NODE_TOKEN_NAME="${local_prefix}-Node"
        fi
    fi
fi

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
TIME_LOCATION="${TIME_LOCATION:-${SYSTEM_TZ:-Europe/Moscow}}"

SUB_UPDATES="${SUB_UPDATES:-1}"
SUB_ENCRYPT="${SUB_ENCRYPT:-true}"
BLOCK_SMTP="${BLOCK_SMTP:-y}"
BLOCK_LAN="${BLOCK_LAN:-y}"
ENABLE_AGH="${ENABLE_AGH:-n}"
AGH_XRAY_DNS="${AGH_XRAY_DNS:-n}"

# Проверяем, активен ли Nginx или сконфигурирован ли он в качестве L4/L7 прокси
HAS_NGINX=0
if command -v nginx >/dev/null 2>&1 && { systemctl is-active --quiet nginx 2>/dev/null || [ -d /etc/nginx/stream.d ]; }; then
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

SSL_ENGINE_CHOICE="${SSL_ENGINE_CHOICE:-1}"
if [ "$SSL_ENGINE_CHOICE" = "1" ]; then
    SSL_CERT_PATH="/etc/letsencrypt/live/$PRIMARY_DOMAIN/fullchain.pem"
    SSL_KEY_PATH="/etc/letsencrypt/live/$PRIMARY_DOMAIN/privkey.pem"
    HY2_CERT_PATH="/etc/letsencrypt/live/$HY2_DOMAIN/fullchain.pem"
    HY2_KEY_PATH="/etc/letsencrypt/live/$HY2_DOMAIN/privkey.pem"
else
    SSL_CERT_PATH="/etc/ssl/acme/$PRIMARY_DOMAIN/fullchain.pem"
    SSL_KEY_PATH="/etc/ssl/acme/$PRIMARY_DOMAIN/privkey.pem"
    HY2_CERT_PATH="/etc/ssl/acme/$HY2_DOMAIN/fullchain.pem"
    HY2_KEY_PATH="/etc/ssl/acme/$HY2_DOMAIN/privkey.pem"
fi

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

# Резервное копирование базы данных перед внесением изменений
if [ "$DRY_RUN" -eq 0 ]; then
    BACKUP_TS="$(date +%Y%m%d_%H%M%S)"
    BACKUP_DB="${DB_PATH}.bak.${BACKUP_TS}"
    backup_sqlite_db "$DB_PATH" "$BACKUP_DB" || warn "Не удалось выполнить онлайн-бэкап базы данных через Backup API."
    chmod 600 "$BACKUP_DB" 2>/dev/null || true
    ok "Создана резервная копия базы данных: $BACKUP_DB"
fi

# Экспорт переменных окружения для Python
export DB_PATH
export DRY_RUN
export FORCE_SUB
export PRIMARY_DOMAIN
export PANEL_PORT
export PANEL_PATH
export SUB_PORT
export SUB_PATH
export SUB_CLASH_PATH
export XHTTP_STREAM_PORT
export XHTTP_STREAM_PATH
export ENABLE_STEAL
export STEAL_PORT
export STEAL_DOMAINS
export ENABLE_CLASSIC
export CLASSIC_PORT
export CLASSIC_SNI
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
export SSL_CERT_PATH
export SSL_KEY_PATH
export ADMIN_USERNAME
export ADMIN_PASSWORD
export SERVER_PREFIX
export ENABLE_WARP
export WARP_LICENSE_KEY
export TIME_LOCATION
export SUB_UPDATES
export SUB_ENCRYPT
export BLOCK_SMTP
export BLOCK_LAN
export WEB_LISTEN
export SUB_LISTEN
export ENABLE_AGH
export AGH_XRAY_DNS
export FORCE_REMARKS

# Приостановка службы x-ui на время реальной транзакции во избежание блокировок SQLite
WAS_ACTIVE=0
cleanup_xui() {
    if [ "${WAS_ACTIVE:-0}" -eq 1 ]; then
        systemctl start x-ui 2>/dev/null || true
    fi
}
trap cleanup_xui EXIT

if [ "$DRY_RUN" -eq 0 ]; then
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet x-ui 2>/dev/null; then
        log "Приостановка службы 3X-UI на время обновления конфигурации базы..."
        systemctl stop x-ui
        WAS_ACTIVE=1
    fi
fi

log "Конфигурирование таблиц settings и inbounds (Smart Reconcile Engine)..."

"$PYTHON_CMD" - << 'EOF_PYTHON_CONFIG'
import os
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

import sqlite3
import json
import uuid
import secrets
import base64
import time
import urllib.request
import re

db_path = os.environ["DB_PATH"]
dry_run = os.environ.get("DRY_RUN", "0") == "1"
force_sub = os.environ.get("FORCE_SUB", "0") == "1"
force_remarks = os.environ.get("FORCE_REMARKS", "0") == "1"

conn = sqlite3.connect(db_path, timeout=30.0)
cur = conn.cursor()

# Извлечение существующих параметров из таблицы settings
existing_settings = {}
try:
    cur.execute("SELECT key, value FROM settings")
    for k, v in cur.fetchall():
        existing_settings[k] = v
except Exception as e:
    print(f"[!] Предупреждение: ошибка чтения таблицы settings: {e}")

domain = os.environ.get("PRIMARY_DOMAIN") or existing_settings.get("subDomain") or "localhost"
panel_port = os.environ.get("PANEL_PORT") or existing_settings.get("webPort") or "10443"
panel_path = (os.environ.get("PANEL_PATH") or existing_settings.get("webBasePath") or "my-3x-panel").strip("/")

sub_port = os.environ.get("SUB_PORT") or existing_settings.get("subPort") or "55443"
sub_env = (os.environ.get("SUB_PATH") or "").strip("/")
if sub_env and sub_env != "my-post-key":
    sub_path = sub_env
else:
    sub_db = (existing_settings.get("subPath") or "").strip("/")
    if sub_db and sub_db != "my-post-key":
        sub_path = sub_db
    else:
        import secrets
        sub_path = "sub-" + secrets.token_hex(4)
sub_clash_path = (os.environ.get("SUB_CLASH_PATH") or existing_settings.get("subClashPath") or f"{sub_path}clash").strip("/")

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
classic_sni = os.environ.get("CLASSIC_SNI") or "gateway.icloud.com"
classic_sni = classic_sni.split()[0] if classic_sni.strip() else "gateway.icloud.com"

ssl_cert = os.environ.get("SSL_CERT_PATH", "")
ssl_key = os.environ.get("SSL_KEY_PATH", "")

enable_hy2 = os.environ.get("ENABLE_HY2", "y").lower() in ("1", "y", "true")
hy2_port = int(os.environ.get("HY2_PORT") or "443")
hy2_domain = (os.environ.get("HY2_DOMAIN") or domain).strip()
hy2_cert = os.environ.get("HY2_CERT_PATH") or ssl_cert
hy2_key = os.environ.get("HY2_KEY_PATH") or ssl_key

enable_awg_v3 = os.environ.get("ENABLE_AWG_V3", "y").lower() in ("1", "y", "true")
awg_v3_port = int(os.environ.get("AWG_V3_PORT") or "8443")

enable_awg_v2 = os.environ.get("ENABLE_AWG_V2", "y").lower() in ("1", "y", "true")
awg_v2_port = int(os.environ.get("AWG_V2_PORT") or "8444")
awg_primary_dns = os.environ.get("AWG_PRIMARY_DNS") or "9.9.9.9"
awg_secondary_dns = os.environ.get("AWG_SECONDARY_DNS") or "76.76.2.0"
awg_subnet_ip = os.environ.get("AWG_SUBNET_IP") or "10.8.0.0"
awg_subnet_cidr = int(os.environ.get("AWG_SUBNET_CIDR") or "22")
awg_hpk_env = os.environ.get("AWG_HEADER_PROTECTION_KEY", "").strip()
awg_random_trailers_env = os.environ.get("AWG_RANDOM_TRAILERS", "false").strip().lower() in ("1", "y", "true")

# Определение ID администратора и настройка учетных данных
admin_user = os.environ.get("ADMIN_USERNAME", "").strip()
admin_pass = os.environ.get("ADMIN_PASSWORD", "").strip()
server_prefix = os.environ.get("SERVER_PREFIX", "").strip()
if server_prefix.lower() in ("-", "none", "off", "no"):
    server_prefix = ""

def make_remark(method):
    if server_prefix:
        return f"{server_prefix} ({method})"
    return method

hashed_pass = None
if admin_pass:
    if admin_pass.startswith("$2a$") or admin_pass.startswith("$2b$") or admin_pass.startswith("$2y$"):
        hashed_pass = admin_pass
    else:
        try:
            import bcrypt
            hashed_pass = bcrypt.hashpw(admin_pass.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")
        except Exception:
            pass

cur.execute("SELECT id, username, password FROM users LIMIT 1")
user_row = cur.fetchone()
if user_row:
    admin_id, curr_user, curr_pass = user_row
    new_user = admin_user if admin_user else curr_user
    new_pass = hashed_pass if hashed_pass else curr_pass
    if admin_user or hashed_pass:
        if not dry_run:
            if hashed_pass:
                cur.execute("UPDATE users SET username = ?, password = ? WHERE id = ?", (new_user, new_pass, admin_id))
            else:
                cur.execute("UPDATE users SET username = ? WHERE id = ?", (new_user, admin_id))
        status_msg = "пароль обновлен (bcrypt)" if hashed_pass else "пароль будет синхронизирован через CLI x-ui"
        print(f"  [ИСПРАВЛЕНО] Администратор (ID {admin_id}): логин='{new_user}', {status_msg}.")
    elif admin_pass:
        print(f"  [ИНФО] Администратор (ID {admin_id}): логин='{new_user}', пароль ожидает хэширования через CLI x-ui.")
else:
    admin_id = 1
    new_pass = hashed_pass if hashed_pass else "admin"
    if not dry_run:
        cur.execute("INSERT INTO users (id, username, password) VALUES (1, ?, ?)", (admin_user or "admin", new_pass))
    print(f"  [СОЗДАНО] Администратор: логин='{admin_user or 'admin'}', пароль создан.")

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

# ----------------- 1. Настройки панели и подписок (settings) -----------------
print("\n[+] Синхронизация системных настроек панели и подписок...")

old_sub_domain = existing_settings.get("subDomain", "").strip()
old_sub_uri = existing_settings.get("subURI", "").strip()
old_sub_path = existing_settings.get("subPath", "").strip()

# Проверка: настроена ли кастомная подписка
is_custom_sub = bool(old_sub_uri and (old_sub_domain != domain or (old_sub_path.strip("/") != sub_path and old_sub_path.strip("/") != "my-post-key")))

if is_custom_sub and not force_sub:
    print(f"  [СОХРАНЕНО] Кастомная подписка сохранена: {old_sub_uri}")
    target_sub_uri = old_sub_uri
    target_sub_domain = old_sub_domain
    target_sub_path = old_sub_path
    target_sub_json_path = existing_settings.get("subJsonPath") or f"/{sub_path.strip('/')}/json/"
    target_sub_json_uri = existing_settings.get("subJsonURI") or f"https://{domain}{target_sub_json_path}"
    target_sub_clash_path = existing_settings.get("subClashPath") or f"/{sub_clash_path.strip('/')}/"
    target_sub_clash_uri = existing_settings.get("subClashURI") or f"https://{domain}{target_sub_clash_path}"
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
    sub_title = existing_settings.get("subTitle", "").strip()

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

# ----------------- 1.1. Тюнинг безопасности и шаблона ядра Xray (xrayTemplateConfig) -----------------
print("\n[+] Синхронизация шаблона конфигурации Xray (DNS, безопасность и защита от абуз)...")

enable_warp = os.environ.get("ENABLE_WARP", "n").lower() in ("1", "y", "true")
warp_license_key = os.environ.get("WARP_LICENSE_KEY", "").strip()

DEFAULT_XRAY_TEMPLATE = {
    "api": {
        "services": ["HandlerService", "LoggerService", "StatsService", "RoutingService"],
        "tag": "api"
    },
    "inbounds": [{
        "listen": "127.0.0.1", "port": 62789, "protocol": "tunnel",
        "settings": {"rewriteAddress": "127.0.0.1"}, "tag": "api"
    }],
    "log": {"access": "none", "dnsLog": False, "error": "", "loglevel": "warning", "maskAddress": ""},
    "metrics": {"listen": "127.0.0.1:11111", "tag": "metrics_out"},
    "outbounds": [
        {"protocol": "freedom", "settings": {"domainStrategy": "AsIs"}, "tag": "direct"},
        {"protocol": "blackhole", "settings": {}, "tag": "blocked"}
    ],
    "policy": {
        "levels": {"0": {"statsUserDownlink": True, "statsUserUplink": True}},
        "system": {"statsInboundDownlink": True, "statsInboundUplink": True, "statsOutboundDownlink": False, "statsOutboundUplink": False}
    },
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
            {"inboundTag": ["api"], "outboundTag": "api", "type": "field"},
            {"ip": ["geoip:private"], "outboundTag": "blocked", "type": "field"}
        ]
    },
    "stats": {}
}

# Чтение и инициализация шаблона Xray
raw_tpl = existing_settings.get("xrayTemplateConfig")
tpl = None
if raw_tpl:
    try:
        tpl = json.loads(raw_tpl)
    except Exception:
        pass
if not tpl or not isinstance(tpl, dict):
    tpl = json.loads(json.dumps(DEFAULT_XRAY_TEMPLATE))

# 1. DNS: UseIPv4 стратегия для предотвращения задержек AAAA
dns_cfg = tpl.get("dns", {})
if not isinstance(dns_cfg, dict):
    dns_cfg = {}
if dns_cfg.get("queryStrategy") != "UseIPv4":
    dns_cfg["queryStrategy"] = "UseIPv4"
    print("  [ОБНОВЛЕН] DNS queryStrategy: зафиксирован 'UseIPv4' (устранение задержек IPv6).")
else:
    print("  [В ПОРЯДКЕ] DNS queryStrategy: 'UseIPv4'.")

enable_agh = os.environ.get("ENABLE_AGH", "").lower() in ("1", "y", "true")
agh_xray_dns = os.environ.get("AGH_XRAY_DNS", "").lower() in ("1", "y", "true")
if enable_agh and agh_xray_dns:
    if dns_cfg.get("servers") != ["127.0.0.1"]:
        dns_cfg["servers"] = ["127.0.0.1"]
        print("  [ОБНОВЛЕН] DNS servers: зафиксирован '127.0.0.1' (AdGuard Home локальный фильтр).")
    else:
        print("  [В ПОРЯДКЕ] DNS servers: '127.0.0.1' (AdGuard Home).")
tpl["dns"] = dns_cfg

# 2. Логирование (тихий безопасный режим, без записи посещаемых URL)
log_cfg = tpl.get("log", {})
if not isinstance(log_cfg, dict):
    log_cfg = {}
log_cfg["loglevel"] = log_cfg.get("loglevel") or "warning"
log_cfg["dnsLog"] = False
if "access" not in log_cfg:
    log_cfg["access"] = "none"
tpl["log"] = log_cfg

# 3. Гарантируем наличие blackhole outbound 'blocked'
outbounds = tpl.get("outbounds", [])
if not isinstance(outbounds, list):
    outbounds = []
has_blocked_ob = any(isinstance(ob, dict) and ob.get("tag") == "blocked" for ob in outbounds)
if not has_blocked_ob:
    outbounds.append({"protocol": "blackhole", "settings": {}, "tag": "blocked"})
    print("  [СОЗДАНО] Outbound 'blocked' (blackhole) добавлен в шаблон.")
tpl["outbounds"] = outbounds

# 4. Правила маршрутизации: Блокировка SMTP (порт 25) и приватных сетей (SSRF)
routing = tpl.get("routing", {})
if not isinstance(routing, dict):
    routing = {}
rules = routing.get("rules", [])
if not isinstance(rules, list):
    rules = []

# А. Блокировка спама (строго порт 25, не затрагивая клиентские 465/587)
if block_smtp:
    has_smtp_block = any(
        isinstance(r, dict) and r.get("outboundTag") == "blocked" and "25" in str(r.get("port", "")).split(",")
        for r in rules
    )
    if not has_smtp_block:
        rules.insert(0, {
            "type": "field",
            "port": "25",
            "outboundTag": "blocked"
        })
        print("  [СОЗДАНО] Защита от спама: исходящий порт 25 заблокирован (outboundTag: blocked).")
    else:
        print("  [В ПОРЯДКЕ] Защита от спама: порт 25 уже заблокирован.")

# Б. Блокировка доступа к приватным IP и хосту (SSRF защита)
if block_lan:
    lan_ips = ["geoip:private", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "fc00::/7", "fe80::/10"]
    has_lan_block = any(
        isinstance(r, dict) and r.get("outboundTag") == "blocked" and any(ip_elem in str(r.get("ip", [])) for ip_elem in ["geoip:private", "127.0.0.0/8", "10.0.0.0/8"])
        for r in rules
    )
    if not has_lan_block:
        rules.insert(0, {
            "type": "field",
            "ip": lan_ips,
            "outboundTag": "blocked"
        })
        print("  [СОЗДАНО] SSRF-защита: доступ к приватным IP хоста заблокирован (outboundTag: blocked).")
    else:
        print("  [В ПОРЯДКЕ] SSRF-защита: локальные сети уже изолированы.")

routing["rules"] = rules
tpl["routing"] = routing

# 5. Опциональная интеграция Cloudflare WARP и выборочной маршрутизации
if enable_warp:
    print("\n[+] Интеграция Cloudflare WARP (Outbound WireGuard, MTU: 1280 & Smart Routing)...")
    warp_data = {}
    if existing_settings.get("warpData"):
        try:
            warp_data = json.loads(existing_settings["warpData"])
        except Exception:
            warp_data = {}

    priv_b64 = warp_data.get("private_key")
    device_id = warp_data.get("device_id")
    client_id = warp_data.get("client_id", "")
    token = warp_data.get("access_token", "")
    endpoint_host = "162.159.192.1:2408"
    v4_address = "172.16.0.2/32"
    v6_address = "2606:4700:110:8780:4178:f4a4:a997:2167/128"
    peer_pub = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

    if priv_b64 and device_id:
        print(f"  [СОХРАНЕНО] Действующий аккаунт WARP (Device ID: {device_id})")
    elif dry_run:
        print("  [DRY-RUN] Регистрация WARP пропущена (холостой прогон)")
        priv_b64, pub_b64 = "dryrun-privkey", "dryrun-pubkey"
        device_id, token, client_id = "dryrun-device", "dryrun-token", ""
    else:
        # Регистрация нового аккаунта через официальный API Cloudflare
        priv_b64, pub_b64 = generate_wg_keypair()
        reg_payload = {
            "key": pub_b64,
            "tos": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
            "type": "PC",
            "model": "x-ui",
            "name": "x-ui"
        }
        reg_req = urllib.request.Request(
            "https://api.cloudflareclient.com/v0a4005/reg",
            data=json.dumps(reg_payload).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "CF-Client-Version": "a-6.30-3596",
                "User-Agent": "okhttp/3.12.1"
            },
            method="POST"
        )
        try:
            with urllib.request.urlopen(reg_req, timeout=12) as reg_resp:
                reg_res = json.loads(reg_resp.read().decode("utf-8"))
            device_id = reg_res.get("id", "")
            token = reg_res.get("token", "")
            cfg = reg_res.get("config", {})
            client_id = cfg.get("client_id", "")
            peers = cfg.get("peers", [])
            if peers:
                peer_pub = peers[0].get("public_key", peer_pub)
                peer_ep_data = peers[0].get("endpoint", {})
                if isinstance(peer_ep_data, dict) and peer_ep_data.get("host"):
                    endpoint_host = peer_ep_data["host"]
            addrs = cfg.get("interface", {}).get("addresses", {})
            if addrs.get("v4"):
                v4_address = f"{addrs['v4']}/32"
            if addrs.get("v6"):
                v6_address = f"{addrs['v6']}/128"

            # Опциональная привязка лицензии WARP+
            if warp_license_key and device_id and token:
                try:
                    lic_req = urllib.request.Request(
                        f"https://api.cloudflareclient.com/v0a4005/reg/{device_id}/account",
                        data=json.dumps({"license": warp_license_key}).encode("utf-8"),
                        headers={
                            "Content-Type": "application/json",
                            "Authorization": f"Bearer {token}",
                            "User-Agent": "okhttp/3.12.1"
                        },
                        method="PUT"
                    )
                    with urllib.request.urlopen(lic_req, timeout=10) as lic_resp:
                        pass
                    print("  [АКТИВИРОВАНО] Лицензия WARP+ успешно привязана к аккаунту.")
                except Exception as e_lic:
                    print(f"  [!] Не удалось привязать ключ WARP+: {e_lic}")

            warp_data = {
                "access_token": token,
                "device_id": device_id,
                "license_key": warp_license_key,
                "private_key": priv_b64,
                "client_id": client_id
            }
            if not dry_run:
                for wk, wv in [("warpData", json.dumps(warp_data)), ("warpUpdateInterval", "0"), ("warpLastUpdate", str(int(time.time())))]:
                    cur.execute("SELECT id FROM settings WHERE key = ?", (wk,))
                    if cur.fetchone():
                        cur.execute("UPDATE settings SET value = ? WHERE key = ?", (wv, wk))
                    else:
                        cur.execute("INSERT INTO settings (key, value) VALUES (?, ?)", (wk, wv))
            print(f"  [СОЗДАНО] Cloudflare WARP аккаунт зарегистрирован (Device ID: {device_id})")
        except Exception as e_reg:
            print(f"  [!] Предупреждение: Cloudflare API недоступен ({e_reg}).")
            print("      Шаблон Xray сконфигурирован с MTU 1280. Регистрацию можно завершить в 1 клик в панели 3X-UI.")
            warp_data = {"private_key": priv_b64, "client_id": ""}

    # Декодирование reserved bytes
    reserved = [0, 0, 0]
    if client_id:
        try:
            dec = list(base64.b64decode(client_id))
            if len(dec) >= 3:
                reserved = dec[:3]
        except Exception:
            pass

    # Формирование объекта outbound 'warp'
    warp_outbound = {
        "tag": "warp",
        "protocol": "wireguard",
        "settings": {
            "secretKey": priv_b64,
            "address": [v4_address, v6_address] if v6_address else [v4_address],
            "peers": [
                {
                    "publicKey": peer_pub,
                    "endpoint": endpoint_host
                }
            ],
            "reserved": reserved,
            "mtu": 1280
        }
    }

    # Согласование outbounds WARP
    outbounds = tpl.get("outbounds", [])
    warp_ob_idx = -1
    for i, ob in enumerate(outbounds):
        if isinstance(ob, dict) and ob.get("tag") == "warp":
            warp_ob_idx = i
            break

    if warp_ob_idx >= 0:
        existing_ob = outbounds[warp_ob_idx]
        ob_settings = existing_ob.get("settings", {})
        ob_settings["mtu"] = 1280
        if not ob_settings.get("secretKey") and priv_b64:
            ob_settings["secretKey"] = priv_b64
        if not ob_settings.get("reserved") and reserved != [0, 0, 0]:
            ob_settings["reserved"] = reserved
        outbounds[warp_ob_idx] = existing_ob
        print("  [ОБНОВЛЕН] Outbound 'warp': зафиксирован MTU 1280 и проверены ключи WireGuard.")
    else:
        outbounds.append(warp_outbound)
        print("  [СОЗДАНО] Outbound 'warp' (WireGuard, MTU: 1280) добавлен в шаблон Xray.")
    tpl["outbounds"] = outbounds

    # Маршрутизация WARP
    routing = tpl.get("routing", {})
    rules = routing.get("rules", [])

    bad_geosites = {
        "geosite:ru", "geosite:yandex", "geosite:vk", "geosite:youtube",
        "geosite:openai", "geosite:google-gemini", "geosite:anthropic", "geosite:cloudflare"
    }

    # Очистка всех существующих правил от отсутствующих/невалидных geosite меток
    for r in rules:
        if isinstance(r, dict) and "domain" in r and isinstance(r["domain"], list):
            r["domain"] = [d for d in r["domain"] if d not in bad_geosites]

    yt_domains = [
        "domain:youtube.com",
        "domain:googlevideo.com",
        "domain:ytimg.com",
        "domain:youtu.be",
        "domain:youtubei.googleapis.com",
        "domain:yt.be"
    ]
    ru_domains = [
        "domain:ru",
        "domain:su",
        "domain:рф",
        "domain:xn--p1ai",
        "domain:yandex.ru",
        "domain:yandex.net",
        "domain:ya.ru",
        "domain:vk.com",
        "domain:vk.ru",
        "domain:vkvideo.ru",
        "domain:gosuslugi.ru",
        "domain:sberbank.ru",
        "domain:tbank.ru",
        "domain:tinkoff.ru",
        "domain:dzen.ru",
        "domain:mail.ru",
        "domain:rutube.ru",
        "domain:ozon.ru",
        "domain:wildberries.ru",
        "domain:avito.ru"
    ]
    warp_domains = [
        "domain:openai.com",
        "domain:chatgpt.com",
        "domain:oaistatic.com",
        "domain:oaiusercontent.com",
        "domain:anthropic.com",
        "domain:claude.ai",
        "domain:gemini.google.com",
        "domain:aistudio.google.com",
        "domain:deepmind.google",
        "domain:makersuite.google.com",
        "domain:generativelanguage.googleapis.com",
        "domain:ai.google.dev",
        "domain:google.com",
        "domain:cloudflare.com",
        "domain:challenges.cloudflare.com"
    ]

    # 1. Из правил WARP исключаем любые YouTube домены
    for r in rules:
        if isinstance(r, dict) and r.get("outboundTag") == "warp":
            if "domain" in r and isinstance(r["domain"], list):
                r["domain"] = [d for d in r["domain"] if not any(y in str(d).lower() for y in ["youtube", "googlevideo", "ytimg", "youtu.be"])]

    # 2. Обработка и нормализация существующих правил
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
        # Direct-правило для RU: разделяем domain и ip
        if tag == "direct" and ("geoip:ru" in r.get("ip", []) or any("domain:ru" in str(d).lower() for d in r.get("domain", []))):
            cur_d = [d for d in r.get("domain", []) if d not in bad_geosites]
            cur_ip = list(r.get("ip", []))
            if cur_d:
                cur_d_set = set(cur_d)
                cur_d_set.update(ru_domains)
                ru_domain_rule = {
                    "type": "field",
                    "outboundTag": "direct",
                    "domain": list(cur_d_set)
                }
            if cur_ip or "geoip:ru" not in cur_ip:
                ru_ip_rule = {
                    "type": "field",
                    "outboundTag": "direct",
                    "ip": ["geoip:ru"]
                }
            continue
        cleaned_existing_rules.append(r)

    new_rules = []
    # 1. Системные правила (api, blocked)
    for r in cleaned_existing_rules:
        if r.get("outboundTag") in ("api", "blocked"):
            new_rules.append(r)

    # 2. YouTube -> Direct (СТРОГО ВЫШЕ WARP)
    if not yt_rule:
        yt_rule = {
            "type": "field",
            "outboundTag": "direct",
            "domain": yt_domains
        }
        print("  [СОЗДАНО] Маршрут YouTube -> DIRECT (без задержек и буферизации).")
    new_rules.append(yt_rule)

    # 3. RU -> Direct (раздельные независимые правила)
    if not ru_domain_rule:
        ru_domain_rule = {
            "type": "field",
            "outboundTag": "direct",
            "domain": ru_domains
        }
    new_rules.append(ru_domain_rule)

    if not ru_ip_rule:
        ru_ip_rule = {
            "type": "field",
            "outboundTag": "direct",
            "ip": ["geoip:ru"]
        }
    new_rules.append(ru_ip_rule)
    print("  [СОЗДАНО/ОБНОВЛЕНО] Маршруты RU-доменов и RU-IP -> DIRECT (раздельные независимые правила).")

    # 4. WARP правило (после direct правил YouTube и RU)
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
        print("  [СОЗДАНО] Маршрут Google, Gemini, OpenAI, Claude -> WARP (обход капч и AI).")
    new_rules.append(warp_rule)

    # 5. Остальные пользовательские правила
    for r in cleaned_existing_rules:
        if r not in new_rules and r.get("outboundTag") != "warp":
            new_rules.append(r)

    routing["rules"] = new_rules
    tpl["routing"] = routing
else:
    print("\n[-] Исходящий туннель Cloudflare WARP отключен в конфигурации.")

# Очистка всех потенциально опасных / отсутствующих geosite из всех маршрутов шаблона
bad_geosites = {
    "geosite:ru", "geosite:yandex", "geosite:vk", "geosite:youtube",
    "geosite:openai", "geosite:google-gemini", "geosite:anthropic", "geosite:cloudflare"
}
routing = tpl.get("routing", {})
if isinstance(routing, dict):
    clean_rules = []
    for r in routing.get("rules", []):
        if isinstance(r, dict):
            if "domain" in r and isinstance(r["domain"], list):
                r["domain"] = [d for d in r["domain"] if d not in bad_geosites]
                if not r["domain"] and not r.get("ip") and not r.get("port"):
                    continue
            clean_rules.append(r)
    routing["rules"] = clean_rules
    tpl["routing"] = routing

# Сохранение обновленного шаблона xrayTemplateConfig
new_xray_json = json.dumps(tpl, indent=2, ensure_ascii=False)
if not dry_run:
    cur.execute("SELECT id FROM settings WHERE key = 'xrayTemplateConfig'")
    if cur.fetchone():
        cur.execute("UPDATE settings SET value = ? WHERE key = 'xrayTemplateConfig'", (new_xray_json,))
    else:
        cur.execute("INSERT INTO settings (key, value) VALUES ('xrayTemplateConfig', ?)", (new_xray_json,))
print("  [ИСПРАВЛЕНО] Конфигурация xrayTemplateConfig синхронизирована и сохранена в базе данных.")

# ----------------- 2. Интеллектуальное согласование инбаундов (Smart Reconcile) -----------------
print("\n[+] Аудит и согласование инбаундов (Smart Reconcile Engine)...")

# --- Единый клиент для всех протоколов и инбаундов (консолидация реестра) ---
client_email_env = os.environ.get("CLIENT_EMAIL", "").strip() or os.environ.get("CLIENT_NAME", "").strip()
safe_prefix_clean = re.sub(r'[^a-zA-Z0-9_-]', '', server_prefix) if server_prefix else ""
unified_email = client_email_env or (f"Client-{safe_prefix_clean}" if safe_prefix_clean and safe_prefix_clean.lower() != "server" else "Client")

# Регулярное выражение для поиска устаревших раздельных клиентов (Client-Steal, Client-Classic и т.п.)
obsolete_pattern = re.compile(r'-(steal|classic|xhttp|hy2|hysteria|hysteria2|awg-v3|awg-v2)$', re.IGNORECASE)

# Сканирование и сбор существующих реквизитов (UUID, subId, пароли, ключи) для бесшовного обновления
harvested_uuid = None
harvested_sub_id = None
harvested_hy2_pass = None
harvested_wg_c_priv = None
harvested_wg_c_pub = None
harvested_wg_hpk = None

if "clients" in all_tables and "email" in clients_cols:
    cand_cols = ["uuid", "sub_id", "password", "wg_private_key", "wg_public_key"]
    avail_cols = [c for c in cand_cols if c in clients_cols]
    if avail_cols:
        col_list = ", ".join(avail_cols)
        cur.execute(f"SELECT {col_list} FROM clients WHERE email = ?", (unified_email,))
        row_c = cur.fetchone()
        if row_c:
            c_map = dict(zip(avail_cols, row_c))
            if c_map.get("uuid"): harvested_uuid = c_map["uuid"]
            if c_map.get("sub_id"): harvested_sub_id = c_map["sub_id"]
            if c_map.get("password"): harvested_hy2_pass = c_map["password"]
            if c_map.get("wg_private_key"): harvested_wg_c_priv = c_map["wg_private_key"]
            if c_map.get("wg_public_key"): harvested_wg_c_pub = c_map["wg_public_key"]

harvested_reality_priv = None
harvested_reality_pub = None
harvested_reality_sids = None

cur.execute("SELECT port, protocol, settings, stream_settings FROM inbounds")
for p, proto, raw_s, raw_st in cur.fetchall():
    try:
        s_obj = json.loads(raw_s) if raw_s else {}
    except Exception:
        continue
    c_list = s_obj.get("clients", [])
    if c_list and isinstance(c_list, list) and len(c_list) > 0:
        for c_cand in c_list:
            c_cand_email = c_cand.get("email") or c_cand.get("Email")
            if c_cand_email == unified_email:
                if proto == "vless":
                    if not harvested_uuid and c_cand.get("id"): harvested_uuid = c_cand.get("id")
                    if not harvested_sub_id and c_cand.get("subId"): harvested_sub_id = c_cand.get("subId")
                elif proto == "hysteria":
                    if not harvested_hy2_pass and (c_cand.get("id") or c_cand.get("password") or c_cand.get("auth")):
                        harvested_hy2_pass = c_cand.get("id") or c_cand.get("password") or c_cand.get("auth")
                elif proto == "amneziawg":
                    if not harvested_wg_c_priv and c_cand.get("privateKey"):
                        harvested_wg_c_priv = c_cand.get("privateKey")
                        harvested_wg_c_pub = c_cand.get("publicKey")
                    srv_conf = s_obj.get("server", {})
                    if srv_conf.get("headerProtectionKey") and not harvested_wg_hpk:
                        harvested_wg_hpk = srv_conf["headerProtectionKey"]
    if raw_st and not harvested_reality_priv:
        try:
            st_obj = json.loads(raw_st)
            r_set = st_obj.get("realitySettings", {})
            if r_set.get("privateKey"):
                harvested_reality_priv = r_set.get("privateKey")
                harvested_reality_pub = r_set.get("settings", {}).get("publicKey") or r_set.get("publicKey") or curve25519_reality_pubkey(harvested_reality_priv)
                if r_set.get("shortIds"):
                    harvested_reality_sids = r_set.get("shortIds")
        except Exception:
            pass

# Итоговые эталонные согласованные реквизиты единого клиента
unified_uuid = harvested_uuid or str(uuid.uuid4())
unified_sub_id = harvested_sub_id or secrets.token_hex(8)
unified_hy2_pass = harvested_hy2_pass or secrets.token_hex(12)

if harvested_reality_priv:
    def_reality_priv = harvested_reality_priv
    def_reality_pub = harvested_reality_pub or curve25519_reality_pubkey(def_reality_priv)
    def_reality_sids = harvested_reality_sids or ([unified_sub_id] + [secrets.token_hex(n) for n in (1, 2, 3, 6)])
    print(f"  [СОХРАНЕНО] Серверные ключи VLESS-REALITY сохранены из базы SQLite")
else:
    def_reality_priv, def_reality_pub = generate_reality_keypair()
    def_reality_sid = unified_sub_id
    def_reality_sids = [def_reality_sid] + [secrets.token_hex(n) for n in (1, 2, 3, 6)]

def_wg_s_priv, def_wg_s_pub = generate_wg_keypair()
if harvested_wg_c_priv and harvested_wg_c_pub:
    def_wg_c_priv, def_wg_c_pub = harvested_wg_c_priv, harvested_wg_c_pub
else:
    def_wg_c_priv, def_wg_c_pub = generate_wg_keypair()

# AWG v3.1: Защита заголовков Handshake (HeaderProtectionKey) и RandomTrailers
unified_awg_hpk = awg_hpk_env or harvested_wg_hpk or base64.b64encode(secrets.token_bytes(32)).decode()
unified_awg_random_trailers = awg_random_trailers_env

# Защита от потери данных: деструктивное удаление клиентов (DELETE FROM clients) заблокировано
obsolete_emails = []
print(f"  [ЕДИНЫЙ КЛИЕНТ] Профиль: '{unified_email}' (привязка ко всем 6 инбаундам, subId: {unified_sub_id[:6]}...)")

# @include "xray/inbounds.py"


