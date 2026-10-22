report_installation() {
    if is_true "${ENABLE_WEB_STACK:-y}"; then
        :
# @include "installer/report-web.sh"
    else
        :
# @include "installer/report-awg.sh"
    fi
    SCRIPT_END_TIME=$(date +%s)
    SCRIPT_END_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
    TOTAL_EXECUTION_TIME=$(( SCRIPT_END_TIME - SCRIPT_START_TIME ))
    FORMATTED_TOTAL_TIME=$(format_duration "$TOTAL_EXECUTION_TIME")

    echo ""
    echo -e "  ${CYAN}${BOLD}⏱️  Статистика выполнения установки:${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
    echo -e "  Время запуска:        ${WHITE}${SCRIPT_START_DATETIME}${NC}"
    echo -e "  Время завершения:     ${WHITE}${SCRIPT_END_DATETIME}${NC}"
    echo -e "  Общее время работы:   ${GREEN}${BOLD}${FORMATTED_TOTAL_TIME}${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${WHITE}Время по шагам:${NC}"
    for ((s_idx=1; s_idx<=TOTAL_STEPS; s_idx++)); do
        step_t="${STEP_DURATIONS[$s_idx]:-0}"
        s_name="${STEP_NAMES[$s_idx]:-Шаг $s_idx}"
        if [ "$step_t" -gt 0 ]; then
            s_dur_str=$(format_duration "$step_t")
            if [ "${STEP_BG_FLAGS[$s_idx]:-0}" -eq 1 ]; then
                echo -e "    • Шаг $s_idx ($s_name): ${GREEN}${s_dur_str}${NC} ${CYAN}[в фоне, сэкономлено]${NC}"
            else
                echo -e "    • Шаг $s_idx ($s_name): ${GREEN}${s_dur_str}${NC}"
            fi
        elif [ "${RESUME_STEP:-1}" -gt "$s_idx" ]; then
            echo -e "    • Шаг $s_idx ($s_name): ${DIM}пропущено (выполнено ранее)${NC}"
        else
            echo -e "    • Шаг $s_idx ($s_name): ${DIM}< 1 сек${NC}"
        fi
    done
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}\n"

    if is_true "${DEBUG_MODE:-0}" || [ -n "${FORCE_LOG_EXPORT:-}" ]; then
        if command -v offer_debug_log_export >/dev/null 2>&1; then
            offer_debug_log_export
        fi
    fi
}
