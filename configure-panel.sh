#!/usr/bin/env bash
# ==============================================================================
#  CONFIGURE 3X-UI INBOUNDS & SETTINGS (v9.0.0 Universal Companion & Smart Reconcile)
# ==============================================================================
#  Скрипт автоматического конфигурирования и самовосстановления базы 3X-UI.
#  Безопасен для повторного запуска:
#    1. Сохранение существующих клиентов (UUID, пароли Hy2, ключи AWG, лимиты);
#    2. Сохранение действующих серверных ключей REALITY и AmneziaWG;
#    3. Самоисправление скрытых ошибок (reality settings.publicKey, мертвый SNI swdist);
#    4. Автоматическая настройка externalProxy :443 для корректных ссылок подписок;
#    5. Защита существующей кастомной подписки (не затирает кастомный домен/путь);
#    6. Режим безопасного аудита (--dry-run) и авто-бэкап базы перед записью.
# ==============================================================================

set -euo pipefail

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
# Discover the closest saved configuration without renaming existing user files.
is_true() {
    local val="${1:-0}"
    [[ "$val" == "1" || "${val,,}" == "y" || "${val,,}" == "true" ]]
}

find_config_file() {
    local script_dir="${1:-.}" directory candidate
    for directory in . "$script_dir" /etc /root; do
        for candidate in "$directory/server-setup.env" "$directory/setup_mask.env"; do
            if [ -f "$candidate" ]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done
    done
    return 1
}
normalize_node_token_config() {
    local enabled="${CLI_ENABLE_NODE_TOKEN:-${ENABLE_NODE_TOKEN:-y}}"
    NODE_TOKEN="${NODE_TOKEN:-}"
    NODE_TOKEN_NAME="${CLI_NODE_TOKEN_NAME:-${NODE_TOKEN_NAME:-}}"
    case "${enabled,,}" in y|1|true) ENABLE_NODE_TOKEN=y ;; *) ENABLE_NODE_TOKEN=n; return 0 ;; esac
    case "${AUTO_SETUP_3XUI:-y}" in n|0|false) ENABLE_NODE_TOKEN=n; return 0 ;; esac
    if [ -z "$NODE_TOKEN_NAME" ]; then
        local prefix="${SERVER_PREFIX-Server}"
        case "${prefix,,}" in ''|-|none|off|no) NODE_TOKEN_NAME=Master-Node-Cluster ;; *) NODE_TOKEN_NAME="${prefix}-Node" ;; esac
    fi
}

node_token_runtime_file() {
    if [ -n "${NODE_ENV_FILE:-}" ]; then printf '%s' "$NODE_ENV_FILE";
    elif [ -d /run ]; then printf '/run/3xui_node_token.env';
    else printf '/tmp/3xui_node_token.env'; fi
}

load_node_token_result() {
    local file="$1" line key value
    NODE_TOKEN=""
    [ -f "$file" ] || return 1
    local double_quote='^"(.*)"$' single_quote="^'(.*)'\$"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^(NODE_TOKEN_NAME|NODE_TOKEN)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
        if [[ "$value" =~ $double_quote ]] || [[ "$value" =~ $single_quote ]]; then value="${BASH_REMATCH[1]}"; fi
        printf -v "$key" '%s' "$value"
    done < "$file"
    [ -n "${NODE_TOKEN:-}" ]
}

node_token_operation() {
    "$PYTHON_CMD" - "$@" <<'EOF_NODE_TOKEN_PY'
"""Local node-token lifecycle for the 3X-UI API-token SQLite schema."""
from contextlib import closing
import hashlib
import hmac
import os
from pathlib import Path
import secrets
import sqlite3
import sys
import tempfile
import time


def connect(path):
    return sqlite3.connect(Path(path).resolve().as_uri() + "?mode=rw", uri=True, timeout=10)


def verify(path, name, token):
    if not token:
        return False
    try:
        with closing(connect(path)) as conn:
            conn.row_factory = sqlite3.Row
            row = conn.execute("SELECT * FROM api_tokens WHERE name=?", (name,)).fetchone()
        if row is None or not row["enabled"]:
            return False
        if "expires_at" in row.keys():
            expiry = int(row["expires_at"] or 0)
            if expiry > 100_000_000_000:
                expiry //= 1000
            if expiry and expiry <= int(time.time()):
                return False
        if "scope" in row.keys() and row["scope"] not in ("admin", "node-admin", "node-sync"):
            return False
        return hmac.compare_digest(hashlib.sha256(token.encode()).hexdigest(), row["token"])
    except (sqlite3.Error, ValueError, TypeError):
        return False


def create(path, name):
    with closing(connect(path)) as conn, conn:
        columns = {row[1] for row in conn.execute("PRAGMA table_info(api_tokens)")}
        if not {"name", "token", "enabled"} <= columns:
            raise ValueError("Unsupported 3X-UI API-token schema")
        token = secrets.token_hex(32)
        values = {"name": name, "token": hashlib.sha256(token.encode()).hexdigest(), "enabled": 1}
        for column, value in (("scope", "admin"), ("created_at", int(time.time())), ("expires_at", 0)):
            if column in columns:
                values[column] = value
        if conn.execute("SELECT 1 FROM api_tokens WHERE name=?", (name,)).fetchone():
            update = {key: value for key, value in values.items() if key != "name"}
            conn.execute("UPDATE api_tokens SET " + ",".join(key + "=?" for key in update) + " WHERE name=?",
                         [*update.values(), name])
        else:
            conn.execute("INSERT INTO api_tokens (" + ",".join(values) + ") VALUES ("
                         + ",".join("?" for _ in values) + ")", list(values.values()))
    return token


def atomic_write(path, text):
    path = Path(path)
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def persist(runtime_path, config_path, name, token):
    values = {"ENABLE_NODE_TOKEN": "y", "NODE_TOKEN_NAME": name, "NODE_TOKEN": token}
    if any("\n" in value or "\r" in value for value in values.values()):
        raise ValueError("Node-token values must be single-line strings")
    # These files are read as literal KEY=value data, never evaluated as shell code.
    lines = [f'{key}="{value}"' for key, value in values.items()]
    atomic_write(runtime_path, "\n".join(lines) + "\n")
    if config_path and Path(config_path).is_file():
        previous = Path(config_path).read_text(encoding="utf-8").splitlines()
        previous = [line for line in previous if line.partition("=")[0] not in values]
        atomic_write(config_path, "\n".join([*previous, *lines]) + "\n")


def main(args):
    action, *values = args
    if action == "verify":
        return 0 if verify(*values) else 1
    if action == "create":
        print(create(*values))
    elif action == "persist":
        persist(*values)
    else:
        raise ValueError("Unknown node-token operation")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (OSError, ValueError, sqlite3.Error) as error:
        print(f"Node API token: {error}", file=sys.stderr)
        raise SystemExit(1)
EOF_NODE_TOKEN_PY
}

ensure_node_token() {
    case "${ENABLE_NODE_TOKEN:-y}" in n|0|false) return 0 ;; esac
    NODE_TOKEN="${NODE_TOKEN:-}"
    if node_token_operation verify "$DB_PATH" "$NODE_TOKEN_NAME" "$NODE_TOKEN"; then
        ok "Действующий API-ключ ноды '$NODE_TOKEN_NAME' сохранён."
    else
        NODE_TOKEN=""
        local token_out="" attempt
        local -a arguments=()
        if [ -n "${XUI_BIN:-}" ]; then
            for attempt in 1 2; do
                case "$attempt" in
                    1) arguments=(-tokenName "$NODE_TOKEN_NAME" -tokenScope admin) ;;
                    2) arguments=(-tokenName "$NODE_TOKEN_NAME") ;;
                esac
                token_out=$("$XUI_BIN" setting -getApiToken "${arguments[@]}" 2>&1 || true)
                NODE_TOKEN=$(printf '%s\n' "$token_out" | awk '$1 == "apiToken:" {gsub(/\r/, "", $2); print $2; exit}')
                [ -z "$NODE_TOKEN" ] || break
            done
        fi
        # Also handles CLI versions without named-token flags, without renaming other tokens.
        if ! node_token_operation verify "$DB_PATH" "$NODE_TOKEN_NAME" "$NODE_TOKEN"; then
            NODE_TOKEN=$(node_token_operation create "$DB_PATH" "$NODE_TOKEN_NAME") || die "Не удалось создать API-ключ ноды 3X-UI."
        fi
        [ -n "$NODE_TOKEN" ] || die "3X-UI не вернул API-ключ ноды."
        ok "API-ключ ноды '$NODE_TOKEN_NAME' создан."
    fi
    local runtime_file
    runtime_file=$(node_token_runtime_file)
    node_token_operation persist "$runtime_file" "${CONFIG_FILE:-}" "$NODE_TOKEN_NAME" "$NODE_TOKEN" || die "Не удалось сохранить API-ключ ноды."
}

# SQLite WAL-safe live database backup and verification
get_sqlite_backup_python() {
    if [ -n "${PYTHON_CMD:-}" ] && "$PYTHON_CMD" -c "import sqlite3" 2>/dev/null; then
        echo "$PYTHON_CMD"
        return 0
    fi
    if python3 -c "import sqlite3" 2>/dev/null; then
        echo "python3"
        return 0
    fi
    if python -c "import sqlite3" 2>/dev/null; then
        echo "python"
        return 0
    fi
    return 1
}

verify_sqlite_backup() {
    local bkp="$1"
    local py_cmd="$2"
    if [ ! -s "$bkp" ]; then
        return 1
    fi
    if [ -n "$py_cmd" ]; then
        "$py_cmd" -c "
import sqlite3, sys
try:
    conn = sqlite3.connect(sys.argv[1])
    res = conn.execute('PRAGMA integrity_check;').fetchall()
    conn.close()
    if res and res[0][0] == 'ok':
        sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
" "$bkp" 2>/dev/null && return 0
    elif command -v sqlite3 >/dev/null 2>&1; then
        local check
        check=$(sqlite3 "$bkp" "PRAGMA integrity_check;" 2>/dev/null || true)
        [ "$check" = "ok" ] && return 0
    fi
    return 1
}

backup_sqlite_db() {
    local src="$1"
    local dst="$2"
    if [ ! -f "$src" ]; then
        return 1
    fi
    local py_cmd
    py_cmd=$(get_sqlite_backup_python || true)

    local backup_ok=0

    # 1. Primary: Python SQLite Online Backup API (atomic, WAL-safe)
    if [ -n "$py_cmd" ]; then
        if "$py_cmd" -c "
import sqlite3, sys
src_p, dst_p = sys.argv[1], sys.argv[2]
try:
    try:
        src_conn = sqlite3.connect(f'file:{src_p}?mode=ro', uri=True)
    except Exception:
        src_conn = sqlite3.connect(src_p)
    dst_conn = sqlite3.connect(dst_p)
    with dst_conn:
        src_conn.backup(dst_conn)
    dst_conn.close()
    src_conn.close()
    sys.exit(0)
except Exception:
    sys.exit(1)
" "$src" "$dst" 2>/dev/null; then
            if verify_sqlite_backup "$dst" "$py_cmd"; then
                backup_ok=1
            fi
        fi
    fi

    # 2. Secondary: sqlite3 CLI .backup command (atomic, WAL-safe)
    if [ "$backup_ok" -eq 0 ] && command -v sqlite3 >/dev/null 2>&1; then
        if sqlite3 "$src" ".backup '$dst'" 2>/dev/null; then
            if verify_sqlite_backup "$dst" "$py_cmd"; then
                backup_ok=1
            fi
        fi
    fi

    if [ "$backup_ok" -eq 1 ]; then
        chmod 600 "$dst" 2>/dev/null || true
        return 0
    fi

    # Never silently downgrade to raw cp of a live WAL database; fail safe and clean up
    rm -f "$dst" 2>/dev/null || true
    return 1
}


