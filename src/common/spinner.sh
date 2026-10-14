# Interactive Terminal Spinner
run_with_spinner() {
    local task_name="$1"
    shift
    local log_file="${SPINNER_LOG_FILE:-/tmp/cmd_spinner.log}"
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

    if [ "$exit_code" -eq 0 ]; then
        printf "\r  ${GREEN}[✓]${NC}  ${WHITE}%-54s${NC}\n" "$task_name"
        return 0
    else
        printf "\r  ${RED}[✗]${NC}  ${WHITE}%-54s${NC}\n" "$task_name (ошибка)"
        if [ -s "$log_file" ]; then
            echo -e "${RED}--- Лог ошибки ($task_name) ---${NC}"
            cat "$log_file"
            echo -e "${RED}-----------------------------------${NC}"
        fi
        return "$exit_code"
    fi
}
