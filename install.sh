#!/usr/bin/env bash
# ==============================================================================
# Nginx L4 Stream Router Mask for 3X-UI — Unified Master Installer
# GitHub: https://github.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui
# ==============================================================================

# Exit on severe unhandled errors
set -o pipefail

SCRIPT_VERSION="v6.6.0"


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

# --- Global Paths & Logs ---
INSTALL_LOG="/var/log/nginx_mask_install.log"
CREDENTIALS_FILE="/root/vpn_credentials.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main"

# Clear screen & display header banner
check_for_script_updates() {
    local remote_ver=""
    remote_ver=$(curl -fsSL --connect-timeout 2 "https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/VERSION" 2>/dev/null | tr -d '[:space:]' || true)
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
    echo -e "${CYAN}${BOLD}"
    echo "  ╔════════════════════════════════════════════════════════════════════════════════╗"
    echo "  ║                                                                                ║"
    echo "  ║    ░█▀▀░▀█▀░█▀▄░█▀▀░█▀█░█▄█   ░█▀▄░█▀█░█░█░▀█▀░█▀▀░█▀▄                         ║"
    echo "  ║    ░▀▀█░░█░░█▀▄░█▀▀░█▀█░█░█   ░█▀▄░█░█░█░█░░█░░█▀▀░█▀▄                         ║"
    echo "  ║    ░▀▀▀░░▀░░▀░▀░▀▀▀░▀░▀░▀░▀   ░▀░▀░▀▀▀░▀▀▀░░▀░░▀▀▀░▀░▀                         ║"
    echo "  ║                                                                                ║"
    echo "  ║    Шлюз маскировки и L4/L7 распределения трафика для 3X-UI (Xray)   [v6.6.0]   ║"
    echo "  ║  ────────────────────────────────────────────────────────────────────────────  ║"
    echo "  ║  • L4 SNI Demux     : Проксирование доменов без расшифровки на уровне ядра     ║"
    echo "  ║  • Steal-Oneself    : Маскировка под свои домены с Anti-Loop защитой (9443)    ║"
    echo "  ║  • xHTTP Stream-One : Чистый HTTP/2 без раздувания буферов и вылетов XMUX     ║"
    echo "  ║  • UDP Dual-Stack   : Hysteria 2 (:443 UDP) + AmneziaWG v3.1 / v2.0 (:8443)    ║"
    echo "  ║  • Decoy Shield     : SPA-маскировка DataSphere + блокировка ботов и DPI (444) ║"
    echo "  ╚════════════════════════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    check_for_script_updates
}

# Spinner function for background processes
# Usage: run_with_spinner "Task description" bash_function_or_command
run_with_spinner() {
    local task_name="$1"
    shift
    local cmd=("$@")
    
    # Spinner glyphs
    local spin_chars=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local delay=0.08
    
    # Run command in background and redirect output to log
    "${cmd[@]}" >> "$INSTALL_LOG" 2>&1 &
    local pid=$!
    
    # Hide cursor
    tput civis 2>/dev/null || echo -ne "\033[?25l"
    
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % 10 ))
        printf "\r  ${CYAN}${spin_chars[$i]}${RESET}  ${WHITE}%-52s${RESET}" "$task_name..."
        sleep "$delay"
    done
    
    wait "$pid"
    local exit_code=$?
    
    # Show cursor
    tput cnorm 2>/dev/null || echo -ne "\033[?25h"
    
    if [ $exit_code -eq 0 ]; then
        printf "\r  ${GREEN}${CHECK}${RESET}  ${WHITE}%-52s${RESET} ${GREEN}[DONE]${RESET}\n" "$task_name"
        return 0
    else
        printf "\r  ${RED}${CROSS}${RESET}  ${WHITE}%-52s${RESET} ${RED}[FAILED]${RESET}\n" "$task_name"
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
prompt_mode() {
    echo -e "  ${WHITE}${BOLD}Выберите режим развертывания:${RESET}\n"
    echo -e "    ${CYAN}${BOLD}[1] Express Режим (Рекомендуется)${RESET} — Запуск в 1 клик для новичков"
    echo -e "        ${DIM}• Всего 2 вопроса: ваш домен и email для SSL.${RESET}"
    echo -e "        ${DIM}• Оптимизация ядра (BBR, буферы, TCP), фаервол UFW.${RESET}"
    echo -e "        ${DIM}• Nginx mainline с поддержкой stream ssl_preread.${RESET}"
    echo -e "        ${DIM}• Официальный 3X-UI с автоматической генерацией надежных паролей.${RESET}"
    echo -e "        ${DIM}• Готовый сайт-приманка (Decoy) + готовая L4-маршрутизация.${RESET}\n"
    echo -e "    ${YELLOW}${BOLD}[2] Экспертный Режим${RESET} — Пошаговое меню (setup_mask.sh)"
    echo -e "        ${DIM}• Ручной выбор всех портов, путей и тонких настроек.${RESET}\n"
    
    while true; do
        echo -ne "  ${WHITE}${ARROW} Ваш выбор [1/2] (по умолчанию: 1): ${RESET}"
        read -r MODE_CHOICE </dev/tty || MODE_CHOICE="1"
        MODE_CHOICE=${MODE_CHOICE:-1}
        if [[ "$MODE_CHOICE" =~ ^[12]$ ]]; then
            break
        fi
        echo -e "  ${RED}Пожалуйста, введите 1 или 2.${RESET}"
    done
}

