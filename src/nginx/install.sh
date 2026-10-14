setup_nginx_mainline() {
    export DEBIAN_FRONTEND=noninteractive
    local os_id os_codename
    os_id=$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "ubuntu")
    os_codename=$(lsb_release -cs 2>/dev/null || echo "jammy")

    # 1. Если Nginx уже установлен — проверяем, запускается ли бинарник
    if command -v nginx >/dev/null 2>&1; then
        if nginx -v >/dev/null 2>&1; then
            mkdir -p /etc/nginx/modules-enabled 2>/dev/null || true
            return 0
        fi
        warn "Обнаружен несовместимый Nginx (CPU ISA level is lower than required). Очистка..."
        rm -f /etc/apt/sources.list.d/nginx.list /etc/apt/preferences.d/99nginx
        apt-get purge -y nginx nginx-common nginx-core libnginx* 2>/dev/null || apt-get remove -y nginx* 2>/dev/null || true
        apt-get update -q || true
    fi

    apt-get update -q || true
    apt-get install gnupg ca-certificates lsb-release openssl -y -q || true

    # 2. Проверяем поддержку процессором микроархитектуры x86-64-v3
    local can_use_nginx_org=1
    if ! supports_x86_64_v3; then
        warn "Процессор VPS (или профиль гипервизора) не поддерживает x86-64-v3 (AVX2/BMI2)."
        log "Подключение Nginx из официального системного репозитория $os_id (100% совместимость со всеми CPU)..."
        can_use_nginx_org=0
    fi

    if [ "$can_use_nginx_org" -eq 1 ]; then
        mkdir -p /usr/share/keyrings
        curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg --yes 2>/dev/null || true

        if [ -s /usr/share/keyrings/nginx-archive-keyring.gpg ]; then
            echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/$os_id $os_codename nginx" \
                > /etc/apt/sources.list.d/nginx.list

            cat << EOF > /etc/apt/preferences.d/99nginx
Package: nginx*
Pin: origin nginx.org
Pin-Priority: 900
EOF

            apt-get update -q || true
            apt-get install -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" nginx -y -q || true
        fi
    fi

    # 3. Валидация работоспособности установленного Nginx (Fail-Safe Fallback)
    if ! command -v nginx >/dev/null 2>&1 || ! nginx -v >/dev/null 2>&1; then
        warn "Сбой запуска Nginx из внешнего репозитория (или несовместимость с ISA процессора)."
        log "Экстренный fallback: установка системного Nginx из репозитория $os_id..."
        rm -f /etc/apt/sources.list.d/nginx.list /etc/apt/preferences.d/99nginx
        apt-get purge -y nginx nginx-common nginx-core libnginx* 2>/dev/null || apt-get remove -y nginx* 2>/dev/null || true
        apt-get update -q || true
        apt-get install -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" nginx libnginx-mod-stream 2>/dev/null || apt-get install -y -q nginx
    fi

    mkdir -p /etc/nginx/modules-enabled 2>/dev/null || true
    nginx -v >/dev/null 2>&1 || die "Не удалось установить рабочий Nginx, совместимый с данным процессором."
}