# Execute in a fresh Bash so a caller's `if`/`||` cannot suppress errexit.
# A private snapshot preserves Bash functions and unexported variables in both modes.
execute_install_task() (
    umask 077
    task_dir=$(mktemp -d "${TMPDIR:-/tmp}/server-task.XXXXXX") || exit 1
    trap 'rm -f -- "$task_dir/task.sh"; rmdir -- "$task_dir"' EXIT
    {
        declare -p | grep -vE '^declare -[^ ]*r|^declare [^ ]+ (BASH[^ =]*|FUNCNAME|DIRSTACK|GROUPS|PIPESTATUS|LINENO|RANDOM|SRANDOM|SECONDS|EPOCHSECONDS|EPOCHREALTIME|_)='
        declare -f
        printf '%s\n' 'shopt -s inherit_errexit 2>/dev/null || true' 'set -Eeuo pipefail' '"$@"'
    } > "$task_dir/task.sh" || exit 1
    bash --noprofile --norc "$task_dir/task.sh" "$@"
)

# Interactive Terminal Spinner & Task Runner
# Supports:
#   - Animated spinner in interactive TTY
#   - Plain output in non-interactive / CI / piped runs
#   - DEBUG_MODE=1 passthrough (full stdout/stderr in real-time)
#   - Required tasks support Retry / Abort; failures cannot be marked as success

run_with_spinner() {
    local task_name="$1"
    shift
    local log_file="${SETUP_MASK_LOG:-${INSTALL_LOG:-${SPINNER_LOG_FILE:-}}}"
    local temporary_log=0
    if [ -z "$log_file" ]; then
        log_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/server-task-log.XXXXXX") || return 1
        temporary_log=1
    fi

    while true; do
        local exit_code=0

        # ── DEBUG MODE: без фона, весь вывод сразу в stdout ──
        if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
            echo -e "\n  ${CYAN}[DEBUG]${NC} ${WHITE}▶ $task_name${NC}"
            echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            execute_install_task "$@" &
            local debug_pid=$!
            if wait "$debug_pid"; then exit_code=0; else exit_code=$?; fi
            if [ $exit_code -eq 0 ]; then
                echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
                echo -e "  ${GREEN}${CHECK:-✔}${NC}  ${WHITE}$task_name${NC} ${GREEN}[ГОТОВО]${NC}\n"
                [ "$temporary_log" -eq 0 ] || rm -f -- "$log_file"
                return 0
            else
                echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            fi
        else
            # ── Нормальный режим: фоновый процесс + спиннер ──
            local spin_chars=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
            local delay=0.08

            (umask 077; : > "$log_file") || return 1
            chmod 600 "$log_file" || return 1

            execute_install_task "$@" >> "$log_file" 2>&1 &
            local pid=$!

            if [ ! -t 1 ]; then
                echo -e "  ${CYAN}*${NC}  ${WHITE}${task_name}...${NC}"
                if wait "$pid"; then exit_code=0; else exit_code=$?; fi
            else
                tput civis 2>/dev/null || echo -ne "\033[?25l"
                local i=0
                while kill -0 "$pid" 2>/dev/null; do
                    i=$(( (i + 1) % 10 ))
                    printf "\r  ${CYAN}${spin_chars[$i]}${NC}  ${WHITE}%-54s${NC}" "$task_name..."
                    sleep "$delay"
                done
                if wait "$pid"; then exit_code=0; else exit_code=$?; fi
                tput cnorm 2>/dev/null || echo -ne "\033[?25h"
            fi

            if [ $exit_code -eq 0 ]; then
                if [ ! -t 1 ]; then
                    printf "  ${GREEN}${CHECK:-✔}${NC}  ${WHITE}%-54s${NC} ${GREEN}[ГОТОВО]${NC}\n" "$task_name"
                else
                    printf "\r  ${GREEN}${CHECK:-✔}${NC}  ${WHITE}%-54s${NC} ${GREEN}[ГОТОВО]${NC}\n" "$task_name"
                fi
                [ "$temporary_log" -eq 0 ] || rm -f -- "$log_file"
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

        # ── Обязательный этап: повторить или прервать ──
        if [ "${NON_INTERACTIVE:-0}" -eq 0 ] && [ -t 1 ]; then
            echo -e "  ${YELLOW}${BOLD}Действия при сбое:${NC}"
            echo -e "    ${CYAN}${BOLD}[1] Повторить попытку (Retry)${NC} — после исправления причин (напр. DNS)"
            echo -e "    ${RED}[3] Прервать установку (Abort)${NC}"
            local retry_ans=""
            read -rp "  Ваш выбор [1/3] (по умолчанию: 1): " retry_ans </dev/tty || read -r retry_ans || retry_ans="1"
            retry_ans=$(echo "${retry_ans:-1}" | tr -d '[:space:]')
            case "$retry_ans" in
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


show_help() {
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
  -y, --yes               Неинтерактивное выполнение (без подтверждений)
  -h, --help              Показать эту справку и выйти

Примеры использования:
  # 1. Обычная настройка / обновление:
  ./configure-panel.sh --config ./server-setup.env -y

  # 2. Безопасный аудит (посмотреть, что изменится, без записи):
  ./configure-panel.sh --dry-run
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
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /root)"
    CONFIG_FILE=$(find_config_file "$script_dir" || true)
fi

# Загрузка переменных из .env файла
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    log "Загрузка параметров из $CONFIG_FILE..."
    re_dquote='^"(.*)"$'
    re_squote="^'(.*)'\$"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
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
PANEL_PATH="${PANEL_PATH:-}"
SUB_PORT="${SUB_PORT:-55443}"
SUB_PATH="${SUB_PATH:-}"
SUB_CLASH_PATH="${SUB_CLASH_PATH:-${SUB_PATH%/}/clash}"
SERVER_PREFIX="${SERVER_PREFIX:-Server}"
SUB_TITLE="${SUB_TITLE:-$SERVER_PREFIX}"
XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-50443}"
XHTTP_STREAM_PATH="${XHTTP_STREAM_PATH:-}"

ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

ENABLE_STEAL="${ENABLE_STEAL:-y}"
STEAL_PORT="${STEAL_PORT:-45443}"
STEAL_DOMAINS="${STEAL_DOMAINS:-cdn.$PRIMARY_DOMAIN}"

ENABLE_CLASSIC="${ENABLE_CLASSIC:-y}"
CLASSIC_PORT="${CLASSIC_PORT:-46443}"
CLASSIC_SNI="${CLASSIC_SNI:-avito.ru}"

ENABLE_HY2="${ENABLE_HY2:-y}"
HY2_PORT="${HY2_PORT:-443}"
HY2_DOMAIN="${HY2_DOMAIN:-$PRIMARY_DOMAIN}"

ENABLE_AWG_V3="${ENABLE_AWG_V3:-y}"
AWG_V3_PORT="${AWG_V3_PORT:-8443}"

ENABLE_AWG_V2="${ENABLE_AWG_V2:-n}"
AWG_V2_PORT="${AWG_V2_PORT:-8444}"

ENABLE_SS2022="${ENABLE_SS2022:-n}"
SS2022_PORT="${SS2022_PORT:-8388}"
ENABLE_SHADOWTLS="${ENABLE_SHADOWTLS:-n}"
SHADOWTLS_PORT="${SHADOWTLS_PORT:-8543}"
SHADOWTLS_SNI="${SHADOWTLS_SNI:-gateway.icloud.com}"
SHADOWTLS_PASSWORD="${SHADOWTLS_PASSWORD:-}"

ENABLE_NAIVE="${ENABLE_NAIVE:-n}"
NAIVE_PORT="${NAIVE_PORT:-8446}"
NAIVE_DOMAIN="${NAIVE_DOMAIN:-}"
NAIVE_USER="${NAIVE_USER:-user}"
NAIVE_PASS="${NAIVE_PASS:-}"

ENABLE_DNSTT="${ENABLE_DNSTT:-n}"
DNSTT_PORT="${DNSTT_PORT:-53053}"
DNSTT_DOMAIN="${DNSTT_DOMAIN:-}"
DNSTT_PUBKEY="${DNSTT_PUBKEY:-}"

ENABLE_TUIC="${ENABLE_TUIC:-n}"
TUIC_PORT="${TUIC_PORT:-8448}"

ENABLE_MTPROTO="${ENABLE_MTPROTO:-n}"
MTPROTO_PORT="${MTPROTO_PORT:-8444}"
MTPROTO_FAKETLS_DOMAIN="${MTPROTO_FAKETLS_DOMAIN:-gateway.icloud.com}"
MTPROTO_ADTAG="${MTPROTO_ADTAG:-}"

AWG_PRIMARY_DNS="${AWG_PRIMARY_DNS:-9.9.9.9}"
AWG_SECONDARY_DNS="${AWG_SECONDARY_DNS:-76.76.2.0}"
AWG_SUBNET_IP="${AWG_SUBNET_IP:-10.8.0.0}"
AWG_SUBNET_CIDR="${AWG_SUBNET_CIDR:-22}"
AWG_HEADER_PROTECTION_KEY="${AWG_HEADER_PROTECTION_KEY:-}"
AWG_RANDOM_TRAILERS="${AWG_RANDOM_TRAILERS:-false}"

ENABLE_WARP="${CLI_ENABLE_WARP:-${ENABLE_WARP:-n}}"
WARP_LICENSE_KEY="${CLI_WARP_KEY:-${WARP_LICENSE_KEY:-}}"

normalize_node_token_config

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

if [ "$DRY_RUN" -eq 0 ]; then
    BACKUP_TS="$(date +%Y%m%d_%H%M%S)"
    BACKUP_DB="${DB_PATH}.bak.${BACKUP_TS}"
    if ! backup_sqlite_db "$DB_PATH" "$BACKUP_DB"; then
        die "Критическая ошибка: невозможно создать проверенную резервную копию базы данных $DB_PATH. Внесение изменений отменено во избежание повреждения данных."
    fi
    chmod 600 "$BACKUP_DB" 2>/dev/null || true
    ok "Создана проверенная резервная копия базы данных: $BACKUP_DB"
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
export SUB_TITLE
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
export ENABLE_MTPROTO
export MTPROTO_PORT
export MTPROTO_FAKETLS_DOMAIN
export MTPROTO_ADTAG
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
export ENABLE_WSTUNNEL="${ENABLE_WSTUNNEL:-n}"
export WSTUNNEL_PREFIX="${WSTUNNEL_PREFIX:-}"
export WSTUNNEL_PORT="${WSTUNNEL_PORT:-8080}"
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
import urllib.parse
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
"""Path resolution shared by the standalone configuration and repair tools."""
import secrets
import shlex
from pathlib import Path


def resolve_panel_path(configured, existing):
    """Preserve explicit and existing paths, including legacy installation paths."""
    return ((configured or "").strip().strip("/")
            or (existing or "").strip().strip("/")
            or "panel-" + secrets.token_hex(16))


def resolve_wstunnel_prefix(configured, service_file="/etc/systemd/system/wstunnel.service"):
    """Read the applied prefix; reporting must never create a new server secret."""
    try:
        for line in Path(service_file).read_text(encoding="utf-8").splitlines():
            if not line.strip().startswith("ExecStart="):
                continue
            args = shlex.split(line.strip().split("=", 1)[1])
            for index, arg in enumerate(args):
                if arg == "--restrict-http-upgrade-path-prefix" and index + 1 < len(args):
                    return args[index + 1].strip("/")
                if arg.startswith("--restrict-http-upgrade-path-prefix="):
                    return arg.split("=", 1)[1].strip("/")
    except (OSError, ValueError):
        pass
    return (configured or "").strip().strip("/")

panel_path = resolve_panel_path(os.environ.get("PANEL_PATH"), existing_settings.get("webBasePath"))

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
sub_clash_env = (os.environ.get("SUB_CLASH_PATH") or "").strip().strip("/")
if sub_clash_env:
    sub_clash_path = sub_clash_env
else:
    sub_clash_db = (existing_settings.get("subClashPath") or "").strip().strip("/")
    if sub_clash_db and sub_clash_db != f"{sub_path}clash":
        sub_clash_path = sub_clash_db
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

ssl_cert = os.environ.get("SSL_CERT_PATH", "")
ssl_key = os.environ.get("SSL_KEY_PATH", "")

