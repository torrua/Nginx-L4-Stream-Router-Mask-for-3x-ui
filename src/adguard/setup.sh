# --- Шаг 8: Приватный AdGuard Home DoH + Split-DNS (Опционально) ---
if should_skip_step 8; then
    :
elif [[ "${ENABLE_AGH,,}" != "y" && "${ENABLE_AGH:-}" != "1" ]]; then
    step_begin 8
    ok "Шаг 8: AdGuard Home DoH отключен в конфигурации — пропущено."
    step_finish 8
else
    step_begin 8

    install_agh_task() {
        # 1. Отключение systemd-resolved StubListener
        mkdir -p /etc/systemd/resolved.conf.d
        cat << 'EOF_RESOLVED' > /etc/systemd/resolved.conf.d/adguard.conf
[Resolve]
DNS=1.1.1.1 8.8.8.8
DNSStubListener=no
EOF_RESOLVED
        systemctl restart systemd-resolved 2>/dev/null || true
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || true

        # 2. Скачивание и распаковка AdGuard Home (если ещё не установлен)
        if [ ! -f /opt/AdGuardHome/AdGuardHome ]; then
            agh_arch="amd64"
            cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
            case "$cur_arch" in
                x86_64) agh_arch="amd64" ;;
                aarch64|arm64) agh_arch="arm64" ;;
                armv7l|armhf) agh_arch="armv7" ;;
                *) agh_arch="amd64" ;;
            esac

            curl -fsSL "https://static.adguard.com/adguardhome/release/AdGuardHome_linux_${agh_arch}.tar.gz" -o /tmp/agh.tar.gz 2>/dev/null || \
                curl -fsSL "https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_${agh_arch}.tar.gz" -o /tmp/agh.tar.gz
            tar -zxf /tmp/agh.tar.gz -C /opt/ >/dev/null 2>&1
            rm -f /tmp/agh.tar.gz
        fi

        # 3. Генерация bcrypt-хэша пароля через htpasswd
        which htpasswd >/dev/null 2>&1 || apt-get install -y -q apache2-utils >/dev/null 2>&1
        agh_pass_hash=""
        if command -v htpasswd >/dev/null 2>&1; then
            agh_pass_hash=$(htpasswd -b -n -B -C 10 "" "$AGH_PASS" 2>/dev/null | tr -d '\n' | cut -d: -f2)
        fi
        if [ -z "$agh_pass_hash" ]; then
            agh_pass_hash=$(python3 -c "
import sys
try:
    import bcrypt
    print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(10)).decode())
except Exception:
    pass
" "$AGH_PASS" 2>/dev/null || true)
        fi

        # 4. Создание конфигурации AdGuardHome.yaml
        mkdir -p /opt/AdGuardHome
        cat << EOF_AGH > /opt/AdGuardHome/AdGuardHome.yaml
http:
  address: 127.0.0.1:${PORT_AGH_WEB:-3000}
  doh:
    insecure_enabled: true
users:
  - name: ${AGH_USER}
    password: "${agh_pass_hash}"
dns:
  bind_hosts:
    - 127.0.0.1
  port: 53
  trusted_proxies:
    - 127.0.0.1
    - ::1
  ratelimit: 20
  ratelimit_whitelist:
    - 127.0.0.1
  dnssec: true
  upstream_dns:
    - "[/ru/kz/by/su/xn--p1ai/]https://77.88.8.8:443/dns-query"
    - "[/google.com/googlevideo.com/youtube.com/ytimg.com/gstatic.com/googleapis.com/1e100.net/]h3://dns.google/dns-query"
    - "quic://p2.freedns.controld.com"
    - "quic://dns.adguard-dns.com"
    - "quic://dns.nextdns.io"
    - "quic://dns.quad9.net"
    - "quic://doq.ffmuc.net"
    - "quic://dns.surfsharkdns.com"
    - "h3://cloudflare-dns.com/dns-query"
  blocked_hosts: []
  allowed_clients:
    - ${AGH_CLIENT_ID}
    - 127.0.0.1
  disallowed_clients: []
