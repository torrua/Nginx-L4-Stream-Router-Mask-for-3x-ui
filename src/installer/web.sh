issue_required_certificate() {
    if [ "${SSL_ENGINE_CHOICE:-1}" = 1 ]; then
        run_with_spinner "Сертификат HTTP-01: $1" obtain_cert "$1"
    else
        run_with_spinner "Сертификат DNS-01: $1" obtain_cf_cert "$1"
    fi
}

install_step_nginx() {
    run_with_spinner "Установка Nginx" setup_nginx_mainline
    NGINX_USER="nginx"
    if ! id -u nginx >/dev/null 2>&1; then
        NGINX_USER="www-data"
    fi

    mkdir -p /etc/systemd/system/nginx.service.d
    cat << 'EOF' > /etc/systemd/system/nginx.service.d/override.conf
[Service]
LimitNOFILE=524288
LimitNPROC=524288
EOF

    systemctl daemon-reload

    log "Инициализация файловой структуры веб-сервера..."
    WEBROOT="/var/www/html"
    mkdir -p "$WEBROOT/.well-known/acme-challenge"
    mkdir -p /var/cache/nginx/img_cache
    mkdir -p /var/cache/nginx/html_cache
    mkdir -p /var/cache/nginx/video_cache
    mkdir -p /var/www/mirror
    mkdir -p /var/www/proxy_temp
    mkdir -p /etc/nginx/stream.d
    mkdir -p /etc/nginx/conf.d

    chown -R "$NGINX_USER:$NGINX_USER" "$WEBROOT" /var/cache/nginx /var/www/mirror /var/www/proxy_temp
    chmod 755 "$WEBROOT" /var/cache/nginx /var/www/mirror /var/www/proxy_temp

    # Стартовый HTTP-сервер для валидации домена (создается только если Шаг 4 выполняется)
    if [ "$SSL_ENGINE_CHOICE" = "1" ] && [ "${RESUME_STEP:-1}" -le 4 ]; then
        NGINX_80_SERVER_NAMES="${ALL_DOMAINS[*]}"

        # Останавливаем конкурирующие веб-сервисы, если они были предустановлены
        systemctl stop apache2 2>/dev/null || true
        systemctl disable apache2 2>/dev/null || true

        # Удаляем дефолтные конфигурации сайтов с [::]:80, которые приводят к сбою запуска при выключенном IPv6
        rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default /etc/nginx/conf.d/default.conf 2>/dev/null || true
        mkdir -p /etc/nginx/sites-enabled /etc/nginx/conf.d /etc/nginx/modules-enabled "$WEBROOT/.well-known/acme-challenge" 2>/dev/null || true
        chown -R "$NGINX_USER:$NGINX_USER" "$WEBROOT" 2>/dev/null || true

        # Удаляем директивы listen [::]: из существующих файлов conf.d
        sed -i '/\[::\]/d' /etc/nginx/conf.d/*.conf 2>/dev/null || true

        log "Создание стартового HTTP-сервера для валидации домена..."
        cat << EOF > "/etc/nginx/conf.d/00-acme.conf"
server {
    listen 80;
    server_name $NGINX_80_SERVER_NAMES;
    server_tokens off;
    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        try_files \$uri =404;
    }
    location / { return 301 https://\$host\$request_uri; }
}
EOF

        if ! nginx -t >/dev/null 2>&1; then
            warn "Сбой проверки начальной конфигурации Nginx. Проверка на ошибки ISA или бинарника..."
            setup_nginx_mainline
            if ! nginx -t >/dev/null 2>&1; then
                nginx -t
                die "Ошибка синтаксиса начальной конфигурации Nginx."
            fi
        fi
        systemctl restart nginx >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1
    fi

    # =============================================================
    #  ВЫПУСК SSL-СЕРТИФИКАТОВ (CERTBOT ИЛИ ACME.SH)
    # =============================================================
}

install_step_certificates() {
        # Обеспечиваем доступность портов 80 и 443 для ACME HTTP-01 проверки
        command -v ufw >/dev/null 2>&1 && ufw allow 80/tcp comment 'HTTP (ACME Challenge)' >/dev/null 2>&1 || true
        command -v ufw >/dev/null 2>&1 && ufw allow 443/tcp comment 'HTTPS (ACME Challenge)' >/dev/null 2>&1 || true
        command -v iptables >/dev/null 2>&1 && iptables -I INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1 || true
        command -v iptables >/dev/null 2>&1 && iptables -I INPUT -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1 || true

        if [ "$SSL_ENGINE_CHOICE" = "1" ]; then
            run_with_spinner "Инициализация подсистемы Certbot (APT / Snap)" install_certbot_package || die "Ошибка установки Certbot."

            mkdir -p /etc/letsencrypt
            if [ -n "$LE_EMAIL" ]; then
                cat << EOF > /etc/letsencrypt/cli.ini
email = $LE_EMAIL
agree-tos = true
non-interactive = true
EOF
            else
                cat << EOF > /etc/letsencrypt/cli.ini
register-unsafely-without-email = true
agree-tos = true
non-interactive = true
EOF
            fi

            for dom in "${ALL_DOMAINS[@]}"; do
                issue_required_certificate "$dom" || die "Certificate issuance failed: $dom"
            done

            mkdir -p /etc/letsencrypt/renewal-hooks/deploy/
            cat << 'EOF' > /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh
#!/bin/bash
chmod 755 /etc/letsencrypt /etc/letsencrypt/live 2>/dev/null || true
chmod 700 /etc/letsencrypt/archive 2>/dev/null || true
chmod 755 /etc/letsencrypt/live/* 2>/dev/null || true
chmod 644 /etc/letsencrypt/live/*/*.pem 2>/dev/null || true
chmod 600 /etc/letsencrypt/live/*/privkey*.pem 2>/dev/null || true
chmod 600 /etc/letsencrypt/archive/*/privkey*.pem 2>/dev/null || true
systemctl reload nginx
EOF
            chmod +x /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh

        else
            run_with_spinner "Инициализация подсистемы acme.sh" install_acmesh || die "Ошибка установки acme.sh."
            _ACME="${HOME:-/root}/.acme.sh/acme.sh"

            if [ "$CF_AUTH_METHOD" = "1" ]; then
                export CF_Token="$CF_Token"
                [ -n "${CF_Account_ID:-}" ] && export CF_Account_ID="$CF_Account_ID"
            else
                export CF_Email="$CF_Email"
                export CF_Key="$CF_Key"
            fi

            mkdir -p /etc/ssl/acme
            chmod 755 /etc/ssl /etc/ssl/acme

            for dom in "${ALL_DOMAINS[@]}"; do
                issue_required_certificate "$dom" || die "Certificate issuance failed: $dom"
            done
        fi

        # Настройка строгих прав доступа на каталоги SSL для чтения Nginx (изоляция приватных ключей)
        if [ "$SSL_ENGINE_CHOICE" = "1" ]; then
            chmod 755 /etc/letsencrypt /etc/letsencrypt/live 2>/dev/null || true
            chmod 700 /etc/letsencrypt/archive 2>/dev/null || true
            for dom in "${ALL_DOMAINS[@]}"; do
                if [ -d "/etc/letsencrypt/live/$dom" ]; then
                    chmod 755 "/etc/letsencrypt/live/$dom" 2>/dev/null || true
                    chmod 644 /etc/letsencrypt/live/"$dom"/*.pem 2>/dev/null || true
                    chmod 600 /etc/letsencrypt/live/"$dom"/privkey*.pem 2>/dev/null || true
                    chmod 600 /etc/letsencrypt/archive/"$dom"/privkey*.pem 2>/dev/null || true
                fi
            done
        else
            chmod 750 /etc/ssl/acme 2>/dev/null || true
            chown -R root:www-data /etc/ssl/acme 2>/dev/null || true
            for dom in "${ALL_DOMAINS[@]}"; do
                if [ -d "/etc/ssl/acme/$dom" ]; then
                    chmod 750 "/etc/ssl/acme/$dom" 2>/dev/null || true
                    chmod 640 /etc/ssl/acme/"$dom"/*.pem 2>/dev/null || true
                    chmod 600 /etc/ssl/acme/"$dom"/privkey*.pem 2>/dev/null || true
                fi
            done
        fi
}
