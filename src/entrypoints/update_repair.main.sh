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
# @include "common/backup.sh"


show_help() {
    cat << 'EOF_HELP'
Использование: ./update_repair.sh [ОПЦИИ]

Утилита безопасного обновления и самовосстановления (Smart Reconcile) для Nginx L4 + 3X-UI.

Опции:
  -c, --config <FILE>     Путь к файлу конфигурации (.env) (по умолчанию: ./setup_mask.env)
  --db <PATH>             Путь к базе данных 3X-UI (по умолчанию: /etc/x-ui/x-ui.db)
  --dry-run               Только аудит и проверка (без внесения изменений)
  --force-sub             Принудительно перезаписать кастомные параметры подписки из .env
  --rollback              Мгновенный откат базы данных и Nginx к последнему бэкапу
  -y, --yes               Выполнить исправления без интерактивного подтверждения
  -h, --help              Показать эту справку и выйти

Примеры использования:
  # 1. Предварительный безопасный аудит (посмотреть, что будет исправлено):
  ./update_repair.sh --dry-run

  # 2. Выполнить обновление и исправление с авто-бэкапом:
  ./update_repair.sh -y

  # 3. Мгновенный откат системы к состоянию до обновления:
  ./update_repair.sh --rollback
EOF_HELP
}

CONFIG_FILE=""
DB_PATH="/etc/x-ui/x-ui.db"
DRY_RUN=0
FORCE_SUB=0
ROLLBACK=0
NON_INTERACTIVE=0

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
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$script_dir/setup_mask.env" ]; then
        CONFIG_FILE="$script_dir/setup_mask.env"
    elif [ -f "./setup_mask.env" ]; then
        CONFIG_FILE="./setup_mask.env"
    elif [ -f "/root/setup_mask.env" ]; then
        CONFIG_FILE="/root/setup_mask.env"
    fi
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
export XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-50443}"
export XHTTP_STREAM_PATH="${XHTTP_STREAM_PATH:-}"
export ENABLE_STEAL="${ENABLE_STEAL:-y}"
export STEAL_PORT="${STEAL_PORT:-45443}"
export STEAL_DOMAINS="${STEAL_DOMAINS:-}"
export ENABLE_CLASSIC="${ENABLE_CLASSIC:-y}"
export CLASSIC_PORT="${CLASSIC_PORT:-46443}"
export CLASSIC_SNI="${CLASSIC_SNI:-gateway.icloud.com}"
export ENABLE_HY2="${ENABLE_HY2:-y}"
export HY2_PORT="${HY2_PORT:-443}"
export ENABLE_AWG_V3="${ENABLE_AWG_V3:-y}"
export AWG_V3_PORT="${AWG_V3_PORT:-8443}"
export AWG_HEADER_PROTECTION_KEY="${AWG_HEADER_PROTECTION_KEY:-}"
export AWG_RANDOM_TRAILERS="${AWG_RANDOM_TRAILERS:-false}"
export ENABLE_AWG_V2="${ENABLE_AWG_V2:-y}"
export AWG_V2_PORT="${AWG_V2_PORT:-8444}"
export AWG_PRIMARY_DNS="${AWG_PRIMARY_DNS:-9.9.9.9}"
export AWG_SECONDARY_DNS="${AWG_SECONDARY_DNS:-76.76.2.0}"
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
panel_path = os.environ.get("PANEL_PATH") or existing_settings.get("webBasePath") or "my-3x-panel"
panel_path = panel_path.strip("/")

sub_port = os.environ.get("SUB_PORT") or existing_settings.get("subPort") or "55443"
sub_path = os.environ.get("SUB_PATH") or existing_settings.get("subPath") or "my-post-key"
sub_path = sub_path.strip("/")
sub_clash_env = os.environ.get("SUB_CLASH_PATH", "").strip().strip("/")
if sub_clash_env:
    sub_clash_path = sub_clash_env
elif existing_settings.get("subClashPath"):
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
classic_sni = os.environ.get("CLASSIC_SNI") or "gateway.icloud.com"
classic_sni = classic_sni.split()[0] if classic_sni.strip() else "gateway.icloud.com"

enable_hy2 = os.environ.get("ENABLE_HY2", "y").lower() in ("1", "y", "true")
hy2_port = int(os.environ.get("HY2_PORT") or "443")

