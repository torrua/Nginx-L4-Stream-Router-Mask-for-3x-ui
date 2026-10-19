# ==============================================================================
#  Подсистема безопасности хоста: SSH Hardening, SSH Keys, Dual-Port & Fail2ban
# ==============================================================================

WHITE="${WHITE:-}"
NC="${NC:-}"
YELLOW="${YELLOW:-}"
RED="${RED:-}"
GREEN="${GREEN:-}"
CYAN="${CYAN:-}"
BOLD="${BOLD:-}"
ARROW="${ARROW:-}"
DIM="${DIM:-}"

has_authorized_keys() {
    local target_user="${1:-root}"
    local user_home
    if [ "$target_user" = "root" ]; then
        user_home="/root"
    else
        user_home=$(eval echo "~$target_user" 2>/dev/null || echo "/home/$target_user")
    fi
    local auth_file="${user_home}/.ssh/authorized_keys"
    if [ -f "$auth_file" ] && [ -s "$auth_file" ]; then
        if grep -qE '^[[:space:]]*(ssh-rsa|ssh-ed25519|ecdsa-sha2-[a-z0-9]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-[a-z0-9]+@openssh\.com)' "$auth_file" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

add_authorized_key() {
    local key_data="$1"
    local target_user="${2:-root}"
    [ -n "$key_data" ] || return 1

    local user_home
    if [ "$target_user" = "root" ]; then
        user_home="/root"
    else
        user_home=$(eval echo "~$target_user" 2>/dev/null || echo "/home/$target_user")
    fi

    mkdir -p "${user_home}/.ssh"
    chmod 700 "${user_home}/.ssh" 2>/dev/null || true

    local auth_file="${user_home}/.ssh/authorized_keys"
    touch "$auth_file"
    chmod 600 "$auth_file" 2>/dev/null || true

    # Проверка, не добавлен ли уже этот ключ
    local clean_key
    clean_key=$(echo "$key_data" | awk '{print $1" "$2}')
    if [ -n "$clean_key" ] && grep -Fq "$clean_key" "$auth_file" 2>/dev/null; then
        ok "SSH-ключ уже присутствует в $auth_file."
        return 0
    fi

    echo "$key_data" >> "$auth_file"
    chmod 600 "$auth_file" 2>/dev/null || true
    if [ "$target_user" != "root" ] && command -v chown >/dev/null 2>&1; then
        chown -R "${target_user}:${target_user}" "${user_home}/.ssh" 2>/dev/null || true
    fi
    ok "SSH-ключ успешно добавлен в ${auth_file}."
    return 0
}

generate_ed25519_keypair() {
    local target_user="${1:-root}"
    local user_home
    if [ "$target_user" = "root" ]; then
        user_home="/root"
    else
        user_home=$(eval echo "~$target_user" 2>/dev/null || echo "/home/$target_user")
    fi

    mkdir -p "${user_home}/.ssh"
    chmod 700 "${user_home}/.ssh" 2>/dev/null || true

    local key_file="${user_home}/.ssh/id_ed25519_$(date +%Y%m%d_%H%M%S)"
    if ! ssh-keygen -t ed25519 -f "$key_file" -C "server-${target_user}-$(date +%Y%m%d)" -N "" -q 2>/dev/null; then
        warn "Не удалось сгенерировать пару ключей ssh-keygen."
        return 1
    fi

    local auth_file="${user_home}/.ssh/authorized_keys"
    cat "${key_file}.pub" >> "$auth_file"
    chmod 600 "$auth_file" "${key_file}" 2>/dev/null || true
    if [ "$target_user" != "root" ] && command -v chown >/dev/null 2>&1; then
        chown -R "${target_user}:${target_user}" "${user_home}/.ssh" 2>/dev/null || true
    fi

    echo
    echo -e "${RED}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║${NC}             ${WHITE}${BOLD}🔑 ВНИМАНИЕ: СОХРАНИТЕ ЭТОТ ПРИВАТНЫЙ КЛЮЧ ПРЯМО СЕЙЧАС!${NC}           ${RED}║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${YELLOW}Скопируйте всё содержимое между линиями и сохраните в файл на своем ПК${NC}"
    echo -e "  ${YELLOW}(например, ~/.ssh/server_key или puttygen -> id_ed25519.ppk):${NC}"
    echo -e "${CYAN}--------------------------------------------------------------------------------${NC}"
    cat "$key_file"
    echo -e "${CYAN}--------------------------------------------------------------------------------${NC}"
    echo
    if [ -t 0 ]; then
        local dummy=""
        read -r -p "  Нажмите [Enter] после того, как сохранили приватный ключ в надежном месте..." dummy </dev/tty 2>/dev/null || read -r -p "  Нажмите [Enter]..." dummy 2>/dev/null || true
    fi
    ok "SSH-ключ Ed25519 сгенерирован и добавлен в ${auth_file}."
    return 0
}

verify_ssh_local_port() {
    local port="$1"
    local timeout_sec="${2:-3}"

    # 1. Попытка чтения баннера SSH-2.0 через Bash /dev/tcp
    local banner=""
    banner=$(timeout "$timeout_sec" bash -c "exec 3<>/dev/tcp/127.0.0.1/$port; head -n 1 <&3" 2>/dev/null || true)
    if [[ "$banner" == *"SSH-2.0"* ]]; then
        return 0
    fi

    # 2. Попытка через nc
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w "$timeout_sec" 127.0.0.1 "$port" 2>/dev/null; then
            return 0
        fi
    fi

    # 3. Попытка через ss
    if command -v ss >/dev/null 2>&1; then
        if ss -tln sport = ":$port" 2>/dev/null | grep -q ":$port"; then
            return 0
        fi
    fi

    return 1
}

apply_ssh_configuration() {
    local target_port="${1:-22}"
    local active_port="${2:-22}"
    local disable_pwd="${3:-n}"

    local ssh_svc
    ssh_svc=$(get_ssh_service_name)

    # 1. Отключаем systemd socket-activation (Ubuntu 22.10+, Ubuntu 24.04 LTS),
    # чтобы служба корректно слушала кастомный порт через стандартный unit.
    systemctl stop ssh.socket 2>/dev/null || true
    systemctl disable ssh.socket 2>/dev/null || true
    systemctl enable "${ssh_svc}.service" 2>/dev/null || true

    # 2. Обновляем базовый /etc/ssh/sshd_config с гарантией директивы Include
    if [ -f /etc/ssh/sshd_config ]; then
        sed -i -E "s/^[#\s]*Port [0-9]+/Port ${target_port}/" /etc/ssh/sshd_config 2>/dev/null || true
        if ! grep -q "^Include /etc/ssh/sshd_config.d/\*\.conf" /etc/ssh/sshd_config 2>/dev/null; then
            sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config 2>/dev/null || true
        fi
    fi

    # 3. Drop-in конфигурация: ДВУХПОРТОВЫЙ РЕЖИМ при смене порта
    mkdir -p /etc/ssh/sshd_config.d/
    local dropin_file="/etc/ssh/sshd_config.d/99-hardening.conf"

    # Формируем директивы портов
    local port_directives="Port ${target_port}"
    if [ "$target_port" -ne "$active_port" ]; then
        port_directives="Port ${target_port}
Port ${active_port}"
    fi

    # Проверяем, можно ли отключить вход по паролю (ТОЛЬКО если есть валидные ключи)
    local pwd_directives=""
    if is_true "$disable_pwd"; then
        if has_authorized_keys "root"; then
            pwd_directives="PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes"
            ok "Вход по паролю будет отключен (авторизованные SSH-ключи подтверждены)."
        else
            warn "Внимание: в authorized_keys не найдено SSH-ключей! Вход по паролю оставлен включенным для предотвращения потери доступа."
        fi
    fi

    cat << EOF > "$dropin_file"
# Сгенерировано Nginx Stream Router Security Subsystem
${port_directives}
AddressFamily inet
PubkeyAuthentication yes
${pwd_directives}
EOF
    chmod 600 "$dropin_file" 2>/dev/null || true

    # 4. Проверяем валидность конфигурации sshd перед перезапуском
    mkdir -p /run/sshd 2>/dev/null || true
    if /usr/sbin/sshd -t 2>/dev/null; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl restart "${ssh_svc}.service" 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    else
        # При синтаксической ошибке — безопасный откат
        warn "Ошибка валидации sshd -t при настройке SSH! Выполнен откат изменений drop-in для предотвращения потери доступа."
        rm -f "$dropin_file"
        systemctl restart "${ssh_svc}.service" 2>/dev/null || true
        return 1
    fi

    # 5. Локальный тест ответа порта
    if [ "$target_port" -ne "$active_port" ]; then
        if verify_ssh_local_port "$target_port" 5; then
            ok "Служба SSH запущена в переходном режиме: слушает новый порт ${WHITE}${target_port}${NC} и резервный порт ${WHITE}${active_port}${NC}."
        else
            warn "Локальный тест порта $target_port не дал ответа! Выполняется откат на активный порт $active_port..."
            cat << EOF > "$dropin_file"
Port ${active_port}
AddressFamily inet
PubkeyAuthentication yes
EOF
            chmod 600 "$dropin_file" 2>/dev/null || true
            systemctl restart "${ssh_svc}.service" 2>/dev/null || true
            return 1
        fi
    else
        ok "Конфигурация SSH успешно применена (порт ${WHITE}${target_port}${NC})."
    fi

    return 0
}

deploy_ssh_transition_watcher() {
    local target_port="$1"
    local active_port="$2"
    local ttl_hours="${3:-24}"

    [ "$target_port" -eq "$active_port" ] && return 0

    local watcher_script="/usr/local/bin/ssh-transition-watcher.sh"
    local watcher_service="/etc/systemd/system/ssh-transition-watcher.service"
    local bin_dir="/usr/local/bin"
    [ -d "$bin_dir" ] || mkdir -p "$bin_dir" 2>/dev/null || true

    cat << 'EOF' > "$watcher_script"
#!/usr/bin/env bash
# SSH Port Transition Watcher — безопасное закрытие старого порта при первом успешном входе на новый
set -u
TARGET_PORT="${1:-2222}"
ACTIVE_PORT="${2:-22}"
TTL_HOURS="${3:-24}"

START_TIME=$(date +%s)
MAX_RUNTIME=$((TTL_HOURS * 3600))

logger -t ssh-watcher "Запущен безопасный монитор перехода SSH: цель=$TARGET_PORT, старый=$ACTIVE_PORT, TTL=${TTL_HOURS}ч."

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    if [ "$ELAPSED" -ge "$MAX_RUNTIME" ]; then
        logger -t ssh-watcher "Истек лимит времени ожидания (${TTL_HOURS}ч). Старый порт $ACTIVE_PORT оставлен для предотвращения потери доступа."
        exit 0
    fi

    # Ищем установленное внешнее соединение на целевой порт
    EST=$(ss -tn sport = ":${TARGET_PORT}" state established 2>/dev/null | grep -vE '127\.0\.0\.1|::1|Local Address' | wc -l)
    if [ "$EST" -gt 0 ]; then
        logger -t ssh-watcher "Обнаружено успешное подключение на порт $TARGET_PORT! Финализация перехода и закрытие порта $ACTIVE_PORT..."

        # 1. Удаляем старый порт из drop-in sshd
        if [ -f /etc/ssh/sshd_config.d/99-hardening.conf ]; then
            sed -i "/^Port ${ACTIVE_PORT}$/d" /etc/ssh/sshd_config.d/99-hardening.conf 2>/dev/null || true
        fi
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true

        # 2. Удаляем старый порт из UFW
        if command -v ufw >/dev/null 2>&1; then
            ufw delete allow "${ACTIVE_PORT}/tcp" >/dev/null 2>&1 || true
        fi

        # 3. Обновляем Fail2ban
        if [ -f /etc/fail2ban/jail.local ]; then
            sed -i "s/port = .*/port = ${TARGET_PORT}/" /etc/fail2ban/jail.local 2>/dev/null || true
            systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban 2>/dev/null || true
        fi

        logger -t ssh-watcher "Переход SSH успешно завершен. Порт $ACTIVE_PORT закрыт, активен только $TARGET_PORT."
        systemctl disable --now ssh-transition-watcher.service 2>/dev/null || true
        rm -f /etc/systemd/system/ssh-transition-watcher.service /usr/local/bin/ssh-transition-watcher.sh 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        exit 0
    fi

    sleep 5
done
EOF
    chmod +x "$watcher_script" 2>/dev/null || true

    mkdir -p /etc/systemd/system
    cat << EOF > "$watcher_service"
[Unit]
Description=SSH Port Transition Safe Watcher
After=network.target sshd.service ssh.service

[Service]
Type=simple
ExecStart=${watcher_script} ${target_port} ${active_port} ${ttl_hours}
Restart=no

[Install]
WantedBy=multi-user.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable --now ssh-transition-watcher.service >/dev/null 2>&1 || true
        ok "Развернут фоновый сторожевой сервис ${WHITE}ssh-transition-watcher.service${NC}."
    fi
}

finalize_ssh_transition() {
    local target_port="$1"
    local active_port="$2"
    local ssh_svc
    ssh_svc=$(get_ssh_service_name)

    [ "$target_port" -eq "$active_port" ] && return 0

    log "Финализация перехода SSH: закрытие резервного порта ${active_port}..."

    # 1. Удаляем старый порт из drop-in конфигурации
    if [ -f /etc/ssh/sshd_config.d/99-hardening.conf ]; then
        sed -i "/^Port ${active_port}$/d" /etc/ssh/sshd_config.d/99-hardening.conf 2>/dev/null || true
    fi

    # 2. Обновляем базовый /etc/ssh/sshd_config
    if [ -f /etc/ssh/sshd_config ]; then
        sed -i -E "s/^[#\s]*Port [0-9]+/Port ${target_port}/" /etc/ssh/sshd_config 2>/dev/null || true
    fi

    # 3. Валидация и перезагрузка sshd
    mkdir -p /run/sshd 2>/dev/null || true
    if /usr/sbin/sshd -t 2>/dev/null; then
        systemctl reload "${ssh_svc}.service" 2>/dev/null || systemctl restart "${ssh_svc}.service" 2>/dev/null || true
    fi

    # 4. Удаляем старый порт из UFW
    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "${active_port}/tcp" >/dev/null 2>&1 || true
    fi

    # 5. Обновляем Fail2ban
    if [ -f /etc/fail2ban/jail.local ]; then
        sed -i "s/port = .*/port = ${target_port}/" /etc/fail2ban/jail.local 2>/dev/null || true
        systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban 2>/dev/null || true
    fi

    # 6. Останавливаем и удаляем watcher
    systemctl disable --now ssh-transition-watcher.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/ssh-transition-watcher.service /usr/local/bin/ssh-transition-watcher.sh 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    ok "Резервный порт SSH ${active_port} закрыт. SSH теперь работает исключительно на порту ${WHITE}${target_port}${NC}."
}

wait_and_finalize_ssh_transition() {
    local target_port="$1"
    local active_port="$2"
    local timeout_sec="${3:-30}"

    [ "$target_port" -eq "$active_port" ] && return 0

    if is_true "${FORCE_CLOSE_OLD_SSH:-n}"; then
        ok "Включен режим принудительного закрытия (--force-close-old-ssh / FORCE_CLOSE_OLD_SSH=y)."
        finalize_ssh_transition "$target_port" "$active_port"
        return 0
    fi

    # Если скрипт выполняется не интерактивно (нет tty) — поднимаем watcher и выходим
    if [ ! -t 0 ] || [ "${NON_INTERACTIVE:-0}" -eq 1 ]; then
        log "Неинтерактивный запуск: активирован фоновый watcher перехода SSH."
        deploy_ssh_transition_watcher "$target_port" "$active_port" 24
        return 0
    fi

    local host_ip
    host_ip=$(get_wan_ip)

    echo
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║${NC}             ${WHITE}${BOLD}⚡ БЕЗОПАСНЫЙ ПЕРЕХОД SSH: ПОРТЫ ${target_port} (НОВЫЙ) И ${active_port} (СТАРЫЙ)${NC}            ${YELLOW}║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "  Служба SSH сейчас слушает ${GREEN}ОБА порта (${target_port} и ${active_port})${NC}. Ваша текущая сессия не прервана."
    echo -e "  Брандмауэр UFW и Fail2ban защищают оба порта."
    echo
    echo -e "  ${CYAN}${BOLD}ПРОВЕРЬТЕ ПОДКЛЮЧЕНИЕ В НОВОЙ ВКЛАДКЕ ТЕРМИНАЛА:${NC}"
    echo -e "    ${WHITE}ssh -p ${target_port} root@${host_ip}${NC}"
    echo
    echo -e "  ${WHITE}[1]${NC} Ожидать вашего подключения (${timeout_sec} сек, автозакрытие при успехе) ${GREEN}[Enter]${NC}"
    echo -e "  ${WHITE}[2]${NC} Оставить оба порта и передать контроль фоновому watcher (закроет старый порт позже)"
    echo -e "  ${WHITE}[3]${NC} Закрыть старый порт ${active_port} прямо сейчас"
    echo

    local choice=""
    echo -ne "  ${WHITE}${ARROW} Ваш выбор [1/2/3] (по умолчанию 1): ${NC}"
    read -r -t 10 choice </dev/tty || choice="1"
    choice="${choice:-1}"
    choice=$(echo "$choice" | tr -d '[:space:]')

    case "$choice" in
        2)
            deploy_ssh_transition_watcher "$target_port" "$active_port" 24
            ok "Оба порта (${target_port} и ${active_port}) остаются открытыми. Watcher закроет ${active_port} после входа."
            return 0
            ;;
        3)
            finalize_ssh_transition "$target_port" "$active_port"
            return 0
            ;;
        *)
            echo -e "  ${CYAN}Ожидание входящего подключения на порт ${target_port} (${timeout_sec} сек)...${NC}"
            local elapsed=0
            while [ "$elapsed" -lt "$timeout_sec" ]; do
                local est_count=0
                est_count=$(ss -tn sport = ":${target_port}" state established 2>/dev/null | grep -vE '127\.0\.0\.1|::1|Local Address' | wc -l)
                if [ "$est_count" -gt 0 ]; then
                    echo
                    ok "Успешное входящее подключение на порт ${target_port} обнаружено!"
                    finalize_ssh_transition "$target_port" "$active_port"
                    return 0
                fi
                sleep 1
                elapsed=$((elapsed + 1))
                echo -ne "\r  ${DIM}Осталось: $((timeout_sec - elapsed)) сек...${NC} "
            done
            echo
            warn "За ${timeout_sec} сек новых подключений не зафиксировано."
            ok "Для вашей безопасности старый порт ${active_port} пока оставлен открытым."
            deploy_ssh_transition_watcher "$target_port" "$active_port" 24
            return 0
            ;;
    esac
}

apply_fail2ban_configuration() {
    local target_port="${1:-22}"
    local active_port="${2:-22}"

    # 1. Установка пакетов fail2ban и python3-systemd (для чтения journald в Ubuntu 24.04 / Debian 12)
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y >/dev/null 2>&1 || true
            apt-get install -y fail2ban python3-systemd >/dev/null 2>&1 || apt-get install -y fail2ban >/dev/null 2>&1 || true
        fi
    fi

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        warn "Пакет fail2ban не найден в системе и не может быть установлен."
        return 1
    fi

    # 2. Формируем список защищаемых портов (и активный, и целевой)
    local port_str="${active_port}"
    if [ "$target_port" -ne "$active_port" ]; then
        port_str="${active_port},${target_port}"
    fi

    mkdir -p /etc/fail2ban
    cat << EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ${port_str}
EOF
    chmod 644 /etc/fail2ban/jail.local 2>/dev/null || true

    # 3. Активация и запуск службы
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true

    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        ok "Служба Fail2ban успешно запущена и защищает SSH (порты: ${WHITE}${port_str}${NC})."
    else
        warn "Служба Fail2ban была установлена, но не смогла запуститься. Проверьте journalctl -u fail2ban."
        return 1
    fi
    return 0
}
