#!/usr/bin/env bash
# ==============================================================================
# Nginx L4 Stream Router Mask for 3X-UI — Unified Master Installer
# GitHub: https://github.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui
# ==============================================================================

# Exit on severe unhandled errors
set -o pipefail

SCRIPT_VERSION="v7.7.0"

# Защита от аварийного обрыва SSH-сессии при установке
trap 'echo -e "\n[!] Внимание: получен сигнал SIGHUP, процесс установки продолжается в фоне..." >> "${INSTALL_LOG:-/var/log/nginx_mask_install.log}" 2>&1' SIGHUP

detect_active_ssh_port() {
    local active_port=""
    if [ -n "${SSH_CONNECTION:-}" ]; then
        active_port=$(echo "$SSH_CONNECTION" | awk '{print $4}')
    fi
    if [ -z "$active_port" ] || ! [[ "$active_port" =~ ^[0-9]+$ ]]; then
        active_port=$(ss -tlnp 2>/dev/null | grep -E 'sshd|ssh' | grep -vE '127\.0\.0\.1|::1' | awk '{print $4}' | awk -F: '{print $NF}' | sort -n | tail -n1 || echo "")
    fi
    if [ -z "$active_port" ] || ! [[ "$active_port" =~ ^[0-9]+$ ]]; then
        active_port="22"
    fi
    echo "$active_port"
}

get_ssh_service_name() {
    if systemctl list-unit-files 2>/dev/null | grep -q "^sshd\.service"; then
        echo "sshd"
    else
        echo "ssh"
    fi
}


# --- Color Palette & Typography ---
BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
MAGENTA=$'\033[0;35m'
CYAN=$'\033[0;36m'
WHITE=$'\033[1;37m'

BG_BLUE=$'\033[44m'
BG_GREEN=$'\033[42m'

# --- Symbols ---
CHECK="✔"
CROSS="✖"
ARROW="➜"
INFO="ℹ"
STAR="★"
LOCK="🔒"
SHIELD="🛡"

die() {
    echo -e "  ${RED}${CROSS} $*${RESET}" >&2
    exit 1
}

# --- Global Paths & Logs ---
INSTALL_LOG="/var/log/nginx_mask_install.log"
CREDENTIALS_FILE="/root/vpn_credentials.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main"

# Clear screen & display header banner
check_for_script_updates() {
    local remote_ver=""
    remote_ver=$(curl -fsSL --connect-timeout 2 "https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/VERSION?v=$(date +%s)" 2>/dev/null | tr -d '[:space:]' || true)
    if [ -n "$remote_ver" ]; then
        if [ "$remote_ver" != "$SCRIPT_VERSION" ]; then
            echo -e "  ${YELLOW}⚠️  Доступно обновление скрипта: ${GREEN}$remote_ver${YELLOW} (текущая версия: ${CYAN}$SCRIPT_VERSION${YELLOW})${RESET}"
            echo -e "  ${DIM}Обновить: curl -sSL "https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/install.sh?v=$(date +%s)" | sudo bash${RESET}\n"
        else
            echo -e "  ${DIM}Версия: ${GREEN}$SCRIPT_VERSION${DIM} (актуальная релизная сборка)${RESET}\n"
        fi
    else
        echo -e "  ${DIM}Версия: ${GREEN}$SCRIPT_VERSION${RESET}\n"
    fi
}

clear_banner() {
    clear 2>/dev/null || true
    echo -e "  ${CYAN}${BOLD}🛡️   Nginx Stream Router для 3X-UI [${SCRIPT_VERSION}]${RESET}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${RESET}"
    echo -e "  ${WHITE}Шлюз маскировки и защиты VPN-подключений:${RESET}"
    echo -e "  ${DIM}• Маскировка под реальный сайт (защита от сканирования и блокировок)${RESET}"
    echo -e "  ${DIM}• Поддержка протоколов: VLESS REALITY, Hysteria 2, AmneziaWG${RESET}"
    echo -e "  ${DIM}• Единый защищенный порт 443 для всех сервисов, панели и подписок${RESET}"
    echo -e "  ${DIM}• Обход капч Google и доступ к AI через Cloudflare WARP${RESET}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${RESET}"
    check_for_script_updates
}