enable_hy2 = os.environ.get("ENABLE_HY2", "y").lower() in ("1", "y", "true")
hy2_port = int(os.environ.get("HY2_PORT") or "443")
hy2_domain = (os.environ.get("HY2_DOMAIN") or domain).strip()
hy2_cert = os.environ.get("HY2_CERT_PATH") or ssl_cert
hy2_key = os.environ.get("HY2_KEY_PATH") or ssl_key

enable_awg_v3 = os.environ.get("ENABLE_AWG_V3", "y").lower() in ("1", "y", "true")
awg_v3_port = int(os.environ.get("AWG_V3_PORT") or "8443")

enable_awg_v2 = os.environ.get("ENABLE_AWG_V2", "n").lower() in ("1", "y", "true")
awg_v2_port = int(os.environ.get("AWG_V2_PORT") or "8444")
awg_primary_dns = os.environ.get("AWG_PRIMARY_DNS") or "9.9.9.9"
awg_secondary_dns = os.environ.get("AWG_SECONDARY_DNS") or "76.76.2.0"
awg_subnet_ip = os.environ.get("AWG_SUBNET_IP") or "10.8.0.0"
awg_subnet_cidr = int(os.environ.get("AWG_SUBNET_CIDR") or "22")
awg_hpk_env = os.environ.get("AWG_HEADER_PROTECTION_KEY", "").strip()
awg_random_trailers_env = os.environ.get("AWG_RANDOM_TRAILERS", "false").strip().lower() in ("1", "y", "true")

enable_ss2022 = os.environ.get("ENABLE_SS2022", "n").lower() in ("1", "y", "true")
ss2022_port = int(os.environ.get("SS2022_PORT") or "8388")
enable_shadowtls = os.environ.get("ENABLE_SHADOWTLS", "n").lower() in ("1", "y", "true")
shadowtls_port = int(os.environ.get("SHADOWTLS_PORT") or "8543")
shadowtls_sni = (os.environ.get("SHADOWTLS_SNI") or "gateway.icloud.com").strip()
shadowtls_password = os.environ.get("SHADOWTLS_PASSWORD", "").strip()

enable_tuic = os.environ.get("ENABLE_TUIC", "n").lower() in ("1", "y", "true")
tuic_port = int(os.environ.get("TUIC_PORT") or "8448")

enable_mtproto = os.environ.get("ENABLE_MTPROTO", "n").lower() in ("1", "y", "true")
mtproto_port = int(os.environ.get("MTPROTO_PORT") or "8444")
mtproto_faketls_domain = (os.environ.get("MTPROTO_FAKETLS_DOMAIN") or "gateway.icloud.com").strip()
mtproto_adtag = os.environ.get("MTPROTO_ADTAG", "").strip()

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

def sync_inbound_clients(inbound_id, protocol, remark, target_settings, target_stream=None):
    clients = target_settings.get("clients", [])
    if not clients:
        return
    
    import time
    now_ms = int(time.time() * 1000)
    for idx, client in enumerate(clients):
        # 1. Email (уникальный ключ клиента в 3X-UI)
        email = client.get("email") or client.get("Email") or ""
        if not email:
            safe_remark = remark.lower().replace(" ", "-").replace("_", "-")
            email = f"client-{safe_remark}" if idx == 0 else f"client-{safe_remark}-{idx+1}"
            client["email"] = email
        
        # 2. subId для персональной подписки
        sub_id = client.get("subId") or client.get("sub_id") or ""
        if not sub_id:
            sub_id = secrets.token_hex(8)
            client["subId"] = sub_id
            
        # 3. Статус активности
        if "enable" not in client:
            client["enable"] = True
            
        client_flow = client.get("flow", "")
        client_secret = client.get("secret", "")
        client_adtag = client.get("adTag") or client.get("ad_tag") or ""
        if protocol in ("vless", "vmess"):
            client_uuid = client.get("id", "") or client.get("uuid", "")
            client_pass = client.get("password", "")
        elif protocol == "hysteria":
            client_uuid = client.get("uuid", "")
            client_pass = client.get("auth") or client.get("password") or client.get("id", "")
        elif protocol == "tuic":
            client_uuid = client.get("uuid", "") or client.get("id", "")
            client_pass = client.get("password", "")
        elif protocol == "shadowsocks":
            client_uuid = client.get("uuid", "") or client.get("id", "")
            client_pass = client.get("password", "")
        elif protocol == "mtproto":
            client_uuid = client.get("uuid", "")
            client_pass = client.get("password", "")
            if not client_pass and "secret" not in clients_cols and client_secret:
                client_pass = client_secret
        else:
            client_uuid = client.get("uuid", "")
            client_pass = client.get("password", "")
        
        if dry_run:
            continue
            
        # A. Таблица client_traffics (статистика, статус и отображение в панели 3X-UI)
        if "client_traffics" in all_tables and "email" in client_traffics_cols:
            cur.execute("SELECT id FROM client_traffics WHERE email = ?", (email,))
            ct_row = cur.fetchone()
            if not ct_row:
                ct_data = {
                    "inbound_id": inbound_id,
                    "enable": 1 if client.get("enable", True) else 0,
                    "email": email,
                    "up": 0, "down": 0, "expiry_time": 0, "total": 0, "reset": 0
                }
                for opt_col in ["uuid", "sub_id", "subId"]:
                    if opt_col in client_traffics_cols:
                        ct_data[opt_col] = client_uuid if opt_col == "uuid" else sub_id
                valid_ct = {k: v for k, v in ct_data.items() if k in client_traffics_cols}
                if valid_ct:
                    cols = ", ".join(valid_ct.keys())
                    placeholders = ", ".join(["?"] * len(valid_ct))
                    cur.execute(f"INSERT INTO client_traffics ({cols}) VALUES ({placeholders})", list(valid_ct.values()))
            else:
                ct_updates = {}
                if "enable" in client and "enable" in client_traffics_cols:
                    ct_updates["enable"] = 1 if client["enable"] else 0
                for opt_col in ["uuid", "sub_id", "subId"]:
                    if opt_col in client_traffics_cols:
                        val = client_uuid if opt_col == "uuid" else sub_id
                        if val: ct_updates[opt_col] = val
                valid_ct_up = {k: v for k, v in ct_updates.items() if k in client_traffics_cols}
                if valid_ct_up:
                    set_ct = ", ".join(f"{k} = ?" for k in valid_ct_up.keys())
                    cur.execute(f"UPDATE client_traffics SET {set_ct} WHERE email = ?", list(valid_ct_up.values()) + [email])
                
        # B. Таблица clients (единый реестр клиентов в 3X-UI v2.5+)
        client_db_id = None
        if "clients" in all_tables and "email" in clients_cols:
            cur.execute("SELECT id FROM clients WHERE email = ?", (email,))
            c_row = cur.fetchone()
            if not c_row:
                c_data = {
                    "email": email,
                    "enable": 1 if client.get("enable", True) else 0,
                    "created_at": now_ms,
                    "updated_at": now_ms
                }
                if "sub_id" in clients_cols and sub_id: c_data["sub_id"] = sub_id
                if "subId" in clients_cols and sub_id: c_data["subId"] = sub_id
                if "uuid" in clients_cols and client_uuid: c_data["uuid"] = client_uuid
                if "password" in clients_cols and client_pass and protocol != "hysteria": c_data["password"] = client_pass
                if "auth" in clients_cols and client_pass and protocol == "hysteria": c_data["auth"] = client_pass
                if "flow" in clients_cols and client_flow: c_data["flow"] = client_flow
                if "secret" in clients_cols and client_secret: c_data["secret"] = client_secret
                if "ad_tag" in clients_cols and client_adtag: c_data["ad_tag"] = client_adtag
                if "adTag" in clients_cols and client_adtag: c_data["adTag"] = client_adtag
                if "encryption" in clients_cols and client.get("encryption"): c_data["encryption"] = client["encryption"]
                if protocol == "amneziawg":
                    if "wg_private_key" in clients_cols and client.get("privateKey"):
                        c_data["wg_private_key"] = client.get("privateKey")
                    if "wg_public_key" in clients_cols and client.get("publicKey"):
                        c_data["wg_public_key"] = client.get("publicKey")
                    if "wg_allowed_ips" in clients_cols and client.get("allowedIPs"):
                        ips = client.get("allowedIPs")
                        c_data["wg_allowed_ips"] = ", ".join(ips) if isinstance(ips, list) else str(ips).strip("[]'\"")
                valid_c = {k: v for k, v in c_data.items() if k in clients_cols}
                if valid_c:
                    cols = ", ".join(valid_c.keys())
                    placeholders = ", ".join(["?"] * len(valid_c))
                    cur.execute(f"INSERT INTO clients ({cols}) VALUES ({placeholders})", list(valid_c.values()))
                    client_db_id = cur.lastrowid
            else:
                client_db_id = c_row[0]
                c_updates = {}
                if "updated_at" in clients_cols:
                    c_updates["updated_at"] = now_ms
                if "enable" in client and "enable" in clients_cols:
                    c_updates["enable"] = 1 if client["enable"] else 0
                if "sub_id" in clients_cols and sub_id: c_updates["sub_id"] = sub_id
                if "uuid" in clients_cols and client_uuid: c_updates["uuid"] = client_uuid
                if "password" in clients_cols and client_pass and protocol != "hysteria": c_updates["password"] = client_pass
                if "auth" in clients_cols and client_pass and protocol == "hysteria": c_updates["auth"] = client_pass
                if "flow" in clients_cols and client_flow: c_updates["flow"] = client_flow
                if "secret" in clients_cols and client_secret: c_updates["secret"] = client_secret
                if "ad_tag" in clients_cols and client_adtag: c_updates["ad_tag"] = client_adtag
                if "adTag" in clients_cols and client_adtag: c_updates["adTag"] = client_adtag
                if "encryption" in clients_cols and client.get("encryption"): c_updates["encryption"] = client["encryption"]
                if protocol == "amneziawg":
                    if "wg_private_key" in clients_cols and client.get("privateKey"):
                        c_updates["wg_private_key"] = client.get("privateKey")
                    if "wg_public_key" in clients_cols and client.get("publicKey"):
                        c_updates["wg_public_key"] = client.get("publicKey")
                    if "wg_allowed_ips" in clients_cols and client.get("allowedIPs"):
                        ips = client.get("allowedIPs")
                        clean_ip = ", ".join(ips) if isinstance(ips, list) else str(ips).strip("[]'\"")
                        is_legacy_v2 = "v2" in remark.lower() or "legacy" in remark.lower()
                        cur.execute("SELECT wg_allowed_ips FROM clients WHERE id = ?", (client_db_id,))
                        curr_wg_ip_row = cur.fetchone()
                        curr_wg_ip = curr_wg_ip_row[0] if curr_wg_ip_row and curr_wg_ip_row[0] else ""
                        if not is_legacy_v2 or not curr_wg_ip or curr_wg_ip.startswith("["):
                            c_updates["wg_allowed_ips"] = clean_ip
                valid_c_up = {k: v for k, v in c_updates.items() if k in clients_cols}
                if valid_c_up:
                    set_clause = ", ".join(f"{k} = ?" for k in valid_c_up.keys())
                    cur.execute(f"UPDATE clients SET {set_clause} WHERE id = ?", list(valid_c_up.values()) + [client_db_id])
                
        # C. Таблица client_inbounds (связь клиент <-> инбаунд в 3X-UI v2.5+)
        if "client_inbounds" in all_tables and client_db_id is not None:
            cur.execute("SELECT 1 FROM client_inbounds WHERE client_id = ? AND inbound_id = ?", (client_db_id, inbound_id))
            if not cur.fetchone():
                ci_data = {
                    "client_id": client_db_id,
                    "inbound_id": inbound_id,
                    "flow_override": client_flow,
                    "created_at": now_ms
                }
                valid_ci = {k: v for k, v in ci_data.items() if k in client_inbounds_cols}
                cols = ", ".join(valid_ci.keys())
                placeholders = ", ".join(["?"] * len(valid_ci))
                cur.execute(f"INSERT INTO client_inbounds ({cols}) VALUES ({placeholders})", list(valid_ci.values()))
            else:
                if "flow_override" in client_inbounds_cols:
                    cur.execute("UPDATE client_inbounds SET flow_override = ? WHERE client_id = ? AND inbound_id = ?", (client_flow, client_db_id, inbound_id))

