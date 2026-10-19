#!/usr/bin/env bash
#
# ==============================================================================
# Production AutoSetup: Nginx Stream L4 Router & 3X-UI Companion __VERSION__ Universal
# Nginx L4 Stream + 3X-UI + Unix Sockets + Native proxy_http_version 2 + 3 Decoys
# ==============================================================================
# Архитектура:
#   1) Nginx Mainline Branch v.1.31.4+ (Официальный репозиторий nginx.org)
#   2) VLESS REALITY (маскировка под свой сайт) с защитой от зацикливания (Anti-Loop Fallback 9443)
#   3) VLESS REALITY (маскировка под популярные внешние сервисы)
#   4) VLESS xHTTP (Stream-One) + VLESSENC + Native H2 Streaming (без XMUX-блокировок)
#      (СТРОГО по TCP/HTTP/2 без QUIC — полнодуплексное HTTP/2-проксирование Nginx)
#   5) Опциональный скоростной UDP VPN: Hysteria 2 (по умолчанию 443/UDP)
#   6) Опциональный двухверсионный стек AmneziaWG / WireGuard:
#      - AmneziaWG v3.1 (WG3, по умолчанию 8443/UDP, Transport Protection)
#      - AmneziaWG v2.0 / Legacy 1.0 (по умолчанию 8444/UDP, для роутеров)
#   7) Гибридный SSL-движок с разделением каталогов:
#      - Certbot (HTTP-01): /etc/letsencrypt/live/
#      - acme.sh + Cloudflare (DNS-01): /etc/ssl/acme/ (изоляция от /root/ и 755/644)
#      - 3 автономных локальных режима маскировки (Decoy Front):
#      - 1: DataSphere Analytics (SPA с 3D-сферой и телеметрией)
#      - 2: Облако CosmosCloud 
#      - 3: Стандартная заглушка Nginx (Welcome to nginx)
#   9) Комплексная защита от ботов, сканеров уязвимостей, AI-парсеров (444/404)
#  10) Полный тюнинг ядра Linux (TCP BBR, fq, somaxconn, lowat, IPC /dev/shm, UDP buffers)
#  ==============================================================================

set -euo pipefail

SCRIPT_VERSION="__VERSION__"


# @include "common/checkpoint.sh"

# @include "tui/base.sh"

# @include "tui/banner.sh"

# @include "system/packages.sh"

# @include "system/env.sh"

# @include "tui/prompts.sh"

# @include "common/preflight.sh"

# @include "system/sysctl.sh"

# @include "system/security.sh"

# @include "nginx/install.sh"

# @include "ssl/certs.sh"

# @include "system/preinstall.sh"

# @include "awg/setup.sh"

# @include "installer/steps.sh"

# @include "tui/wizard.sh"

# =============================================================
#  ФАЗА УСТАНОВКИ И РАЗВЕРТЫВАНИЯ СИСТЕМЫ
# =============================================================
if is_true "${ENABLE_WEB_STACK:-y}"; then
    if [[ "${ENABLE_AGH,,}" == "y" || "${ENABLE_AGH:-}" == "1" ]]; then
        TOTAL_STEPS=8
    else
        TOTAL_STEPS=7
    fi
else
    TOTAL_STEPS=3
    STEP_NAMES[3]="Развертывание автономного сервера AmneziaWG (awg-mgr)"
fi

# Ожидание фоновой пред-установки (если была запущена параллельно с опросом)
sync_background_preinstall

# Универсальная предварительная инспекция портов и предотвращение конфликтов со сторонними службами
inspect_port_conflicts

# --- Шаг 1: Системные зависимости и утилиты ---
if ! should_skip_step 1; then
    step_begin 1
    if [ "$PREINSTALL_COMPLETED" -eq 1 ]; then
        ok "Базовые утилиты (curl, socat, dig, ufw) установлены [В фоне]"
    else
        run_with_spinner "Проверка и установка базовых утилит (curl, socat, dig, ufw)" install_prerequisites || die "Ошибка установки базовых утилит."
    fi
    step_finish 1
fi

# --- Шаг 2: Тюнинг ядра Linux (TCP BBR & UDP Buffers) ---
if ! should_skip_step 2; then
    step_begin 2
    if [ "$PREINSTALL_COMPLETED" -eq 1 ]; then
        ok "Системные параметры BBR и лимиты дескрипторов применены [В фоне]"
    else
        run_with_spinner "Применение системных параметров BBR и лимитов дескрипторов" apply_sysctl_and_limits || die "Ошибка применения сетевого тюнинга."
    fi
    step_finish 2