# Spinner function for background processes
# Usage: run_with_spinner "Task description" bash_function_or_command
run_with_spinner() {
    local task_name="$1"
    shift
    local cmd=("$@")
    
    # Run command in background and redirect output to log
    "${cmd[@]}" >> "$INSTALL_LOG" 2>&1 &
    local pid=$!
    local exit_code=0
    
    if [ ! -t 1 ]; then
        echo -e "  ${CYAN}*${RESET}  ${WHITE}${task_name}...${RESET}"
        wait "$pid"
        exit_code=$?
    else
        # Spinner glyphs
        local spin_chars=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
        local delay=0.08
        
        # Hide cursor
        tput civis 2>/dev/null || echo -ne "\033[?25l"
        
        local i=0
        while kill -0 "$pid" 2>/dev/null; do
            i=$(( (i + 1) % 10 ))
            printf "\r  ${CYAN}${spin_chars[$i]}${RESET}  ${WHITE}%-52s${RESET}" "$task_name..."
            sleep "$delay"
        done
        
        wait "$pid"
        exit_code=$?
        
        # Show cursor
        tput cnorm 2>/dev/null || echo -ne "\033[?25h"
    fi
    
    if [ $exit_code -eq 0 ]; then
        if [ ! -t 1 ]; then
            printf "  ${GREEN}${CHECK}${RESET}  ${WHITE}%-52s${RESET} ${GREEN}[DONE]${RESET}\n" "$task_name"
        else
            printf "\r  ${GREEN}${CHECK}${RESET}  ${WHITE}%-52s${RESET} ${GREEN}[DONE]${RESET}\n" "$task_name"
        fi
        return 0
    else
        if [ ! -t 1 ]; then
            printf "  ${RED}${CROSS}${RESET}  ${WHITE}%-52s${RESET} ${RED}[FAILED]${RESET}\n" "$task_name"
        else
            printf "\r  ${RED}${CROSS}${RESET}  ${WHITE}%-52s${RESET} ${RED}[FAILED]${RESET}\n" "$task_name"
        fi
        echo -e "\n  ${RED}${BOLD}Ошибка при выполнении:${RESET} ${YELLOW}$task_name${RESET}"
        echo -e "  ${DIM}Подробности записаны в лог:${RESET} ${WHITE}$INSTALL_LOG${RESET}"
        echo -e "  ${DIM}Последние строки лога:${RESET}"
        echo -e "${RED}────────────────────────────────────────────────────────────${RESET}"
        tail -n 12 "$INSTALL_LOG" | sed 's/^/    /'
        echo -e "${RED}────────────────────────────────────────────────────────────${RESET}"
        exit 1
    fi
}

# Step Progress Header
print_step() {
    local step_num="$1"
    local total_steps="$2"
    local step_title="$3"
    local progress_bar=""
    
    local percent=$(( step_num * 100 / total_steps ))
    local filled=$(( step_num * 15 / total_steps ))
    local empty=$(( 15 - filled ))
    
    for ((j=0; j<filled; j++)); do progress_bar+="█"; done
    for ((j=0; j<empty; j++)); do progress_bar+="░"; done
    
    echo ""
    echo -e "  ${BLUE}${BOLD}[Шаг $step_num из $total_steps]${RESET} ${WHITE}${BOLD}$step_title${RESET}"
    echo -e "  ${DIM}Прогресс: [${CYAN}$progress_bar${DIM}] ${percent}%${RESET}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${RESET}"
}

# Root and OS Check
check_prerequisites() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "  ${RED}${BOLD}${CROSS} Ошибка:${RESET} Этот скрипт должен быть запущен от имени ${YELLOW}root${RESET}."
        echo -e "  Запустите: ${CYAN}sudo bash $0${RESET}"
        exit 1
    fi

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME=$ID
        OS_VER=$VERSION_ID
    else
        echo -e "  ${YELLOW}${INFO} Предупреждение: Не удалось определить дистрибутив Linux. Рекомендуется Ubuntu/Debian.${RESET}"
    fi
    
    touch "$INSTALL_LOG"
    chmod 600 "$INSTALL_LOG"
}

# Mode Selection Screen

# @include "installer/express.sh"

# @include "installer/steps.sh"

# @include "installer/summary.sh"

# --- Main Flow ---
main() {
    if [[ "${1:-}" == "-v" || "${1:-}" == "--version" ]]; then
        echo "STREAM ROUTER $SCRIPT_VERSION"
        exit 0
    fi
    clear_banner
    check_prerequisites
    prompt_mode
    
    if [ "$MODE_CHOICE" == "2" ]; then
        echo -e "  ${YELLOW}${INFO} Запуск экспертного режима (setup_mask.sh)...${RESET}\n"
        echo -e "  ${CYAN}[i] Загрузка актуального установщика...${RESET}"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "${REPO_URL}/setup_mask.sh?v=$(date +%s)" -o /tmp/setup_mask.sh
        else
            wget -qO /tmp/setup_mask.sh "${REPO_URL}/setup_mask.sh?v=$(date +%s)"
        fi
        chmod +x /tmp/setup_mask.sh
        [ -f "$SCRIPT_DIR/setup_mask.sh" ] && cp /tmp/setup_mask.sh "$SCRIPT_DIR/setup_mask.sh" 2>/dev/null || true
        cp /tmp/setup_mask.sh "./setup_mask.sh" 2>/dev/null || true
        bash /tmp/setup_mask.sh --expert "$@"
        exit 0
    fi
    
    # Express Mode
    collect_express_inputs
    
    echo -e "\n  ${CYAN}${BOLD}${STAR} Начинаем сборку и настройку компонентов системы...${RESET}"
    
    # Step 1: OS, Sysctl, UFW
    print_step 1 4 "Подготовка ОС, BBR-оптимизация и настройка фаервола"
    run_with_spinner "Обновление репозиториев и установка базовых утилит" step_os_hardening
    
    # Step 2: 3X-UI Engine
    print_step 2 4 "Установка и запуск официального ядра 3X-UI"
    run_with_spinner "Развертывание 3X-UI и создание учетной записи администратора" step_install_3xui
    
    # Step 3: Nginx L4 Stream Router & SSL
    print_step 3 4 "Установка Nginx mainline, получение SSL и настройка L4 Router"
    run_with_spinner "Конфигурация SNI-роутера, сайта-маскировки и SSL Let's Encrypt" step_install_nginx_and_mask
    
    # Step 4: Database Reconcile & Lockdown
    print_step 4 4 "Синхронизация входящих подключений (Inbounds) и финализация"
    run_with_spinner "Инициализация профилей Xray и блокировка внутренних портов" step_configure_inbounds
    
    save_and_display_summary
    print_dashboard
}

main "$@"
