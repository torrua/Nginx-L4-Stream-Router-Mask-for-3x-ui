install_certbot_package() {
    export DEBIAN_FRONTEND=noninteractive

    # 1. Если certbot уже присутствует в системе и работает — используем его
    if command -v certbot >/dev/null 2>&1 && certbot --version >/dev/null 2>&1; then
        return 0
    fi

    # 2. Приоритет: Нативный легкий certbot из официального apt репозитория
    apt-get update -q -y >/dev/null 2>&1 || true
    if apt-get install -y -q certbot python3-certbot-nginx; then
        if command -v certbot >/dev/null 2>&1; then
            return 0
        fi
    fi

    # 3. Резервный вариант (Fallback): Установка через Snap, если apt недоступен
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

    # 4. Если оба метода не удались — пробуем pip / certbot standalone
    if command -v certbot >/dev/null 2>&1; then
        return 0
    fi

    die "Не удалось установить Certbot ни через APT, ни через Snap. Проверьте репозитории вашей ОС."
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
    systemctl stop nginx 2>/dev/null || true
    local res=0
    certbot certonly --standalone --expand -d "$dom" --non-interactive || res=$?
    systemctl start nginx 2>/dev/null || true
    return $res
}

install_acmesh() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y cron socat -q
    local acme_mail="${LE_EMAIL:-admin@$PRIMARY_DOMAIN}"
    curl -s https://get.acme.sh | sh -s email="$acme_mail"
    local _acme_bin="${HOME:-/root}/.acme.sh/acme.sh"
    chmod +x "$_acme_bin"
    "$_acme_bin" --register-account -m "$acme_mail" --server letsencrypt
}

# Принимает $1 = домен (был closure-переменной $dom из цикла)
# Использует глобальные $_ACME (устанавливается после install_acmesh)
obtain_cf_cert() {
    local dom="$1"
    "$_ACME" --issue --dns dns_cf -d "$dom" --server letsencrypt --force && \
    mkdir -p "/etc/ssl/acme/$dom" && \
    chmod 750 "/etc/ssl/acme/$dom" && \
    "$_ACME" --install-cert -d "$dom" \
        --key-file       "/etc/ssl/acme/$dom/privkey.pem" \
        --fullchain-file "/etc/ssl/acme/$dom/fullchain.pem" \
        --reloadcmd     "chmod 750 /etc/ssl/acme /etc/ssl/acme/$dom 2>/dev/null || true; chmod 640 /etc/ssl/acme/$dom/*.pem 2>/dev/null || true; chmod 600 /etc/ssl/acme/$dom/privkey*.pem 2>/dev/null || true; chown -R root:www-data /etc/ssl/acme 2>/dev/null || true; systemctl reload nginx"
}

nginx_reload_task() {
    nginx -t || return 1
    systemctl unmask nginx 2>/dev/null || true
    systemctl enable nginx 2>/dev/null || true
    systemctl restart nginx
}