fi

# --- Настройка безопасности хоста: SSH & Fail2ban ---
local_active_ssh="${SSH_ACTIVE_PORT:-22}"
local_target_ssh="${SSH_PORT:-$local_active_ssh}"
if is_true "${ENABLE_HOST_SECURITY:-n}" || [ "$local_target_ssh" -ne "$local_active_ssh" ] || is_true "${ENABLE_FAIL2BAN:-n}" || is_true "${DISABLE_PASSWORD_AUTH:-n}"; then
    if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
        add_authorized_key "$SSH_PUBLIC_KEY" "root"
    fi
    if [ "$local_target_ssh" -ne "$local_active_ssh" ] || is_true "${DISABLE_PASSWORD_AUTH:-n}"; then
        run_with_spinner "Применение конфигурации OpenSSH (порт $local_target_ssh)" apply_ssh_configuration "$local_target_ssh" "$local_active_ssh" "${DISABLE_PASSWORD_AUTH:-n}" || warn "Не удалось применить конфигурацию SSH."
        if command -v ufw >/dev/null 2>&1; then
            ufw allow "${local_active_ssh}/tcp" comment 'Current SSH Port' >/dev/null 2>&1 || true
            ufw allow "${local_target_ssh}/tcp" comment 'Target SSH Port' >/dev/null 2>&1 || true
        fi
    fi
    if is_true "${ENABLE_FAIL2BAN:-n}"; then
        run_with_spinner "Установка и настройка службы Fail2ban" apply_fail2ban_configuration "$local_target_ssh" "$local_active_ssh" || warn "Не удалось настроить Fail2ban."
    fi
fi

if is_true "${ENABLE_WEB_STACK:-y}"; then
    # --- Шаг 3: Установка Nginx Mainline ---
    if ! should_skip_step 3; then
        step_begin 3
        if [ "$PREINSTALL_COMPLETED" -eq 1 ]; then
            ok "Репозиторий nginx.org подключен, Nginx Mainline установлен [В фоне]"
        else
            run_with_spinner "Подключение репозитория nginx.org и установка Nginx" setup_nginx_mainline || die "Ошибка установки Nginx Mainline."
        fi
        step_finish 3
    fi

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

    # Стартовый HTTP-сервер для верификации ACME (создается только если Шаг 4 выполняется)
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

        log "Создание стартового HTTP-сервера для верификации ACME..."
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
    if ! should_skip_step 4; then
        step_begin 4

        # Обеспечиваем доступность портов 80 и 443 для ACME HTTP-01 проверки
        command -v ufw >/dev/null 2>&1 && ufw allow 80/tcp >/dev/null 2>&1 || true
        command -v ufw >/dev/null 2>&1 && ufw allow 443/tcp >/dev/null 2>&1 || true
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
                if run_with_spinner "Выпуск SSL для домена $dom (HTTP-01)" obtain_cert "$dom"; then
                    :
                else
                    warn "Не удалось выпустить сертификат для $dom."
                fi
                # Защитный fallback: создаем самоподписанный сертификат, если боевой не был получен
                if [ ! -f "/etc/letsencrypt/live/$dom/fullchain.pem" ] || [ ! -f "/etc/letsencrypt/live/$dom/privkey.pem" ]; then
                    warn "Генерация временного самоподписанного сертификата для $dom (для запуска веб-сервера)..."
                    mkdir -p "/etc/letsencrypt/live/$dom"
                    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                        -keyout "/etc/letsencrypt/live/$dom/privkey.pem" \
                        -out "/etc/letsencrypt/live/$dom/fullchain.pem" \
                        -subj "/CN=$dom" >/dev/null 2>&1 || true
                fi
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
                if run_with_spinner "Выпуск SSL для домена $dom через Cloudflare DNS-01" obtain_cf_cert "$dom"; then
                    :
                else
                    warn "Ошибка при выпуске сертификата для $dom."
                fi
                # Защитный fallback: создаем самоподписанный сертификат, если боевой не был получен
                if [ ! -f "/etc/ssl/acme/$dom/fullchain.pem" ] || [ ! -f "/etc/ssl/acme/$dom/privkey.pem" ]; then
                    warn "Генерация временного самоподписанного сертификата для $dom (для запуска веб-сервера)..."
                    mkdir -p "/etc/ssl/acme/$dom"
                    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                        -keyout "/etc/ssl/acme/$dom/privkey.pem" \
                        -out "/etc/ssl/acme/$dom/fullchain.pem" \
                        -subj "/CN=$dom" >/dev/null 2>&1 || true
                fi
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

        step_finish 4
    fi

