# Execute in a fresh Bash so a caller's `if`/`||` cannot suppress errexit.
# A private snapshot preserves Bash functions and unexported variables in both modes.
execute_install_task() (
    umask 077
    task_dir=$(mktemp -d "${TMPDIR:-/tmp}/server-task.XXXXXX") || exit 1
    trap 'rm -f -- "$task_dir/task.sh"; rmdir -- "$task_dir"' EXIT
    {
        declare -p | grep -vE '^declare -[^ ]*r|^declare [^ ]+ (BASH[^ =]*|FUNCNAME|DIRSTACK|GROUPS|PIPESTATUS|LINENO|RANDOM|SRANDOM|SECONDS|EPOCHSECONDS|EPOCHREALTIME|_)='
        declare -f
        cat << 'EOF_TASK_TRAP'
__task_err_handler() {
    local ec=$?
    local cmd="${BASH_COMMAND:-unknown}"
    local line="${BASH_LINENO[0]:-unknown}"
    local fn="${FUNCNAME[1]:-main}"
    printf '\n[ERROR-TRACE] Сбой команды: %s (строка: %s, функция: %s, код: %s)\n' "$cmd" "$line" "$fn" "$ec" >&2
}
trap '__task_err_handler' ERR
EOF_TASK_TRAP
        printf '%s\n' 'shopt -s inherit_errexit 2>/dev/null || true' 'set -Eeuo pipefail' '"$@"'
    } > "$task_dir/task.sh" || exit 1
    bash --noprofile --norc "$task_dir/task.sh" "$@"
)

# Инициализация единого системного журнала установки
init_server_setup_log() {
    if [ -n "${SERVER_SETUP_LOG:-}" ]; then
        return 0
    fi
    local cand
    for cand in "${TARGET_ROOT:-}/var/log/server-setup.log" \
                "${TMPDIR:-/tmp}/server-setup.log"; do
        [ -n "$cand" ] || continue
        local pdir
        pdir="$(dirname "$cand" 2>/dev/null || echo ".")"
        if [ -d "$pdir" ] && [ -w "$pdir" ]; then
            SERVER_SETUP_LOG="$cand"
            break
        fi
    done
    [ -n "${SERVER_SETUP_LOG:-}" ] || SERVER_SETUP_LOG="${TMPDIR:-/tmp}/server-setup.log"
    if [ ! -f "$SERVER_SETUP_LOG" ]; then
        touch "$SERVER_SETUP_LOG" 2>/dev/null && chmod 600 "$SERVER_SETUP_LOG" 2>/dev/null || true
    fi
}

# Извлечение журналов systemd при сбое служб
get_systemd_diagnostic_logs() {
    command -v journalctl >/dev/null 2>&1 || return 0
    [ -d /run/systemd/system ] || return 0

    local diag=""
    if command -v systemctl >/dev/null 2>&1; then
        local failed_units
        failed_units=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' || true)
        if [ -n "$failed_units" ]; then
            diag="${diag}  [systemd: аварийные службы]: ${failed_units}"$'\n'
            for u in $failed_units; do
                local u_logs
                u_logs=$(journalctl -u "$u" -n 15 --no-pager 2>/dev/null || true)
                if [ -n "$u_logs" ]; then
                    diag="${diag}  --- journalctl -u ${u} (последние 15 строк) ---"$'\n'
                    diag="${diag}$(echo "$u_logs" | sed 's/^/    /')"$'\n'
                fi
            done
        fi
    fi

    if [ -z "$diag" ]; then
        local recent_errs
        recent_errs=$(journalctl --since "1 minute ago" -p err..emerg --no-pager -n 15 2>/dev/null || true)
        if [ -n "$recent_errs" ]; then
            diag="${diag}  --- Системные ошибки journalctl (за последнюю минуту) ---"$'\n'
            diag="${diag}$(echo "$recent_errs" | sed 's/^/    /')"$'\n'
        fi
    fi

    if [ -n "$diag" ]; then
        echo -e "\n  ${YELLOW}${BOLD}Диагностика системных служб (journalctl):${NC}"
        echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
        echo "$diag"
        echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
    fi
}