import base64
import os
import re
import secrets
import subprocess
import uuid

# Curve25519 helper (RFC 7748) для генерации, валидации и починки ключей
P = 2**255 - 19
A24 = 121665

def clamp(k_bytes):
    b = bytearray(k_bytes)
    b[0] &= 248
    b[31] &= 127
    b[31] |= 64
    return int.from_bytes(b, "little")

def x25519(k, u=9):
    x1 = u
    x2, z2 = 1, 0
    x3, z3 = u, 1
    for i in range(254, -1, -1):
        bit = (k >> i) & 1
        if bit:
            x2, x3 = x3, x2
            z2, z3 = z3, z2
        A = (x2 + z2) % P
        AA = (A * A) % P
        B = (x2 - z2) % P
        BB = (B * B) % P
        E = (AA - BB) % P
        C = (x3 + z3) % P
        D = (x3 - z3) % P
        DA = (D * A) % P
        CB = (C * B) % P
        x3 = pow(DA + CB, 2, P)
        z3 = (x1 * pow(DA - CB, 2, P)) % P
        x2 = (AA * BB) % P
        z2 = (E * (AA + A24 * E)) % P
        if bit:
            x2, x3 = x3, x2
            z2, z3 = z3, z2
    return (x2 * pow(z2, P - 2, P)) % P

def curve25519_pubkey(priv_b64):
    try:
        raw_priv = base64.b64decode(priv_b64)
        k = clamp(raw_priv)
        pub_raw = x25519(k, 9).to_bytes(32, "little")
        return base64.b64encode(pub_raw).decode()
    except Exception:
        return None

def curve25519_reality_pubkey(priv_b64url):
    try:
        padding = "=" * ((4 - len(priv_b64url) % 4) % 4)
        raw_priv = base64.urlsafe_b64decode(priv_b64url + padding)
        k = clamp(raw_priv)
        pub_raw = x25519(k, 9).to_bytes(32, "little")
        return base64.urlsafe_b64encode(pub_raw).decode().rstrip("=")
    except Exception:
        return None

def generate_reality_keypair():
    priv_raw = os.urandom(32)
    k = clamp(priv_raw)
    pub_raw = x25519(k, 9).to_bytes(32, "little")
    priv_b64 = base64.urlsafe_b64encode(priv_raw).decode().rstrip("=")
    pub_b64 = base64.urlsafe_b64encode(pub_raw).decode().rstrip("=")
    return priv_b64, pub_b64

def generate_wg_keypair():
    priv_raw = os.urandom(32)
    k = clamp(priv_raw)
    pub_raw = x25519(k, 9).to_bytes(32, "little")
    priv_b64 = base64.b64encode(priv_raw).decode()
    pub_b64 = base64.b64encode(pub_raw).decode()
    return priv_b64, pub_b64

def generate_vlessenc_keypair():
    for candidate in ["/usr/local/x-ui/bin/xray-linux-amd64", "/usr/local/x-ui/bin/xray-linux-arm64", "/usr/local/x-ui/bin/xray", "xray"]:
        try:
            res = subprocess.run([candidate, "vlessenc"], capture_output=True, text=True, timeout=5)
            if res.returncode == 0:
                out = res.stdout
                de_m = re.search(r'"decryption":\s*"([^"]+)"', out)
                en_m = re.search(r'"encryption":\s*"([^"]+)"', out)
                if de_m and en_m:
                    return de_m.group(1), en_m.group(1)
        except Exception:
            pass
    return None, None

def generate_ss2022_key(method="2022-blake3-aes-256-gcm"):
    raw_len = 16 if "128" in method else 32
    return base64.b64encode(os.urandom(raw_len)).decode()

def validate_ss2022_key(key_b64, method="2022-blake3-aes-256-gcm"):
    try:
        if not isinstance(key_b64, str) or not key_b64.strip():
            return False
        k = key_b64.strip().replace('-', '+').replace('_', '/')
        padding = "=" * ((4 - len(k) % 4) % 4)
        raw = base64.b64decode(k + padding, validate=True)
        expected_len = 16 if "128" in method else 32
        return len(raw) == expected_len
    except Exception:
        return False

def generate_mtproto_secret(fake_tls_domain="gateway.icloud.com"):
    domain = fake_tls_domain.strip().lower() if fake_tls_domain else "gateway.icloud.com"
    token = secrets.token_hex(16)
    domain_hex = domain.encode("utf-8").hex()
    return f"ee{token}{domain_hex}"

def validate_mtproto_secret(secret_hex):
    if not isinstance(secret_hex, str):
        return False
    s = secret_hex.strip().lower()
    return s.startswith("ee") and len(s) >= 38 and all(c in "0123456789abcdef" for c in s[2:])

def validate_mtproto_adtag(adtag):
    return bool(isinstance(adtag, str) and re.match(r"^[0-9a-fA-F]{32}$", adtag.strip()))

def generate_shadowtls_password():
    return secrets.token_urlsafe(16)

def validate_shadowtls_password(pw):
    return bool(isinstance(pw, str) and len(pw.strip()) >= 8)

def generate_masque_credentials(default_user="client"):
    return default_user, secrets.token_urlsafe(16)

def generate_naiveproxy_credentials(default_user="user"):
    return default_user, secrets.token_urlsafe(16)

def generate_tuic_credentials(default_uuid=None):
    return default_uuid or str(uuid.uuid4()), secrets.token_urlsafe(16)

def generate_dnstt_keypair():
    priv_raw = os.urandom(32)
    k = clamp(priv_raw)
    pub_raw = ((x25519(k, 9)) % P).to_bytes(32, "little")
    return priv_raw.hex(), pub_raw.hex()

def validate_dnstt_pubkey(pubkey):
    if not isinstance(pubkey, str):
        return False
    s = pubkey.strip().lower()
    return len(s) == 64 and all(c in "0123456789abcdef" for c in s)

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
        # Direct-правило для RU: разделяем domain и ip с сохранением пользовательских ограничений
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
harvested_ss_server_pass = None
harvested_ss_client_pass = None
harvested_tuic_uuid = None
harvested_tuic_pass = None
harvested_mtp_secret = None
harvested_mtp_adtag = None
harvested_vless_dekey = None
harvested_vless_enkey = None

if "clients" in all_tables and "email" in clients_cols:
    cand_cols = ["uuid", "sub_id", "password", "wg_private_key", "wg_public_key", "secret", "ad_tag", "encryption"]
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
            if c_map.get("secret"): harvested_mtp_secret = c_map["secret"]
            if c_map.get("ad_tag"): harvested_mtp_adtag = c_map["ad_tag"]
            if c_map.get("encryption"): harvested_vless_enkey = c_map["encryption"]

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
                elif proto == "shadowsocks":
                    if not harvested_ss_client_pass and c_cand.get("password"):
                        harvested_ss_client_pass = c_cand.get("password")
                elif proto == "tuic":
                    if not harvested_tuic_uuid and c_cand.get("uuid"):
                        harvested_tuic_uuid = c_cand.get("uuid")
                    elif not harvested_tuic_uuid and c_cand.get("id"):
                        harvested_tuic_uuid = c_cand.get("id")
                    if not harvested_tuic_pass and c_cand.get("password"):
                        harvested_tuic_pass = c_cand.get("password")
                elif proto == "mtproto":
                    if not harvested_mtp_secret and c_cand.get("secret"):
                        harvested_mtp_secret = c_cand.get("secret")
                    if not harvested_mtp_adtag and (c_cand.get("ad_tag") or c_cand.get("adTag")):
                        harvested_mtp_adtag = c_cand.get("ad_tag") or c_cand.get("adTag")
                elif proto == "amneziawg":
                    if not harvested_wg_c_priv and c_cand.get("privateKey"):
                        harvested_wg_c_priv = c_cand.get("privateKey")
                        harvested_wg_c_pub = c_cand.get("publicKey")
                    srv_conf = s_obj.get("server", {})
                    if srv_conf.get("headerProtectionKey") and not harvested_wg_hpk:
                        harvested_wg_hpk = srv_conf["headerProtectionKey"]
    if proto == "vless":
        if s_obj.get("decryption") and s_obj["decryption"] != "none":
            if not harvested_vless_dekey: harvested_vless_dekey = s_obj["decryption"]
            if not harvested_vless_enkey and s_obj.get("encryption"):
                harvested_vless_enkey = s_obj["encryption"]
        if not harvested_vless_enkey and c_list:
            for _c in c_list:
                if _c.get("encryption"):
                    harvested_vless_enkey = _c["encryption"]
                    break
    if proto == "shadowsocks":
        if not harvested_ss_server_pass and s_obj.get("password"):
            harvested_ss_server_pass = s_obj.get("password")
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

# Реквизиты Shadowsocks 2022
ss_method = "2022-blake3-aes-256-gcm"
if harvested_ss_server_pass and validate_ss2022_key(harvested_ss_server_pass, ss_method):
    unified_ss_server_pass = harvested_ss_server_pass
else:
    unified_ss_server_pass = generate_ss2022_key(ss_method)

if harvested_ss_client_pass and validate_ss2022_key(harvested_ss_client_pass, ss_method):
    unified_ss_client_pass = harvested_ss_client_pass
else:
    unified_ss_client_pass = generate_ss2022_key(ss_method)

# Реквизиты TUIC v5
unified_tuic_uuid = harvested_tuic_uuid or unified_uuid
# ВАЖНО: Пароль TUIC v5 должен строго совпадать с clients.password (unified_ss_client_pass),
# чтобы прямая ссылка tuic:// и экспорт подписки Clash/Mihomo содержали один и тот же пароль
unified_tuic_pass = unified_ss_client_pass
tuic_cert = os.environ.get("TUIC_CERT_PATH") or ssl_cert
tuic_key = os.environ.get("TUIC_KEY_PATH") or ssl_key

# Реквизиты Telegram MTProxy
if harvested_mtp_secret and validate_mtproto_secret(harvested_mtp_secret):
    unified_mtp_secret = harvested_mtp_secret
else:
    unified_mtp_secret = generate_mtproto_secret(mtproto_faketls_domain)

unified_mtp_adtag = mtproto_adtag or harvested_mtp_adtag or ""
if unified_mtp_adtag and not validate_mtproto_adtag(unified_mtp_adtag):
    unified_mtp_adtag = ""

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
print(f"  [ЕДИНЫЙ КЛИЕНТ] Профиль: '{unified_email}' (привязка ко всем инбаундам, subId: {unified_sub_id[:6]}...)")

