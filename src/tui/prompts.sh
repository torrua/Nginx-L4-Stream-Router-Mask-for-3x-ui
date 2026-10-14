
prompt_default() {
    local prompt_text="$1"
    local default_val="$2"
    local var_name="$3"
    local cur_val="${!var_name:-}"
    local effective_default="${cur_val:-$default_val}"

    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        printf -v "$var_name" '%s' "$effective_default"
        declare -g "$var_name=$effective_default" 2>/dev/null || true
        log "Параметр $var_name: ${GREEN}$effective_default${NC} (авто)"
        return 0
    fi

    local prompt_suffix=" [${GREEN}${effective_default}${NC}]"
    [ -z "$effective_default" ] && prompt_suffix=" [${GREEN}(пусто)${NC}]"
    if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
        prompt_suffix="${prompt_suffix} ${DIM}(b - назад)${NC}"
    fi

    local input_val
    read -rp "$(echo -e "${prompt_text}${prompt_suffix}: ")" input_val </dev/tty || read -r input_val || true
    if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
        if [[ "${input_val,,}" == "b" || "${input_val,,}" == "back" || "${input_val,,}" == "назад" ]]; then
            return 10
        fi
    fi
    local res_val="${input_val:-$effective_default}"
    printf -v "$var_name" '%s' "$res_val"
    declare -g "$var_name=$res_val" 2>/dev/null || true
    return 0
}

prompt_yes_no() {
    local prompt_text="$1"
    local default_val="$2"
    local var_name="$3"
    local cur_val="${!var_name:-}"
    local effective_default="${cur_val:-$default_val}"

    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        case "${effective_default,,}" in
            y|yes|1|true)
                printf -v "$var_name" '%s' "y"
                declare -g "$var_name=y" 2>/dev/null || true
                ;;
            *)
                printf -v "$var_name" '%s' "n"
                declare -g "$var_name=n" 2>/dev/null || true
                ;;
        esac
        log "Выбор $var_name: ${GREEN}${!var_name}${NC} (авто)"
        return 0
    fi

    local hint="y/N"
    case "${effective_default,,}" in
        y|yes|1|true) hint="Y/n" ;;
    esac

    local prompt_suffix=" [${GREEN}${hint}${NC}]"
    if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
        prompt_suffix="${prompt_suffix} ${DIM}(b - назад)${NC}"
    fi

    while true; do
        local input_val
        read -rp "$(echo -e "${prompt_text}${prompt_suffix}: ")" input_val </dev/tty || read -r input_val || true
        if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
            if [[ "${input_val,,}" == "b" || "${input_val,,}" == "back" || "${input_val,,}" == "назад" ]]; then
                return 10
            fi
        fi
        input_val="${input_val:-$effective_default}"
        case "${input_val,,}" in
            y|yes|1|true)
                printf -v "$var_name" '%s' "y"
                declare -g "$var_name=y" 2>/dev/null || true
                return 0
                ;;
            n|no|0|false)
                printf -v "$var_name" '%s' "n"
                declare -g "$var_name=n" 2>/dev/null || true
                return 0
                ;;
            *) warn "Пожалуйста, введите 'y' или 'n' (или 'b' для возврата назад)." ;;
        esac
    done
}

prompt_secret() {
    local prompt_text="$1"
    local default_val="$2"
    local var_name="$3"
    local cur_val="${!var_name:-}"
    local effective_default="${cur_val:-$default_val}"

    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        printf -v "$var_name" '%s' "$effective_default"
        declare -g "$var_name=$effective_default" 2>/dev/null || true
        if [ -n "$effective_default" ]; then
            log "Параметр $var_name: ${GREEN}***скрыто***${NC} (авто)"
        else
            log "Параметр $var_name: ${GREEN}(пусто)${NC} (авто)"
        fi
        return 0
    fi

    local prompt_suffix=" [${GREEN}***${NC}]"
    if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
        prompt_suffix="${prompt_suffix} ${DIM}(b - назад)${NC}"
    fi

    local input_val
    read -rp "$(echo -e "${prompt_text}${prompt_suffix}: ")" input_val </dev/tty || read -r input_val || true
    if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
        if [[ "${input_val,,}" == "b" || "${input_val,,}" == "back" || "${input_val,,}" == "назад" ]]; then
            return 10
        fi
    fi
    local res_val="${input_val:-$effective_default}"
    printf -v "$var_name" '%s' "$res_val"
    declare -g "$var_name=$res_val" 2>/dev/null || true
    return 0
}

