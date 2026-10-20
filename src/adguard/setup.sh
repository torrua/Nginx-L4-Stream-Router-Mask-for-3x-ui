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
