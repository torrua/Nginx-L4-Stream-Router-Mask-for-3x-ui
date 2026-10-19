
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
    ([ -t 0 ] || [ -c /dev/tty ]) || return 1
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
    return 0
}

prompt_multiselect_tui() {
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

    tput civis 2>/dev/null || printf '\033[?25l'
    trap 'tput cnorm 2>/dev/null || printf "\033[?25h"; exit 130' INT TERM

    render_tui_menu() {
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
            printf "\033[2K  %b[${color}%s${NC}] [%b] %b\n" "$prefix" "$num" "$mark" "${_tui_labels[$i]}"
        done
        printf "\033[2K  ${DIM}[↑/↓: навигация | Пробел: отметка | 1-%d: перекл | a: все | Enter: готово]${NC}\n" "$count"
    }

    render_tui_menu

    while true; do
        local key=""
        if [ -c /dev/tty ]; then
            IFS= read -rsn1 key </dev/tty || key="ERR"
        else
            IFS= read -rsn1 key || key="ERR"
        fi

        if [ "$key" = "ERR" ]; then
            tput cnorm 2>/dev/null || printf '\033[?25h'
            trap - INT TERM
            prompt_multiselect_numeric "$prompt_text" _tui_keys _tui_labels
            return $?
        fi

        if [ "$key" = $'\x1b' ]; then
            local rest=""
            if [ -c /dev/tty ]; then
                read -rsn2 -t 0.2 rest </dev/tty 2>/dev/null || rest=""
            else
                read -rsn2 -t 0.2 rest 2>/dev/null || rest=""
            fi
            case "$rest" in
                "[A"|"OA")
                    cursor=$(( (cursor - 1 + count) % count ))
                    ;;
                "[B"|"OB")
                    cursor=$(( (cursor + 1) % count ))
                    ;;
            esac
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
        elif [ -z "$key" ]; then
            break
        elif [[ "$key" == "b" || "$key" == "B" ]]; then
            if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
                tput cnorm 2>/dev/null || printf '\033[?25h'
                trap - INT TERM
                printf "\033[%dA\r" "$total_lines"
                for ((i=0; i<total_lines; i++)); do printf "\033[2K\n"; done
                printf "\033[%dA\r" "$total_lines"
                return 10
            fi
        elif [ "$key" = "?" ]; then
            tput cnorm 2>/dev/null || printf '\033[?25h'
            trap - INT TERM
            printf "\033[%dA\r" "$total_lines"
            for ((i=0; i<total_lines; i++)); do printf "\033[2K\n"; done
            printf "\033[%dA\r" "$total_lines"
            prompt_multiselect_numeric "$prompt_text" _tui_keys _tui_labels
            return $?
        fi

        printf "\033[%dA\r" "$total_lines"
        render_tui_menu
    done

    tput cnorm 2>/dev/null || printf '\033[?25h'
    trap - INT TERM

    printf "\033[%dA\r" "$total_lines"
    for ((i=0; i<total_lines; i++)); do
        printf "\033[2K\n"
    done
    printf "\033[%dA\r" "$total_lines"

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

    # По умолчанию используем надежный числовой селектор:
    # 1. 100% стабилен при любых размерах окна терминала и переносе строк
    # 2. Не зависит от задержек сети и фрагментации пакетов SSH
    # 3. Поддерживает мгновенный выбор по Enter, список номеров, 'all' и '0'
    if [ "${ENABLE_TUI_MULTISELECT:-0}" = "1" ] && can_use_interactive_tui; then
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

# Сессия всегда сохраняется в setup_mask.env в текущей папке или рядом со скриптом
SAVED_CONFIG_FILE="${CONFIG_FILE:-./setup_mask.env}"

