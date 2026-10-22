
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

can_use_interactive_tui() {
    [ "${NON_INTERACTIVE:-0}" -eq 1 ] && return 1
    [ -t 1 ] || return 1
    ([ -t 0 ] || { : </dev/tty; } 2>/dev/null) || return 1
    local term="${TERM:-dumb}"
    [ "$term" != "dumb" ] && [ -n "$term" ] || return 1
    if command -v tput >/dev/null 2>&1; then
        tput cuu1 >/dev/null 2>&1 || return 1
    fi
    return 0
}

prompt_multiselect_numeric() {
    local prompt_text="$1"
    local -n _num_keys="$2"
    local -n _num_labels="$3"
    local count="${#_num_keys[@]}"

    echo ""
    echo -e "  ${WHITE}${BOLD}${prompt_text}:${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"

    local sel=()
    local def_indices=()
    for ((i=0; i<count; i++)); do
        local k="${_num_keys[$i]}"
        if is_true "${!k:-n}"; then
            sel[i]=1
            def_indices+=("$((i+1))")
        else
            sel[i]=0
        fi
    done

    for ((i=0; i<count; i++)); do
        local mark=" "
        [ "${sel[$i]}" -eq 1 ] && mark="${GREEN}✔${NC}"
        local num=$((i+1))
        echo -e "    ${CYAN}[$num]${NC} [${mark}] ${_num_labels[$i]}"
    done
    echo ""

    local def_str=""
    if [ "${#def_indices[@]}" -gt 0 ]; then
        def_str=$(IFS=,; echo "${def_indices[*]}")
    else
        def_str="0"
    fi

    local prompt_hint=" [${GREEN}${def_str}${NC}]"
    if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
        prompt_hint="${prompt_hint} ${DIM}(b - назад)${NC}"
    fi

    while true; do
        local input_val=""
        echo -ne "  ${WHITE}${ARROW} Номера через запятую/пробел, 'all' или '0'${prompt_hint}: ${NC}"
        read -r input_val </dev/tty || read -r input_val || true
        input_val=$(echo "${input_val:-}" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
            if [[ "$input_val" == "b" || "$input_val" == "back" || "$input_val" == "назад" ]]; then
                return 10
            fi
        fi

        if [ -z "$input_val" ]; then
            break
        fi

        if [[ "$input_val" == "all" || "$input_val" == "a" || "$input_val" == "все" ]]; then
            for ((i=0; i<count; i++)); do sel[i]=1; done
            break
        elif [[ "$input_val" == "0" || "$input_val" == "none" || "$input_val" == "нет" ]]; then
            for ((i=0; i<count; i++)); do sel[i]=0; done
            break
        fi

        local valid=1
        local new_sel=()
        for ((i=0; i<count; i++)); do new_sel[i]=0; done

        IFS=', ' read -ra tokens <<< "${input_val//,/ }"
        for tok in "${tokens[@]}"; do
            [ -z "$tok" ] && continue
            if [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le "$count" ]; then
                new_sel[$((tok-1))]=1
            else
                warn "  Некорректный номер: '$tok'. Введите числа от 1 до $count."
                valid=0
                break
            fi
        done

        if [ "$valid" -eq 1 ]; then
            for ((i=0; i<count; i++)); do sel[i]="${new_sel[$i]}"; done
            break
        fi
    done

    local chosen=()
    for ((i=0; i<count; i++)); do
        local k="${_num_keys[$i]}"
        if [ "${sel[$i]}" -eq 1 ]; then
            printf -v "$k" '%s' "y"
            declare -g "$k=y" 2>/dev/null || true
            chosen+=("${_num_labels[$i]%% (*}")
        else
            printf -v "$k" '%s' "n"
            declare -g "$k=n" 2>/dev/null || true
        fi
    done

    if [ "${#chosen[@]}" -gt 0 ]; then
        ok "Выбрано: $(IFS=,; echo "${chosen[*]}")"
    else
        log "Все протоколы из списка отключены."
    fi
    echo ""
    return 0
}

prompt_multiselect_tui() {
    # Menu labels are UTF-8; clipping must count characters even on LANG=C hosts.
    local LC_ALL=C.UTF-8
    local prompt_text="$1"
    local -n _tui_keys="$2"
    local -n _tui_labels="$3"
    local count="${#_tui_keys[@]}"

    local sel=()
    for ((i=0; i<count; i++)); do
        local k="${_tui_keys[$i]}"
        if is_true "${!k:-n}"; then
            sel[i]=1
        else
            sel[i]=0
        fi
    done

    echo ""
    echo -e "  ${WHITE}${BOLD}${prompt_text}:${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"

    local cursor=0
    local total_lines=$((count + 1))

    # Keep one input descriptor open, including curl | bash installations.
    local input_fd tty_settings=""
    if { exec {input_fd}</dev/tty; } 2>/dev/null; then
        :
    else
        exec {input_fd}<&0
    fi
    if [ -t "$input_fd" ]; then
        tty_settings=$(stty -g <&"$input_fd" 2>/dev/null) || tty_settings=""
        if [ -n "$tty_settings" ]; then
            stty -echo -icanon min 1 time 0 <&"$input_fd" 2>/dev/null || true
        fi
    fi
    local saved_int_trap saved_term_trap
    saved_int_trap=$(trap -p INT)
    saved_term_trap=$(trap -p TERM)
    tput civis 2>/dev/null || printf '\033[?25l'
    trap '[ -z "${tty_settings:-}" ] || stty "$tty_settings" <&"$input_fd" 2>/dev/null; tput cnorm 2>/dev/null || printf "\033[?25h"; exit 130' INT
    trap '[ -z "${tty_settings:-}" ] || stty "$tty_settings" <&"$input_fd" 2>/dev/null; tput cnorm 2>/dev/null || printf "\033[?25h"; exit 143' TERM

    render_tui_menu() {
        local cols="${COLUMNS:-}"
        if [[ ! "$cols" =~ ^[0-9]+$ ]]; then
            cols=$(tput cols 2>/dev/null || echo 80)
        fi
        [[ "$cols" =~ ^[0-9]+$ ]] && [ "$cols" -ge 20 ] || cols=80
        local num_width="${#count}"
        local label_width=$((cols - num_width - 12))
        local i
        for ((i=0; i<count; i++)); do
            local mark=" "
            [ "${sel[$i]}" -eq 1 ] && mark="${GREEN}✔${NC}"
            local prefix="  "
            local color="${WHITE}"
            if [ "$i" -eq "$cursor" ]; then
                prefix="${CYAN}${ARROW}${NC} "
                color="${CYAN}${BOLD}"
            fi
            local num=$((i+1))
            local label="${_tui_labels[$i]}"
            if [ "${#label}" -gt "$label_width" ]; then
                label="${label:0:label_width-1}…"
            fi
            printf "\033[2K  %b[${color}%*s${NC}] [%b] %s\n" "$prefix" "$num_width" "$num" "$mark" "$label"
        done
        local hint="↑/↓: курсор | Пробел: выбор | Enter: готово | ?: номера"
        printf "\033[2K  ${DIM}%s${NC}\n" "${hint:0:cols-3}"
    }

    render_tui_menu

    local result=0 numeric_fallback=0 escape=""
    while true; do
        local key=""
        if ! IFS= read -rsn1 -u "$input_fd" key; then
            result=1
            break
        fi

        # Preserve escape-parser state between reads; SSH packet boundaries and
        # latency must not turn the final B of an arrow into the Back shortcut.
        if [ "$key" = $'\x1b' ]; then
            escape="$key"
            continue
        fi
        if [ "$escape" = $'\x1b' ]; then
            case "$key" in
                '['|O) escape="$key" ;;
                ''|$'\r') break ;;
                *) escape="" ;;
            esac
            continue
        fi
        if [ -n "$escape" ]; then
            escape+="$key"
            if [ -z "$key" ] || [ "$key" = $'\r' ] || [ "${#escape}" -gt 32 ]; then
                escape=""
                continue
            fi
            [[ "$key" == [@-~] ]] || continue
            case "$escape" in
                '['*A|OA) cursor=$(( (cursor - 1 + count) % count )) ;;
                '['*B|OB) cursor=$(( (cursor + 1) % count )) ;;
            esac
            escape=""
        elif [[ "$key" == "k" || "$key" == "K" ]]; then
            cursor=$(( (cursor - 1 + count) % count ))
        elif [[ "$key" == "j" || "$key" == "J" ]]; then
            cursor=$(( (cursor + 1) % count ))
        elif [ "$key" = " " ]; then
            if [ "${sel[$cursor]}" -eq 1 ]; then
                sel[$cursor]=0
            else
                sel[$cursor]=1
            fi
        elif [[ "$key" =~ ^[1-9]$ ]] && [ "$key" -le "$count" ]; then
            local idx=$((key - 1))
            if [ "${sel[$idx]}" -eq 1 ]; then
                sel[$idx]=0
            else
                sel[$idx]=1
            fi
        elif [[ "$key" == "a" || "$key" == "A" ]]; then
            for ((i=0; i<count; i++)); do sel[i]=1; done
        elif [[ "$key" == "0" || "$key" == "n" || "$key" == "N" ]]; then
            for ((i=0; i<count; i++)); do sel[i]=0; done
        elif [ -z "$key" ] || [ "$key" = $'\r' ]; then
            break
        elif [[ "$key" == "b" || "$key" == "B" ]]; then
            if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
                result=10
                break
            fi
        elif [ "$key" = "?" ]; then
            numeric_fallback=1
            break
        fi

        printf "\033[%dA\r" "$total_lines"
        render_tui_menu
    done

    [ -z "$tty_settings" ] || stty "$tty_settings" <&"$input_fd" 2>/dev/null || true
    exec {input_fd}<&-
    tput cnorm 2>/dev/null || printf '\033[?25h'
    trap - INT TERM
    # These strings come from Bash's own trap -p, not from external input.
    [ -z "$saved_int_trap" ] || eval "$saved_int_trap"
    [ -z "$saved_term_trap" ] || eval "$saved_term_trap"

    printf "\033[%dA\r" "$total_lines"
    for ((i=0; i<total_lines; i++)); do
        printf "\033[2K\n"
    done
    printf "\033[%dA\r" "$total_lines"

    [ "$result" -eq 0 ] || return "$result"
    if [ "$numeric_fallback" -eq 1 ]; then
        prompt_multiselect_numeric "$prompt_text" "$2" "$3"
        return $?
    fi

    local chosen=()
    for ((i=0; i<count; i++)); do
        local k="${_tui_keys[$i]}"
        if [ "${sel[$i]}" -eq 1 ]; then
            printf -v "$k" '%s' "y"
            declare -g "$k=y" 2>/dev/null || true
            chosen+=("${_tui_labels[$i]%% (*}")
        else
            printf -v "$k" '%s' "n"
            declare -g "$k=n" 2>/dev/null || true
        fi
    done

    if [ "${#chosen[@]}" -gt 0 ]; then
        ok "Выбрано: $(IFS=,; echo "${chosen[*]}")"
    else
        log "Все протоколы из списка отключены."
    fi
    echo ""
    return 0
}