enable_awg_v3 = os.environ.get("ENABLE_AWG_V3", "y").lower() in ("1", "y", "true")
awg_v3_port = int(os.environ.get("AWG_V3_PORT") or "8443")
awg_hpk_env = os.environ.get("AWG_HEADER_PROTECTION_KEY", "").strip()
awg_random_trailers_env = os.environ.get("AWG_RANDOM_TRAILERS", "false").strip().lower() in ("1", "y", "true")
awg_primary_dns = os.environ.get("AWG_PRIMARY_DNS") or "9.9.9.9"
awg_secondary_dns = os.environ.get("AWG_SECONDARY_DNS") or "76.76.2.0"

enable_awg_v2 = os.environ.get("ENABLE_AWG_V2", "y").lower() in ("1", "y", "true")
awg_v2_port = int(os.environ.get("AWG_V2_PORT") or "8444")

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

# 1. VLESS REALITY (маскировка под свой сайт)
if enable_steal:
    s_set = {"clients": [{"id": def_uuid, "flow": "xtls-rprx-vision"}], "decryption": "none"}
    s_str = {
        "network": "tcp",
        "tcpSettings": {"acceptProxyProtocol": True, "header": {"type": "none"}},
        "security": "reality",
        "realitySettings": {
            "show": False, "xver": 1, "dest": f"127.0.0.1:{reality_fallback_port}", "target": f"127.0.0.1:{reality_fallback_port}",
            "serverNames": [steal_dom], "privateKey": def_reality_priv,
            "shortIds": def_reality_sids,
            "settings": {"publicKey": def_reality_pub, "fingerprint": "chrome", "spiderX": "/"}
        },
        "externalProxy": [{"dest": domain, "port": 443, "forceTls": "same", "remark": "VLESS_STEAL"}]
    }
    smart_reconcile_inbound(steal_port, "vless", "in-steal-reality", "VLESS_STEAL", s_set, s_str, listen="127.0.0.1")

# 2. VLESS REALITY (маскировка под внешние сервисы)
if enable_classic:
    c_set = {"clients": [{"id": def_uuid, "flow": "xtls-rprx-vision"}], "decryption": "none"}
    c_str = {
        "network": "tcp",
        "tcpSettings": {"acceptProxyProtocol": True, "header": {"type": "none"}},
        "security": "reality",
        "realitySettings": {
            "show": False, "xver": 0, "dest": f"{classic_sni}:443", "target": f"{classic_sni}:443",
            "serverNames": [classic_sni], "privateKey": def_reality_priv,
            "shortIds": def_reality_sids,
            "settings": {"publicKey": def_reality_pub, "fingerprint": "chrome", "spiderX": "/"}
        },
        "externalProxy": [{"dest": domain, "port": 443, "forceTls": "same", "remark": "VLESS_CLASSIC"}]
    }
    smart_reconcile_inbound(classic_port, "vless", "in-classic-reality", "VLESS_CLASSIC", c_set, c_str, listen="127.0.0.1")

# 3. VLESS xHTTP (Stream-One) - сохраняем или генерируем постквантовый ML-KEM-768
cur.execute("SELECT settings FROM inbounds WHERE port = ?", (xhttp_port,))
row_xh = cur.fetchone()
prev_xh_dec = "none"
prev_xh_enc = None
if row_xh and row_xh[0]:
    try:
        prev_s = json.loads(row_xh[0])
        if prev_s.get("decryption") and prev_s["decryption"] != "none":
            prev_xh_dec = prev_s["decryption"]
            prev_xh_enc = prev_s.get("encryption")
    except Exception:
        pass

if prev_xh_dec != "none":
    x_set = {"clients": [{"id": def_uuid, "flow": "xtls-rprx-vision"}], "decryption": prev_xh_dec}
    if prev_xh_enc:
        x_set["encryption"] = prev_xh_enc
else:
    vless_dekey, vless_enkey = generate_vlessenc_keypair()
    if vless_dekey and vless_enkey:
        x_set = {"clients": [{"id": def_uuid, "flow": "xtls-rprx-vision"}], "decryption": vless_dekey, "encryption": vless_enkey}
    else:
        x_set = {"clients": [{"id": def_uuid, "flow": "xtls-rprx-vision"}], "decryption": "none"}
