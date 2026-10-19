# Interactive Terminal Spinner & Task Runner
# Supports:
#   - Animated spinner in interactive TTY
#   - Plain output in non-interactive / CI / piped runs
#   - DEBUG_MODE=1 passthrough (full stdout/stderr in real-time)
#   - Interactive failure recovery menu (Retry / Skip / Abort)

run_with_spinner() {
    local task_name="$1"
    shift
    local log_file="${SETUP_MASK_LOG:-${INSTALL_LOG:-${SPINNER_LOG_FILE:-/tmp/cmd_spinner.log}}}"

    while true; do
        local exit_code=0

        # ── DEBUG MODE: без фона, весь вывод сразу в stdout ──
        if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
            echo -e "\n  ${CYAN}[DEBUG]${NC} ${WHITE}▶ $task_name${NC}"
            echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            local _prev_e=0
            [[ "$-" =~ e ]] && _prev_e=1
            set +e
            if declare -f "$1" >/dev/null 2>&1; then
                ( shopt -s inherit_errexit 2>/dev/null || true; set -euo pipefail; "$@" )
                exit_code=$?
            else
                ( shopt -s inherit_errexit 2>/dev/null || true; set -euo pipefail; eval "$*" )
                exit_code=$?
            fi
            [ "$_prev_e" -eq 1 ] && set -e
            if [ $exit_code -eq 0 ]; then
                echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
                echo -e "  ${GREEN}${CHECK:-✔}${NC}  ${WHITE}$task_name${NC} ${GREEN}[ГОТОВО]${NC}\n"
                return 0
            else
                echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            fi
        else
            # ── Нормальный режим: фоновый процесс + спиннер ──
            local spin_chars=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
            local delay=0.08

            : > "$log_file"

            if declare -f "$1" >/dev/null 2>&1; then
                "$@" >> "$log_file" 2>&1 &
            else
                ( eval "$*" ) >> "$log_file" 2>&1 &
            fi
            local pid=$!

            if [ ! -t 1 ]; then
                echo -e "  ${CYAN}*${NC}  ${WHITE}${task_name}...${NC}"
                wait "$pid"
                exit_code=$?
            else
                tput civis 2>/dev/null || echo -ne "\033[?25l"
                local i=0
                while kill -0 "$pid" 2>/dev/null; do
                    i=$(( (i + 1) % 10 ))
                    printf "\r  ${CYAN}${spin_chars[$i]}${NC}  ${WHITE}%-54s${NC}" "$task_name..."
                    sleep "$delay"
                done
                wait "$pid"
                exit_code=$?
                tput cnorm 2>/dev/null || echo -ne "\033[?25h"
            fi

            if [ $exit_code -eq 0 ]; then
                if [ ! -t 1 ]; then
                    printf "  ${GREEN}${CHECK:-✔}${NC}  ${WHITE}%-54s${NC} ${GREEN}[ГОТОВО]${NC}\n" "$task_name"
                else
                    printf "\r  ${GREEN}${CHECK:-✔}${NC}  ${WHITE}%-54s${NC} ${GREEN}[ГОТОВО]${NC}\n" "$task_name"
                fi
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

        # ── Интерактивная обработка сбоя (Retry / Skip / Abort) ──
        if [ "${NON_INTERACTIVE:-0}" -eq 0 ] && [ -t 1 ]; then
            echo -e "  ${YELLOW}${BOLD}Действия при сбое:${NC}"
            echo -e "    ${CYAN}${BOLD}[1] Повторить попытку (Retry)${NC} — после исправления причин (напр. DNS)"
            echo -e "    ${YELLOW}[2] Пропустить этот шаг и продолжить (Skip)${NC}"
            echo -e "    ${RED}[3] Прервать установку (Abort)${NC}"
            local retry_ans=""
            read -rp "  Ваш выбор [1/2/3] (по умолчанию: 1): " retry_ans </dev/tty || read -r retry_ans || retry_ans="1"
            retry_ans=$(echo "${retry_ans:-1}" | tr -d '[:space:]')
            case "$retry_ans" in
                2)
                    warn "Шаг '$task_name' пропущен по выбору пользователя."
                    return 0
                    ;;
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
