_TUI_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
[ -f "$_TUI_BASE_DIR/../common/colors.sh" ] && . "$_TUI_BASE_DIR/../common/colors.sh" 2>/dev/null || true
[ -f "$_TUI_BASE_DIR/../common/logger.sh" ] && . "$_TUI_BASE_DIR/../common/logger.sh" 2>/dev/null || true
[ -f "$_TUI_BASE_DIR/../common/spinner.sh" ] && . "$_TUI_BASE_DIR/../common/spinner.sh" 2>/dev/null || true

# @include "common/colors.sh"
# @include "common/logger.sh"
# @include "common/spinner.sh"


# Прогресс-бар шагов
print_step_bar() {
    local step_num="$1"
    local total_steps="$2"
    local step_title="$3"
    local percent=$(( step_num * 100 / total_steps ))
    local filled=$(( step_num * 16 / total_steps ))
    local empty=$(( 16 - filled ))
    local bar=""
    for ((j=0; j<filled; j++)); do bar+="█"; done
    for ((j=0; j<empty; j++)); do bar+="░"; done
    
    echo ""
    echo -e "  ${BLUE}${BOLD}┌─[ Шаг $step_num из $total_steps ] ${WHITE}$step_title${NC}"
    echo -e "  ${BLUE}${BOLD}└─ Прогресс: [${CYAN}$bar${BLUE}${BOLD}] ${WHITE}${percent}%${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
}

# Вывод карточки заголовка
check_for_script_updates() {
    local remote_ver=""
    remote_ver=$(curl -fsSL --connect-timeout 2 "https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/VERSION" 2>/dev/null | tr -d '[:space:]' || true)
    if [ -n "$remote_ver" ]; then
        if [ "$remote_ver" != "$SCRIPT_VERSION" ]; then
            echo -e "  ${YELLOW}⚠️  Доступно обновление скрипта: ${GREEN}$remote_ver${YELLOW} (текущая версия: ${CYAN}$SCRIPT_VERSION${YELLOW})${NC}"
            echo -e "  ${DIM}Обновить: curl -sSL "https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/install.sh?v=$(date +%s)" | sudo bash${NC}\n"
        else
            echo -e "  ${DIM}Версия: ${GREEN}$SCRIPT_VERSION${DIM} (актуальная релизная сборка)${NC}\n"
        fi
    else
        echo -e "  ${DIM}Версия: ${GREEN}$SCRIPT_VERSION${NC}\n"
    fi
}
