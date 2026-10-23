ensure_nginx_stream_module() {
    command -v nginx >/dev/null 2>&1 || return 0

    mkdir -p /etc/nginx/modules-enabled 2>/dev/null || true
    find /etc/nginx/modules-enabled/ -xtype l -delete 2>/dev/null || true

    # 1. Проверяем, поддерживает ли бинарник Nginx директиву stream изначально (статическая сборка)
    local test_conf
    test_conf=$(mktemp 2>/dev/null || echo "/tmp/nginx_test_stream_$$.conf")
    cat << 'EOF' > "$test_conf"
events { worker_connections 64; }
stream {}
EOF
    if nginx -t -c "$test_conf" >/dev/null 2>&1; then
        rm -f "$test_conf" 2>/dev/null || true
        return 0
    fi

    # 2. Проверяем, работает ли stream с текущими модулями в /etc/nginx/modules-enabled/
    cat << 'EOF' > "$test_conf"
include /etc/nginx/modules-enabled/*.conf;
events { worker_connections 64; }
stream {}
EOF
    if nginx -t -c "$test_conf" >/dev/null 2>&1; then
        rm -f "$test_conf" 2>/dev/null || true
        return 0
    fi
    rm -f "$test_conf" 2>/dev/null || true

    # 3. Модуль stream не загружен или отсутствует. Ищем файл ngx_stream_module.so
    local mod_so=""
    for cand in /etc/nginx/modules/ngx_stream_module.so \
                /usr/lib/nginx/modules/ngx_stream_module.so \
                /usr/share/nginx/modules/ngx_stream_module.so \
                /usr/local/nginx/modules/ngx_stream_module.so; do
        if [ -f "$cand" ]; then
            mod_so="$cand"
            break
        fi
    done

    # 4. Если модуль не найден на диске, устанавливаем пакет модуля через пакетный менеджер
    if [ -z "$mod_so" ] && command -v apt-get >/dev/null 2>&1; then
        log "Установка модуля Nginx Stream L4 (libnginx-mod-stream / nginx-module-stream)..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q || true
        apt-get install -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
            libnginx-mod-stream 2>/dev/null || \
        apt-get install -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
            nginx-module-stream 2>/dev/null || true

        for cand in /etc/nginx/modules/ngx_stream_module.so \
                    /usr/lib/nginx/modules/ngx_stream_module.so \
                    /usr/share/nginx/modules/ngx_stream_module.so \
                    /usr/local/nginx/modules/ngx_stream_module.so; do
            if [ -f "$cand" ]; then
                mod_so="$cand"
                break
            fi
        done
    fi

    # 5. Если модуль найден, создаем конфигурационный файл в modules-enabled
    if [ -n "$mod_so" ]; then
        rm -f /etc/nginx/modules-enabled/*stream*.conf 2>/dev/null || true
        cat << EOF > /etc/nginx/modules-enabled/50-mod-stream.conf
load_module $mod_so;
EOF
    fi

    # 6. Проверяем работоспособность директивы stream с подключенным модулем
    test_conf=$(mktemp 2>/dev/null || echo "/tmp/nginx_test_stream_$$.conf")
    cat << 'EOF' > "$test_conf"
include /etc/nginx/modules-enabled/*.conf;
events { worker_connections 64; }
stream {}
EOF
    if nginx -t -c "$test_conf" >/dev/null 2>&1; then
        rm -f "$test_conf" 2>/dev/null || true
        ok "Модуль Nginx Stream L4 успешно активирован."
        return 0
    fi
    rm -f "$test_conf" 2>/dev/null || true

    # 7. Fail-safe fallback: если Nginx по-прежнему не распознает stream (например, бинарник несовместим с модулем),
    # выполняем чистую переустановку дистрибутивного Nginx с libnginx-mod-stream
    if command -v apt-get >/dev/null 2>&1; then
        local os_id
        os_id=$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "ubuntu")
        warn "Сбой загрузки модуля Stream в текущей версии Nginx. Экстренное восстановление системного Nginx..."
        rm -f /etc/apt/sources.list.d/nginx.list /etc/apt/preferences.d/99nginx
        apt-get purge -y nginx nginx-common nginx-core libnginx* 2>/dev/null || apt-get remove -y nginx* 2>/dev/null || true
        apt-get update -q || true
        apt-get install -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" nginx libnginx-mod-stream 2>/dev/null || apt-get install -y -q nginx

        find /etc/nginx/modules-enabled/ -xtype l -delete 2>/dev/null || true
        for cand in /etc/nginx/modules/ngx_stream_module.so \
                    /usr/lib/nginx/modules/ngx_stream_module.so \
                    /usr/share/nginx/modules/ngx_stream_module.so; do
            if [ -f "$cand" ]; then
                mod_so="$cand"
                break
            fi
        done
        if [ -n "$mod_so" ] && ! grep -rqs "ngx_stream_module" /etc/nginx/modules-enabled/ 2>/dev/null; then
            cat << EOF > /etc/nginx/modules-enabled/50-mod-stream.conf
load_module $mod_so;
EOF
        fi
    fi
}

setup_nginx_mainline() {
    export DEBIAN_FRONTEND=noninteractive
    local os_id os_codename
    os_id=$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "ubuntu")
    os_codename=$(lsb_release -cs 2>/dev/null || echo "jammy")

    # 1. Если Nginx уже установлен — проверяем, запускается ли бинарник и поддерживает ли ssl_reject_handshake
    if command -v nginx >/dev/null 2>&1; then
        if nginx -v >/dev/null 2>&1; then
            local test_conf
            test_conf=$(mktemp 2>/dev/null || echo "/tmp/nginx_probe_$$.conf")
            cat << 'EOF' > "$test_conf"
events { worker_connections 32; }
http {
    server {
        listen 127.0.0.1:65432 ssl;
        ssl_reject_handshake on;
    }
}
EOF
            local is_suitable=0
            if nginx -t -c "$test_conf" >/dev/null 2>&1; then
                is_suitable=1
            fi
            rm -f "$test_conf" 2>/dev/null || true

            if [ "$is_suitable" -eq 1 ]; then
                mkdir -p /etc/nginx/modules-enabled 2>/dev/null || true
                ensure_nginx_stream_module
                return 0
            fi
            log "Обнаружен устаревший Nginx (отсутствует поддержка ssl_reject_handshake). Обновление до Nginx Mainline..."
        else
            warn "Обнаружен несовместимый Nginx (CPU ISA level is lower than required). Очистка..."
            rm -f /etc/apt/sources.list.d/nginx.list /etc/apt/preferences.d/99nginx
            apt-get purge -y nginx nginx-common nginx-core libnginx* 2>/dev/null || apt-get remove -y nginx* 2>/dev/null || true
            apt-get update -q || true
        fi
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
        chmod 644 /usr/share/keyrings/nginx-archive-keyring.gpg 2>/dev/null || true

        if [ -s /usr/share/keyrings/nginx-archive-keyring.gpg ]; then
            echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/$os_id $os_codename nginx" \
                > /etc/apt/sources.list.d/nginx.list

            cat << EOF > /etc/apt/preferences.d/99nginx
Package: nginx*
Pin: origin nginx.org
Pin-Priority: 900
EOF

            apt-get update -q || true
            apt-get install -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" nginx nginx-module-stream -y -q 2>/dev/null || \
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
    ensure_nginx_stream_module
}