validate_path_segment() {
    local val="$1"
    local name="$2"
    if [[ ! "$val" =~ ^[a-zA-Z0-9_/-]+$ ]]; then
        die "Параметр $name ('$val') содержит недопустимые символы. Используйте только латиницу, цифры, дефис, подчеркивание и слэши."
    fi
}

# ----------------- Обработка аргументов командной строки -----------------
CONFIG_FILE=""
NON_INTERACTIVE=${NON_INTERACTIVE:-0}
DEBUG_MODE=${DEBUG_MODE:-0}
EXPERT_MODE=${EXPERT_MODE:-0}
SHOW_TIPS=${SHOW_TIPS:-}
CHECK_MODE=0
GEN_CONFIG=0
FORCE_DNS=${FORCE_DNS:-0}
SAVED_CONFIG_FILE="setup_mask.env"

CLI_PRIMARY_DOMAIN=""
CLI_ADD_WWW=""
CLI_LE_EMAIL=""
CLI_PANEL_PORT=""
CLI_PANEL_PATH=""
CLI_SUB_PATH=""
CLI_SUB_TITLE=""
CLI_XHTTP_STREAM_PATH=""
CLI_ADMIN_USERNAME=""
CLI_ADMIN_PASSWORD=""
CLI_ENABLE_HY2=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: путь к файлу конфигурации."
            CONFIG_FILE="$2"
            shift 2
            ;;
        -y|--yes|--non-interactive)
            NON_INTERACTIVE=1
            shift
            ;;
        --auto)
            NON_INTERACTIVE=1
            EXPRESS_MODE=1
            shift
            ;;
        -d|--domain)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: доменное имя."
            PRIMARY_DOMAIN="$2"
            CLI_PRIMARY_DOMAIN="$2"
            shift 2
            ;;
        --add-www)
            ADD_WWW="y"
            CLI_ADD_WWW="y"
            shift
            ;;
        --no-www)
            ADD_WWW="n"
            CLI_ADD_WWW="n"
            shift
            ;;
        --hy2)
            ENABLE_HY2="y"
            CLI_ENABLE_HY2="y"
            shift
            ;;
        --no-hy2)
            ENABLE_HY2="n"
            CLI_ENABLE_HY2="n"
            shift
            ;;
        -m|--email)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: email."
            LE_EMAIL="$2"
            CLI_LE_EMAIL="$2"
            shift 2
            ;;
        --panel-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт панели."
            PANEL_PORT="$2"
            CLI_PANEL_PORT="$2"
            shift 2
            ;;
        --panel-path)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: путь к панели."
            PANEL_PATH="$2"
            CLI_PANEL_PATH="$2"
            shift 2
            ;;
        --sub-path)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: путь к подпискам."
            SUB_PATH="$2"
            CLI_SUB_PATH="$2"
            shift 2
            ;;
        --sub-title)
            SUB_TITLE="${2:-}"
            CLI_SUB_TITLE="${2:-}"
            shift 2
            ;;
        --xhttp-path)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: путь к xHTTP."
            XHTTP_STREAM_PATH="$2"
            CLI_XHTTP_STREAM_PATH="$2"
            shift 2
            ;;
        -u|--user|--admin-user)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: логин администратора 3X-UI."
            ADMIN_USERNAME="$2"
            CLI_ADMIN_USERNAME="$2"
            shift 2
            ;;
        -p|--pass|--admin-pass)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: пароль администратора 3X-UI."
            ADMIN_PASSWORD="$2"
            CLI_ADMIN_PASSWORD="$2"
            shift 2
            ;;
        -r|--resume)
            RESUME_MODE=1
            shift
            ;;
        --step)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует номер шага (1-$TOTAL_STEPS)."
            RESUME_STEP="$2"
            shift 2
            ;;
        --check|--doctor)
            CHECK_MODE=1
            shift
            ;;
        --express)
            EXPRESS_MODE=1
            shift
            ;;
        --expert)
            EXPERT_MODE=1
            shift
            ;;
        --gen-config)
            GEN_CONFIG=1
            if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                TARGET_GEN_FILE="$2"
                shift 2
            else
                TARGET_GEN_FILE="setup_mask.env.example"
                shift
            fi
            ;;
        --debug)
            DEBUG_MODE=1
            shift
            ;;
        -f|--force)
            FORCE_DNS=1
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

