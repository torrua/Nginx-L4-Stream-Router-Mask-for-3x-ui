install_certbot_package() {
    export DEBIAN_FRONTEND=noninteractive

    # 1. Если certbot уже присутствует в системе и работает — используем его
    if command -v certbot >/dev/null 2>&1 && certbot --version >/dev/null 2>&1; then
        return 0
    fi

    # 2. Alpine Linux: Нативная установка через apk (без snapd)
    local os_id="${ID:-}"
    if [ -f /etc/os-release ]; then . /etc/os-release 2>/dev/null; os_id="${ID:-}"; fi
    if [ "$os_id" = "alpine" ] || command -v apk >/dev/null 2>&1; then
        apk add --no-cache certbot py3-certbot 2>/dev/null || apk add --no-cache certbot || true
        if command -v certbot >/dev/null 2>&1; then
            return 0
        fi
    fi

    # 3. Приоритет: Нативный легкий certbot из официального apt репозитория
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -q -y >/dev/null 2>&1 || true
        if apt-get install -y -q certbot; then
            if command -v certbot >/dev/null 2>&1; then
                return 0
            fi
        fi

        # 4. Резервный вариант (Fallback): Установка через Snap, если apt недоступен
        if apt-get install -y -q snapd; then
            systemctl start snapd.socket 2>/dev/null || true
            systemctl enable snapd.socket 2>/dev/null || true
            for i in {1..10}; do
                if snap version >/dev/null 2>&1; then break; fi
                sleep 2
            done
            snap install core 2>/dev/null || true
            snap refresh core 2>/dev/null || true
            if snap install --classic certbot 2>/dev/null; then
                ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
                if command -v certbot >/dev/null 2>&1; then
                    return 0
                fi
            fi
        fi
    fi

    # 5. Если оба метода не удались — пробуем pip / certbot standalone
    if command -v certbot >/dev/null 2>&1; then
        return 0
    fi

    die "Не удалось установить Certbot ни через системный пакетный менеджер, ни через Snap. Проверьте репозитории вашей ОС."
}

# Принимает $1 = домен (был closure-переменной $dom из цикла)
obtain_cert() {
    local dom="$1"
    if [ -f "/etc/letsencrypt/live/$dom/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/$dom/privkey.pem" ]; then
        return 0
    fi

    # 1. Попытка через Nginx Webroot (если порт 80 слушается)
    if ss -tlnp 2>/dev/null | grep -qE ':80\s'; then
        if certbot certonly --webroot -w "$WEBROOT" --expand -d "$dom" --non-interactive; then
            return 0
        fi
        warn "Сбой верификации через Nginx Webroot для $dom. Пробуем Standalone-режим..."
    fi

    # 2. Надежный fallback: Standalone (Certbot сам поднимает временный сервер на порту 80)
    svc_stop nginx 2>/dev/null || systemctl stop nginx 2>/dev/null || true
    local res=0
    certbot certonly --standalone --expand -d "$dom" --non-interactive || res=$?
    svc_start nginx 2>/dev/null || systemctl start nginx 2>/dev/null || true
    return $res
}

install_acmesh() {
    export DEBIAN_FRONTEND=noninteractive
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache socat dcron 2>/dev/null || true
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get install -y cron socat -q
    fi
    local acme_mail="${LE_EMAIL:-admin@$PRIMARY_DOMAIN}"
    local _acme_bin="${HOME:-/root}/.acme.sh/acme.sh"

    if [ ! -x "$_acme_bin" ]; then
        local acme_tmp="/tmp/acme_staging_$$"
        mkdir -p "$acme_tmp"
        if download_manifest_component "acme.sh" "$acme_tmp/acme.tar.gz" "all"; then
            tar -zxf "$acme_tmp/acme.tar.gz" -C "$acme_tmp" --strip-components=1 2>/dev/null || tar -zxf "$acme_tmp/acme.tar.gz" -C "$acme_tmp" 2>/dev/null || true
            local acme_src
            acme_src="$(find "$acme_tmp" -name acme.sh -type f 2>/dev/null | head -n1)"
            if [ -n "$acme_src" ] && [ -f "$acme_src" ]; then
                bash "$acme_src" --install --home "${HOME:-/root}/.acme.sh" --accountemail "$acme_mail" >/dev/null 2>&1 || true
            fi
        else
            warn "Не удалось скачать проверенный дистрибутив acme.sh"
        fi
        rm -rf "$acme_tmp" 2>/dev/null || true
    fi

    if [ -f "$_acme_bin" ]; then
        chmod +x "$_acme_bin" 2>/dev/null || true
        "$_acme_bin" --register-account -m "$acme_mail" --server letsencrypt >/dev/null 2>&1 || true
    fi
}

# Принимает $1 = домен (был closure-переменной $dom из цикла)
# Использует глобальные $_ACME (устанавливается после install_acmesh)
obtain_cf_cert() {
    local dom="$1"
    local ng_usr="www-data"
    if command -v get_nginx_user >/dev/null 2>&1; then
        ng_usr="$(get_nginx_user)"
    elif [ -f /etc/os-release ]; then
        local os_id=""
        os_id=$(. /etc/os-release 2>/dev/null; echo "${ID:-}")
        [ "$os_id" = "alpine" ] && ng_usr="nginx"
    fi

    "$_ACME" --issue --dns dns_cf -d "$dom" --server letsencrypt --force && \
    mkdir -p "/etc/ssl/acme/$dom" && \
    chmod 750 "/etc/ssl/acme/$dom" && \
    "$_ACME" --install-cert -d "$dom" \
        --key-file       "/etc/ssl/acme/$dom/privkey.pem" \
        --fullchain-file "/etc/ssl/acme/$dom/fullchain.pem" \
        --reloadcmd     "chmod 750 /etc/ssl/acme /etc/ssl/acme/$dom 2>/dev/null || true; chmod 640 /etc/ssl/acme/$dom/*.pem 2>/dev/null || true; chmod 600 /etc/ssl/acme/$dom/privkey*.pem 2>/dev/null || true; chown -R root:${ng_usr} /etc/ssl/acme 2>/dev/null || true; svc_reload nginx 2>/dev/null || systemctl reload nginx 2>/dev/null || rc-service nginx reload 2>/dev/null || true"
}

nginx_reload_task() {
    nginx -t || return 1
    svc_enable nginx 2>/dev/null || systemctl enable nginx 2>/dev/null || true
    svc_restart nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || rc-service nginx restart 2>/dev/null || true
}
