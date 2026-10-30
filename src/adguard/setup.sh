    install_agh_task() {
        # 1. Бесконфликтная изоляция DNS: systemd-resolved (DoT на :53) и AdGuard Home (на :10053)
        rm -f /etc/systemd/resolved.conf.d/adguard.conf 2>/dev/null || true

        # 2. Скачивание и распаковка AdGuard Home (если ещё не установлен, T04/T05)
        if [ ! -f /opt/AdGuardHome/AdGuardHome ]; then
            cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
            local m_arch="x86_64"
            case "$cur_arch" in
                x86_64|amd64) m_arch="x86_64" ;;
                aarch64|arm64) m_arch="aarch64" ;;
                *) m_arch="x86_64" ;;
            esac

            local agh_tmp="/tmp/agh_staging_$$"
            mkdir -p "$agh_tmp"
            if download_manifest_component "AdGuardHome" "$agh_tmp/agh.tar.gz" "$m_arch"; then
                tar -zxf "$agh_tmp/agh.tar.gz" -C /opt/ >/dev/null 2>&1
            fi
            rm -rf "$agh_tmp"
        fi

        # 3. Генерация bcrypt-хэша пароля через Python3 (без сторонних пакетов Apache)
        agh_pass_hash=$(python3 -c "
import sys
try:
    import bcrypt
    print(bcrypt.hashpw(sys.argv[1].encode('utf-8'), bcrypt.gensalt(10)).decode('utf-8'))
except Exception:
    pass
" "$AGH_PASS" 2>/dev/null || true)
        if [ -z "$agh_pass_hash" ] && command -v htpasswd >/dev/null 2>&1; then
            agh_pass_hash=$(htpasswd -b -n -B -C 10 "" "$AGH_PASS" 2>/dev/null | tr -d '\n' | cut -d: -f2)
        fi
        [ -n "$agh_pass_hash" ] || die "Не удалось сгенерировать bcrypt-хэш пароля для AdGuard Home."

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
  port: ${PORT_AGH_DNS:-10053}
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
        if [ ! -x /opt/AdGuardHome/AdGuardHome ]; then
            die "Не удалось загрузить или распаковать бинарник AdGuard Home в /opt/AdGuardHome/AdGuardHome"
        fi
        /opt/AdGuardHome/AdGuardHome -s install >/dev/null 2>&1 || true

        # 6. Ограничение памяти Go для экономии RAM на VPS
        if ! is_openrc && command -v systemctl >/dev/null 2>&1; then
            mkdir -p /etc/systemd/system/AdGuardHome.service.d
            cat << 'EOF_GOMEM' > /etc/systemd/system/AdGuardHome.service.d/memory.conf
[Service]
Environment="GOGC=50"
Environment="GOMEMLIMIT=100MiB"
EOF_GOMEM
            systemctl daemon-reload 2>/dev/null || true
        fi
        svc_restart AdGuardHome 2>/dev/null || systemctl restart AdGuardHome 2>/dev/null || rc-service AdGuardHome restart 2>/dev/null || true

        # 7. Интеграция с Xray DNS (если выбрано AGH_XRAY_DNS=y)
        if is_true "${AGH_XRAY_DNS:-n}"; then
            xui_db="/etc/x-ui/x-ui.db"
            [ -f "$xui_db" ] || xui_db="/usr/local/x-ui/bin/x-ui.db"
            if [ -f "$xui_db" ]; then
                python3 -c "
import sqlite3, json, os

db_path = '$xui_db'
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute(\"SELECT value FROM settings WHERE key='xrayTemplateConfig'\")
row = cur.fetchone()
if row and row[0]:
    try:
        cfg = json.loads(row[0])
        dns = cfg.get('dns', {})
        agh_port = int(os.environ.get('PORT_AGH_DNS') or '10053')
        dns['servers'] = [{'address': '127.0.0.1', 'port': agh_port}]
        dns['queryStrategy'] = 'UseIPv4'
        cfg['dns'] = dns
        new_val = json.dumps(cfg, ensure_ascii=False)
        cur.execute(\"UPDATE settings SET value=? WHERE key='xrayTemplateConfig'\", (new_val,))
        conn.commit()
    except Exception:
        pass
conn.close()
" 2>/dev/null || true
                svc_restart x-ui 2>/dev/null || systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null || true
            fi
        fi
    }

    run_with_spinner "Установка и настройка AdGuard Home (DoH + Split-DNS + OISD)" install_agh_task || die "Ошибка установки AdGuard Home."