# @include "nginx/decoys.sh"

# @include "nginx/config.sh"

# @include "system/firewall.sh"

# @include "tui/summary.sh"

# @include "adguard/setup.sh"

    if [[ "${ENABLE_AWG_V3:-}" == "1" || "${ENABLE_AWG_V3,,}" == "y" ]] || \
       [[ "${ENABLE_AWG_V2:-}" == "1" || "${ENABLE_AWG_V2,,}" == "y" ]] || \
       [[ "${ENABLE_AWG_STANDALONE:-}" == "1" || "${ENABLE_AWG_STANDALONE,,}" == "y" ]]; then
        ensure_amneziawg_installed
    fi

    if [[ "${ENABLE_AWG_STANDALONE:-}" == "1" || "${ENABLE_AWG_STANDALONE,,}" == "y" ]]; then
        setup_amneziawg_controller
        deploy_amneziawg_backend
    fi

    if [[ "${ENABLE_AWG_V2:-}" == "1" || "${ENABLE_AWG_V2,,}" == "y" ]] && [ -n "${AWG_V2_PORT:-}" ]; then
        echo -e "${YELLOW}ШАГ 6: Инбаунд AmneziaWG v2.0 / Legacy (UDP $AWG_V2_PORT):${NC}"
        echo -e "  - ${YELLOW}Вкладка «Основное»:${NC} Протокол: ${GREEN}amneziawg / wireguard${NC} | Адрес: ${GREEN}0.0.0.0${NC} | Порт: ${GREEN}$AWG_V2_PORT${NC} (UDP)"
        echo -e "  - ${YELLOW}Вкладка «Параметры AWG» (Для роутеров Keenetic / OpenWrt и старых клиентов):${NC}"
        echo -e "    * ${CYAN}H1-H4 (Строки):${NC} ${GREEN}\"149419586\", \"878791997\", \"1251051976\", \"1657628296\"${NC}"
        echo -e "    * ${CYAN}HeaderProtectionKey:${NC} ${RED}ПУСТО (Выключено)${NC}"
        echo -e "    * ${CYAN}Смещения (>= 12):${NC} ${GREEN}S1 = 16, S2 = 20, S3 = 24, S4 = 16${NC}"
        echo -e "    * ${CYAN}Junk packets:${NC} ${GREEN}Jc = 2, Jmin = 20, Jmax = 50${NC} | ${CYAN}MTU:${NC} ${GREEN}1280${NC}"
        echo
    fi

    if [[ "${ENABLE_AWG_STANDALONE:-}" == "1" || "${ENABLE_AWG_STANDALONE,,}" == "y" ]]; then
        echo -e "${YELLOW}СЕРВЕРНЫЙ КОНТРОЛЛЕР AMNEZIAWG (awg-mgr):${NC}"
        echo -e "  - ${YELLOW}Утилита управления:${NC}      ${GREEN}awg-mgr${NC} (или ${GREEN}awg-cli${NC})"
        echo -e "  - ${YELLOW}Первичный конфиг админа:${NC} ${CYAN}/root/awg/client-1.conf${NC}"
        echo -e "  - ${YELLOW}Основные команды CLI:${NC}"
        echo -e "    * Создать клиента:   ${CYAN}awg-mgr add <имя> [--expires=30d] [--dns=quad9|cloudflare|adguard|local]${NC}"
        echo -e "    * Показать список:   ${CYAN}awg-mgr list${NC}"
        echo -e "    * QR-код в терминал: ${CYAN}awg-mgr qr <имя>${NC}"
        echo -e "    * Удалить клиента:   ${CYAN}awg-mgr remove <имя>${NC}"
        echo -e "    * Резервная копия:   ${CYAN}awg-mgr backup${NC} / ${CYAN}awg-mgr restore <файл>${NC}"
        echo -e "    * Очистка истекших:  ${CYAN}awg-mgr purge-expired${NC} (также настроен в cron)"
        echo

        if [ -f "/root/awg/client-1.conf" ] && command -v /root/awg/manage_amneziawg.sh >/dev/null 2>&1; then
            echo -e "  ${WHITE}${BOLD}QR-код для подключения первого клиента (client-1):${NC}"
            /root/awg/manage_amneziawg.sh qr client-1 2>/dev/null || true
            echo
        fi
    fi

    echo -e "${YELLOW}ШАГ 7: Настройки Клиента и Подписок в 3X-UI:${NC}"
    echo -e "  - ${YELLOW}В карточке Клиента (Клиенты -> Учетные данные):${NC}"
    echo -e "    * Для инбаунда REALITY: Flow: выбрать ${GREEN}xtls-rprx-vision${NC}"
    echo -e "    * Для инбаунда xHTTP: Flow: строго ${RED}пусто (none)${NC} | Decryption: ключ ${GREEN}vlessenc${NC}"
    echo -e "  - ${YELLOW}Настройки подписок (Панель -> Подписка):${NC}"
    echo -e "    * Subscription Port: ${GREEN}$SUB_PORT${NC} | Subscription Path: ${GREEN}$SUB_PATH${NC}"
    echo -e "    * Subscription URL: ${CYAN}https://${PRIMARY_DOMAIN}${SUB_PATH}${NC}"
    echo -e "    * Subscription URL (JSON): ${CYAN}https://${PRIMARY_DOMAIN}${SUB_JSON_PATH}${NC}"
    echo -e "    * Subscription URL (Clash): ${CYAN}https://${PRIMARY_DOMAIN}${SUB_CLASH_PATH}${NC}"
    echo -e "  - ${YELLOW}В разделе «Хосты» (Hosts) добавьте 2 правила:${NC}"
    echo -e "    1) ${BOLD}MAIN_SAME_443:${NC} Инбаунды: ${CYAN}REALITY + Hysteria 2${NC} -> Порт: ${GREEN}443${NC} | Безопасность: ${GREEN}same${NC}"
    echo -e "    2) ${BOLD}XHTTP_TLS_443:${NC} Инбаунд: ${CYAN}${SERVER_PREFIX} (VLESS xHTTP)${NC} -> Порт: ${GREEN}443${NC} | Безопасность: ${GREEN}tls${NC} (SNI: ${CYAN}$PRIMARY_DOMAIN${NC})"

    if [[ "${ENABLE_AGH,,}" == "y" || "${ENABLE_AGH:-}" == "1" ]]; then
        local_agh_panel_url=""
        local_agh_doh_url=""
        local_server_ip="${WAN_IP:-$(get_wan_ip)}"

        if [ "${AGH_MODE:-1}" = "2" ] && [ -n "${AGH_DOMAIN:-}" ]; then
            local_agh_panel_url="https://${AGH_DOMAIN}/"
            local_agh_doh_url="https://${AGH_DOMAIN}/dns-query/${AGH_CLIENT_ID}"
        else
            local_agh_panel_url="http://127.0.0.1:${PORT_AGH_WEB:-3000} (доступ через SSH-туннель: ssh -L ${PORT_AGH_WEB:-3000}:127.0.0.1:${PORT_AGH_WEB:-3000} user@${local_server_ip})"
            local_agh_doh_url="https://${PRIMARY_DOMAIN}/dns-query/${AGH_CLIENT_ID}"
        fi

        echo
        echo -e "${YELLOW}ШАГ 8: Приватный AdGuard Home DoH + Split-DNS:${NC}"
        echo -e "  - ${YELLOW}Веб-панель:${NC}          ${CYAN}${local_agh_panel_url}${NC}"
        echo -e "  - ${YELLOW}Логин / Пароль:${NC}      ${GREEN}${AGH_USER}${NC} / ${GREEN}${AGH_PASS}${NC}"
        echo -e "  - ${YELLOW}URL DoH для роутера:${NC} ${GREEN}${local_agh_doh_url}${NC}"
        echo -e "  - ${YELLOW}Split-DNS зоны:${NC}      ${CYAN}.ru, .рф, .su, .kz, .by${NC} → ${GREEN}Яндекс DNS (77.88.8.8)${NC}"
        echo -e "  - ${YELLOW}Блокировка рекламы:${NC}  ${GREEN}OISD Small (активен, автообновление каждые 24ч)${NC}"
        echo -e "  - ${YELLOW}Upstream DNS:${NC}        ${CYAN}Control D (p2 Ads/Malware), Google H3, Cloudflare, DoQ${NC}"
        if [[ "${AGH_XRAY_DNS,,}" == "y" || "${AGH_XRAY_DNS:-}" == "1" ]]; then
            echo -e "  - ${YELLOW}Интеграция с Xray:${NC}   ${GREEN}127.0.0.1 (Все VPN-клиенты фильтруются через AGH)${NC}"
        fi
        echo
        echo -e "  ${YELLOW}Инструкция по настройке роутера (Keenetic):${NC}"
        echo -e "    1. Сетевые правила -> Интернет-фильтры -> Настройка DNS (вкладка DNS-серверы)"
        echo -e "    2. Добавить DNS-сервер -> IP-адрес: ${CYAN}${local_server_ip}${NC}"
        echo -e "    3. URL DoH: ${CYAN}${local_agh_doh_url}${NC}"
        echo
        echo -e "  ${YELLOW}Инструкция по настройке OpenWrt (Podkop / https-dns-proxy):${NC}"
        echo -e "    1. Services -> HTTPS DNS Proxy -> Добавить upstream"
        echo -e "    2. Custom URL: ${CYAN}${local_agh_doh_url}${NC}"
    fi

    if [[ "${ENABLE_NODE_TOKEN,,}" == "y" || "${ENABLE_NODE_TOKEN:-}" == "1" ]]; then
        echo
        echo -e "${YELLOW}ПОДКЛЮЧЕНИЕ СЕРВЕРА КАК УЗЛА (3X-UI NODE):${NC}"
        echo -e "  - ${YELLOW}Имя узла (Node Name):${NC}       ${GREEN}${NODE_TOKEN_NAME}${NC}"
        echo -e "  - ${YELLOW}Адрес хоста (Host):${NC}         ${CYAN}${PRIMARY_DOMAIN}${NC}"
        echo -e "  - ${YELLOW}Порт (Port):${NC}                ${GREEN}443${NC} (HTTPS через Nginx L4/L7 маскировку)"
        echo -e "  - ${YELLOW}Базовый путь (Base Path):${NC}   ${CYAN}${PANEL_PATH}${NC}"
        if [ -n "${NODE_TOKEN:-}" ]; then
            echo -e "  - ${YELLOW}API Token:${NC}                  ${GREEN}${NODE_TOKEN}${NC}"
        else
            echo -e "  - ${YELLOW}API Token:${NC}                  ${GREEN}Сгенерирован в базе 3X-UI${NC}"
        fi
        echo -e "  - ${YELLOW}Авторизация (Fallback):${NC}     Логин: ${WHITE}${ADMIN_USERNAME:-admin}${NC}, Пароль: ${YELLOW}${ADMIN_PASSWORD}${NC}"
        echo -e "  - ${YELLOW}Проверка сертификата (TLS):${NC}  ${GREEN}Включена (Действительный сертификат Let's Encrypt)${NC}"
    fi
