# ==============================================================================
#  Подсистема безопасности хоста: SSH Hardening & Fail2ban
# ==============================================================================

apply_ssh_configuration() {
    local target_port="${1:-22}"
    local active_port="${2:-22}"

    if [ "$target_port" -eq "$active_port" ]; then
        return 0
    fi

    local ssh_svc
    ssh_svc=$(get_ssh_service_name)

    # 1. Отключаем systemd socket-activation (Ubuntu 22.10+, Ubuntu 24.04 LTS),
    # чтобы служба корректно слушала кастомный порт через стандартный unit.
    systemctl stop ssh.socket 2>/dev/null || true
    systemctl disable ssh.socket 2>/dev/null || true
    systemctl enable "${ssh_svc}.service" 2>/dev/null || true

    # 2. Обновляем базовый /etc/ssh/sshd_config с гарантией директивы Include
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
    chmod 600 /etc/ssh/sshd_config.d/99-hardening.conf 2>/dev/null || true

    # 4. Проверяем валидность конфигурации sshd перед перезапуском
    mkdir -p /run/sshd
    if /usr/sbin/sshd -t 2>/dev/null; then
        systemctl restart "${ssh_svc}.service" || true
        ok "Служба SSH успешно переведена на порт ${WHITE}${target_port}${NC}."
    else
        # При синтаксической ошибке — безопасный откат
        warn "Ошибка валидации sshd -t при смене порта! Откат изменений для предотвращения потери доступа."
        rm -f /etc/ssh/sshd_config.d/99-hardening.conf
        systemctl restart "${ssh_svc}.service" || true
        return 1
    fi
    return 0
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