prompt_multiselect() {
    local prompt_text="$1"
    local -n _ms_keys="$2"
    local -n _ms_labels="$3"

    if [ "${NON_INTERACTIVE:-0}" -eq 1 ]; then
        for _k in "${_ms_keys[@]}"; do
            log "Выбор $_k: ${GREEN}${!_k:-n}${NC} (авто)"
        done
        return 0
    fi

    # Use arrow navigation automatically on an interactive terminal. Setting
    # ENABLE_TUI_MULTISELECT=0 explicitly retains the numeric selector.
    if [ "${ENABLE_TUI_MULTISELECT:-1}" != "0" ] && can_use_interactive_tui; then
        prompt_multiselect_tui "$prompt_text" _ms_keys _ms_labels || return $?
    else
        prompt_multiselect_numeric "$prompt_text" _ms_keys _ms_labels || return $?
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
ROTATE_PATHS=0
FORCE_DNS=${FORCE_DNS:-0}
PORTS_SETUP_MODE="${PORTS_SETUP_MODE:-0}"
PATHS_SETUP_MODE="${PATHS_SETUP_MODE:-0}"
SAVED_CONFIG_FILE="server-setup.env"

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
CLI_ENABLE_NODE_TOKEN=""
CLI_NODE_TOKEN_NAME=""
CLI_ENABLE_HY2=""
CLI_ENABLE_AWG_V3=""
CLI_AWG_V3_PORT=""
CLI_ENABLE_AWG_V2=""
CLI_AWG_V2_PORT=""
CLI_ENABLE_AWG_STANDALONE=""
CLI_AWG_STANDALONE_PORT=""
CLI_ENABLE_SS2022=""
CLI_SS2022_PORT=""
CLI_ENABLE_TUIC=""
CLI_TUIC_PORT=""
CLI_ENABLE_MTPROTO=""
CLI_MTPROTO_PORT=""
CLI_MTPROTO_FAKETLS_DOMAIN=""
CLI_MTPROTO_ADTAG=""
CLI_ENABLE_WEB_STACK=""
CLI_AWG_SERVER_HOST=""
CLI_ENABLE_MASQUE=""
CLI_MASQUE_PORT=""
CLI_ENABLE_SHADOWTLS=""
CLI_SHADOWTLS_PORT=""
CLI_SHADOWTLS_SNI=""
CLI_SHADOWTLS_PASSWORD=""
CLI_ENABLE_WSTUNNEL=""
CLI_WSTUNNEL_PORT=""
CLI_WSTUNNEL_PREFIX=""
CLI_ENABLE_ZAPRET=""
CLI_ZAPRET_QNUM=""
CLI_ENABLE_NAIVE=""
CLI_NAIVE_PORT=""
CLI_NAIVE_DOMAIN=""
CLI_NAIVE_USER=""
CLI_NAIVE_PASS=""
CLI_ENABLE_DNSTT=""
CLI_DNSTT_PORT=""
CLI_DNSTT_DOMAIN=""
CLI_DNSTT_PUBKEY=""
CLI_ENABLE_MIERU=""
CLI_MIERU_PORT_MODE=""
CLI_MIERU_PORT=""
CLI_MIERU_TRANSPORT=""
CLI_MIERU_USER=""
CLI_MIERU_PASS=""
CLI_ALL_PROTOCOLS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --node-token)
            CLI_ENABLE_NODE_TOKEN=y
            shift
            ;;
        --no-node-token)
            CLI_ENABLE_NODE_TOKEN=n
            shift
            ;;
        --node-token-name)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует имя API-ключа ноды."
            CLI_NODE_TOKEN_NAME="$2"
            shift 2
            ;;
        --rotate-paths)
            ROTATE_PATHS=1
            shift
            ;;
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
        --awg-v3|--enable-awg-v3)
            ENABLE_AWG_V3="y"
            CLI_ENABLE_AWG_V3="y"
            shift
            ;;
        --no-awg-v3|--disable-awg-v3)
            ENABLE_AWG_V3="n"
            CLI_ENABLE_AWG_V3="n"
            shift
            ;;
        --awg-v3-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт AmneziaWG v3."
            AWG_V3_PORT="$2"
            CLI_AWG_V3_PORT="$2"
            shift 2
            ;;
        --awg-v2|--enable-awg-v2)
            ENABLE_AWG_V2="y"
            CLI_ENABLE_AWG_V2="y"
            shift
            ;;
        --no-awg-v2|--disable-awg-v2)
            ENABLE_AWG_V2="n"
            CLI_ENABLE_AWG_V2="n"
            shift
            ;;
        --awg-v2-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт AmneziaWG v2."
            AWG_V2_PORT="$2"
            CLI_AWG_V2_PORT="$2"
            shift 2
            ;;
        --awg-standalone|--enable-awg-standalone)
            ENABLE_AWG_STANDALONE="y"
            CLI_ENABLE_AWG_STANDALONE="y"
            shift
            ;;
        --no-awg-standalone|--disable-awg-standalone)
            ENABLE_AWG_STANDALONE="n"
            CLI_ENABLE_AWG_STANDALONE="n"
            shift
            ;;
        --awg-standalone-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт автономного AmneziaWG."
            AWG_STANDALONE_PORT="$2"
            CLI_AWG_STANDALONE_PORT="$2"
            shift 2
            ;;
        --awg-host)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: хост/IP для подключения клиентов AmneziaWG."
            AWG_SERVER_HOST="$2"
            CLI_AWG_SERVER_HOST="$2"
            shift 2
            ;;
        --web-stack|--enable-web-stack)
            ENABLE_WEB_STACK="y"
            CLI_ENABLE_WEB_STACK="y"
            shift
            ;;
        --no-web-stack|--disable-web-stack)
            ENABLE_WEB_STACK="n"
            CLI_ENABLE_WEB_STACK="n"
            shift
            ;;
        --ss2022|--enable-ss2022)
            ENABLE_SS2022="y"
            CLI_ENABLE_SS2022="y"
            shift
            ;;
        --no-ss2022|--disable-ss2022)
            ENABLE_SS2022="n"
            CLI_ENABLE_SS2022="n"
            shift
            ;;
        --ss2022-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт Shadowsocks 2022."
            SS2022_PORT="$2"
            CLI_SS2022_PORT="$2"
            shift 2
            ;;
        --tuic|--enable-tuic)
            ENABLE_TUIC="y"
            CLI_ENABLE_TUIC="y"
            shift
            ;;
        --no-tuic|--disable-tuic)
            ENABLE_TUIC="n"
            CLI_ENABLE_TUIC="n"
            shift
            ;;
        --tuic-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт TUIC."
            TUIC_PORT="$2"
            CLI_TUIC_PORT="$2"
            shift 2
            ;;
        --mtproto|--enable-mtproto)
            ENABLE_MTPROTO="y"
            CLI_ENABLE_MTPROTO="y"
            shift
            ;;
        --no-mtproto|--disable-mtproto)
            ENABLE_MTPROTO="n"
            CLI_ENABLE_MTPROTO="n"
            shift
            ;;
        --mtproto-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт MTProxy."
            MTPROTO_PORT="$2"
            CLI_MTPROTO_PORT="$2"
            shift 2
            ;;
        --mtproto-domain)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: FakeTLS домен MTProxy."
            MTPROTO_FAKETLS_DOMAIN="$2"
            CLI_MTPROTO_FAKETLS_DOMAIN="$2"
            shift 2
            ;;
        --mtproto-adtag)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: промо-тег adTag."
            MTPROTO_ADTAG="$2"
            CLI_MTPROTO_ADTAG="$2"
            shift 2
            ;;
        --masque|--enable-masque)
            ENABLE_MASQUE="y"
            CLI_ENABLE_MASQUE="y"
            shift
            ;;
        --no-masque|--disable-masque)
            ENABLE_MASQUE="n"
            CLI_ENABLE_MASQUE="n"
            shift
            ;;
        --masque-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт MASQUE."
            MASQUE_PORT="$2"
            CLI_MASQUE_PORT="$2"
            shift 2
            ;;
        --shadowtls|--enable-shadowtls)
            ENABLE_SHADOWTLS="y"
            CLI_ENABLE_SHADOWTLS="y"
            shift
            ;;
        --no-shadowtls|--disable-shadowtls)
            ENABLE_SHADOWTLS="n"
            CLI_ENABLE_SHADOWTLS="n"
            shift
            ;;
        --shadowtls-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт ShadowTLS."
            SHADOWTLS_PORT="$2"
            CLI_SHADOWTLS_PORT="$2"
            shift 2
            ;;
        --shadowtls-sni)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: SNI ShadowTLS."
            SHADOWTLS_SNI="$2"
            CLI_SHADOWTLS_SNI="$2"
            shift 2
            ;;
        --shadowtls-pass|--shadowtls-password)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: пароль ShadowTLS."
            SHADOWTLS_PASSWORD="$2"
            CLI_SHADOWTLS_PASSWORD="$2"
            shift 2
            ;;
        --wstunnel|--enable-wstunnel)
            ENABLE_WSTUNNEL="y"
            CLI_ENABLE_WSTUNNEL="y"
            shift
            ;;
        --no-wstunnel|--disable-wstunnel)
            ENABLE_WSTUNNEL="n"
            CLI_ENABLE_WSTUNNEL="n"
            shift
            ;;
        --wstunnel-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт Wstunnel."
            WSTUNNEL_PORT="$2"
            CLI_WSTUNNEL_PORT="$2"
            shift 2
            ;;
        --wstunnel-prefix|--wstunnel-path)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: путь Wstunnel."
            WSTUNNEL_PREFIX="$2"
            CLI_WSTUNNEL_PREFIX="$2"
            shift 2
            ;;
        --zapret|--enable-zapret)
            ENABLE_ZAPRET="y"
            CLI_ENABLE_ZAPRET="y"
            shift
            ;;
        --no-zapret|--disable-zapret)
            ENABLE_ZAPRET="n"
            CLI_ENABLE_ZAPRET="n"
            shift
            ;;
        --zapret-qnum)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: номер очереди NFQUEUE для Zapret."
            ZAPRET_QNUM="$2"
            CLI_ZAPRET_QNUM="$2"
            shift 2
            ;;
        --naive|--enable-naive)
            ENABLE_NAIVE="y"
            CLI_ENABLE_NAIVE="y"
            shift
            ;;
        --no-naive|--disable-naive)
            ENABLE_NAIVE="n"
            CLI_ENABLE_NAIVE="n"
            shift
            ;;
        --naive-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт NaïveProxy."
            NAIVE_PORT="$2"
            CLI_NAIVE_PORT="$2"
            shift 2
            ;;
        --naive-domain)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: SNI домен NaïveProxy."
            NAIVE_DOMAIN="$2"
            CLI_NAIVE_DOMAIN="$2"
            shift 2
            ;;
        --naive-user)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: имя пользователя NaïveProxy."
            NAIVE_USER="$2"
            CLI_NAIVE_USER="$2"
            shift 2
            ;;
        --naive-pass|--naive-password)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: пароль NaïveProxy."
            NAIVE_PASS="$2"
            CLI_NAIVE_PASS="$2"
            shift 2
            ;;
        --dnstt|--enable-dnstt)
            ENABLE_DNSTT="y"
            CLI_ENABLE_DNSTT="y"
            shift
            ;;
        --no-dnstt|--disable-dnstt)
            ENABLE_DNSTT="n"
            CLI_ENABLE_DNSTT="n"
            shift
            ;;
        --dnstt-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: UDP порт DNSTT."
            DNSTT_PORT="$2"
            CLI_DNSTT_PORT="$2"
            shift 2
            ;;
        --dnstt-domain)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: домен зоны DNSTT."
            DNSTT_DOMAIN="$2"
            CLI_DNSTT_DOMAIN="$2"
            shift 2
            ;;
        --dnstt-pubkey)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: публичный ключ DNSTT."
            DNSTT_PUBKEY="$2"
            CLI_DNSTT_PUBKEY="$2"
            shift 2
            ;;
        --mieru|--enable-mieru)
            ENABLE_MIERU="y"
            CLI_ENABLE_MIERU="y"
            shift
            ;;
        --no-mieru|--disable-mieru)
            ENABLE_MIERU="n"
            CLI_ENABLE_MIERU="n"
            shift
            ;;
        --mieru-port-mode)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: single или range."
            MIERU_PORT_MODE="$2"
            CLI_MIERU_PORT_MODE="$2"
            shift 2
            ;;
        --mieru-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт или диапазон Mieru (например 8450 или 8450-8455)."
            MIERU_PORT="$2"
            CLI_MIERU_PORT="$2"
            shift 2
            ;;
        --mieru-transport)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: транспорт Mieru (TCP, UDP, BOTH)."
            MIERU_TRANSPORT="$2"
            CLI_MIERU_TRANSPORT="$2"
            shift 2
            ;;
        --mieru-user)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: имя пользователя Mieru."
            MIERU_USER="$2"
            CLI_MIERU_USER="$2"
            shift 2
            ;;
        --mieru-pass|--mieru-password)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: пароль Mieru."
            MIERU_PASS="$2"
            CLI_MIERU_PASS="$2"
            shift 2
            ;;
        --all-protocols|--all-proto)
            CLI_ALL_PROTOCOLS="1"
            ALL_PROTOCOLS="1"
            ENABLE_HY2="y"; CLI_ENABLE_HY2="y"
            ENABLE_AWG_V3="y"; CLI_ENABLE_AWG_V3="y"
            ENABLE_SS2022="y"; CLI_ENABLE_SS2022="y"
            ENABLE_TUIC="y"; CLI_ENABLE_TUIC="y"
            ENABLE_MTPROTO="y"; CLI_ENABLE_MTPROTO="y"
            ENABLE_MASQUE="y"; CLI_ENABLE_MASQUE="y"
            ENABLE_SHADOWTLS="y"; CLI_ENABLE_SHADOWTLS="y"
            ENABLE_WSTUNNEL="y"; CLI_ENABLE_WSTUNNEL="y"
            ENABLE_ZAPRET="y"; CLI_ENABLE_ZAPRET="y"
            ENABLE_NAIVE="y"; CLI_ENABLE_NAIVE="y"
            ENABLE_DNSTT="y"; CLI_ENABLE_DNSTT="y"
            ENABLE_MIERU="y"; CLI_ENABLE_MIERU="y"
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
        --manual-steps)
            SHOW_MANUAL_STEPS=1
            shift
            ;;
        --gen-config)
            GEN_CONFIG=1
            if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                TARGET_GEN_FILE="$2"
                shift 2
            else
                TARGET_GEN_FILE="server-setup.env.example"
                shift
            fi
            ;;
        --debug)
            DEBUG_MODE=1
            shift
            ;;
        --dry-run)
            echo -e "\n  ${YELLOW}${BOLD}[INFO] Режим --dry-run не поддерживается установщиком setup.sh.${NC}"
            echo -e "  Развертывание ОС и сетевого стека требует реальных изменений системы.\n"
            echo -e "  ${CYAN}Для безопасного аудита без внесения изменений используйте:${NC}"
            echo -e "    • ${WHITE}./setup.sh --check${NC}         (быстрая диагностика сервисов, портов, SSL)"
            echo -e "    • ${WHITE}./maintain.sh --dry-run${NC}    (холостой аудит базы 3X-UI и конфигов Nginx)\n"
            exit 0
            ;;
        --uninstall)
            if command -v run_uninstall >/dev/null 2>&1; then
                run_uninstall
                exit 0
            else
                die "Модуль деинсталляции недоступен."
            fi
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
    CONFIG_FILE=$(find_config_file "$SCRIPT_DIR" || true)
    if [ -n "$CONFIG_FILE" ]; then
        log "Автообнаружен конфигурационный файл: $CONFIG_FILE"
    elif [ "$NON_INTERACTIVE" -eq 0 ] && [ -f "./.env" ]; then
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
[ -n "${CLI_ENABLE_NODE_TOKEN:-}" ] && ENABLE_NODE_TOKEN="$CLI_ENABLE_NODE_TOKEN"
[ -n "${CLI_NODE_TOKEN_NAME:-}" ] && NODE_TOKEN_NAME="$CLI_NODE_TOKEN_NAME"
if [ -n "${CLI_PANEL_PATH:-}" ]; then
    RAW_PATH="${CLI_PANEL_PATH#/}"; RAW_PATH="${RAW_PATH%/}"