else
    # --- Шаг 3: Автономный сервер AmneziaWG (awg-mgr) ---
    if ! should_skip_step 3; then
        step_begin 3
        ensure_amneziawg_installed
        setup_amneziawg_controller
        deploy_amneziawg_backend
        if command -v ufw >/dev/null 2>&1; then
            awg_p="${AWG_STANDALONE_PORT:-8445}"
            ufw allow "${awg_p}/udp" comment "AmneziaWG Standalone Server" >/dev/null 2>&1 || true
            ok "Правило файрвола: разрешен порт ${awg_p}/udp (AmneziaWG)"
        fi
        step_finish 3
    fi

    echo
    echo -e "${GREEN}=====================================================================${NC}"
    echo -e "  ${GREEN}${BOLD}🎉 УСТАНОВКА АВТОНОМНОГО СЕРВЕРА AMNEZIAWG УСПЕШНО ЗАВЕРШЕНА!${NC}"
    echo -e "${GREEN}=====================================================================${NC}"
    echo
    echo -e "${YELLOW}СЕРВЕРНЫЙ КОНТРОЛЛЕР AMNEZIAWG (awg-mgr):${NC}"
    echo -e "  - ${YELLOW}Служба ядра Linux:${NC}         ${GREEN}awg-quick@awg0${NC} (активна)"
    echo -e "  - ${YELLOW}Внешний UDP-порт:${NC}          ${WHITE}${AWG_STANDALONE_PORT:-8445}/udp${NC}"
    echo -e "  - ${YELLOW}Хост подключения (Endpoint):${NC} ${CYAN}${AWG_SERVER_HOST:-${WAN_IP:-127.0.0.1}}:${AWG_STANDALONE_PORT:-8445}${NC}"
    echo -e "  - ${YELLOW}Первичный конфиг админа:${NC}     ${CYAN}/root/awg/client-1.conf${NC}"
    echo -e "  - ${YELLOW}Утилита управления:${NC}          ${GREEN}awg-mgr${NC} (или ${GREEN}awg-cli${NC})"
    echo
    echo -e "  ${YELLOW}Команды управления клиентами:${NC}"
    echo -e "    * Создать нового клиента:   ${CYAN}awg-mgr add <имя> [--expires=30d] [--dns=quad9|cloudflare|adguard]${NC}"
    echo -e "    * Список всех клиентов:     ${CYAN}awg-mgr list${NC}"
    echo -e "    * Показать QR-код клиента:  ${CYAN}awg-mgr qr <имя>${NC}"
    echo -e "    * Отозвать / удалить:       ${CYAN}awg-mgr remove <имя>${NC}"
    echo -e "    * Резервная копия:          ${CYAN}awg-mgr backup${NC} / ${CYAN}awg-mgr restore <файл>${NC}"
    echo -e "    * Автоочистка истекших:     ${CYAN}awg-mgr purge-expired${NC} (активна в cron)"
    echo

    if [ -f "/root/awg/client-1.conf" ] && command -v /root/awg/manage_amneziawg.sh >/dev/null 2>&1; then
        echo -e "  ${WHITE}${BOLD}QR-код для подключения первого клиента (client-1):${NC}"
        /root/awg/manage_amneziawg.sh qr client-1 2>/dev/null || true
        echo
    fi