def smart_reconcile_inbound(port, protocol, tag, remark, default_settings, default_stream, listen="127.0.0.1"):
    cur.execute("SELECT id, settings, stream_settings, protocol, tag, remark, listen, enable FROM inbounds WHERE port = ? OR tag = ?", (port, tag))
    row = cur.fetchone()
    
    if not row:
        # Инбаунд отсутствует -> создаем под ключ
        target_settings = json.loads(json.dumps(default_settings))
        target_stream = json.loads(json.dumps(default_stream))
        if protocol == "mtproto" and "preferIp" not in target_settings:
            target_settings["preferIp"] = "prefer-ipv4"
        if "externalProxy" in target_stream and isinstance(target_stream["externalProxy"], list) and len(target_stream["externalProxy"]) > 0:
            if protocol in ("shadowsocks", "mtproto", "amneziawg"):
                target_stream["externalProxy"][0]["forceTls"] = "none"
            elif protocol == "vless" and "realitySettings" in target_stream:
                target_stream["externalProxy"][0]["forceTls"] = "same"
            elif "forceTls" not in target_stream["externalProxy"][0]:
                target_stream["externalProxy"][0]["forceTls"] = "tls"

        settings_json = json.dumps(target_settings, ensure_ascii=False)
        stream_json = json.dumps(target_stream, ensure_ascii=False)
        sniffing_json = json.dumps({"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"]})
        new_inbound_id = None
        if not dry_run:
            cur.execute("""
                INSERT INTO inbounds (
                    user_id, up, down, total, remark, enable, expiry_time,
                    listen, port, protocol, settings, stream_settings, tag, sniffing
                ) VALUES (?, 0, 0, 0, ?, 1, 0, ?, ?, ?, ?, ?, ?, ?)
            """, (admin_id, remark, listen, port, protocol, settings_json, stream_json, tag, sniffing_json))
            new_inbound_id = cur.lastrowid
            if "sync_inbound_clients" in globals():
                sync_inbound_clients(new_inbound_id, protocol, remark, target_settings, target_stream)
                settings_json = json.dumps(target_settings, ensure_ascii=False)
                cur.execute("UPDATE inbounds SET settings = ? WHERE id = ?", (settings_json, new_inbound_id))
        print(f"  [СОЗДАНО] Отсутствующий инбаунд: {remark} ({protocol.upper()} на порту {port}) добавлен и зарегистрирован в реестре клиентов.")
        return new_inbound_id

    inbound_id, raw_s, raw_st, proto, cur_tag, cur_remark, cur_listen, cur_enable = row
    cur_enable = 1 if cur_enable is None else cur_enable
    try:
        cur_settings = json.loads(raw_s) if raw_s else {}
    except Exception:
        cur_settings = {}
    try:
        cur_stream = json.loads(raw_st) if raw_st else {}
    except Exception:
        cur_stream = {}

    target_settings = json.loads(json.dumps(default_settings))
    target_stream = json.loads(json.dumps(default_stream))
    repairs = []
    preserved = []

    # Сохранение пользовательского названия инбаунда (remark), если оно было изменено
    final_remark = remark
    force_remarks_flag = globals().get("force_remarks", False)
    if not force_remarks_flag and cur_remark and str(cur_remark).strip():
        final_remark = str(cur_remark).strip()
        if final_remark != remark:
            preserved.append(f"пользовательское название '{final_remark}'")

    # А. Сохранение и консолидация клиентов (единый реестр)
    existing_clients = cur_settings.get("clients", [])
    if "unified_email" in globals() and globals().get("unified_email"):
        u_email = globals()["unified_email"]
        consolidated_clients = []
        has_unified = False
        default_client = default_settings.get("clients", [])[0] if default_settings.get("clients") else None
        
        for ec in existing_clients:
            ec_email = ec.get("email") or ec.get("Email") or ""
            if ec_email == u_email:
                if not has_unified and default_client:
                    merged_c = json.loads(json.dumps(default_client))
                    for limit_field in ["totalGB", "expiryTime", "limitIp", "tgId", "reset", "resetDay", "resetMax", "enable"]:
                        if limit_field in ec:
                            merged_c[limit_field] = ec[limit_field]
                    if protocol == "shadowsocks" and ec.get("password"):
                        if "validate_ss2022_key" in globals() and validate_ss2022_key(ec["password"], target_settings.get("method", "2022-blake3-aes-256-gcm")):
                            merged_c["password"] = ec["password"]
                        else:
                            repairs.append("исправлен невалидный ключ единого клиента SS-2022")
                    elif protocol == "tuic":
                        if ec.get("uuid"): merged_c["uuid"] = ec["uuid"]
                        if ec.get("password"): merged_c["password"] = ec["password"]
                    elif protocol == "mtproto":
                        if ec.get("secret"):
                            if "validate_mtproto_secret" not in globals() or validate_mtproto_secret(ec["secret"]):
                                merged_c["secret"] = ec["secret"]
                            else:
                                repairs.append("исправлен невалидный FakeTLS секрет MTProto единого клиента")
                        if ec.get("adTag") or ec.get("ad_tag"):
                            ad_cand = ec.get("adTag") or ec.get("ad_tag")
                            if "validate_mtproto_adtag" in globals() and not validate_mtproto_adtag(ad_cand):
                                merged_c["adTag"] = ""
                                repairs.append("очищен невалидный adTag MTProto")
                            else:
                                merged_c["adTag"] = ad_cand
                    elif protocol == "vless" and "xhttpSettings" in target_stream:
                        enc_cand = ec.get("encryption") or cur_settings.get("encryption") or target_settings.get("encryption")
                        if enc_cand:
                            merged_c["encryption"] = enc_cand
                    consolidated_clients.append(merged_c)
                    has_unified = True
                    preserved.append(f"единый клиент '{u_email}'")
            else:
                consolidated_clients.append(ec)
                preserved.append(f"клиент '{ec_email}'")
                
        if not has_unified and default_client:
            consolidated_clients.insert(0, json.loads(json.dumps(default_client)))
            repairs.append(f"добавлен единый клиент '{u_email}'")
            
        target_settings["clients"] = consolidated_clients
    else:
        if existing_clients and len(existing_clients) > 0:
            target_settings["clients"] = existing_clients
            preserved.append(f"клиенты ({len(existing_clients)} польз.)")
        else:
            repairs.append("добавлен клиент по умолчанию")

    # Б. Проверка и ремонт VLESS REALITY
    if protocol == "vless" and "realitySettings" in target_stream:
        cur_reality = cur_stream.get("realitySettings", {})
        
        # Сохранение privateKey
        priv = cur_reality.get("privateKey")
        if priv:
            target_stream["realitySettings"]["privateKey"] = priv
            preserved.append("privateKey Reality")
        
        # Сохранение shortIds
        sids = cur_reality.get("shortIds")
        if sids:
            target_stream["realitySettings"]["shortIds"] = sids
            preserved.append("shortIds")

        # Ремонт / сохранение settings.publicKey
        pub = cur_reality.get("settings", {}).get("publicKey") or cur_reality.get("publicKey")
        if pub:
            target_stream["realitySettings"]["settings"]["publicKey"] = pub
            if not cur_reality.get("settings", {}).get("publicKey"):
                repairs.append("исправлен отсутствующий settings.publicKey (устранена ошибка empty password)")
            else:
                preserved.append("publicKey")
        else:
            derived_pub = curve25519_reality_pubkey(target_stream["realitySettings"]["privateKey"])
            if derived_pub:
                target_stream["realitySettings"]["settings"]["publicKey"] = derived_pub
                repairs.append("восстановлен settings.publicKey по x25519")

        # Ремонт мертвого swdist.microsoft.com SNI или пустых значений
        old_snis = cur_reality.get("serverNames", [])
        old_dest = str(cur_reality.get("dest", "")).strip()
        if any("swdist.microsoft.com" in s for s in old_snis) or "swdist.microsoft.com" in old_dest:
            repairs.append(f"заменен мертвый SNI swdist.microsoft.com -> {classic_sni}")
            target_stream["realitySettings"]["serverNames"] = [classic_sni]
            target_stream["realitySettings"]["dest"] = f"{classic_sni}:443"
            target_stream["realitySettings"]["xver"] = 0
        elif old_snis:
            target_stream["realitySettings"]["serverNames"] = old_snis
            target_stream["realitySettings"]["dest"] = old_dest or target_stream["realitySettings"]["dest"]
            preserved.append(f"SNI ({','.join(old_snis)})")

        # Строгая гарантия параметров VLESS REALITY (маскировка под свой сайт: Nginx Fallback + Xver=1 + target)
        s_port = globals().get("steal_port", 45443)
        rf_port = globals().get("reality_fallback_port", 9443)
        if port == s_port or tag == "in-steal-reality" or cur_tag == "in-steal-reality":
            fallback_dest = f"127.0.0.1:{rf_port}"
            if not target_stream["realitySettings"].get("dest") or target_stream["realitySettings"]["dest"] != fallback_dest:
                target_stream["realitySettings"]["dest"] = fallback_dest
                repairs.append(f"установлен dest: {fallback_dest} (Nginx SSL Fallback, защита от сброса)")
            else:
                preserved.append(f"anti-loop dest {rf_port}")
            target_stream["realitySettings"]["target"] = fallback_dest
            if target_stream["realitySettings"].get("xver") != 1:
                target_stream["realitySettings"]["xver"] = 1
                repairs.append("установлен xver: 1 (Proxy Protocol для Nginx Anti-Loop)")

        # Строгая гарантия параметров VLESS REALITY (маскировка под внешние сервисы: xver=0, dest: 443, target: 443)
        c_port = globals().get("classic_port", 46443)
        c_sni = globals().get("classic_sni", "avito.ru")
        if port == c_port or tag == "in-classic-reality" or cur_tag == "in-classic-reality":
            if not target_stream["realitySettings"].get("dest"):
                target_stream["realitySettings"]["dest"] = f"{c_sni}:443"
                repairs.append(f"восстановлен пустой dest -> {c_sni}:443")
            target_stream["realitySettings"]["target"] = target_stream["realitySettings"]["dest"]
            target_stream["realitySettings"]["xver"] = 0

    # В. Проверка и ремонт xHTTP
    if protocol == "vless" and "xhttpSettings" in target_stream:
        cur_xh = cur_stream.get("xhttpSettings", {})
        if cur_xh.get("path"):
            target_stream["xhttpSettings"]["path"] = cur_xh["path"]
            preserved.append(f"path ({cur_xh['path']})")
        target_stream["xhttpSettings"]["mode"] = "stream-one"
        if cur_settings.get("decryption") and cur_settings["decryption"] != "none":
            target_settings["decryption"] = cur_settings["decryption"]
            preserved.append("decryption xHTTP")
        if cur_settings.get("encryption"):
            target_settings["encryption"] = cur_settings["encryption"]
            preserved.append("encryption xHTTP")
        elif not target_settings.get("encryption"):
            for c in cur_settings.get("clients", []):
                if c.get("encryption"):
                    target_settings["encryption"] = c["encryption"]
                    preserved.append("encryption xHTTP (из клиентов)")
                    break
        if cur_xh.get("xmux") and isinstance(cur_xh["xmux"], dict):
            target_stream["xhttpSettings"]["xmux"] = cur_xh["xmux"]
            preserved.append("xmux xHTTP")
        if cur_xh.get("noSSEHeader") is not None:
            target_stream["xhttpSettings"]["noSSEHeader"] = cur_xh["noSSEHeader"]
            preserved.append("noSSEHeader xHTTP")
        if cur_xh.get("xPaddingBytes"):
            target_stream["xhttpSettings"]["xPaddingBytes"] = cur_xh["xPaddingBytes"]
            preserved.append(f"xPaddingBytes ({cur_xh['xPaddingBytes']})")
        if target_settings.get("encryption"):
            for c in target_settings.get("clients", []):
                c["encryption"] = target_settings["encryption"]

    # Г. Проверка и ремонт Hysteria 2
    if protocol == "hysteria":
        if cur_settings.get("clients"):
            target_settings["clients"] = cur_settings["clients"]
            preserved.append("пароль Hysteria 2")
        
        cur_certs = cur_stream.get("tlsSettings", {}).get("certificates", [])
        if cur_certs and cur_certs[0].get("certificateFile") and os.path.exists(cur_certs[0]["certificateFile"]):
            target_stream["tlsSettings"]["certificates"] = cur_certs
            preserved.append("действующие SSL-сертификаты Hy2")

    # Д. Проверка и ремонт AmneziaWG
    if protocol == "amneziawg":
        cur_srv = cur_settings.get("server", {})
        if cur_srv.get("privateKey"):
            target_settings["server"]["privateKey"] = cur_srv["privateKey"]
            preserved.append("серверный privateKey AWG")
            
            # Валидация Curve25519
            expected_pub = curve25519_pubkey(cur_srv["privateKey"])
            actual_pub = cur_srv.get("publicKey")
            if actual_pub and expected_pub and actual_pub == expected_pub:
                target_settings["server"]["publicKey"] = actual_pub
                preserved.append("валидный publicKey AWG (Handshake OK)")
            elif expected_pub:
                target_settings["server"]["publicKey"] = expected_pub
                repairs.append("исправлен поврежденный publicKey сервера Curve25519")
        
        # Сохранение параметров обфускации
        for param in [
            "jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4",
            "headerProtectionKey", "randomTrailers", "disableCookies", "mtu", "subnetIp", "subnetCidr",
            "keepaliveTimeout", "rekeyAfterTime", "rekeyTimeout", "rejectAfterTime", "maxHandshakeAttempts",
            "i1", "i2", "i3", "i4", "i5", "contentPaddingAddition", "cpa"
        ]:
            if param in cur_srv:
                target_settings["server"][param] = cur_srv[param]
        if cur_srv.get("headerProtectionKey"):
            preserved.append("HeaderProtectionKey AWG")
        if cur_srv.get("contentPaddingAddition") or cur_srv.get("cpa"):
            preserved.append("ContentPaddingAddition (CPA)")

        # Аудит и оптимизация AmneziaWG (v3.1 и v2.0):
        # 1. RandomTrailers:
        # Для новых профилей по умолчанию отключен (off/False).
        # На существующем инбаунде сохраняем действующее значение сервера, чтобы не нарушать wire-формат клиентов.
        # Принудительно отключается только при явном указании AWG_DISABLE_RANDOM_TRAILERS=1.
        disable_rt = os.environ.get("AWG_DISABLE_RANDOM_TRAILERS", "").strip().lower() in ("1", "y", "true")
        if disable_rt and target_settings["server"].get("randomTrailers"):
            target_settings["server"]["randomTrailers"] = False
            repairs.append("отключен randomTrailers по флагу AWG_DISABLE_RANDOM_TRAILERS")

        # 1.1 Коррекция граничного условия таймингов в 3X-UI: строго max(rekey) < min(reject)
        rekey_val = str(target_settings["server"].get("rekeyAfterTime", ""))
        reject_val = str(target_settings["server"].get("rejectAfterTime", ""))
        if "-" in rekey_val and "-" in reject_val:
            try:
                r_parts = [int(x.strip()) for x in rekey_val.split("-", 1)]
                rej_parts = [int(x.strip()) for x in reject_val.split("-", 1)]
                if r_parts[1] >= rej_parts[0]:
                    new_r_max = max(r_parts[0], rej_parts[0] - 10)
                    target_settings["server"]["rekeyAfterTime"] = f"{r_parts[0]}-{new_r_max}"
                    repairs.append(f"исправлен rekeyAfterTime='{r_parts[0]}-{new_r_max}' (обеспечение max(rekey) < min(reject) для валидатора 3X-UI)")
            except (ValueError, IndexError):
                pass

        # 2. Фиксация базового MTU 1280 (уменьшение риска фрагментации)
        cur_mtu = target_settings["server"].get("mtu")
        try:
            cur_mtu_int = int(cur_mtu) if cur_mtu is not None else 1280
        except (TypeError, ValueError):
            cur_mtu_int = 1280
        if cur_mtu_int > 1280:
            target_settings["server"]["mtu"] = 1280
            repairs.append(f"исправлен MTU={cur_mtu_int} -> 1280 (базовый MTU)")

        # 3. Аудит смещений S1-S4: должны быть >= 12 при активном HeaderProtectionKey
        has_hpk = bool(target_settings["server"].get("headerProtectionKey"))
        if has_hpk:
            s_defaults = {"s1": 16, "s2": 16, "s3": 16, "s4": 16}
            for s_param, min_val in [("s1", 12), ("s2", 12), ("s3", 12), ("s4", 12)]:
                val = target_settings["server"].get(s_param)
                try:
                    val_int = int(val)
                except (TypeError, ValueError):
                    val_int = 0
                if val_int < min_val:
                    target_settings["server"][s_param] = s_defaults[s_param]
                    repairs.append(f"исправлен {s_param}={val} -> {s_defaults[s_param]} (требование HPK: S >= 12)")

        # 4. Валидация мусорных пакетов Jc / Jmin / Jmax (допустимый диапазон Jc: 0-128, J: 0-1280)
        cur_jc = target_settings["server"].get("jc")
        if cur_jc is not None:
            try:
                jc_int = int(cur_jc)
                if jc_int < 0 or jc_int > 128:
                    target_settings["server"]["jc"] = 4
                    repairs.append(f"исправлен Jc={cur_jc} -> 4 (выход за пределы протокола 0-128)")
            except (TypeError, ValueError):
                target_settings["server"]["jc"] = 4
                repairs.append(f"исправлен Jc={cur_jc} -> 4 (некорректное значение)")

        cur_jmin = target_settings["server"].get("jmin")
        cur_jmax = target_settings["server"].get("jmax")
        if cur_jmin is not None and cur_jmax is not None:
            try:
                jmin_int = int(cur_jmin)
                jmax_int = int(cur_jmax)
                if jmin_int < 0 or jmax_int < 0 or jmin_int > jmax_int or jmax_int > 1280:
                    target_settings["server"]["jmin"] = 40
                    target_settings["server"]["jmax"] = 70
                    repairs.append("исправлены некорректные Jmin/Jmax -> Jmin=40, Jmax=70")
            except (TypeError, ValueError):
                target_settings["server"]["jmin"] = 40
                target_settings["server"]["jmax"] = 70
                repairs.append("исправлены нечисловые Jmin/Jmax -> Jmin=40, Jmax=70")

    # Е. Проверка и ремонт Shadowsocks 2022
    if protocol == "shadowsocks":
        ss_method = cur_settings.get("method") or target_settings.get("method", "2022-blake3-aes-256-gcm")
        target_settings["method"] = ss_method
        target_settings["network"] = "tcp,udp"
        target_settings["udpOverTcp"] = True
        target_settings["udp_over_tcp"] = True
        if target_stream.get("network") in ("tcp,udp", "udp"):
            target_stream["network"] = "tcp"
            repairs.append("исправлен network в stream_settings -> 'tcp'")

        # Валидация / сохранение серверного пароля (PSK)
        cur_srv_pwd = cur_settings.get("password")
        if cur_srv_pwd and "validate_ss2022_key" in globals() and validate_ss2022_key(cur_srv_pwd, ss_method):
            target_settings["password"] = cur_srv_pwd
            preserved.append("серверный ключ SS-2022")
        elif "generate_ss2022_key" in globals():
            target_settings["password"] = generate_ss2022_key(ss_method)
            repairs.append("сгенерирован валидный серверный ключ SS-2022 (исправлена ошибка длины)")

        # Аудит клиентов: валидация ключей и очистка устаревшего поля 'method'
        c_repaired = False
        method_removed = False
        for c in target_settings.get("clients", []):
            if "method" in c:
                c.pop("method", None)
                method_removed = True
            c_pwd = c.get("password")
            if not c_pwd or ("validate_ss2022_key" in globals() and not validate_ss2022_key(c_pwd, ss_method)):
                if "generate_ss2022_key" in globals():
                    c["password"] = generate_ss2022_key(ss_method)
                    c_repaired = True
        if method_removed:
            repairs.append("удалено устаревшее поле client.method")
        if c_repaired:
            repairs.append("исправлен невалидный ключ клиента SS-2022")
        elif not any("невалидный ключ" in r for r in repairs):
            preserved.append("ключи клиентов SS-2022")

    # Ж. Проверка и ремонт TUIC v5
    if protocol == "tuic":
        tuic_cert = cur_settings.get("certificate") or target_settings.get("certificate") or globals().get("ssl_cert") or ""
        tuic_key = cur_settings.get("private_key") or target_settings.get("private_key") or globals().get("ssl_key") or ""
        if cur_settings.get("certificate") and cur_settings.get("private_key"):
            target_settings["certificate"] = tuic_cert
            target_settings["private_key"] = tuic_key
            preserved.append("SSL-сертификаты TUIC")
        else:
            target_settings["certificate"] = tuic_cert
            target_settings["private_key"] = tuic_key
            repairs.append("добавлены пути сертификатов в settings TUIC")

        target_settings["congestion_control"] = cur_settings.get("congestion_control") or target_settings.get("congestion_control", "bbr")
        target_settings["alpn"] = cur_settings.get("alpn") or target_settings.get("alpn", ["h3", "spdy/3.1"])
        for tuic_opt in ["udp_relay_mode", "zero_rtt_handshake", "max_idle_time", "authentication_timeout", "max_udp_relay_packet_size", "sni"]:
            if tuic_opt in cur_settings:
                target_settings[tuic_opt] = cur_settings[tuic_opt]
        if cur_settings.get("congestion_control"):
            preserved.append(f"congestion_control ({target_settings['congestion_control']})")
        if cur_settings.get("alpn"):
            preserved.append(f"alpn ({target_settings['alpn']})")

        target_stream["network"] = "quic"
        target_stream["security"] = "tls"

    # З. Проверка и ремонт Telegram MTProxy (FakeTLS)
    if protocol == "mtproto":
        root_cleaned = False
        for obsolete_field in ["secret", "adTag", "ad_tag"]:
            if obsolete_field in cur_settings or obsolete_field in target_settings:
                target_settings.pop(obsolete_field, None)
                root_cleaned = True
        if root_cleaned:
            repairs.append("очищены устаревшие корневые поля secret/adTag в settings MTProto")

        if cur_settings.get("domainFronting"):
            target_settings["domainFronting"] = cur_settings["domainFronting"]
            preserved.append("domainFronting MTProto")

        target_settings["preferIp"] = cur_settings.get("preferIp") or target_settings.get("preferIp") or "prefer-ipv4"
        if target_settings.get("preferIp") == "prefer-ipv4":
            preserved.append("preferIp (prefer-ipv4)")

        mtp_faketls = globals().get("mtproto_faketls_domain") or target_settings.get("domainFronting", {}).get("ip") or "gateway.icloud.com"
        for c in target_settings.get("clients", []):
            c_sec = c.get("secret")
            if not c_sec or ("validate_mtproto_secret" in globals() and not validate_mtproto_secret(c_sec)):
                if "generate_mtproto_secret" in globals():
                    c["secret"] = generate_mtproto_secret(mtp_faketls)
                    repairs.append("исправлен/сгенерирован FakeTLS секрет MTProto")
            else:
                preserved.append("секрет FakeTLS MTProto")
            c_ad = c.get("adTag") or c.get("ad_tag")
            if c_ad:
                if "validate_mtproto_adtag" in globals() and not validate_mtproto_adtag(c_ad):
                    c["adTag"] = ""
                    c.pop("ad_tag", None)
                    repairs.append("очищен невалидный adTag MTProto")
                else:
                    c["adTag"] = c_ad
                    c.pop("ad_tag", None)
                    preserved.append("промо-тег adTag MTProto")

    # И. Проверка и сохранение externalProxy (:443, SNI и кастомных хостов узлов)
    cur_ext = cur_stream.get("externalProxy", [])
    expected_ext_port = 443 if protocol in ("vless", "hysteria") and port != hy2_port else (hy2_port if protocol == "hysteria" else port)

    def_ext = default_stream.get("externalProxy", [])
    def_dest = def_ext[0].get("dest") if (def_ext and isinstance(def_ext, list) and def_ext[0].get("dest")) else domain
    def_sni = def_ext[0].get("sni", "") if (def_ext and isinstance(def_ext, list) and def_ext[0].get("sni")) else ""

    # Сохраняем кастомный хост узла (dest), если он был настроен и не равен localhost
    target_dest = def_dest
    if cur_ext and len(cur_ext) > 0 and cur_ext[0].get("dest"):
        ext_dest = str(cur_ext[0]["dest"]).strip()
        if ext_dest and ext_dest not in ("127.0.0.1", "localhost", "0.0.0.0"):
            target_dest = ext_dest
            if ext_dest != domain and ext_dest != def_dest:
                preserved.append(f"кастомный хост узла ({ext_dest})")

    # Сохраняем SNI для externalProxy (критично для VLESS REALITY и маршрутизации Nginx Stream L4)
    target_sni = def_sni
    if cur_ext and len(cur_ext) > 0 and cur_ext[0].get("sni"):
        ext_sni = str(cur_ext[0]["sni"]).strip()
        if ext_sni:
            target_sni = ext_sni
            if target_sni != def_sni:
                preserved.append(f"кастомный externalProxy SNI ({ext_sni})")

    if protocol in ("shadowsocks", "mtproto", "amneziawg"):
        force_tls_val = "none"
    elif protocol == "vless" and "realitySettings" in target_stream:
        force_tls_val = "same"
    else:
        force_tls_val = "tls"

    ext_entry = {
        "dest": target_dest,
        "port": expected_ext_port,
        "forceTls": force_tls_val,
        "remark": final_remark
    }
    if target_sni:
        ext_entry["sni"] = target_sni
    if def_ext and isinstance(def_ext, list):
        if def_ext[0].get("fingerprint"):
            ext_entry["fingerprint"] = def_ext[0]["fingerprint"]
        if def_ext[0].get("alpn"):
            ext_entry["alpn"] = def_ext[0]["alpn"]

    needs_ext_repair = (
        not cur_ext
        or cur_ext[0].get("port") != expected_ext_port
        or cur_ext[0].get("dest") != target_dest
        or cur_ext[0].get("remark") != final_remark
        or cur_ext[0].get("forceTls") != force_tls_val
        or (target_sni and cur_ext[0].get("sni") != target_sni)
    )

    if needs_ext_repair:
        target_stream["externalProxy"] = [ext_entry]
        sni_desc = f", sni: {target_sni}" if target_sni else ""
        repairs.append(f"исправлен externalProxy -> {target_dest}:{expected_ext_port}{sni_desc}")
    else:
        target_stream["externalProxy"] = cur_ext
        preserved.append(f"externalProxy :{expected_ext_port}")

    # Синхронизация клиентов в реестре (client_traffics, clients, client_inbounds)
    if "sync_inbound_clients" in globals():
        sync_inbound_clients(inbound_id, protocol, final_remark, target_settings, target_stream)

    # Запись в SQLite
    settings_json = json.dumps(target_settings, ensure_ascii=False)
    stream_json = json.dumps(target_stream, ensure_ascii=False)
    sniffing_json = json.dumps({"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"]})

    if not dry_run:
        cur.execute("""
            UPDATE inbounds
            SET protocol = ?, tag = ?, remark = ?, settings = ?, stream_settings = ?, listen = ?, sniffing = ?, enable = ?
            WHERE id = ?
        """, (protocol, tag, final_remark, settings_json, stream_json, listen, sniffing_json, cur_enable, inbound_id))

    status_str = f"  [ОБНОВЛЕН] {final_remark} (порт {port}):"
    if repairs:
        status_str += f"\n    -> Исправлено: {', '.join(repairs)}"
    if preserved:
        status_str += f"\n    -> Сохранено: {', '.join(preserved)}"
    print(status_str)
    return inbound_id


