#!/usr/bin/env bash
# ==============================================================================
# Nginx L4 Stream Router Mask for 3X-UI — Unified Master Installer
# GitHub: https://github.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui
# ==============================================================================

# Exit on severe unhandled errors
set -o pipefail

SCRIPT_VERSION="v7.3.0"

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
    
    # Автоопределение текущего активного порта SSH
    SSH_ACTIVE_PORT=$(detect_active_ssh_port)

    # Неинтерактивный режим: если параметры уже переданы через переменные окружения
    if [[ -n "${PRIMARY_DOMAIN:-}" && -n "${LE_EMAIL:-}" ]]; then
        PRIMARY_DOMAIN=$(echo "$PRIMARY_DOMAIN" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        LE_EMAIL=$(echo "$LE_EMAIL" | tr -d '[:space:]')
        SSH_PORT="${SSH_PORT:-$SSH_ACTIVE_PORT}"
        echo -e "  ${GREEN}${CHECK} Параметры приняты из переменных окружения:${RESET}"
        echo -e "    ${DIM}• Домен:${RESET}      ${WHITE}${BOLD}$PRIMARY_DOMAIN${RESET}"
        echo -e "    ${DIM}• Email:${RESET}      ${WHITE}$LE_EMAIL${RESET}"
        echo -e "    ${DIM}• SSH Порт:${RESET}   ${WHITE}$SSH_PORT${RESET} ${DIM}(активный: $SSH_ACTIVE_PORT)${RESET}"
        echo ""
        PANEL_USER="admin_$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
        PANEL_PASS="$(head /dev/urandom | tr -dc A-Za-z0-9_\- | head -c 16)"
        PANEL_SECRET="$(head /dev/urandom | tr -dc a-z0-9 | head -c 12)"
        PANEL_INTERNAL_PORT="2053"
        return 0
    fi

    echo -e "  ${YELLOW}${INFO} ВАЖНО О DNS-ЗАПИСЯХ:${RESET}"
    echo -e "  ${DIM}Для работы маскировки Nginx и Steal-Oneself REALITY в DNS нужны 2 A-записи:${RESET}"
    echo -e "    ${DIM}1) Основной домен (напр. domain.com)  ➜ IP вашего VPS (Маска, Панель, xHTTP)${RESET}"
    echo -e "    ${DIM}2) Поддомен (напр. cdn.domain.com)     ➜ IP вашего VPS (Steal-Oneself REALITY)${RESET}
"

    # 1. Domain
    while true; do
        echo -ne "  ${WHITE}${ARROW} Введите ваш основной домен (напр. domain.com или vpn.domain.com): ${RESET}"
        read -r PRIMARY_DOMAIN </dev/tty 2>/dev/null || read -r PRIMARY_DOMAIN 2>/dev/null || true
        PRIMARY_DOMAIN=$(echo "${PRIMARY_DOMAIN:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        
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
        read -r LE_EMAIL </dev/tty 2>/dev/null || read -r LE_EMAIL 2>/dev/null || true
        LE_EMAIL=$(echo "${LE_EMAIL:-}" | tr -d '[:space:]')
        
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
    echo -ne "  ${WHITE}${ARROW} Оставить текущий порт SSH (${SSH_ACTIVE_PORT})? [Y/n]: ${RESET}"
    read -r KEEP_SSH </dev/tty 2>/dev/null || read -r KEEP_SSH 2>/dev/null || KEEP_SSH="y"
    KEEP_SSH=${KEEP_SSH:-y}
    if [[ "$KEEP_SSH" =~ ^[Nn]$ ]]; then
        while true; do
            echo -ne "  ${WHITE}${ARROW} Введите новый порт SSH (1024-65535): ${RESET}"
            read -r CUSTOM_SSH_PORT </dev/tty 2>/dev/null || read -r CUSTOM_SSH_PORT 2>/dev/null || true
            if [[ "$CUSTOM_SSH_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_SSH_PORT" -ge 1024 ] && [ "$CUSTOM_SSH_PORT" -le 65535 ]; then
                SSH_PORT=$CUSTOM_SSH_PORT
                break
            fi
            echo -e "  ${RED}${CROSS} Порт должен быть числом от 1024 до 65535.${RESET}"
        done
    else
        SSH_PORT="$SSH_ACTIVE_PORT"
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
    echo -e "    ${DIM}• SSH Порт:${RESET}   ${WHITE}$SSH_PORT${RESET} ${DIM}(активный: $SSH_ACTIVE_PORT)${RESET}"
    echo ""
    echo -ne "  ${WHITE}${ARROW} Начать автоматическое развертывание? [Y/n]: ${RESET}"
    read -r CONFIRM </dev/tty 2>/dev/null || read -r CONFIRM 2>/dev/null || CONFIRM="y"
    CONFIRM=${CONFIRM:-y}
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "  ${YELLOW}Установка отменена пользователем.${RESET}"
        exit 0
    fi
}

# --- SSH Configuration & Hardening ---
apply_ssh_configuration() {
    local target_port="$1"
    local active_port="$2"

    if [ "$target_port" -eq "$active_port" ]; then
        return 0
    fi

    local ssh_svc
    ssh_svc=$(get_ssh_service_name)

    # 1. Отключаем systemd socket-activation (Ubuntu 22.10+, Ubuntu 24.04 LTS)
    systemctl stop ssh.socket 2>/dev/null || true
    systemctl disable ssh.socket 2>/dev/null || true
    systemctl enable "${ssh_svc}.service" 2>/dev/null || true

    # 2. Обновляем базовый /etc/ssh/sshd_config с гарантией Include
    if [ -f /etc/ssh/sshd_config ]; then
        sed -i -E "s/^[#\s]*Port [0-9]+/Port ${target_port}/" /etc/ssh/sshd_config || true
        if ! grep -q "^Include /etc/ssh/sshd_config.d/\*\.conf" /etc/ssh/sshd_config 2>/dev/null; then
            sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config 2>/dev/null || true
        fi
    fi

    # 3. Drop-in конфигурация для OpenSSH с явным портом
    mkdir -p /etc/ssh/sshd_config.d/
    cat << EOF > /etc/ssh/sshd_config.d/99-hardening.conf
Port ${target_port}
AddressFamily inet
PubkeyAuthentication yes
EOF

    # 4. Проверяем валидность конфигурации sshd перед перезапуском
    mkdir -p /run/sshd
    if /usr/sbin/sshd -t 2>/dev/null; then
        systemctl restart "${ssh_svc}.service" || true
    else
        # При синтаксической ошибке — безопасный откат
        rm -f /etc/ssh/sshd_config.d/99-hardening.conf
        systemctl restart "${ssh_svc}.service" || true
    fi
}

# --- Installation Steps ---

step_os_hardening() {
    export DEBIAN_FRONTEND=noninteractive
    
    # Update package lists
    apt-get update -y
    
    # Install foundational tools (включая python3-systemd для fail2ban и python3-bcrypt для 3x-ui)
    apt-get install -y curl wget git jq ufw certbot fail2ban python3-systemd python3-bcrypt ca-certificates lsb-release gnupg sed coreutils
    
    # 1. Enable BBR & System Network Tuning
    cat <<'EOF' > /etc/sysctl.d/99-vps-tuning.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.ipv4.ip_nonlocal_bind=1
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=65535
net.core.netdev_max_backlog=100000
net.ipv4.ip_local_port_range=1024 65535
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

    # Zero-Log Policy для journald (хранение логов в RAM)
    mkdir -p /etc/systemd/journald.conf.d/
    cat << 'EOF' > /etc/systemd/journald.conf.d/00-volatile.conf
[Journal]
Storage=volatile
RuntimeMaxUse=64M
MaxRetentionSec=1day
EOF
    systemctl restart systemd-journald 2>/dev/null || true

    # Disable IPv6 immediately on all active interfaces (runtime)
    if [ -d /proc/sys/net/ipv6/conf ]; then
        for iface in $(ls /proc/sys/net/ipv6/conf/ 2>/dev/null); do
            sysctl -w net.ipv6.conf."$iface".disable_ipv6=1 >/dev/null 2>&1 || true
        done
    fi

    # Hardware/Kernel level disable via GRUB (survives cloud network resets upon reboot)
    if [ -f /etc/default/grub ]; then
        if ! grep -q "ipv6.disable=1" /etc/default/grub; then
            cp /etc/default/grub /etc/default/grub.bak 2>/dev/null || true
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1 /' /etc/default/grub
            sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT='/GRUB_CMDLINE_LINUX_DEFAULT='ipv6.disable=1 /" /etc/default/grub
            sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="ipv6.disable=1 /' /etc/default/grub
            sed -i "s/GRUB_CMDLINE_LINUX='/GRUB_CMDLINE_LINUX='ipv6.disable=1 /" /etc/default/grub
            if command -v update-grub &>/dev/null; then
                update-grub >/dev/null 2>&1 || true
            elif command -v grub-mkconfig &>/dev/null; then
                grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
            fi
        fi
    fi

    # Crontab guard against cloud-init / network daemon sysctl overrides on boot
    if command -v crontab &>/dev/null; then
        cron_job="@reboot sleep 10 && sysctl --system"
        if ! crontab -l 2>/dev/null | grep -Fq "$cron_job"; then
            (crontab -l 2>/dev/null || true; echo "$cron_job") | crontab - 2>/dev/null || true
        fi
    fi

    # 2. SSH Configuration & Fail2ban (Zero-Lockout)
    apply_ssh_configuration "$SSH_PORT" "$SSH_ACTIVE_PORT"

    cat << EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = ${SSH_ACTIVE_PORT},${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 1h
backend = systemd
EOF
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true

    # 3. UFW Firewall Setup & Disable IPv6 in UFW
    ufw --force reset >/dev/null 2>&1 || true
    if [ -f /etc/default/ufw ]; then
        sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
        if grep -q "^IPV6=" /etc/default/ufw; then
            sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw 2>/dev/null || true
        else
            echo "IPV6=no" >> /etc/default/ufw 2>/dev/null || true
        fi
    fi
    ufw default deny incoming >/dev/null 2>&1 || true
    ufw default allow outgoing >/dev/null 2>&1 || true

    # КРИТИЧЕСКАЯ ЗАЩИТА: Всегда разрешаем ТЕКУЩИЙ активный порт SSH
    ufw allow "${SSH_ACTIVE_PORT}/tcp" comment 'Current SSH Port' >/dev/null 2>&1 || true

    # Если задан новый целевой порт — разрешаем и его параллельно (Zero-Lockout)
    if [ "$SSH_PORT" -ne "$SSH_ACTIVE_PORT" ]; then
        ufw allow "${SSH_PORT}/tcp" comment 'Target SSH Port' >/dev/null 2>&1 || true
    fi
    ufw allow 80/tcp comment 'HTTP / ACME' >/dev/null 2>&1 || true
    ufw allow 443/tcp comment 'HTTPS / L4 Router' >/dev/null 2>&1 || true
    ufw allow 443/udp comment 'QUIC / H3 / Hysteria 2' >/dev/null 2>&1 || true
    ufw allow 8443/udp comment 'AmneziaWG v3 / Hysteria 2' >/dev/null 2>&1 || true
    ufw allow 8444/udp comment 'AmneziaWG v2' >/dev/null 2>&1 || true
    ufw allow 51820/udp comment 'Native AmneziaWG' >/dev/null 2>&1 || true
    ufw allow 20000:50000/udp comment 'Hysteria 2 Port Hopping' >/dev/null 2>&1 || true
    
    # Deny direct access to internal 3X-UI inbound ports
    ufw deny 10443/tcp comment 'VLESS Reality Internal' >/dev/null 2>&1 || true
    ufw deny 11443/tcp comment 'Anti-Loop Stub Internal' >/dev/null 2>&1 || true
    ufw deny 55443/tcp comment 'VLESS gRPC Internal' >/dev/null 2>&1 || true
    ufw deny 45443/tcp comment 'VLESS WS Internal' >/dev/null 2>&1 || true
    ufw deny 46443/tcp comment 'VLESS xHTTP Internal' >/dev/null 2>&1 || true
    ufw deny 50443/tcp comment 'Shadowsocks 2022 Internal' >/dev/null 2>&1 || true
    ufw deny 9443/tcp  comment 'Trojan Internal' >/dev/null 2>&1 || true
    ufw deny "$PANEL_INTERNAL_PORT"/tcp comment '3X-UI Panel Internal' >/dev/null 2>&1 || true
    
    echo "y" | ufw enable >/dev/null 2>&1 || true
}

step_install_3xui() {
    export DEBIAN_FRONTEND=noninteractive
    
    # Kill any existing service if reinstalling
    systemctl stop x-ui >/dev/null 2>&1 || true
    
    # Download and run official 3x-ui release with default quick install
    # (Все параметры: логин, пароль, порт и webBasePath настраиваются через SQLite в configure_3xui.sh)
    local ui_installer="/tmp/3x-ui-install.sh"
    rm -f "$ui_installer"
    if ! curl -fsSL --connect-timeout 15 "https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh" -o "$ui_installer" 2>/dev/null; then
        curl -fsSL --connect-timeout 15 "https://ghfast.top/https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh" -o "$ui_installer" 2>/dev/null || true
    fi
    
    if [ -f "$ui_installer" ]; then
        printf "n\n" | bash "$ui_installer" >/dev/null 2>&1 || true
        rm -f "$ui_installer"
    else
        printf "n\n" | bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) >/dev/null 2>&1 || true
    fi

    # Allow service to settle
    sleep 2
    systemctl enable x-ui >/dev/null 2>&1 || true
    systemctl restart x-ui >/dev/null 2>&1 || true
}

step_install_nginx_and_mask() {
    # Download scripts from repository into /root if not present
    mkdir -p /root/nginx_mask_setup
    cd /root/nginx_mask_setup
    
    if [ -f "${SCRIPT_DIR}/setup_mask.sh" ]; then
        cp "${SCRIPT_DIR}/setup_mask.sh" ./setup_mask.sh
    else
        wget -qO setup_mask.sh "${REPO_URL}/setup_mask.sh"
    fi
    if [ -f "${SCRIPT_DIR}/configure_3xui.sh" ]; then
        cp "${SCRIPT_DIR}/configure_3xui.sh" ./configure_3xui.sh
    else
        wget -qO configure_3xui.sh "${REPO_URL}/configure_3xui.sh"
    fi
    chmod +x setup_mask.sh configure_3xui.sh
    
    # Download decoy template if needed
    if [ -f "${SCRIPT_DIR}/site.tar.gz" ]; then
        cp "${SCRIPT_DIR}/site.tar.gz" /root/nginx_mask_setup/
    fi

    # Run setup_mask.sh in automated mode with explicit admin credentials
    export ADMIN_USERNAME="$PANEL_USER"
    export ADMIN_PASSWORD="$PANEL_PASS"
    export PANEL_PORT="$PANEL_INTERNAL_PORT"
    export PANEL_PATH="/$PANEL_SECRET/"

    bash ./setup_mask.sh --auto \
        --domain "$PRIMARY_DOMAIN" \
        --email "$LE_EMAIL" \
        --panel-port "$PANEL_INTERNAL_PORT" \
        --panel-path "/$PANEL_SECRET/" \
        --user "$PANEL_USER" \
        --pass "$PANEL_PASS" || {
            # Fallback if --auto flag isn't supported by setup_mask.sh
            printf "%s\n%s\n1\ny\n" "$PRIMARY_DOMAIN" "$LE_EMAIL" | bash ./setup_mask.sh
        }
}

step_configure_inbounds() {
    cd /root/nginx_mask_setup
    if [ -f "./configure_3xui.sh" ]; then
        export ADMIN_USERNAME="$PANEL_USER"
        export ADMIN_PASSWORD="$PANEL_PASS"
        export PANEL_PORT="$PANEL_INTERNAL_PORT"
        export PANEL_PATH="/$PANEL_SECRET/"
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
    if [ "$SSH_PORT" -ne "${SSH_ACTIVE_PORT:-22}" ]; then
        echo -e "  ${YELLOW}${BOLD}⚠️  ВНИМАНИЕ: Порт SSH изменен на ${WHITE}${SSH_PORT}${YELLOW}!${RESET}"
        echo -e "    ${DIM}1. Проверьте вход в НОВОМ окне терминала:${RESET} ${CYAN}ssh -p ${SSH_PORT} root@${PRIMARY_DOMAIN}${RESET}"
        echo -e "    ${DIM}2. После успешной проверки закройте старый порт ${SSH_ACTIVE_PORT} в UFW:${RESET}"
        echo -e "       ${WHITE}ufw delete allow ${SSH_ACTIVE_PORT}/tcp${RESET}"
        echo ""
    fi
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
