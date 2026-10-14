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
        SUB_SECRET="sub-$(head /dev/urandom | tr -dc a-z0-9 | head -c 8)"
        XHTTP_SECRET="$(head /dev/urandom | tr -dc a-z0-9 | head -c 8)"
        PANEL_INTERNAL_PORT="2053"
        return 0
    fi

    echo -e "  ${YELLOW}${INFO} ВАЖНО О DNS-ЗАПИСЯХ:${RESET}"
    echo -e "  ${DIM}Для работы веб-маскировки Nginx и VLESS REALITY в DNS нужны 2 A-записи:${RESET}"
    echo -e "    ${DIM}1) Основной домен (напр. domain.com)  ➜ IP вашего VPS (Сайт, Панель, VLESS xHTTP)${RESET}"
    echo -e "    ${DIM}2) Поддомен (напр. cdn.domain.com)     ➜ IP вашего VPS (Маскировка Reality под свой сайт)${RESET}
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

    # Сохраняем существующие учетные данные при повторном запуске, чтобы не инвалидировать доступ
    local existing_env="/root/nginx_mask_setup/setup_mask.env"
    [ ! -f "$existing_env" ] && [ -f "/etc/setup_mask.env" ] && existing_env="/etc/setup_mask.env"
    if [ -f "$existing_env" ]; then
        local saved_user saved_pass saved_path saved_sub saved_xhttp
        saved_user=$(grep -E '^ADMIN_USERNAME=' "$existing_env" 2>/dev/null | cut -d= -f2- | tr -d '"'\''')
        saved_pass=$(grep -E '^ADMIN_PASSWORD=' "$existing_env" 2>/dev/null | cut -d= -f2- | tr -d '"'\''')
        saved_path=$(grep -E '^PANEL_PATH=' "$existing_env" 2>/dev/null | cut -d= -f2- | tr -d '"'\''')
        saved_sub=$(grep -E '^SUB_PATH=' "$existing_env" 2>/dev/null | cut -d= -f2- | tr -d '"'\''')
        saved_xhttp=$(grep -E '^XHTTP_STREAM_PATH=' "$existing_env" 2>/dev/null | cut -d= -f2- | tr -d '"'\''')
        [ -n "$saved_user" ] && PANEL_USER="$saved_user"
        [ -n "$saved_pass" ] && PANEL_PASS="$saved_pass"
        if [ -n "$saved_path" ]; then
            PANEL_SECRET="${saved_path#/}"
            PANEL_SECRET="${PANEL_SECRET%/}"
        fi
        if [ -n "$saved_sub" ] && [ "$saved_sub" != "my-post-key" ] && [ "$saved_sub" != "/my-post-key/" ]; then
            SUB_SECRET="${saved_sub#/}"
            SUB_SECRET="${SUB_SECRET%/}"
        fi
        if [ -n "$saved_xhttp" ] && [ "$saved_xhttp" != "Stream-One-Path" ] && [ "$saved_xhttp" != "/Stream-One-Path/" ] && [[ "$saved_xhttp" != *vless-* ]]; then
            XHTTP_SECRET="${saved_xhttp#/}"
            XHTTP_SECRET="${XHTTP_SECRET%/}"
        fi
    fi

    # Generate secure random credentials for 3X-UI if not restored
    [ -z "${PANEL_USER:-}" ] && PANEL_USER="admin_$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
    [ -z "${PANEL_PASS:-}" ] && PANEL_PASS="$(head /dev/urandom | tr -dc A-Za-z0-9_\- | head -c 16)"
    [ -z "${PANEL_SECRET:-}" ] && PANEL_SECRET="$(head /dev/urandom | tr -dc a-z0-9 | head -c 12)"
    [ -z "${SUB_SECRET:-}" ] && SUB_SECRET="sub-$(head /dev/urandom | tr -dc a-z0-9 | head -c 8)"
    [ -z "${XHTTP_SECRET:-}" ] && XHTTP_SECRET="$(head /dev/urandom | tr -dc a-z0-9 | head -c 8)"
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