# --- Применение эталонных конфигураций инбаундов с единым клиентом ---

# 1. Steal-Oneself REALITY (45443)
if enable_steal:
    s_set = {"clients": [{"id": unified_uuid, "flow": "xtls-rprx-vision", "email": unified_email, "subId": unified_sub_id, "enable": True}], "decryption": "none", "testseed": [900, 500, 900, 256]}
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
        "externalProxy": [{"dest": domain, "port": 443, "forceTls": "same", "sni": steal_dom, "fingerprint": "firefox", "remark": make_remark("VLESS Steal")}]
    }
    steal_remark = make_remark("VLESS Steal")
    steal_ib_id = smart_reconcile_inbound(steal_port, "vless", "in-steal-reality", steal_remark, s_set, s_str, listen="127.0.0.1")

# 2. Classic REALITY (46443)
if enable_classic:
    c_set = {"clients": [{"id": unified_uuid, "flow": "xtls-rprx-vision", "email": unified_email, "subId": unified_sub_id, "enable": True}], "decryption": "none", "testseed": [900, 500, 900, 256]}
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
        "externalProxy": [{"dest": domain, "port": 443, "forceTls": "same", "sni": classic_sni, "fingerprint": "firefox", "remark": make_remark("VLESS Classic")}]
    }
    classic_remark = make_remark("VLESS Classic")
    classic_ib_id = smart_reconcile_inbound(classic_port, "vless", "in-classic-reality", classic_remark, c_set, c_str, listen="127.0.0.1")