# Interactive Terminal Spinner & Task Runner
# Supports:
#   - Animated spinner in interactive TTY
#   - Plain output in non-interactive / CI / piped runs
#   - Smart Implicit Debug: full output and ERR-traces captured automatically
#   - Explicit DEBUG_MODE=1 passthrough (full stdout/stderr in real-time)
#   - Required tasks support Retry / Abort; failures cannot be marked as success

run_with_spinner() {
    local task_name="$1"
    shift
    init_server_setup_log

    local log_file="${SPINNER_LOG_FILE:-}"
    local temporary_log=0
    if [ -z "$log_file" ]; then
        log_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/server-task-log.XXXXXX") || return 1
        temporary_log=1
    fi

    while true; do
        local exit_code=0
        local task_start_ts
        task_start_ts="$(date -u +"%Y-%m-%d %H:%M:%SZ" 2>/dev/null || date)"
        printf "\n[%s] === START TASK: %s ===\n" "$task_start_ts" "$task_name" >> "$SERVER_SETUP_LOG" 2>/dev/null || true

        # ── DEBUG MODE: трансляция в реальном времени с одновременной записью в лог ──
        if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
            echo -e "\n  ${CYAN}[DEBUG]${NC} ${WHITE}▶ $task_name${NC}"
            echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            (umask 077; : > "$log_file") || true
            chmod 600 "$log_file" 2>/dev/null || true

            local prev_e="0"
            case "$-" in *e*) prev_e="1" ;; esac
            set +e
            execute_install_task "$@" 2>&1 | tee -a "$log_file"
            exit_code=${PIPESTATUS[0]}
            if [ "$prev_e" = "1" ]; then set -e; fi

            if [ -s "$log_file" ] && [ -f "$SERVER_SETUP_LOG" ]; then
                cat "$log_file" >> "$SERVER_SETUP_LOG" 2>/dev/null || true
            fi
            printf "[%s] === END TASK: %s (exit: %s) ===\n" "$(date -u +"%Y-%m-%d %H:%M:%SZ" 2>/dev/null || date)" "$task_name" "$exit_code" >> "$SERVER_SETUP_LOG" 2>/dev/null || true

            if [ $exit_code -eq 0 ]; then
                echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
                echo -e "  ${GREEN}${CHECK:-✔}${NC}  ${WHITE}$task_name${NC} ${GREEN}[ГОТОВО]${NC}\n"
                [ "$temporary_log" -eq 0 ] || rm -f -- "$log_file"
                return 0
            else
                echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
                get_systemd_diagnostic_logs
                echo -e "  ${DIM}Полный журнал выполнения: ${WHITE}${SERVER_SETUP_LOG}${NC}\n"
            fi
        else
            # ── Нормальный режим («Умный неявный Debug»): спиннер + фоновая запись ──
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

            if [ -s "$log_file" ] && [ -f "$SERVER_SETUP_LOG" ]; then
                cat "$log_file" >> "$SERVER_SETUP_LOG" 2>/dev/null || true
            fi
            printf "[%s] === END TASK: %s (exit: %s) ===\n" "$(date -u +"%Y-%m-%d %H:%M:%SZ" 2>/dev/null || date)" "$task_name" "$exit_code" >> "$SERVER_SETUP_LOG" 2>/dev/null || true

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
            get_systemd_diagnostic_logs
            echo -e "  ${DIM}Полный журнал выполнения сохранен в: ${WHITE}${SERVER_SETUP_LOG}${NC}\n"
        fi

        # ── Обязательный этап: повторить или прервать ──
        if [ "${NON_INTERACTIVE:-0}" -eq 0 ] && [ -t 1 ]; then
            echo -e "  ${YELLOW}${BOLD}Действия при сбое:${NC}"
            echo -e "    ${CYAN}${BOLD}[1] Повторить попытку (Retry)${NC} — после исправления причин (напр. DNS)"
            echo -e "    ${RED}[2] Прервать установку (Abort)${NC}"
            local retry_ans=""
            read -rp "  Ваш выбор [1/2] (по умолчанию: 1): " retry_ans </dev/tty || read -r retry_ans || retry_ans="1"
            retry_ans=$(echo "${retry_ans:-1}" | tr -d '[:space:]')
            case "$retry_ans" in
                2|3)
                    if command -v offer_debug_log_export >/dev/null 2>&1; then
                        offer_debug_log_export || true
                    fi
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