fi
echo -e "${GREEN}=====================================================================${NC}"

# Сброс контрольной точки после успешного завершения всех этапов установки
record_step_completed 0

# Расчет общего времени выполнения скрипта
SCRIPT_END_TIME=$(date +%s)
SCRIPT_END_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
TOTAL_EXECUTION_TIME=$(( SCRIPT_END_TIME - SCRIPT_START_TIME ))
FORMATTED_TOTAL_TIME=$(format_duration "$TOTAL_EXECUTION_TIME")

echo ""
echo -e "  ${CYAN}${BOLD}⏱️  Статистика выполнения установки:${NC}"
echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
echo -e "  Время запуска:        ${WHITE}${SCRIPT_START_DATETIME}${NC}"
echo -e "  Время завершения:     ${WHITE}${SCRIPT_END_DATETIME}${NC}"
echo -e "  Общее время работы:   ${GREEN}${BOLD}${FORMATTED_TOTAL_TIME}${NC}"
echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
echo -e "  ${WHITE}Время по шагам:${NC}"
for ((s_idx=1; s_idx<=TOTAL_STEPS; s_idx++)); do
    step_t="${STEP_DURATIONS[$s_idx]:-0}"
    s_name="${STEP_NAMES[$s_idx]:-Шаг $s_idx}"
    if [ "$step_t" -gt 0 ]; then
        s_dur_str=$(format_duration "$step_t")
        if [ "${STEP_BG_FLAGS[$s_idx]:-0}" -eq 1 ]; then
            echo -e "    • Шаг $s_idx ($s_name): ${GREEN}${s_dur_str}${NC} ${CYAN}[в фоне, сэкономлено]${NC}"
        else
            echo -e "    • Шаг $s_idx ($s_name): ${GREEN}${s_dur_str}${NC}"
        fi
    elif [ "${RESUME_STEP:-1}" -gt "$s_idx" ]; then
        echo -e "    • Шаг $s_idx ($s_name): ${DIM}пропущено (выполнено ранее)${NC}"
    else
        echo -e "    • Шаг $s_idx ($s_name): ${DIM}< 1 сек${NC}"
    fi
done
echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}\n"

if [ "$local_target_ssh" -ne "$local_active_ssh" ]; then
    wait_and_finalize_ssh_transition "$local_target_ssh" "$local_active_ssh"
fi

exit 0