# 3. VLESS xHTTP (50443)
if harvested_vless_dekey and harvested_vless_enkey:
    vless_dekey, vless_enkey = harvested_vless_dekey, harvested_vless_enkey
else:
    vless_dekey, vless_enkey = generate_vlessenc_keypair()

xhttp_client = {"id": unified_uuid, "flow": "", "email": unified_email, "subId": unified_sub_id, "enable": True}
if vless_dekey and vless_enkey:
    xhttp_client["encryption"] = vless_enkey
    x_set = {"clients": [xhttp_client], "decryption": vless_dekey, "encryption": vless_enkey}
else:
    x_set = {"clients": [xhttp_client], "decryption": "none"}
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
    "externalProxy": [{"dest": domain, "port": 443, "forceTls": "tls", "sni": domain, "fingerprint": "firefox", "alpn": "h2", "remark": make_remark("VLESS xHTTP")}]
}
xhttp_remark = make_remark("VLESS xHTTP")
xhttp_ib_id = smart_reconcile_inbound(xhttp_port, "vless", "in-xhttp-stream", xhttp_remark, x_set, x_str, listen="127.0.0.1")

unified_vless_enkey = ""
cur.execute("SELECT settings FROM inbounds WHERE id = ? OR port = ?", (xhttp_ib_id, xhttp_port))
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
    unified_vless_enkey = vless_enkey or ""

# 4. Hysteria 2 (443)
if enable_hy2:
    h_set = {"clients": [{"id": unified_hy2_pass, "auth": unified_hy2_pass, "password": unified_hy2_pass, "email": unified_email, "subId": unified_sub_id, "enable": True}], "version": 2}
    h_str = {
        "network": "hysteria",
        "hysteriaSettings": {"version": 2, "udpIdleTimeout": 60, "masquerade": {"type": "proxy", "url": "http://127.0.0.1:80"}},
        "security": "tls",
        "tlsSettings": {
            "serverName": hy2_domain, "minVersion": "1.3", "maxVersion": "1.3",
            "certificates": [{"certificateFile": hy2_cert, "keyFile": hy2_key}], "alpn": ["h3"]
        },
        "externalProxy": [{"dest": hy2_domain, "port": hy2_port, "forceTls": "tls", "remark": make_remark("Hysteria 2")}]
    }
    hy2_remark = make_remark("Hysteria 2")
    smart_reconcile_inbound(hy2_port, "hysteria", "in-hysteria2", hy2_remark, h_set, h_str, listen="0.0.0.0")

# 5. AmneziaWG v3.1 (8443)
if enable_awg_v3:
    awg_i1_env = os.environ.get("AWG_I1", "").strip()
    if awg_i1_env.lower() == "dns":
        awg_i1_env = "<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>"
    a3_set = {
        "clients": [{
            "privateKey": def_wg_c_priv, "publicKey": def_wg_c_pub,
            "allowedIPs": ["10.8.1.2/32"], "email": unified_email, "subId": unified_sub_id, "enable": True
        }],
        "server": {
            "h1": "1", "h2": "2", "h3": "3", "h4": "4",
            "jc": 4, "jmin": 40, "jmax": 70,
            "s1": 16, "s2": 16, "s3": 16, "s4": 16,
            "mtu": 1280,
            "primaryDns": awg_primary_dns, "secondaryDns": awg_secondary_dns,
            "privateKey": def_wg_s_priv, "publicKey": def_wg_s_pub,
            "headerProtectionKey": unified_awg_hpk,
            "randomTrailers": True,
            "disableCookies": False,
            "keepaliveTimeout": "15-20",
            "rekeyAfterTime": "120-170",
            "rekeyTimeout": "3-4",
            "rejectAfterTime": "180-210",
            "maxHandshakeAttempts": "20-25",
            "subnetCidr": awg_subnet_cidr, "subnetIp": awg_subnet_ip,
            "i1": awg_i1_env
        }
    }
    a3_str = {"externalProxy": [{"dest": domain, "port": awg_v3_port, "remark": make_remark("AmneziaWG v3")}]}
    awg_v3_remark = make_remark("AmneziaWG v3")
    smart_reconcile_inbound(awg_v3_port, "amneziawg", "in-8443-udp", awg_v3_remark, a3_set, a3_str, listen="0.0.0.0")

# 6. AmneziaWG v2.0 (8444)
if enable_awg_v2:
    a2_set = {
        "clients": [{
            "privateKey": def_wg_c_priv, "publicKey": def_wg_c_pub,
            "allowedIPs": ["10.8.2.2/32"], "email": unified_email, "subId": unified_sub_id, "enable": True
        }],
        "server": {
            "h1": "149419586", "h2": "878791997", "h3": "1251051976", "h4": "1657628296",
            "jc": 2, "jmin": 20, "jmax": 50, "mtu": 1280,
            "primaryDns": awg_primary_dns, "secondaryDns": awg_secondary_dns,
            "privateKey": def_wg_s_priv, "publicKey": def_wg_s_pub,
            "s1": 16, "s2": 20, "s3": 24, "s4": 16,
            "subnetCidr": 24, "subnetIp": "10.8.2.0"
        }
    }
    a2_str = {"externalProxy": [{"dest": domain, "port": awg_v2_port, "remark": make_remark("AmneziaWG v2")}]}
    awg_v2_remark = make_remark("AmneziaWG v2")
    smart_reconcile_inbound(awg_v2_port, "amneziawg", "in-awg-v2", awg_v2_remark, a2_set, a2_str, listen="0.0.0.0")

# 7. Shadowsocks 2022 (8388)
if enable_ss2022:
    ss_set = {
        "method": ss_method,
        "password": unified_ss_server_pass,
        "network": "tcp,udp",
        "udpOverTcp": True,
        "udp_over_tcp": True,
        "clients": [{
            "email": unified_email,
            "password": unified_ss_client_pass,
            "subId": unified_sub_id,
            "enable": True
        }]
    }
    ss_ext_proxies = [{"dest": domain, "port": ss2022_port, "forceTls": "none", "remark": make_remark("Shadowsocks 2022")}]
    if enable_shadowtls:
        ss_ext_proxies.append({"dest": domain, "port": shadowtls_port, "forceTls": "tls", "remark": make_remark("ShadowTLS v4 + SS-2022")})
    ss_str = {
        "network": "tcp",
        "security": "none",
        "externalProxy": ss_ext_proxies
    }
    ss_remark = make_remark("Shadowsocks 2022")
    smart_reconcile_inbound(ss2022_port, "shadowsocks", "in-shadowsocks-2022", ss_remark, ss_set, ss_str, listen="0.0.0.0")

# 8. TUIC v5 (8448)
if enable_tuic:
    tuic_set = {
        "certificate": tuic_cert,
        "private_key": tuic_key,
        "congestion_control": "bbr",
        "alpn": ["h3", "spdy/3.1"],
        "udp_relay_mode": "native",
        "zero_rtt_handshake": False,
        "max_idle_time": 15,
        "authentication_timeout": 3,
        "max_udp_relay_packet_size": 1500,
        "sni": domain,
        "clients": [{
            "uuid": unified_tuic_uuid,
            "password": unified_tuic_pass,
            "email": unified_email,
            "subId": unified_sub_id,
            "enable": True
        }]
    }
    tuic_str = {
        "network": "quic",
        "security": "tls",
        "externalProxy": [{"dest": domain, "port": tuic_port, "forceTls": "tls", "remark": make_remark("TUIC v5")}]
    }
    tuic_remark = make_remark("TUIC v5")
    smart_reconcile_inbound(tuic_port, "tuic", "in-tuic-v5", tuic_remark, tuic_set, tuic_str, listen="0.0.0.0")

# 9. Telegram MTProxy FakeTLS (8444)
if enable_mtproto:
    mtp_set = {
        "preferIp": "prefer-ipv4",
        "domainFronting": {
            "ip": mtproto_faketls_domain,
            "port": 443,
            "proxyProtocol": False
        },
        "clients": [{
            "email": unified_email,
            "secret": unified_mtp_secret,
            "adTag": unified_mtp_adtag,
            "subId": unified_sub_id,
            "enable": True
        }]
    }
    mtp_str = {
        "network": "tcp",
        "security": "none",
        "externalProxy": [{"dest": domain, "port": mtproto_port, "forceTls": "none", "remark": make_remark("Telegram MTProxy")}]
    }
    mtp_remark = make_remark("Telegram MTProxy")
    smart_reconcile_inbound(mtproto_port, "mtproto", "in-mtproto-faketls", mtp_remark, mtp_set, mtp_str, listen="0.0.0.0")

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
    s_iid = steal_ib_id if ('steal_ib_id' in locals() and steal_ib_id) else lookup_inbound_id("in-steal-reality", steal_port)
    if s_iid:
        sync_host_entry(s_iid, steal_remark, domain, 443, "same", host_sni=steal_dom, host_fp="firefox", sort_order=1)