fi
if [ -n "${CLI_SUB_PATH:-}" ]; then
    RAW_SUB_PATH="${CLI_SUB_PATH#/}"; RAW_SUB_PATH="${RAW_SUB_PATH%/}"
    SUB_PATH="/${RAW_SUB_PATH}/"
    SUB_JSON_PATH="${SUB_PATH}json/"
    if [ -z "${CONFIG_EXPLICIT_KEYS[SUB_CLASH_PATH]:-}" ]; then
        SUB_CLASH_PATH="${SUB_PATH}clash/"
    fi
fi
if [ -n "${CLI_XHTTP_STREAM_PATH:-}" ]; then
    RAW_XHTTP_STREAM_PATH="${CLI_XHTTP_STREAM_PATH#/}"
    RAW_XHTTP_STREAM_PATH="${RAW_XHTTP_STREAM_PATH%/}"
fi
[ -n "${CLI_ENABLE_HY2:-}" ]      && ENABLE_HY2="$CLI_ENABLE_HY2"
[ -n "${CLI_ENABLE_AWG_V3:-}" ]   && ENABLE_AWG_V3="$CLI_ENABLE_AWG_V3"
[ -n "${CLI_AWG_V3_PORT:-}" ]     && AWG_V3_PORT="$CLI_AWG_V3_PORT"
[ -n "${CLI_ENABLE_AWG_V2:-}" ]   && ENABLE_AWG_V2="$CLI_ENABLE_AWG_V2"
[ -n "${CLI_AWG_V2_PORT:-}" ]     && AWG_V2_PORT="$CLI_AWG_V2_PORT"
[ -n "${CLI_ENABLE_AWG_STANDALONE:-}" ] && ENABLE_AWG_STANDALONE="$CLI_ENABLE_AWG_STANDALONE"
[ -n "${CLI_AWG_STANDALONE_PORT:-}" ] && AWG_STANDALONE_PORT="$CLI_AWG_STANDALONE_PORT"
[ -n "${CLI_ENABLE_SS2022:-}" ]   && ENABLE_SS2022="$CLI_ENABLE_SS2022"
[ -n "${CLI_SS2022_PORT:-}" ]     && SS2022_PORT="$CLI_SS2022_PORT"
[ -n "${CLI_ENABLE_TUIC:-}" ]     && ENABLE_TUIC="$CLI_ENABLE_TUIC"
[ -n "${CLI_TUIC_PORT:-}" ]       && TUIC_PORT="$CLI_TUIC_PORT"
[ -n "${CLI_ENABLE_MTPROTO:-}" ]  && ENABLE_MTPROTO="$CLI_ENABLE_MTPROTO"
[ -n "${CLI_MTPROTO_PORT:-}" ]    && MTPROTO_PORT="$CLI_MTPROTO_PORT"
[ -n "${CLI_MTPROTO_FAKETLS_DOMAIN:-}" ] && MTPROTO_FAKETLS_DOMAIN="$CLI_MTPROTO_FAKETLS_DOMAIN"
[ -n "${CLI_MTPROTO_ADTAG:-}" ]   && MTPROTO_ADTAG="$CLI_MTPROTO_ADTAG"
[ -n "${CLI_ENABLE_WEB_STACK:-}" ] && ENABLE_WEB_STACK="$CLI_ENABLE_WEB_STACK"
[ -n "${CLI_AWG_SERVER_HOST:-}" ]  && AWG_SERVER_HOST="$CLI_AWG_SERVER_HOST"
[ -n "${CLI_ENABLE_MASQUE:-}" ]      && ENABLE_MASQUE="$CLI_ENABLE_MASQUE"
[ -n "${CLI_MASQUE_PORT:-}" ]        && MASQUE_PORT="$CLI_MASQUE_PORT"
[ -n "${CLI_ENABLE_SHADOWTLS:-}" ]   && ENABLE_SHADOWTLS="$CLI_ENABLE_SHADOWTLS"
[ -n "${CLI_SHADOWTLS_PORT:-}" ]     && SHADOWTLS_PORT="$CLI_SHADOWTLS_PORT"
[ -n "${CLI_SHADOWTLS_SNI:-}" ]      && SHADOWTLS_SNI="$CLI_SHADOWTLS_SNI"
[ -n "${CLI_SHADOWTLS_PASSWORD:-}" ] && SHADOWTLS_PASSWORD="$CLI_SHADOWTLS_PASSWORD"
[ -n "${CLI_ENABLE_WSTUNNEL:-}" ]    && ENABLE_WSTUNNEL="$CLI_ENABLE_WSTUNNEL"
[ -n "${CLI_WSTUNNEL_PORT:-}" ]      && WSTUNNEL_PORT="$CLI_WSTUNNEL_PORT"
[ -n "${CLI_WSTUNNEL_PREFIX:-}" ]    && WSTUNNEL_PREFIX="$CLI_WSTUNNEL_PREFIX"
[ -n "${CLI_ENABLE_ZAPRET:-}" ]      && ENABLE_ZAPRET="$CLI_ENABLE_ZAPRET"
[ -n "${CLI_ZAPRET_QNUM:-}" ]        && ZAPRET_QNUM="$CLI_ZAPRET_QNUM"
[ -n "${CLI_ENABLE_NAIVE:-}" ]       && ENABLE_NAIVE="$CLI_ENABLE_NAIVE"
[ -n "${CLI_NAIVE_PORT:-}" ]         && NAIVE_PORT="$CLI_NAIVE_PORT"
[ -n "${CLI_NAIVE_DOMAIN:-}" ]       && NAIVE_DOMAIN="$CLI_NAIVE_DOMAIN"
[ -n "${CLI_NAIVE_USER:-}" ]         && NAIVE_USER="$CLI_NAIVE_USER"
[ -n "${CLI_NAIVE_PASS:-}" ]         && NAIVE_PASS="$CLI_NAIVE_PASS"
[ -n "${CLI_ENABLE_DNSTT:-}" ]       && ENABLE_DNSTT="$CLI_ENABLE_DNSTT"
[ -n "${CLI_DNSTT_PORT:-}" ]         && DNSTT_PORT="$CLI_DNSTT_PORT"
[ -n "${CLI_DNSTT_DOMAIN:-}" ]       && DNSTT_DOMAIN="$CLI_DNSTT_DOMAIN"
[ -n "${CLI_DNSTT_PUBKEY:-}" ]       && DNSTT_PUBKEY="$CLI_DNSTT_PUBKEY"
[ -n "${CLI_ENABLE_MIERU:-}" ]       && ENABLE_MIERU="$CLI_ENABLE_MIERU"
[ -n "${CLI_MIERU_PORT_MODE:-}" ]    && MIERU_PORT_MODE="$CLI_MIERU_PORT_MODE"
[ -n "${CLI_MIERU_PORT:-}" ]         && MIERU_PORT="$CLI_MIERU_PORT"
[ -n "${CLI_MIERU_TRANSPORT:-}" ]    && MIERU_TRANSPORT="$CLI_MIERU_TRANSPORT"
[ -n "${CLI_MIERU_USER:-}" ]         && MIERU_USER="$CLI_MIERU_USER"
[ -n "${CLI_MIERU_PASS:-}" ]         && MIERU_PASS="$CLI_MIERU_PASS"
[ -n "${CLI_ALL_PROTOCOLS:-}" ]      && ALL_PROTOCOLS="$CLI_ALL_PROTOCOLS"

if [ "$ROTATE_PATHS" -eq 1 ]; then
    rotate_secret_paths || die "Не удалось сгенерировать новые секретные пути."
    warn "Пути панели, Wstunnel и ClientID DoH изменены. Обновите адреса на клиентах после установки."
fi

_stls_chk="${ENABLE_SHADOWTLS:-}"
if [[ "$_stls_chk" == "1" || "${_stls_chk,,}" == "y" ]] && [ -z "${CLI_ENABLE_SS2022:-}" ]; then
    ENABLE_SS2022="y"
fi

_dnstt_chk="${ENABLE_DNSTT:-}"
if [[ "$_dnstt_chk" == "1" || "${_dnstt_chk,,}" == "y" ]] && [ -z "${CLI_ENABLE_SS2022:-}" ]; then
    ENABLE_SS2022="y"
fi

# Сессия всегда сохраняется в server-setup.env в текущей папке или рядом со скриптом
SAVED_CONFIG_FILE="${CONFIG_FILE:-./server-setup.env}"