# Автообнаружение конфигурационного файла, если путь не передан явно
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
if [ -z "$CONFIG_FILE" ]; then
    if [ -f "./setup_mask.env" ]; then
        CONFIG_FILE="./setup_mask.env"
        log "Автообнаружен конфигурационный файл: $CONFIG_FILE"
    elif [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/setup_mask.env" ]; then
        CONFIG_FILE="$SCRIPT_DIR/setup_mask.env"
        log "Автообнаружен конфигурационный файл: $CONFIG_FILE"
    elif [ -f "/etc/setup_mask.env" ]; then
        CONFIG_FILE="/etc/setup_mask.env"
        log "Автообнаружен конфигурационный файл: $CONFIG_FILE"
    elif [ "$NON_INTERACTIVE" -eq 0 ] && [ -f "./.env" ]; then
        # В неинтерактивном режиме .env не загружается автоматически — только setup_mask.env
        CONFIG_FILE="./.env"
        warn "Автообнаружен конфигурационный файл: $CONFIG_FILE (убедитесь, что он предназначен для этого скрипта)"
    fi
fi

if [ -n "$CONFIG_FILE" ]; then
    load_env_file "$CONFIG_FILE"
fi

# Явные аргументы командной строки имеют абсолютный приоритет над файлом конфигурации
[ -n "${CLI_PRIMARY_DOMAIN:-}" ] && PRIMARY_DOMAIN="$CLI_PRIMARY_DOMAIN"
[ -n "${CLI_ADD_WWW:-}" ]        && ADD_WWW="$CLI_ADD_WWW"
[ -n "${CLI_LE_EMAIL:-}" ]       && LE_EMAIL="$CLI_LE_EMAIL"
[ -n "${CLI_PANEL_PORT:-}" ]     && PANEL_PORT="$CLI_PANEL_PORT"
[ -n "${CLI_PANEL_PATH:-}" ]     && PANEL_PATH="$CLI_PANEL_PATH"
[ -n "${CLI_SUB_PATH:-}" ]       && SUB_PATH="$CLI_SUB_PATH"
[ -n "${CLI_SUB_TITLE:-}" ]      && SUB_TITLE="$CLI_SUB_TITLE"
[ -n "${CLI_XHTTP_STREAM_PATH:-}" ] && XHTTP_STREAM_PATH="$CLI_XHTTP_STREAM_PATH"
[ -n "${CLI_ADMIN_USERNAME:-}" ] && ADMIN_USERNAME="$CLI_ADMIN_USERNAME"
[ -n "${CLI_ADMIN_PASSWORD:-}" ] && ADMIN_PASSWORD="$CLI_ADMIN_PASSWORD"
[ -n "${CLI_ENABLE_HY2:-}" ]      && ENABLE_HY2="$CLI_ENABLE_HY2"

# Сессия всегда сохраняется в setup_mask.env в текущей папке или рядом со скриптом
SAVED_CONFIG_FILE="${CONFIG_FILE:-./setup_mask.env}"