if enable_classic:
    c_iid = classic_ib_id if ('classic_ib_id' in locals() and classic_ib_id) else lookup_inbound_id("in-classic-reality", classic_port)
    if c_iid:
        sync_host_entry(c_iid, classic_remark, domain, 443, "same", host_sni=classic_sni, host_fp="firefox", sort_order=1)

x_iid = xhttp_ib_id if ('xhttp_ib_id' in locals() and xhttp_ib_id) else lookup_inbound_id("in-xhttp-stream", xhttp_port)
if x_iid:
    sync_host_entry(x_iid, xhttp_remark, domain, 443, "tls", host_sni=domain, host_path=f"/{xhttp_path.strip('/')}/", host_alpn=json.dumps(["h2"]), host_fp="firefox", sort_order=2)


# Формирование клиентских ссылок для новых протоколов
# SIP002 Base64: ss://BASE64(method:server_psk:user_psk)@host:port#name (совместим с Happ, Shadowrocket, v2rayNG)
raw_ss_userinfo = f"{ss_method}:{unified_ss_server_pass}:{unified_ss_client_pass}"
b64_ss_userinfo = base64.urlsafe_b64encode(raw_ss_userinfo.encode("utf-8")).decode("utf-8").rstrip("=")
ss2022_uri = f"ss://{b64_ss_userinfo}@{domain}:{ss2022_port}#{urllib.parse.quote(make_remark('Shadowsocks 2022'))}"
tuic_uri = f"tuic://{unified_tuic_uuid}:{unified_tuic_pass}@{domain}:{tuic_port}?congestion_control=bbr&alpn=h3&udp_relay_mode=native&sni={domain}#{urllib.parse.quote(make_remark('TUIC v5'))}"
mtproto_tg_uri = f"tg://proxy?server={domain}&port={mtproto_port}&secret={unified_mtp_secret}"
mtproto_https_uri = f"https://t.me/proxy?server={domain}&port={mtproto_port}&secret={unified_mtp_secret}"
mtproto_bot_secret = unified_mtp_secret[2:34] if len(unified_mtp_secret) >= 34 else unified_mtp_secret

# Формирование клиентских реквизитов для протоколов нового поколения (Next-Gen Protocols)
enable_masque = os.environ.get("ENABLE_MASQUE", "n").lower() in ("1", "y", "true")
masque_port = int(os.environ.get("MASQUE_PORT") or "8445")
masque_user = (os.environ.get("MASQUE_USER") or "client").strip()
masque_password = os.environ.get("MASQUE_PASSWORD", "").strip() or unified_ss_client_pass
masque_uri = f"masque://{masque_user}:{masque_password}@{domain}:{masque_port}?alpn=h3#{urllib.parse.quote(make_remark('MASQUE RFC 9484'))}"

enable_shadowtls = os.environ.get("ENABLE_SHADOWTLS", "n").lower() in ("1", "y", "true")
shadowtls_port = int(os.environ.get("SHADOWTLS_PORT") or "8543")
shadowtls_sni = (os.environ.get("SHADOWTLS_SNI") or "gateway.icloud.com").strip()
shadowtls_password = os.environ.get("SHADOWTLS_PASSWORD", "").strip()
shadowtls_uri = f"shadowtls://{shadowtls_password}@{domain}:443?sni={shadowtls_sni}&version=4#{urllib.parse.quote(make_remark('ShadowTLS v4'))}"
ss_shadowtls_uri = f"ss://{b64_ss_userinfo}@{domain}:443?plugin=shadow-tls;host={shadowtls_sni};password={shadowtls_password};version=4#{urllib.parse.quote(make_remark('ShadowTLS + SS-2022'))}"

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
naive_uri = f"naive+https://{naive_user}:{naive_pass}@{naive_domain}:443#{urllib.parse.quote(make_remark('NaïveProxy'))}"

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

if not dry_run:
    try:
        cur.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    except Exception:
        pass
    conn.commit()

    # Сохранение параметров единого клиента во временный файл в /run (tmpfs) с безопасными правами
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
            if enable_ss2022:
                f.write(f"SS2022_URI='{ss2022_uri}'\n")
                f.write(f"SS2022_PORT='{ss2022_port}'\n")
            if enable_tuic:
                f.write(f"TUIC_URI='{tuic_uri}'\n")
                f.write(f"TUIC_PORT='{tuic_port}'\n")
            if enable_mtproto:
                f.write(f"MTPROTO_TG_URI='{mtproto_tg_uri}'\n")
                f.write(f"MTPROTO_HTTPS_URI='{mtproto_https_uri}'\n")
                f.write(f"MTPROTO_SECRET='{unified_mtp_secret}'\n")
                f.write(f"MTPROTO_BOT_SECRET='{mtproto_bot_secret}'\n")
                f.write(f"MTPROTO_PORT='{mtproto_port}'\n")
            if enable_masque:
                f.write(f"MASQUE_URI='{masque_uri}'\n")
                f.write(f"MASQUE_PORT='{masque_port}'\n")
                f.write(f"MASQUE_USER='{masque_user}'\n")
                f.write(f"MASQUE_PASSWORD='{masque_password}'\n")
            if enable_shadowtls:
                f.write(f"SHADOWTLS_URI='{shadowtls_uri}'\n")
                f.write(f"SS_SHADOWTLS_URI='{ss_shadowtls_uri}'\n")
                f.write(f"SHADOWTLS_PORT='{shadowtls_port}'\n")
                f.write(f"SHADOWTLS_SNI='{shadowtls_sni}'\n")
                f.write(f"SHADOWTLS_PASSWORD='{shadowtls_password}'\n")
            if enable_wstunnel and wstunnel_prefix:
                f.write(f"WSTUNNEL_CLI='{wstunnel_cli}'\n")
                f.write(f"WSTUNNEL_URI='{wstunnel_uri}'\n")
                f.write(f"WSTUNNEL_PREFIX='{wstunnel_prefix}'\n")
                f.write(f"WSTUNNEL_PORT='{wstunnel_port}'\n")
            if enable_zapret:
                f.write(f"ZAPRET_INFO='{zapret_info}'\n")
            if enable_naive:
                f.write(f"NAIVE_URI='{naive_uri}'\n")
                f.write(f"NAIVE_PORT='{naive_port}'\n")
                f.write(f"NAIVE_USER='{naive_user}'\n")
                f.write(f"NAIVE_PASS='{naive_pass}'\n")
            if enable_dnstt:
                f.write(f"DNSTT_CLI='{dnstt_cli}'\n")
                f.write(f"DNSTT_PORT='{dnstt_port}'\n")
                f.write(f"DNSTT_DOMAIN='{dnstt_domain}'\n")
                f.write(f"DNSTT_PUBKEY='{dnstt_pubkey}'\n")
        os.umask(old_umask)
        os.chmod(run_file, 0o600)
    except Exception:
        pass

conn.close()
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

    # Очистка устаревших/невалидных geosite меток в bin/config.json во избежание сбоя парсинга ядра Xray
    for cfg_candidate in "/usr/local/x-ui/bin/config.json" "/etc/x-ui/bin/config.json"; do
        if [ -f "$cfg_candidate" ]; then
            sed -i 's/"geosite:ru",*//g; s/"geosite:yandex",*//g; s/"geosite:vk",*//g; s/"geosite:youtube",*//g; s/"geosite:openai",*//g; s/"geosite:google-gemini",*//g; s/"geosite:anthropic",*//g; s/"geosite:cloudflare",*//g' "$cfg_candidate" 2>/dev/null || true
            sed -i 's/,\s*]/]/g; s/,\s*}/}/g' "$cfg_candidate" 2>/dev/null || true
        fi
    done

    # Обновление ядра Xray-core до последней актуальной версии (v26.9.30+)
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
                LATEST_TAG=$(echo "$gh_resp" | { grep -m1 '"tag_name":' || true; } | { cut -d '"' -f 4 || true; }) || LATEST_TAG=""
            fi
        fi
        [ -n "$LATEST_TAG" ] || LATEST_TAG="v26.9.30"
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

    # Возобновление/перезапуск службы 3X-UI
    if [ "${WAS_ACTIVE:-0}" -eq 1 ] || (command -v systemctl >/dev/null 2>&1 && systemctl is-enabled --quiet x-ui 2>/dev/null); then
        log "Перезапуск службы 3X-UI..."
        systemctl restart x-ui && ok "Служба 3X-UI успешно перезапущена." || warn "Не удалось перезапустить службу x-ui."
    fi

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
    echo -e "  - ${BOLD}Панель управления:${NC}      ${CYAN}https://${PRIMARY_DOMAIN}/${PANEL_PATH}/${NC}"
    echo -e "  - ${BOLD}Логин панели:${NC}           ${WHITE}${ADMIN_USERNAME:-admin}${NC}"
    if [ -n "${ADMIN_PASSWORD:-}" ]; then
        echo -e "  - ${BOLD}Пароль панели:${NC}          ${WHITE}${ADMIN_PASSWORD}${NC}"
    fi
    echo -e "  - ${BOLD}Канал подписок:${NC}        ${CYAN}https://${PRIMARY_DOMAIN}/${SUB_PATH#/}/${NC}"
    echo -e "  - ${BOLD}Канал подписок (Clash):${NC}  ${CYAN}https://${PRIMARY_DOMAIN}/${SUB_CLASH_PATH#/}/${NC}"
    if [ -n "${UNIFIED_SUB_ID:-}" ]; then
        echo -e "  - ${BOLD}Прямая подписка:${NC}       ${GREEN}https://${PRIMARY_DOMAIN}/${SUB_PATH#/}/${UNIFIED_SUB_ID}${NC}"
        echo -e "  - ${BOLD}Прямая подписка (Clash):${NC} ${GREEN}https://${PRIMARY_DOMAIN}/${SUB_CLASH_PATH#/}/${UNIFIED_SUB_ID}${NC}"
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
    if [[ "${ENABLE_NODE_TOKEN,,}" == "y" || "${ENABLE_NODE_TOKEN:-}" == "1" ]] && [ -n "${NODE_TOKEN:-}" ]; then
        echo -e "  - ${BOLD}3X-UI Node API:${NC}         ${GREEN}${NODE_TOKEN_NAME}${NC} (Host: ${CYAN}${PRIMARY_DOMAIN}:443${NC}, Path: ${CYAN}/${PANEL_PATH#/}/${NC})"
        echo -e "  - ${BOLD}API Bearer Token:${NC}       ${YELLOW}${NODE_TOKEN}${NC}"
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
Панель управления:     https://${PRIMARY_DOMAIN}/${PANEL_PATH}/
Логин администратора:   ${ADMIN_USERNAME:-admin}
Пароль администратора:  ${ADMIN_PASSWORD}
$([ -n "$INSTALLED_XRAY_VER" ] && echo "Ядро Xray-core:        ${INSTALLED_XRAY_VER}")

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
$([ -n "${NODE_TOKEN:-}" ] && printf "3X-UI Node Token:      %s\nИмя ноды (Node Name):  %s (Host: %s:443, Path: /%s/)\n" "${NODE_TOKEN}" "${NODE_TOKEN_NAME}" "${PRIMARY_DOMAIN}" "${PANEL_PATH#/}")
(Объединяет все конфигурации: Steal REALITY, Classic REALITY, xHTTP, Hysteria 2, AWG v3, AWG v2, SS-2022, TUIC v5, MTProxy, MASQUE, ShadowTLS, Wstunnel, Zapret, NaïveProxy, DNSTT)
=====================================================================
EOF_CRED
        echo -e "  - ${BOLD}Файл с паролями:${NC}        ${CYAN}$CRED_FILE${NC} (chmod 600)"
    elif [ -f "$CRED_FILE" ]; then
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
        echo -e "  - ${BOLD}Файл с паролями:${NC}        ${CYAN}$CRED_FILE${NC} (обновлен, chmod 600)"
    fi
    chmod 600 "$CRED_FILE" 2>/dev/null || true
fi
echo -e "${GREEN}=====================================================================${NC}"
echo
exit 0