# Collect Inputs for Express Mode
collect_express_inputs() {
    echo ""
    echo -e "  ${MAGENTA}${BOLD}Ввод основных параметров:${RESET}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${RESET}"
    
    echo -e "  ${YELLOW}${INFO} ВАЖНО О DNS-ЗАПИСЯХ:${RESET}"
    echo -e "  ${DIM}Для работы маскировки Nginx и Steal-Oneself REALITY в DNS нужны 2 A-записи:${RESET}"
    echo -e "    ${DIM}1) Основной домен (напр. domain.com)  ➜ IP вашего VPS (Маска, Панель, xHTTP)${RESET}"
    echo -e "    ${DIM}2) Поддомен (напр. cdn.domain.com)     ➜ IP вашего VPS (Steal-Oneself REALITY)${RESET}
"

    # 1. Domain
    while true; do
        echo -ne "  ${WHITE}${ARROW} Введите ваш основной домен (напр. domain.com или vpn.domain.com): ${RESET}"
        read -r PRIMARY_DOMAIN </dev/tty
        PRIMARY_DOMAIN=$(echo "$PRIMARY_DOMAIN" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        
        if [[ -z "$PRIMARY_DOMAIN" ]]; then
            echo -e "  ${RED}${CROSS} Домен не может быть пустым!${RESET}"
            continue
        fi
        
        if [[ ! "$PRIMARY_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
            echo -e "  ${RED}${CROSS} Некорректный формат домена. Попробуйте снова.${RESET}"
            continue
        fi
        break
    done
    
    # 2. Email
    while true; do
        echo -ne "  ${WHITE}${ARROW} Введите Email для сертификатов Let's Encrypt: ${RESET}"
        read -r LE_EMAIL </dev/tty
        LE_EMAIL=$(echo "$LE_EMAIL" | tr -d '[:space:]')
        
        if [[ -z "$LE_EMAIL" ]]; then
            echo -e "  ${RED}${CROSS} Email не может быть пустым!${RESET}"
            continue
        fi
        
        if [[ ! "$LE_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            echo -e "  ${RED}${CROSS} Некорректный формат email. Попробуйте снова.${RESET}"
            continue
        fi
        break
    done

    # 3. Optional SSH port
    echo -ne "  ${WHITE}${ARROW} Оставить порт SSH по умолчанию (22)? [Y/n]: ${RESET}"
    read -r KEEP_SSH </dev/tty || KEEP_SSH="y"
    KEEP_SSH=${KEEP_SSH:-y}
    if [[ "$KEEP_SSH" =~ ^[Nn]$ ]]; then
        while true; do
            echo -ne "  ${WHITE}${ARROW} Введите новый порт SSH (1024-65535): ${RESET}"
            read -r CUSTOM_SSH_PORT </dev/tty
            if [[ "$CUSTOM_SSH_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_SSH_PORT" -ge 1024 ] && [ "$CUSTOM_SSH_PORT" -le 65535 ]; then
                SSH_PORT=$CUSTOM_SSH_PORT
                break
            fi
            echo -e "  ${RED}${CROSS} Порт должен быть числом от 1024 до 65535.${RESET}"
        done
    else
        SSH_PORT=22
    fi

    # Generate secure random credentials for 3X-UI
    PANEL_USER="admin_$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
    PANEL_PASS="$(head /dev/urandom | tr -dc A-Za-z0-9_\- | head -c 16)"
    PANEL_SECRET="$(head /dev/urandom | tr -dc a-z0-9 | head -c 12)"
    PANEL_INTERNAL_PORT="2053"

    echo ""
    echo -e "  ${GREEN}${CHECK} Параметры приняты:${RESET}"
    echo -e "    ${DIM}• Домен:${RESET}      ${WHITE}${BOLD}$PRIMARY_DOMAIN${RESET}"
    echo -e "    ${DIM}• Email:${RESET}      ${WHITE}$LE_EMAIL${RESET}"
    echo -e "    ${DIM}• SSH Порт:${RESET}   ${WHITE}$SSH_PORT${RESET}"
    echo ""
    echo -ne "  ${WHITE}${ARROW} Начать автоматическое развертывание? [Y/n]: ${RESET}"
    read -r CONFIRM </dev/tty || CONFIRM="y"
    CONFIRM=${CONFIRM:-y}
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "  ${YELLOW}Установка отменена пользователем.${RESET}"
        exit 0
    fi
}

# --- Installation Steps ---

step_os_hardening() {
    export DEBIAN_FRONTEND=noninteractive
    
    # Update package lists
    apt-get update -y
    
    # Install foundational tools
    apt-get install -y curl wget git jq ufw certbot fail2ban ca-certificates lsb-release gnupg sed coreutils
    
    # 1. Enable BBR & System Network Tuning
    cat <<'EOF' > /etc/sysctl.d/99-vps-tuning.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.ipv4.tcp_mtu_probing=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
    sysctl --system >/dev/null 2>&1 || true

    # 2. SSH Configuration
    if [ "$SSH_PORT" -ne 22 ]; then
        sed -i -E "s/^#?Port [0-9]+/Port $SSH_PORT/" /etc/ssh/sshd_config
        systemctl restart ssh || systemctl restart sshd || true
    fi

    # 3. UFW Firewall Setup
    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming >/dev/null 2>&1 || true
    ufw default allow outgoing >/dev/null 2>&1 || true
    ufw allow "$SSH_PORT"/tcp comment 'SSH Port' >/dev/null 2>&1 || true
    ufw allow 80/tcp comment 'HTTP / ACME' >/dev/null 2>&1 || true
    ufw allow 443/tcp comment 'HTTPS / L4 Router' >/dev/null 2>&1 || true
    
    # Deny direct access to internal 3X-UI inbound ports
    ufw deny 10443/tcp comment 'VLESS Reality Internal' >/dev/null 2>&1 || true
    ufw deny 55443/tcp comment 'VLESS gRPC Internal' >/dev/null 2>&1 || true
    ufw deny 45443/tcp comment 'VLESS WS Internal' >/dev/null 2>&1 || true
    ufw deny 46443/tcp comment 'VLESS xHTTP Internal' >/dev/null 2>&1 || true
    ufw deny 50443/tcp comment 'Shadowsocks 2022 Internal' >/dev/null 2>&1 || true
    ufw deny 9443/tcp  comment 'Trojan Internal' >/dev/null 2>&1 || true
    ufw deny "$PANEL_INTERNAL_PORT"/tcp comment '3X-UI Panel Internal' >/dev/null 2>&1 || true
    
    echo "y" | ufw enable >/dev/null 2>&1 || true
}

step_install_3xui() {
    # Install official 3X-UI non-interactively
    # We download MHSanaei 3x-ui installer
    export DEBIAN_FRONTEND=noninteractive
    
    # Kill any existing service if reinstalling
    systemctl stop x-ui >/dev/null 2>&1 || true
    
    # Download and run official 3x-ui release
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<EOF
y
$PANEL_USER
$PANEL_PASS
$PANEL_INTERNAL_PORT
/$PANEL_SECRET/
EOF

    # Allow service to settle
    sleep 3
    systemctl enable x-ui >/dev/null 2>&1 || true
    systemctl restart x-ui >/dev/null 2>&1 || true
}

step_install_nginx_and_mask() {
    # Download scripts from repository into /root if not present
    mkdir -p /root/nginx_mask_setup
    cd /root/nginx_mask_setup
    
    wget -qO setup_mask.sh "${REPO_URL}/setup_mask.sh" || cp "${SCRIPT_DIR}/setup_mask.sh" ./setup_mask.sh
    wget -qO configure_3xui.sh "${REPO_URL}/configure_3xui.sh" || cp "${SCRIPT_DIR}/configure_3xui.sh" ./configure_3xui.sh
    chmod +x setup_mask.sh configure_3xui.sh
    
    # Download decoy template if needed
    if [ -f "${SCRIPT_DIR}/site.tar.gz" ]; then
        cp "${SCRIPT_DIR}/site.tar.gz" /root/nginx_mask_setup/
    fi

    # Run setup_mask.sh in automated mode
    # setup_mask.sh supports automated parameters or piped input
    # In express mode, we feed inputs to setup_mask.sh:
    # 1. Domain
    # 2. Let's Encrypt Email
    # 3. Decoy type (HTML5 game/template)
    # 4. Confirmations
    bash ./setup_mask.sh --auto \
        --domain "$PRIMARY_DOMAIN" \
        --email "$LE_EMAIL" \
        --panel-port "$PANEL_INTERNAL_PORT" \
        --panel-path "/$PANEL_SECRET/" || {
            # Fallback if --auto flag isn't supported by setup_mask.sh
            printf "%s\n%s\n1\ny\n" "$PRIMARY_DOMAIN" "$LE_EMAIL" | bash ./setup_mask.sh
        }
}

step_configure_inbounds() {
    cd /root/nginx_mask_setup
    if [ -f "./configure_3xui.sh" ]; then
        # Run 3X-UI database configuration
        bash ./configure_3xui.sh --non-interactive --domain "$PRIMARY_DOMAIN" || true
    fi
    
    # Ensure Nginx is reloaded and active
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || systemctl restart nginx
}

# Save credentials and connection summary
save_and_display_summary() {
    cat <<EOF > "$CREDENTIALS_FILE"
====================================================================
 NGINX L4 STREAM ROUTER & 3X-UI — УЧЕТНЫЕ ДАННЫЕ СЕРВЕРА
 Дата развертывания: $(date "+%Y-%m-%d %H:%M:%S %Z")
====================================================================

[ ВЕБ-ПАНЕЛЬ 3X-UI ]
URL Панели:     https://${PRIMARY_DOMAIN}/${PANEL_SECRET}/
Логин:          ${PANEL_USER}
Пароль:         ${PANEL_PASS}
Внутренний порт: 127.0.0.1:${PANEL_INTERNAL_PORT} (Закрыт извне фаерволом)

[ СЕТЕВЫЕ ПАРАМЕТРЫ ]
Основной домен: ${PRIMARY_DOMAIN}
SSL Сертификат: /etc/letsencrypt/live/${PRIMARY_DOMAIN}/
Внешние порты:  80/tcp (HTTP), 443/tcp (HTTPS Stream Router)
SSH Порт:       ${SSH_PORT}

[ НАСТРОЙКА КЛИЕНТОВ ]
1. Откройте панель: https://${PRIMARY_DOMAIN}/${PANEL_SECRET}/
2. Перейдите в раздел "Inbounds" (Подключения).
3. Скопируйте ссылку подключения (VLESS-XTLS-Reality, gRPC или WebSocket).
4. Импортируйте в клиент (v2rayN, v2rayNG, Sing-box, Nekoray).

Файл сохранен в: ${CREDENTIALS_FILE}
====================================================================
EOF
    chmod 600 "$CREDENTIALS_FILE"
}

# Final Unicode Box Dashboard
print_dashboard() {
    echo ""
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════════════════════${RESET}"
    echo -e "  ${GREEN}${BOLD}       ${CHECK} РАЗВЕРТЫВАНИЕ СИСТЕМЫ УСПЕШНО ЗАВЕРШЕНО!                           ${RESET}"
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════════════════════${RESET}"
    echo -e "  ${WHITE}${BOLD}Панель управления 3X-UI:${RESET}"
    echo -e "    ${CYAN}${ARROW} URL:${RESET}      ${WHITE}${BOLD}https://${PRIMARY_DOMAIN}/${PANEL_SECRET}/${RESET}"
    echo -e "    ${CYAN}${ARROW} Логин:${RESET}    ${WHITE}${PANEL_USER}${RESET}"
    echo -e "    ${CYAN}${ARROW} Пароль:${RESET}   ${YELLOW}${BOLD}${PANEL_PASS}${RESET}"
    echo ""
    echo -e "  ${WHITE}${BOLD}Архитектурная защита (L4 Stream Router):${RESET}"
    echo -e "    ${DIM}• Внешний фасад:${RESET}  ${GREEN}443 TCP (Nginx Stream ssl_preread)${RESET}"
    echo -e "    ${DIM}• Маскировка SNI:${RESET} ${WHITE}${PRIMARY_DOMAIN} ${DIM}➜${RESET} ${GREEN}Decoy Site (HTML5/Nginx)${RESET}"
    echo -e "    ${DIM}• Фаервол UFW:${RESET}    ${GREEN}Порты протоколов (10443, 55443 и др.) изолированы${RESET}"
    echo -e "    ${DIM}• Ядро Linux:${RESET}     ${GREEN}BBR активирован, IPv6 отключен (no leak)${RESET}"
    echo ""
    echo -e "  ${WHITE}${BOLD}Безопасность учетных данных:${RESET}"
    echo -e "    ${DIM}Все доступы сохранены в защищенный файл:${RESET} ${YELLOW}${CREDENTIALS_FILE}${RESET}"
    echo -e "    ${DIM}Для повторного просмотра:${RESET} ${CYAN}cat /root/vpn_credentials.txt${RESET}"
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════════════════════${RESET}"
    echo ""
}

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
