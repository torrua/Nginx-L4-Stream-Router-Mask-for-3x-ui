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