clients:
  runtime_sources:
    whois: false
    dhcp: false
  persistent:
    - name: "Home-Router"
      ids:
        - ${AGH_CLIENT_ID}
      use_global_settings: true
filters:
  - enabled: true
    url: "https://small.oisd.nl/domainswild"
    name: "OISD Small (Ads + Trackers)"
    id: 1
filtering:
  filtering_enabled: true
  filters_update_interval: 24
querylog:
  enabled: true
  interval: 24h
  size_memory: 1000
statistics:
  enabled: true
  interval: 168h
tls:
  enabled: false
  allow_unencrypted_doh: true
schema_version: 28
EOF_AGH

        # 5. Установка и запуск службы systemd
        /opt/AdGuardHome/AdGuardHome -s install >/dev/null 2>&1 || true

        # 6. Ограничение памяти Go для экономии RAM на VPS
        mkdir -p /etc/systemd/system/AdGuardHome.service.d
        cat << 'EOF_GOMEM' > /etc/systemd/system/AdGuardHome.service.d/memory.conf
[Service]
Environment="GOGC=50"
Environment="GOMEMLIMIT=100MiB"
EOF_GOMEM
        systemctl daemon-reload 2>/dev/null || true
        systemctl restart AdGuardHome 2>/dev/null || true

        # 7. Интеграция с Xray DNS (если выбрано AGH_XRAY_DNS=y)
        if [[ "${AGH_XRAY_DNS,,}" == "y" || "${AGH_XRAY_DNS:-}" == "1" ]]; then
            xui_db="/etc/x-ui/x-ui.db"
            [ -f "$xui_db" ] || xui_db="/usr/local/x-ui/bin/x-ui.db"
            if [ -f "$xui_db" ]; then
                python3 -c "
import sqlite3, json