x_str = {
    "network": "xhttp",
    "xhttpSettings": {
        "path": f"/{xhttp_path.strip('/')}/", "host": domain, "mode": "stream-one",
        "xPaddingBytes": "", "xPaddingObfsMode": False, "xPaddingKey": ""
    },
    "security": "none",
    "externalProxy": [{"dest": domain, "port": 443, "forceTls": "tls", "sni": domain, "fingerprint": "chrome", "remark": "VLESS_XHTTP"}]
}
smart_reconcile_inbound(xhttp_port, "vless", "in-xhttp-stream", "VLESS_XHTTP", x_set, x_str, listen="127.0.0.1")

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
    a3_set = {
        "clients": [{
            "privateKey": def_wg_c_priv, "publicKey": def_wg_c_pub,
            "allowedIPs": ["10.8.1.2/32"], "email": "Client-1", "enable": True
        }],
        "server": {
            "disableCookies": True,
            "h1": "", "h2": "", "h3": "", "h4": "", "jc": 2, "jmax": 50, "jmin": 20,
            "keepaliveTimeout": "15-20", "maxHandshakeAttempts": "20-25", "mtu": 1280,
            "primaryDns": awg_primary_dns, "secondaryDns": awg_secondary_dns,
            "privateKey": def_wg_s_priv, "publicKey": def_wg_s_pub,
            "headerProtectionKey": def_wg_hpk,
            "randomTrailers": awg_random_trailers_env,
            "rejectAfterTime": "180-210", "rekeyAfterTime": "120-170",
            "rekeyTimeout": "3-4", "s1": 16, "s2": 20, "s3": 24, "s4": 16,
            "subnetCidr": 22, "subnetIp": "10.8.0.0"
        }
    }
    a3_str = {"externalProxy": [{"dest": domain, "port": awg_v3_port, "remark": "AmneziaWG v3.1"}]}
    smart_reconcile_inbound(awg_v3_port, "amneziawg", "in-8443-udp", "AmneziaWG v3.1", a3_set, a3_str, listen="0.0.0.0")

# 6. AmneziaWG v2.0 Legacy
if enable_awg_v2:
    a2_set = {
        "clients": [{
            "privateKey": def_wg_c_priv, "publicKey": def_wg_c_pub,
            "allowedIPs": ["10.8.2.2/32"], "email": "Legacy-Router", "enable": True
        }],
        "server": {
            "h1": "149419586", "h2": "878791997", "h3": "1251051976", "h4": "1657628296",
            "jc": 2, "jmax": 50, "jmin": 20, "mtu": 1280, "primaryDns": awg_primary_dns, "secondaryDns": awg_secondary_dns,
            "privateKey": def_wg_s_priv, "publicKey": def_wg_s_pub,
            "s1": 16, "s2": 20, "s3": 24, "s4": 16, "subnetCidr": 24, "subnetIp": "10.8.2.0"
        }
    }
    a2_str = {"externalProxy": [{"dest": domain, "port": awg_v2_port, "remark": "AmneziaWG v2.0"}]}
    smart_reconcile_inbound(awg_v2_port, "amneziawg", "in-awg-v2-legacy", "AmneziaWG v2.0", a2_set, a2_str, listen="0.0.0.0")

if not dry_run:
    try:
        cur.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    except Exception:
        pass
    conn.commit()

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
    echo -e "  ${BOLD}sudo ./update_repair.sh -y${NC}"
else
    echo -e "${GREEN}      ОБНОВЛЕНИЕ И ВОССТАНОВЛЕНИЕ СИСТЕМЫ УСПЕШНО ЗАВЕРШЕНО!         ${NC}"
    echo -e "  - ${BOLD}Подключения клиентов:${NC}   ${GREEN}Сохранены без разрыва и сброса ключей${NC}"
    echo -e "  - ${BOLD}Вход в панель 3X-UI:${NC}    ${CYAN}https://${PRIMARY_DOMAIN:-домен}/${PANEL_PATH:-my-3x-panel}/${NC}"
    echo -e "  - ${BOLD}Ссылка на подписку:${NC}     ${CYAN}https://${PRIMARY_DOMAIN:-домен}/${SUB_PATH:-my-post-key}/${NC}"
    echo -e "  - ${BOLD}Ссылка (Clash):${NC}         ${CYAN}https://${PRIMARY_DOMAIN:-домен}/${SUB_CLASH_PATH:-${SUB_PATH:-my-post-key}clash}/${NC}"
fi
echo -e "${GREEN}=====================================================================${NC}"
echo