db_path = '$xui_db'
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute(\"SELECT value FROM settings WHERE key='xrayTemplateConfig'\")
row = cur.fetchone()
if row and row[0]:
    try:
        cfg = json.loads(row[0])
        dns = cfg.get('dns', {})
        dns['servers'] = ['127.0.0.1']
        dns['queryStrategy'] = 'UseIPv4'
        cfg['dns'] = dns
        new_val = json.dumps(cfg, ensure_ascii=False)
        cur.execute(\"UPDATE settings SET value=? WHERE key='xrayTemplateConfig'\", (new_val,))
        conn.commit()
    except Exception:
        pass
conn.close()
" 2>/dev/null || true
                systemctl restart x-ui 2>/dev/null || true
            fi
        fi
    }

    run_with_spinner "Установка и настройка AdGuard Home (DoH + Split-DNS + OISD)" install_agh_task || die "Ошибка установки AdGuard Home."
    step_finish 8
fi

# Итоговая проверка работоспособности ключевых сервисов (Smoke Test)
post_install_sanity_check

echo
echo -e "${GREEN}=====================================================================${NC}"
echo -e "   ИНФРАСТРУКТУРА УСПЕШНО РАЗВЕРНУТА (${SCRIPT_VERSION} PUBLIC EDITION)!       "
echo -e "${GREEN}=====================================================================${NC}"
echo -e "  Главная страница:            ${CYAN}https://${PRIMARY_DOMAIN}/${NC} (${DECOY_NAME})"
echo -e "  Вход в панель 3X-UI:         ${GREEN}https://${PRIMARY_DOMAIN}${PANEL_PATH}${NC}"
echo -e "  Логин администратора:        ${BOLD}${ADMIN_USERNAME:-admin}${NC}"
if [ -n "${ADMIN_PASSWORD:-}" ]; then
    echo -e "  Пароль администратора:       ${BOLD}${ADMIN_PASSWORD}${NC}"
fi
echo -e "  Канал подписок:              ${GREEN}https://${PRIMARY_DOMAIN}${SUB_PATH}${NC}"
echo -e "  Канал подписок (JSON):       ${GREEN}https://${PRIMARY_DOMAIN}${SUB_JSON_PATH}${NC}"
echo -e "  Канал подписок (Clash):      ${GREEN}https://${PRIMARY_DOMAIN}${SUB_CLASH_PATH}${NC}"
if [[ "${ENABLE_WARP,,}" == "y" || "${ENABLE_WARP:-}" == "1" ]]; then
    echo -e "  Cloudflare WARP Outbound:    ${GREEN}АКТИВИРОВАН (Google, Gemini, ChatGPT / MTU 1280)${NC}"
fi
if [[ "${ENABLE_AGH,,}" == "y" || "${ENABLE_AGH:-}" == "1" ]]; then
    if [ "${AGH_MODE:-1}" = "2" ] && [ -n "${AGH_DOMAIN:-}" ]; then
        echo -e "  Панель AdGuard Home:         ${CYAN}https://${AGH_DOMAIN}/${NC}"
        echo -e "  Приватный DoH для роутера:   ${GREEN}https://${AGH_DOMAIN}/dns-query/${AGH_CLIENT_ID}${NC}"
    else
        echo -e "  Панель AdGuard Home:         ${CYAN}http://127.0.0.1:${PORT_AGH_WEB:-3000}${NC} ${DIM}(SSH туннель)${NC}"
        echo -e "  Приватный DoH для роутера:   ${GREEN}https://${PRIMARY_DOMAIN}/dns-query/${AGH_CLIENT_ID}${NC}"
    fi
fi
if [[ "${ENABLE_NODE_TOKEN,,}" == "y" || "${ENABLE_NODE_TOKEN:-}" == "1" ]]; then
    echo -e "  3X-UI Node API Token:        ${GREEN}${NODE_TOKEN:-Создан в 3X-UI}${NC} (${WHITE}${NODE_TOKEN_NAME}${NC})"
fi

# Сохранение учетных данных в защищенный файл
if [ -n "${ADMIN_PASSWORD:-}" ]; then
    CRED_FILE="/root/vpn_credentials.txt"
    cat << EOF_CRED > "$CRED_FILE"
=====================================================================
УЧЕТНЫЕ ДАННЫЕ ПАНЕЛИ И СЕРВИСОВ 3X-UI
Файл создан: $(date '+%Y-%m-%d %H:%M:%S')
=====================================================================
Панель управления:         https://${PRIMARY_DOMAIN}${PANEL_PATH}
Логин администратора:       ${ADMIN_USERNAME:-admin}
Пароль администратора:      ${ADMIN_PASSWORD}

Ссылка на подписку:        https://${PRIMARY_DOMAIN}${SUB_PATH}
Ссылка на подписку (JSON): https://${PRIMARY_DOMAIN}${SUB_JSON_PATH}
Ссылка на подписку (Clash): https://${PRIMARY_DOMAIN}${SUB_CLASH_PATH}
EOF_CRED
    if [[ "${ENABLE_AGH,,}" == "y" || "${ENABLE_AGH:-}" == "1" ]]; then
        cat << EOF_AGH_CRED >> "$CRED_FILE"
=====================================================================
ПРИВАТНЫЙ ADGUARD HOME DOH
Логин администратора:  ${AGH_USER}
Пароль администратора: ${AGH_PASS}
URL DoH для роутера:   $([ "${AGH_MODE:-1}" = "2" ] && echo "https://${AGH_DOMAIN}/dns-query/${AGH_CLIENT_ID}" || echo "https://${PRIMARY_DOMAIN}/dns-query/${AGH_CLIENT_ID}")
EOF_AGH_CRED
    fi
    if [[ "${ENABLE_NODE_TOKEN,,}" == "y" || "${ENABLE_NODE_TOKEN:-}" == "1" ]]; then
        cat << EOF_NODE_CRED >> "$CRED_FILE"
=====================================================================
ПОДКЛЮЧЕНИЕ СЕРВЕРА КАК УЗЛА (3X-UI NODE)
Имя узла (Node Name):  ${NODE_TOKEN_NAME}
Адрес хоста (Host):    ${PRIMARY_DOMAIN}
Порт (Port):           443 (HTTPS через Nginx L4/L7)
Базовый путь:          ${PANEL_PATH}
API Token:             ${NODE_TOKEN:-Создан в базе 3X-UI}
Логин администратора:  ${ADMIN_USERNAME:-admin}
Пароль администратора: ${ADMIN_PASSWORD}
TLS сертификат:        Действительный (Let's Encrypt / acme.sh)
EOF_NODE_CRED
    fi
    echo "=====================================================================" >> "$CRED_FILE"
    chmod 600 "$CRED_FILE" 2>/dev/null || true
    echo -e "  ${CYAN}[i] Учетные данные сохранены в:${NC} ${BOLD}$CRED_FILE${NC} (chmod 600)"
fi
echo

echo -e "${YELLOW}[SSL] ВЫПУЩЕННЫЕ СЕРТИФИКАТЫ (Базовый путь: ${SSL_BASE_DIR}):${NC}"
echo -e "$SSL_CERT_REPORT"

echo -e "${YELLOW}ШАГ 1: Настройка файервола UFW (Защита локальных сокетов и открытие VPN):${NC}"
echo -e "  ${CYAN}${UFW_ALLOW_LIST}${NC}"
echo -e "  ${RED}ufw deny $PANEL_PORT/tcp && ufw deny $SUB_PORT/tcp && ufw deny $XHTTP_STREAM_PORT/tcp && ufw deny $REALITY_FALLBACK_PORT/tcp${UFW_DENY_LIST}${NC}"
echo

echo -e "${YELLOW}ШАГ 2: Инбаунды VLESS REALITY (3X-UI):${NC}"
echo -e "$REALITY_INBOUNDS_REPORT"

echo -e "${YELLOW}ШАГ 3: Инбаунд VLESS xHTTP (Native H2 Stream-One + VLESSENC + Анти-Дроп):${NC}"
echo -e "  - ${YELLOW}Вкладка «Основное»:${NC} Протокол: ${GREEN}vless${NC} | Адрес: ${GREEN}127.0.0.1${NC} | Порт: ${GREEN}$XHTTP_STREAM_PORT${NC}"
echo -e "  - ${YELLOW}Вкладка «Протокол»:${NC} Генерация ключей: выбрать ${GREEN}ML-KEM-768 (native)${NC} и нажать ${CYAN}«Сгенерировать»${NC}"
echo -e "  - ${YELLOW}Вкладка «Поток»:${NC}"
echo -e "    * Транспорт: ${GREEN}xHTTP${NC} | Режим: ${GREEN}stream-one${NC}"
echo -e "    * Хост: ${CYAN}$PRIMARY_DOMAIN${NC} | Путь: ${CYAN}$XHTTP_STREAM_PATH${NC}"
echo -e "    * Padding Bytes: ${GREEN}100-500${NC} | Padding Obfs Mode: ${GREEN}Включить${NC} | Key: ${GREEN}X-Amz-Meta-Trace${NC}"
echo -e "    * XMUX: ${GREEN}maxConcurrency: 0 (Выключено)${NC} — исключает раздувание буферов и вылеты на iOS/ПК"
echo -e "    * ${RED}ВНИМАНИЕ:${NC} ${YELLOW}QUIC / UDP ПАРАМЕТРЫ СТРОГО ВЫКЛЮЧИТЬ (0)${NC} — поток идёт строго по HTTP/2 TCP через Nginx!"
echo -e "  - ${YELLOW}Вкладка «Безопасность»:${NC} ${RED}Нет (None)${NC} | Accept Proxy Protocol: ${RED}Выключить (0)${NC}"
echo -e "  - ${YELLOW}Вкладка «Сниффинг»:${NC} Включить (${GREEN}HTTP, TLS, QUIC, FAKEDNS${NC})"
echo

if [[ "${ENABLE_HY2:-}" == "1" || "${ENABLE_HY2,,}" == "y" ]] && [ -n "${HY2_PORT:-}" ]; then
hy2_active_dom="${HY2_DOMAIN:-$PRIMARY_DOMAIN}"
echo -e "${YELLOW}ШАГ 4: Инбаунд Hysteria 2 (UDP $HY2_PORT):${NC}"
echo -e "  - ${YELLOW}Вкладка «Основное»:${NC} Протокол: ${GREEN}hysteria (v2)${NC} | Адрес: ${GREEN}0.0.0.0${NC} | Порт: ${GREEN}$HY2_PORT${NC} (UDP)"
echo -e "  - ${YELLOW}Вкладка «Поток»:${NC} Masquerade: тип ${GREEN}proxy${NC} -> URL: ${CYAN}http://127.0.0.1:80${NC}"
echo -e "  - ${YELLOW}Вкладка «Безопасность»:${NC} ${GREEN}TLS${NC} | SNI: ${CYAN}${hy2_active_dom}${NC} | ALPN: ${GREEN}h3${NC}"
echo -e "    * Публичный ключ: ${CYAN}${SSL_BASE_DIR}/${hy2_active_dom}/fullchain.pem${NC}"
echo -e "    * Приватный ключ: ${CYAN}${SSL_BASE_DIR}/${hy2_active_dom}/privkey.pem${NC}"
if [[ "${HY2_PORT_HOPPING,,}" == "y" || "${HY2_PORT_HOPPING:-}" == "1" ]] && [ -n "${HY2_PORT_HOPPING_RANGE:-}" ]; then
echo -e "  - ${YELLOW}Port Hopping:${NC} ${GREEN}Активирован${NC} | Диапазон: ${CYAN}UDP ${HY2_PORT_HOPPING_RANGE//:/-}${NC} → порт ${GREEN}${HY2_PORT}${NC}"
echo -e "    * Адрес подключения клиента: ${CYAN}${hy2_active_dom}:${HY2_PORT},${HY2_PORT_HOPPING_RANGE//:/-}${NC}"
fi
echo
fi

if [[ "${ENABLE_AWG_V3:-}" == "1" || "${ENABLE_AWG_V3,,}" == "y" ]] && [ -n "${AWG_V3_PORT:-}" ]; then
echo -e "${YELLOW}ШАГ 5: Инбаунд AmneziaWG v3.1 (WG3 — UDP $AWG_V3_PORT):${NC}"
echo -e "  - ${YELLOW}Вкладка «Основное»:${NC}"
echo -e "    * Включить: ${GREEN}Включено${NC} | Примечание: ${GREEN}WG3${NC} | Протокол: ${GREEN}amneziawg${NC}"
echo -e "    * Адрес: ${GREEN}0.0.0.0${NC} | Стратегия адреса для ссылок: ${GREEN}Адрес прослушивания inbound${NC}"
echo -e "    * Порядок в подписке: ${GREEN}1${NC} | Порт: ${GREEN}$AWG_V3_PORT${NC} (UDP)"
echo -e "    * Общий расход: ${GREEN}0${NC} | Сброс трафика: ${GREEN}Никогда${NC}"
echo -e "  - ${YELLOW}Вкладка «Протокол»:${NC}"
echo -e "    * Ключи: нажать ${CYAN}«Сгенерировать»${NC} (иконка обновления рядом с приватным ключом)"
echo -e "    * Сеть: Подсеть: ${GREEN}10.8.0.0${NC} | Маска подсети (CIDR): ${GREEN}22${NC} | MTU: ${GREEN}1280${NC}"
