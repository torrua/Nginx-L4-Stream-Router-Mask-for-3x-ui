import os
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

import sqlite3
import json
import uuid
import secrets
import base64
import time
import urllib.request
import urllib.parse
import re

db_path = os.environ["DB_PATH"]
dry_run = os.environ.get("DRY_RUN", "0") == "1"
force_sub = os.environ.get("FORCE_SUB", "0") == "1"
force_remarks = os.environ.get("FORCE_REMARKS", "0") == "1"

conn = sqlite3.connect(db_path, timeout=30.0)
cur = conn.cursor()

# Извлечение существующих параметров из таблицы settings
existing_settings = {}
try:
    cur.execute("SELECT key, value FROM settings")
    for k, v in cur.fetchall():
        existing_settings[k] = v
except Exception as e:
    print(f"[!] Предупреждение: ошибка чтения таблицы settings: {e}")

domain = os.environ.get("PRIMARY_DOMAIN") or existing_settings.get("subDomain") or "localhost"
panel_port = os.environ.get("PANEL_PORT") or existing_settings.get("webPort") or "10443"
# @include "xray/paths.py"

panel_path = resolve_panel_path(os.environ.get("PANEL_PATH"), existing_settings.get("webBasePath"))

sub_port = os.environ.get("SUB_PORT") or existing_settings.get("subPort") or "55443"
sub_env = (os.environ.get("SUB_PATH") or "").strip("/")
if sub_env and sub_env != "my-post-key":
    sub_path = sub_env
else:
    sub_db = (existing_settings.get("subPath") or "").strip("/")
    if sub_db and sub_db != "my-post-key":
        sub_path = sub_db
    else:
        import secrets
        sub_path = "sub-" + secrets.token_hex(4)
sub_clash_env = (os.environ.get("SUB_CLASH_PATH") or "").strip().strip("/")
if sub_clash_env:
    sub_clash_path = sub_clash_env
else:
    sub_clash_db = (existing_settings.get("subClashPath") or "").strip().strip("/")
    if sub_clash_db and sub_clash_db != f"{sub_path}clash":
        sub_clash_path = sub_clash_db
    else:
        sub_clash_path = f"{sub_path}/clash"

xhttp_port = int(os.environ.get("XHTTP_STREAM_PORT") or "50443")
xhttp_raw_path = (os.environ.get("XHTTP_STREAM_PATH") or "").strip("/")
if not xhttp_raw_path or xhttp_raw_path == "Stream-One-Path" or xhttp_raw_path.startswith("vless-"):
    cur.execute("SELECT stream_settings FROM inbounds WHERE port = ?", (xhttp_port,))
    row_xh = cur.fetchone()
    found_p = None
    if row_xh and row_xh[0]:
        try:
            found_p = json.loads(row_xh[0]).get("xhttpSettings", {}).get("path", "").strip("/")
        except Exception:
            pass
    if found_p and found_p != "Stream-One-Path" and not found_p.startswith("vless-"):
        xhttp_raw_path = found_p
    else:
        import secrets
        xhttp_raw_path = secrets.token_hex(4)
xhttp_path = "/" + xhttp_raw_path.strip("/") + "/"

enable_steal = os.environ.get("ENABLE_STEAL", "y").lower() in ("1", "y", "true")
steal_port = int(os.environ.get("STEAL_PORT") or "45443")
steal_dom = os.environ.get("STEAL_DOMAINS") or f"cdn.{domain}"
steal_dom = steal_dom.split()[0] if steal_dom.strip() else f"cdn.{domain}"
reality_fallback_port = int(os.environ.get("REALITY_FALLBACK_PORT") or "9443")

enable_classic = os.environ.get("ENABLE_CLASSIC", "y").lower() in ("1", "y", "true")
classic_port = int(os.environ.get("CLASSIC_PORT") or "46443")
classic_sni = os.environ.get("CLASSIC_SNI") or "avito.ru"
classic_sni = classic_sni.split()[0] if classic_sni.strip() else "avito.ru"

def resolve_cert_key_paths(target_dom: str, env_cert: str = "", env_key: str = "") -> tuple:
    """
    Unified SSL certificate resolver: returns (cert_path, key_path).
    Prioritizes explicit valid files, then Let's Encrypt (/etc/letsencrypt/live),
    then ACME (/etc/ssl/acme for Cloudflare DNS-01 API).
    """
    if env_cert and env_key and os.path.isfile(env_cert) and os.path.isfile(env_key):
        return env_cert, env_key
    le_cert = f"/etc/letsencrypt/live/{target_dom}/fullchain.pem"
    le_key = f"/etc/letsencrypt/live/{target_dom}/privkey.pem"
    if os.path.isfile(le_cert) and os.path.isfile(le_key):
        return le_cert, le_key
    acme_cert = f"/etc/ssl/acme/{target_dom}/fullchain.pem"
    acme_key = f"/etc/ssl/acme/{target_dom}/privkey.pem"
    if os.path.isfile(acme_cert) and os.path.isfile(acme_key):
        return acme_cert, acme_key
    return env_cert or le_cert, env_key or le_key


ssl_cert, ssl_key = resolve_cert_key_paths(domain, os.environ.get("SSL_CERT_PATH", ""), os.environ.get("SSL_KEY_PATH", ""))

enable_hy2 = os.environ.get("ENABLE_HY2", "y").lower() in ("1", "y", "true")
hy2_port = int(os.environ.get("HY2_PORT") or "443")
hy2_domain = (os.environ.get("HY2_DOMAIN") or domain).strip()
hy2_cert, hy2_key = resolve_cert_key_paths(hy2_domain, os.environ.get("HY2_CERT_PATH", ""), os.environ.get("HY2_KEY_PATH", ""))

enable_awg_v3 = os.environ.get("ENABLE_AWG_V3", "y").lower() in ("1", "y", "true")
awg_v3_port = int(os.environ.get("AWG_V3_PORT") or "8443")

enable_awg_v2 = os.environ.get("ENABLE_AWG_V2", "n").lower() in ("1", "y", "true")
awg_v2_port = int(os.environ.get("AWG_V2_PORT") or "8444")
awg_primary_dns = os.environ.get("AWG_PRIMARY_DNS") or "9.9.9.9"
awg_secondary_dns = os.environ.get("AWG_SECONDARY_DNS") or "76.76.2.0"
awg_subnet_ip = os.environ.get("AWG_SUBNET_IP") or "10.8.0.0"
awg_subnet_cidr = int(os.environ.get("AWG_SUBNET_CIDR") or "22")
awg_hpk_env = os.environ.get("AWG_HEADER_PROTECTION_KEY", "").strip()
awg_random_trailers_env = os.environ.get("AWG_RANDOM_TRAILERS", "false").strip().lower() in ("1", "y", "true")

enable_ss2022 = os.environ.get("ENABLE_SS2022", "n").lower() in ("1", "y", "true")
ss2022_port = int(os.environ.get("SS2022_PORT") or "8388")
enable_shadowtls = os.environ.get("ENABLE_SHADOWTLS", "n").lower() in ("1", "y", "true")
shadowtls_port = int(os.environ.get("SHADOWTLS_PORT") or "8543")
shadowtls_sni = (os.environ.get("SHADOWTLS_SNI") or "gateway.icloud.com").strip()
shadowtls_password = os.environ.get("SHADOWTLS_PASSWORD", "").strip()

enable_tuic = os.environ.get("ENABLE_TUIC", "n").lower() in ("1", "y", "true")
tuic_port = int(os.environ.get("TUIC_PORT") or "8448")

enable_mtproto = os.environ.get("ENABLE_MTPROTO", "n").lower() in ("1", "y", "true")
mtproto_port = int(os.environ.get("MTPROTO_PORT") or "8444")
mtproto_faketls_domain = (os.environ.get("MTPROTO_FAKETLS_DOMAIN") or "gateway.icloud.com").strip()
mtproto_adtag = os.environ.get("MTPROTO_ADTAG", "").strip()

# Определение ID администратора и настройка учетных данных
admin_user = os.environ.get("ADMIN_USERNAME", "").strip()
admin_pass = os.environ.get("ADMIN_PASSWORD", "").strip()
server_prefix = os.environ.get("SERVER_PREFIX", "").strip()
if server_prefix.lower() in ("-", "none", "off", "no"):
    server_prefix = ""

def make_remark(method):
    if server_prefix:
        return f"{server_prefix} ({method})"
    return method

hashed_pass = None
if admin_pass:
    if admin_pass.startswith("$2a$") or admin_pass.startswith("$2b$") or admin_pass.startswith("$2y$"):
        hashed_pass = admin_pass
    else:
        try:
            import bcrypt
            hashed_pass = bcrypt.hashpw(admin_pass.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")
        except Exception:
            pass

cur.execute("SELECT id, username, password FROM users LIMIT 1")
user_row = cur.fetchone()
if user_row:
    admin_id, curr_user, curr_pass = user_row
    new_user = admin_user if admin_user else curr_user
    new_pass = hashed_pass if hashed_pass else curr_pass
    if admin_user or hashed_pass:
        if not dry_run:
            if hashed_pass:
                cur.execute("UPDATE users SET username = ?, password = ? WHERE id = ?", (new_user, new_pass, admin_id))
            else:
                cur.execute("UPDATE users SET username = ? WHERE id = ?", (new_user, admin_id))
        status_msg = "пароль обновлен (bcrypt)" if hashed_pass else "пароль будет синхронизирован через CLI x-ui"
        print(f"  [ИСПРАВЛЕНО] Администратор (ID {admin_id}): логин='{new_user}', {status_msg}.")
    elif admin_pass:
        print(f"  [ИНФО] Администратор (ID {admin_id}): логин='{new_user}', пароль ожидает хэширования через CLI x-ui.")
else:
    admin_id = 1
    new_pass = hashed_pass if hashed_pass else "admin"
    if not dry_run:
        cur.execute("INSERT INTO users (id, username, password) VALUES (1, ?, ?)", (admin_user or "admin", new_pass))
    print(f"  [СОЗДАНО] Администратор: логин='{admin_user or 'admin'}', пароль создан.")

# Инспекция существующих таблиц и колонок для гарантированной синхронизации клиентов
cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
all_tables = set(r[0] for r in cur.fetchall())

def get_table_columns(tbl):
    if tbl not in all_tables:
        return set()
    cur.execute(f"PRAGMA table_info({tbl})")
    return set(r[1] for r in cur.fetchall())

client_traffics_cols = get_table_columns("client_traffics")
clients_cols = get_table_columns("clients")
client_inbounds_cols = get_table_columns("client_inbounds")

# @include "xray/clients.py"

# @include "xray/keys.py"

# ----------------- 1. Настройки панели и подписок (settings) -----------------
print("\n[+] Синхронизация системных настроек панели и подписок...")

old_sub_domain = existing_settings.get("subDomain", "").strip()
old_sub_uri = existing_settings.get("subURI", "").strip()
old_sub_path = existing_settings.get("subPath", "").strip()

# Проверка: настроена ли кастомная подписка
is_custom_sub = bool(old_sub_uri and (old_sub_domain != domain or (old_sub_path.strip("/") != sub_path and old_sub_path.strip("/") != "my-post-key")))

if is_custom_sub and not force_sub:
    print(f"  [СОХРАНЕНО] Кастомная подписка сохранена: {old_sub_uri}")
    target_sub_uri = old_sub_uri
    target_sub_domain = old_sub_domain
    target_sub_path = old_sub_path
    target_sub_json_path = existing_settings.get("subJsonPath") or f"/{sub_path.strip('/')}/json/"
    target_sub_json_uri = existing_settings.get("subJsonURI") or f"https://{domain}{target_sub_json_path}"
    target_sub_clash_path = existing_settings.get("subClashPath") or f"/{sub_clash_path.strip('/')}/"
    if target_sub_clash_path.strip("/") == f"{sub_path}clash":
        target_sub_clash_path = f"/{sub_clash_path.strip('/')}/"
    target_sub_clash_uri = existing_settings.get("subClashURI") or f"https://{domain}{target_sub_clash_path}"
    if target_sub_clash_uri.endswith(f"{sub_path}clash/"):
        target_sub_clash_uri = f"https://{domain}{target_sub_clash_path}"
else:
    target_sub_uri = f"https://{domain}/{sub_path}/"
    target_sub_domain = domain
    target_sub_path = f"/{sub_path}/"
    target_sub_json_path = f"/{sub_path.strip('/')}/json/"
    target_sub_json_uri = f"https://{domain}{target_sub_json_path}"
    target_sub_clash_path = f"/{sub_clash_path.strip('/')}/"
    target_sub_clash_uri = f"https://{domain}{target_sub_clash_path}"

time_location = os.environ.get("TIME_LOCATION", "Europe/Moscow").strip()
sub_updates = os.environ.get("SUB_UPDATES", "1").strip()
sub_encrypt = os.environ.get("SUB_ENCRYPT", "true").strip().lower()
block_smtp = os.environ.get("BLOCK_SMTP", "y").strip().lower() in ("1", "y", "true")
block_lan = os.environ.get("BLOCK_LAN", "y").strip().lower() in ("1", "y", "true")
web_listen = os.environ.get("WEB_LISTEN", "").strip()
sub_listen = os.environ.get("SUB_LISTEN", "").strip()
sub_title = os.environ.get("SUB_TITLE", "").strip()
if not sub_title:
    srv_prefix = os.environ.get("SERVER_PREFIX", "").strip()
    if srv_prefix and srv_prefix.lower() not in ("-", "none", "off", "no"):
        sub_title = srv_prefix
if not sub_title:
    sub_title = existing_settings.get("subTitle", "").strip()
if not sub_title and domain and domain not in ("localhost", "127.0.0.1", "0.0.0.0"):
    sub_title = domain

settings_updates = {
    "webPort": panel_port,
    "webBasePath": f"/{panel_path}/",
    "subEnable": "true",
    "subPort": sub_port,
    "subPath": target_sub_path,
    "subURI": target_sub_uri,
    "subJsonPath": target_sub_json_path,
    "subJsonURI": target_sub_json_uri,
    "subJsonEnable": "true",
    "subClashPath": target_sub_clash_path,
    "subClashURI": target_sub_clash_uri,
    "subClashEnable": "true",
    "subDomain": target_sub_domain,
    "subCertFile": "",
    "subKeyFile": "",
    "timeLocation": time_location,
    "subUpdates": sub_updates,
    "subEncrypt": sub_encrypt
}

if sub_title:
    settings_updates["subTitle"] = sub_title

if web_listen:
    settings_updates["webListen"] = web_listen
if sub_listen:
    settings_updates["subListen"] = sub_listen

for k, v in settings_updates.items():
    current_val = existing_settings.get(k)
    if current_val != v:
        if not dry_run:
            cur.execute("SELECT id FROM settings WHERE key = ?", (k,))
            if cur.fetchone():
                cur.execute("UPDATE settings SET value = ? WHERE key = ?", (str(v), k))
            else:
                cur.execute("INSERT INTO settings (key, value) VALUES (?, ?)", (k, str(v)))
        print(f"  [ИСПРАВЛЕНО] Настройка {k}: '{current_val}' -> '{v}'")
    else:
        print(f"  [В ПОРЯДКЕ] Настройка {k}: '{v}'")

# ----------------- 1.0. Интеграция Mieru в шаблон подписки Clash (subClashTemplate) -----------------
enable_mieru = os.environ.get("ENABLE_MIERU", "n").lower() in ("1", "y", "true")
mieru_port_mode = (os.environ.get("MIERU_PORT_MODE") or "single").strip().lower()
mieru_port = (os.environ.get("MIERU_PORT") or ("8450-8455" if mieru_port_mode == "range" else "8450")).strip()
mieru_user = (os.environ.get("MIERU_USER") or "").strip()
mieru_pass = (os.environ.get("MIERU_PASS") or "").strip()

if enable_mieru and (not mieru_user or not mieru_pass) and os.path.isfile("/etc/mita_server_config.json"):
    try:
        with open("/etc/mita_server_config.json", "r", encoding="utf-8") as mf:
            mdata = json.load(mf)
            if mdata.get("users") and len(mdata["users"]) > 0:
                if not mieru_user: mieru_user = mdata["users"][0].get("name", "")
                if not mieru_pass: mieru_pass = mdata["users"][0].get("password", "")
    except Exception:
        pass

if enable_mieru and mieru_user and mieru_pass:
    server_title = (sub_title or domain or "VPN").strip()
    mieru_node_name = f"{server_title} — Mieru"
    if mieru_port_mode == "range" or "-" in mieru_port:
        m_port_field = f"port-range: {mieru_port}"
    else:
        m_port_clean = mieru_port.split("-")[0].split(":")[0]
        m_port_field = f"port: {m_port_clean}"

    mieru_yaml_block = f"""  - name: "{mieru_node_name}"
    type: mieru
    server: {domain}
    {m_port_field}
    transport: TCP
    udp: true
    username: "{mieru_user}"
    password: "{mieru_pass}"
    multiplexing: MULTIPLEXING_LOW
    handshake-mode: HANDSHAKE_STANDARD"""

    raw_clash_tpl = existing_settings.get("subClashTemplate", "")
    if not raw_clash_tpl or not raw_clash_tpl.strip():
        new_clash_tpl = f"""port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
unified-delay: true
global-client-fingerprint: chrome
dns:
  enable: true
  listen: :1053
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver:
    - 1.1.1.1
    - 8.8.8.8
  nameserver:
    - https://dns.google/dns-query
    - https://1.1.1.1/dns-query
proxies:
{mieru_yaml_block}
proxy-groups:
  - name: "PROXIES"
    type: select
    proxies:
      - "{mieru_node_name}"
  - name: "AUTO"
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    proxies:
      - "{mieru_node_name}"
rules:
  - GEOIP,private,DIRECT
  - MATCH,PROXIES
"""
    elif "type: mieru" not in raw_clash_tpl:
        lines = raw_clash_tpl.splitlines()
        new_lines = []
        proxies_injected = False
        has_proxies = any(l.strip().startswith("proxies:") for l in lines)
        if not has_proxies:
            new_lines.append("proxies:")
            new_lines.append(mieru_yaml_block)
            new_lines.extend(lines)
        else:
            for l in lines:
                new_lines.append(l)
                if not proxies_injected and l.strip().startswith("proxies:"):
                    new_lines.append(mieru_yaml_block)
                    proxies_injected = True
        
        final_lines = []
        in_tg = False
        for l in new_lines:
            final_lines.append(l)
            if re.search(r'name:\s*["\']?(PROXIES|AUTO|PROXY|Default|FALLBACK)["\']?', l, re.IGNORECASE):
                in_tg = True
            elif in_tg and l.strip().startswith("proxies:"):
                final_lines.append(f'      - "{mieru_node_name}"')
                in_tg = False
            elif in_tg and l.strip() and not l.startswith(" ") and not l.startswith("\t"):
                in_tg = False
        new_clash_tpl = "\n".join(final_lines) + "\n"
    else:
        new_clash_tpl = raw_clash_tpl

    if new_clash_tpl != raw_clash_tpl:
        if not dry_run:
            cur.execute("SELECT id FROM settings WHERE key = 'subClashTemplate'")
            if cur.fetchone():
                cur.execute("UPDATE settings SET value = ? WHERE key = 'subClashTemplate'", (new_clash_tpl,))
            else:
                cur.execute("INSERT INTO settings (key, value) VALUES ('subClashTemplate', ?)", (new_clash_tpl,))
        print(f"  [ИСПРАВЛЕНО] Узел Mieru ({mieru_port}) интегрирован в шаблон подписки subClashTemplate.")

# ----------------- 1.1. Тюнинг безопасности и шаблона ядра Xray (xrayTemplateConfig) -----------------
print("\n[+] Синхронизация шаблона конфигурации Xray (DNS, безопасность и защита от абуз)...")

enable_warp = os.environ.get("ENABLE_WARP", "n").lower() in ("1", "y", "true")
warp_license_key = os.environ.get("WARP_LICENSE_KEY", "").strip()

DEFAULT_XRAY_TEMPLATE = {
    "api": {
        "services": ["HandlerService", "LoggerService", "StatsService", "RoutingService"],
        "tag": "api"
    },
    "inbounds": [{
        "listen": "127.0.0.1", "port": 62789, "protocol": "tunnel",
        "settings": {"rewriteAddress": "127.0.0.1"}, "tag": "api"
    }],
    "log": {"access": "none", "dnsLog": False, "error": "", "loglevel": "warning", "maskAddress": ""},
    "metrics": {"listen": "127.0.0.1:11111", "tag": "metrics_out"},
    "outbounds": [
        {"protocol": "freedom", "settings": {"domainStrategy": "AsIs"}, "tag": "direct"},
        {"protocol": "blackhole", "settings": {}, "tag": "blocked"}
    ],
    "policy": {
        "levels": {"0": {"statsUserDownlink": True, "statsUserUplink": True}},
        "system": {"statsInboundDownlink": True, "statsInboundUplink": True, "statsOutboundDownlink": False, "statsOutboundUplink": False}
    },
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
            {"inboundTag": ["api"], "outboundTag": "api", "type": "field"},
            {"ip": ["geoip:private"], "outboundTag": "blocked", "type": "field"}
        ]
    },
    "stats": {}
}

# Чтение и инициализация шаблона Xray
raw_tpl = existing_settings.get("xrayTemplateConfig")
tpl = None
if raw_tpl:
    try:
        tpl = json.loads(raw_tpl)
    except Exception:
        pass
if not tpl or not isinstance(tpl, dict):
    tpl = json.loads(json.dumps(DEFAULT_XRAY_TEMPLATE))

# 1. DNS: UseIPv4 стратегия для предотвращения задержек AAAA
dns_cfg = tpl.get("dns", {})
if not isinstance(dns_cfg, dict):
    dns_cfg = {}
if dns_cfg.get("queryStrategy") != "UseIPv4":
    dns_cfg["queryStrategy"] = "UseIPv4"
    print("  [ОБНОВЛЕН] DNS queryStrategy: зафиксирован 'UseIPv4' (устранение задержек IPv6).")
else:
    print("  [В ПОРЯДКЕ] DNS queryStrategy: 'UseIPv4'.")

enable_agh = os.environ.get("ENABLE_AGH", "").lower() in ("1", "y", "true")
agh_xray_dns = os.environ.get("AGH_XRAY_DNS", "").lower() in ("1", "y", "true")
if enable_agh and agh_xray_dns:
    if dns_cfg.get("servers") != ["127.0.0.1"]:
        dns_cfg["servers"] = ["127.0.0.1"]
        print("  [ОБНОВЛЕН] DNS servers: зафиксирован '127.0.0.1' (AdGuard Home локальный фильтр).")
    else:
        print("  [В ПОРЯДКЕ] DNS servers: '127.0.0.1' (AdGuard Home).")
tpl["dns"] = dns_cfg

# 2. Логирование (тихий безопасный режим, без записи посещаемых URL)
log_cfg = tpl.get("log", {})
if not isinstance(log_cfg, dict):
    log_cfg = {}
log_cfg["loglevel"] = log_cfg.get("loglevel") or "warning"
log_cfg["dnsLog"] = False
if "access" not in log_cfg:
    log_cfg["access"] = "none"
tpl["log"] = log_cfg

# 3. Гарантируем наличие blackhole outbound 'blocked'
outbounds = tpl.get("outbounds", [])
if not isinstance(outbounds, list):
    outbounds = []
has_blocked_ob = any(isinstance(ob, dict) and ob.get("tag") == "blocked" for ob in outbounds)
if not has_blocked_ob:
    outbounds.append({"protocol": "blackhole", "settings": {}, "tag": "blocked"})
    print("  [СОЗДАНО] Outbound 'blocked' (blackhole) добавлен в шаблон.")
tpl["outbounds"] = outbounds

# 4. Правила маршрутизации: Блокировка SMTP (порт 25) и приватных сетей (SSRF)
routing = tpl.get("routing", {})
if not isinstance(routing, dict):
    routing = {}
rules = routing.get("rules", [])
if not isinstance(rules, list):
    rules = []

# А. Блокировка спама (строго порт 25, не затрагивая клиентские 465/587)
if block_smtp:
    has_smtp_block = any(
        isinstance(r, dict) and r.get("outboundTag") == "blocked" and "25" in str(r.get("port", "")).split(",")
        for r in rules
    )
    if not has_smtp_block:
        rules.insert(0, {
            "type": "field",
            "port": "25",
            "outboundTag": "blocked"
        })
        print("  [СОЗДАНО] Защита от спама: исходящий порт 25 заблокирован (outboundTag: blocked).")
    else:
        print("  [В ПОРЯДКЕ] Защита от спама: порт 25 уже заблокирован.")

# Б. Блокировка доступа к приватным IP и хосту (SSRF защита)
if block_lan:
    lan_ips = ["geoip:private", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "fc00::/7", "fe80::/10"]
    has_lan_block = any(
        isinstance(r, dict) and r.get("outboundTag") == "blocked" and any(ip_elem in str(r.get("ip", [])) for ip_elem in ["geoip:private", "127.0.0.0/8", "10.0.0.0/8"])
        for r in rules
    )
    if not has_lan_block:
        rules.insert(0, {
            "type": "field",
            "ip": lan_ips,
            "outboundTag": "blocked"
        })
        print("  [СОЗДАНО] SSRF-защита: доступ к приватным IP хоста заблокирован (outboundTag: blocked).")
    else:
        print("  [В ПОРЯДКЕ] SSRF-защита: локальные сети уже изолированы.")

routing["rules"] = rules
tpl["routing"] = routing

# 5. Опциональная интеграция Cloudflare WARP и выборочной маршрутизации
if enable_warp:
    print("\n[+] Интеграция Cloudflare WARP (Outbound WireGuard, MTU: 1280 & Smart Routing)...")
    warp_data = {}
    if existing_settings.get("warpData"):
        try:
            warp_data = json.loads(existing_settings["warpData"])
        except Exception:
            warp_data = {}

    priv_b64 = warp_data.get("private_key")
    device_id = warp_data.get("device_id")
    client_id = warp_data.get("client_id", "")
    token = warp_data.get("access_token", "")
    endpoint_host = "162.159.192.1:2408"
    v4_address = "172.16.0.2/32"
    v6_address = "2606:4700:110:8780:4178:f4a4:a997:2167/128"
    peer_pub = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

    if priv_b64 and device_id:
        print(f"  [СОХРАНЕНО] Действующий аккаунт WARP (Device ID: {device_id})")
    elif dry_run:
        print("  [DRY-RUN] Регистрация WARP пропущена (холостой прогон)")
        priv_b64, pub_b64 = "dryrun-privkey", "dryrun-pubkey"
        device_id, token, client_id = "dryrun-device", "dryrun-token", ""
    else:
        # Регистрация нового аккаунта через официальный API Cloudflare
        priv_b64, pub_b64 = generate_wg_keypair()
        reg_payload = {
            "key": pub_b64,
            "tos": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
            "type": "PC",
            "model": "x-ui",
            "name": "x-ui"
        }
        reg_req = urllib.request.Request(
            "https://api.cloudflareclient.com/v0a4005/reg",
            data=json.dumps(reg_payload).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "CF-Client-Version": "a-6.30-3596",
                "User-Agent": "okhttp/3.12.1"
            },
            method="POST"
        )
        try:
            with urllib.request.urlopen(reg_req, timeout=12) as reg_resp:
                reg_res = json.loads(reg_resp.read().decode("utf-8"))
            device_id = reg_res.get("id", "")
            token = reg_res.get("token", "")
            cfg = reg_res.get("config", {})
            client_id = cfg.get("client_id", "")
            peers = cfg.get("peers", [])
            if peers:
                peer_pub = peers[0].get("public_key", peer_pub)
                peer_ep_data = peers[0].get("endpoint", {})
                if isinstance(peer_ep_data, dict) and peer_ep_data.get("host"):
                    endpoint_host = peer_ep_data["host"]
            addrs = cfg.get("interface", {}).get("addresses", {})
            if addrs.get("v4"):
                v4_address = f"{addrs['v4']}/32"
            if addrs.get("v6"):
                v6_address = f"{addrs['v6']}/128"

            # Опциональная привязка лицензии WARP+
            if warp_license_key and device_id and token:
                try:
                    lic_req = urllib.request.Request(
                        f"https://api.cloudflareclient.com/v0a4005/reg/{device_id}/account",
                        data=json.dumps({"license": warp_license_key}).encode("utf-8"),
                        headers={
                            "Content-Type": "application/json",
                            "Authorization": f"Bearer {token}",
                            "User-Agent": "okhttp/3.12.1"
                        },
                        method="PUT"
                    )
                    with urllib.request.urlopen(lic_req, timeout=10) as lic_resp:
                        pass
                    print("  [АКТИВИРОВАНО] Лицензия WARP+ успешно привязана к аккаунту.")
                except Exception as e_lic:
                    print(f"  [!] Не удалось привязать ключ WARP+: {e_lic}")

            warp_data = {
                "access_token": token,
                "device_id": device_id,
                "license_key": warp_license_key,
                "private_key": priv_b64,
                "client_id": client_id
            }
            if not dry_run:
                for wk, wv in [("warpData", json.dumps(warp_data)), ("warpUpdateInterval", "0"), ("warpLastUpdate", str(int(time.time())))]:
                    cur.execute("SELECT id FROM settings WHERE key = ?", (wk,))
                    if cur.fetchone():
                        cur.execute("UPDATE settings SET value = ? WHERE key = ?", (wv, wk))
                    else:
                        cur.execute("INSERT INTO settings (key, value) VALUES (?, ?)", (wk, wv))
            print(f"  [СОЗДАНО] Cloudflare WARP аккаунт зарегистрирован (Device ID: {device_id})")
        except Exception as e_reg:
            print(f"  [!] Предупреждение: Cloudflare API недоступен ({e_reg}).")
            print("      Шаблон Xray сконфигурирован с MTU 1280. Регистрацию можно завершить в 1 клик в панели 3X-UI.")
            warp_data = {"private_key": priv_b64, "client_id": ""}

    # Декодирование reserved bytes
    reserved = [0, 0, 0]
    if client_id:
        try:
            dec = list(base64.b64decode(client_id))
            if len(dec) >= 3:
                reserved = dec[:3]
        except Exception:
            pass

    # Формирование объекта outbound 'warp'
    warp_outbound = {
        "tag": "warp",
        "protocol": "wireguard",
        "settings": {
            "secretKey": priv_b64,
            "address": [v4_address, v6_address] if v6_address else [v4_address],
            "peers": [
                {
                    "publicKey": peer_pub,
                    "endpoint": endpoint_host
                }
            ],
            "reserved": reserved,
            "mtu": 1280
        }
    }

    # Согласование outbounds WARP
    outbounds = tpl.get("outbounds", [])
    warp_ob_idx = -1
    for i, ob in enumerate(outbounds):
        if isinstance(ob, dict) and ob.get("tag") == "warp":
            warp_ob_idx = i
            break

    if warp_ob_idx >= 0:
        existing_ob = outbounds[warp_ob_idx]
        ob_settings = existing_ob.get("settings", {})
        ob_settings["mtu"] = 1280
        if not ob_settings.get("secretKey") and priv_b64:
            ob_settings["secretKey"] = priv_b64
        if not ob_settings.get("reserved") and reserved != [0, 0, 0]:
            ob_settings["reserved"] = reserved
        outbounds[warp_ob_idx] = existing_ob
        print("  [ОБНОВЛЕН] Outbound 'warp': зафиксирован MTU 1280 и проверены ключи WireGuard.")
    else:
        outbounds.append(warp_outbound)
        print("  [СОЗДАНО] Outbound 'warp' (WireGuard, MTU: 1280) добавлен в шаблон Xray.")
    tpl["outbounds"] = outbounds

    # Маршрутизация WARP
    routing = tpl.get("routing", {})
    rules = routing.get("rules", [])

    bad_geosites = {
        "geosite:ru", "geosite:yandex", "geosite:vk", "geosite:youtube",
        "geosite:openai", "geosite:google-gemini", "geosite:anthropic", "geosite:cloudflare"
    }

    # Очистка всех существующих правил от отсутствующих/невалидных geosite меток
    for r in rules:
        if isinstance(r, dict) and "domain" in r and isinstance(r["domain"], list):
            r["domain"] = [d for d in r["domain"] if d not in bad_geosites]

    yt_domains = [
        "domain:youtube.com",
        "domain:googlevideo.com",
        "domain:ytimg.com",
        "domain:youtu.be",
        "domain:youtubei.googleapis.com",
        "domain:yt.be"
    ]
    ru_domains = [
        "domain:ru",
        "domain:su",
        "domain:рф",
        "domain:xn--p1ai",
        "domain:yandex.ru",
        "domain:yandex.net",
        "domain:ya.ru",
        "domain:vk.com",
        "domain:vk.ru",
        "domain:vkvideo.ru",
        "domain:gosuslugi.ru",
        "domain:sberbank.ru",
        "domain:tbank.ru",
        "domain:tinkoff.ru",
        "domain:dzen.ru",
        "domain:mail.ru",
        "domain:rutube.ru",
        "domain:ozon.ru",
        "domain:wildberries.ru",
        "domain:avito.ru"
    ]
    warp_domains = [
        "domain:openai.com",
        "domain:chatgpt.com",
        "domain:oaistatic.com",
        "domain:oaiusercontent.com",
        "domain:anthropic.com",
        "domain:claude.ai",
        "domain:gemini.google.com",
        "domain:aistudio.google.com",
        "domain:deepmind.google",
        "domain:makersuite.google.com",
        "domain:generativelanguage.googleapis.com",
        "domain:ai.google.dev",
        "domain:google.com",
        "domain:cloudflare.com",
        "domain:challenges.cloudflare.com"
    ]

    # 1. Из правил WARP исключаем любые YouTube домены
    for r in rules:
        if isinstance(r, dict) and r.get("outboundTag") == "warp":
            if "domain" in r and isinstance(r["domain"], list):
                r["domain"] = [d for d in r["domain"] if not any(y in str(d).lower() for y in ["youtube", "googlevideo", "ytimg", "youtu.be"])]

    # 2. Обработка и нормализация существующих правил
    yt_rule = None
    ru_domain_rule = None
    ru_ip_rule = None

    cleaned_existing_rules = []
    for r in rules:
        if not isinstance(r, dict):
            continue
        tag = r.get("outboundTag")
        # Direct-правило для YouTube
        if tag == "direct" and any("youtube" in str(d).lower() or "googlevideo" in str(d).lower() for d in r.get("domain", [])):
            cur_domains = set(r.get("domain", [])) - bad_geosites
            cur_domains.update(yt_domains)
            r["domain"] = list(cur_domains)
            yt_rule = r
            continue
        # Direct-правило для RU: разделяем domain и ip с сохранением пользовательских ограничений
        if tag == "direct" and ("geoip:ru" in r.get("ip", []) or any("domain:ru" in str(d).lower() for d in r.get("domain", []))):
            cur_d = [d for d in r.get("domain", []) if d not in bad_geosites]
            cur_ip = list(r.get("ip", []))
            has_custom_constraints = bool(
                r.get("user") or r.get("inboundTag") or r.get("network") or r.get("port") or r.get("protocol") or
                any(ip != "geoip:ru" for ip in cur_ip)
            )
            if has_custom_constraints:
                # Пользовательское правило с ограничениями или кастомными сетями:
                # сохраняем все ограничения и исходные IP, аккуратно разделяя domain и ip
                if cur_d and cur_ip:
                    r_d = dict(r)
                    r_d["domain"] = cur_d
                    r_d.pop("ip", None)
                    cleaned_existing_rules.append(r_d)

                    r_ip = dict(r)
                    r_ip["ip"] = cur_ip
                    r_ip.pop("domain", None)
                    cleaned_existing_rules.append(r_ip)
                else:
                    cleaned_existing_rules.append(r)
                continue

            # Системное общее правило RU без ограничений:
            if cur_d:
                cur_d_set = set(cur_d)
                cur_d_set.update(ru_domains)
                ru_domain_rule = {
                    "type": "field",
                    "outboundTag": "direct",
                    "domain": list(cur_d_set)
                }
            if cur_ip:
                cur_ip_set = set(cur_ip)
                cur_ip_set.add("geoip:ru")
                ru_ip_rule = {
                    "type": "field",
                    "outboundTag": "direct",
                    "ip": list(cur_ip_set)
                }
            else:
                ru_ip_rule = {
                    "type": "field",
                    "outboundTag": "direct",
                    "ip": ["geoip:ru"]
                }
            continue
        cleaned_existing_rules.append(r)

    new_rules = []
    # 1. Системные правила (api, blocked)
    for r in cleaned_existing_rules:
        if r.get("outboundTag") in ("api", "blocked"):
            new_rules.append(r)

    # 2. YouTube -> Direct (СТРОГО ВЫШЕ WARP)
    if not yt_rule:
        yt_rule = {
            "type": "field",
            "outboundTag": "direct",
            "domain": yt_domains
        }
        print("  [СОЗДАНО] Маршрут YouTube -> DIRECT (без задержек и буферизации).")
    new_rules.append(yt_rule)

    # 3. RU -> Direct (раздельные независимые правила)
    if not ru_domain_rule:
        ru_domain_rule = {
            "type": "field",
            "outboundTag": "direct",
            "domain": ru_domains
        }
    new_rules.append(ru_domain_rule)

    if not ru_ip_rule:
        ru_ip_rule = {
            "type": "field",
            "outboundTag": "direct",
            "ip": ["geoip:ru"]
        }
    new_rules.append(ru_ip_rule)
    print("  [СОЗДАНО/ОБНОВЛЕНО] Маршруты RU-доменов и RU-IP -> DIRECT (раздельные независимые правила).")

    # 4. WARP правило (после direct правил YouTube и RU)
    warp_rule = None
    for r in cleaned_existing_rules:
        if r.get("outboundTag") == "warp":
            cur_d = set(r.get("domain", [])) - bad_geosites
            cur_d.update(warp_domains)
            cur_d = {d for d in cur_d if not any(y in str(d).lower() for y in ["youtube", "googlevideo", "ytimg", "youtu.be"])}
            r["domain"] = list(cur_d)
            warp_rule = r
            break

    if not warp_rule:
        warp_rule = {
            "type": "field",
            "outboundTag": "warp",
            "domain": [d for d in warp_domains if not any(y in str(d).lower() for y in ["youtube", "googlevideo", "ytimg", "youtu.be"])]
        }
        print("  [СОЗДАНО] Маршрут Google, Gemini, OpenAI, Claude -> WARP (обход капч и AI).")
    new_rules.append(warp_rule)

    # 5. Остальные пользовательские правила
    for r in cleaned_existing_rules:
        if r not in new_rules and r.get("outboundTag") != "warp":
            new_rules.append(r)

    routing["rules"] = new_rules
    tpl["routing"] = routing
else:
    print("\n[-] Исходящий туннель Cloudflare WARP отключен в конфигурации.")

# Очистка всех потенциально опасных / отсутствующих geosite из всех маршрутов шаблона
bad_geosites = {
    "geosite:ru", "geosite:yandex", "geosite:vk", "geosite:youtube",
    "geosite:openai", "geosite:google-gemini", "geosite:anthropic", "geosite:cloudflare"
}
routing = tpl.get("routing", {})
if isinstance(routing, dict):
    clean_rules = []
    for r in routing.get("rules", []):
        if isinstance(r, dict):
            if "domain" in r and isinstance(r["domain"], list):
                r["domain"] = [d for d in r["domain"] if d not in bad_geosites]
                if not r["domain"] and not r.get("ip") and not r.get("port"):
                    continue
            clean_rules.append(r)
    routing["rules"] = clean_rules
    tpl["routing"] = routing

# Сохранение обновленного шаблона xrayTemplateConfig
new_xray_json = json.dumps(tpl, indent=2, ensure_ascii=False)
if not dry_run:
    cur.execute("SELECT id FROM settings WHERE key = 'xrayTemplateConfig'")
    if cur.fetchone():
        cur.execute("UPDATE settings SET value = ? WHERE key = 'xrayTemplateConfig'", (new_xray_json,))
    else:
        cur.execute("INSERT INTO settings (key, value) VALUES ('xrayTemplateConfig', ?)", (new_xray_json,))
print("  [ИСПРАВЛЕНО] Конфигурация xrayTemplateConfig синхронизирована и сохранена в базе данных.")

# ----------------- 2. Интеллектуальное согласование инбаундов (Smart Reconcile) -----------------
print("\n[+] Аудит и согласование инбаундов (Smart Reconcile Engine)...")

# --- Единый клиент для всех протоколов и инбаундов (консолидация реестра) ---
client_email_env = os.environ.get("CLIENT_EMAIL", "").strip() or os.environ.get("CLIENT_NAME", "").strip()
safe_prefix_clean = re.sub(r'[^a-zA-Z0-9_-]', '', server_prefix) if server_prefix else ""
unified_email = client_email_env or (f"Client-{safe_prefix_clean}" if safe_prefix_clean and safe_prefix_clean.lower() != "server" else "Client")

# Регулярное выражение для поиска устаревших раздельных клиентов (Client-Steal, Client-Classic и т.п.)
obsolete_pattern = re.compile(r'-(steal|classic|xhttp|hy2|hysteria|hysteria2|awg-v3|awg-v2)$', re.IGNORECASE)

# Сканирование и сбор существующих реквизитов (UUID, subId, пароли, ключи) для бесшовного обновления
harvested_uuid = None
harvested_sub_id = None
harvested_hy2_pass = None
harvested_wg_c_priv = None
harvested_wg_c_pub = None
harvested_wg_hpk = None
harvested_ss_server_pass = None
harvested_ss_client_pass = None
harvested_tuic_uuid = None
harvested_tuic_pass = None
harvested_mtp_secret = None
harvested_mtp_adtag = None
harvested_vless_dekey = None
harvested_vless_enkey = None

if "clients" in all_tables and "email" in clients_cols:
    cand_cols = ["uuid", "sub_id", "password", "wg_private_key", "wg_public_key", "secret", "ad_tag", "encryption"]
    avail_cols = [c for c in cand_cols if c in clients_cols]
    if avail_cols:
        col_list = ", ".join(avail_cols)
        cur.execute(f"SELECT {col_list} FROM clients WHERE email = ?", (unified_email,))
        row_c = cur.fetchone()
        if row_c:
            c_map = dict(zip(avail_cols, row_c))
            if c_map.get("uuid"): harvested_uuid = c_map["uuid"]
            if c_map.get("sub_id"): harvested_sub_id = c_map["sub_id"]
            if c_map.get("password"): harvested_hy2_pass = c_map["password"]
            if c_map.get("wg_private_key"): harvested_wg_c_priv = c_map["wg_private_key"]
            if c_map.get("wg_public_key"): harvested_wg_c_pub = c_map["wg_public_key"]
            if c_map.get("secret"): harvested_mtp_secret = c_map["secret"]
            if c_map.get("ad_tag"): harvested_mtp_adtag = c_map["ad_tag"]
            if c_map.get("encryption"): harvested_vless_enkey = c_map["encryption"]

harvested_reality_priv = None
harvested_reality_pub = None
harvested_reality_sids = None

cur.execute("SELECT port, protocol, settings, stream_settings FROM inbounds")
for p, proto, raw_s, raw_st in cur.fetchall():
    try:
        s_obj = json.loads(raw_s) if raw_s else {}
    except Exception:
        continue
    c_list = s_obj.get("clients", [])
    if c_list and isinstance(c_list, list) and len(c_list) > 0:
        for c_cand in c_list:
            c_cand_email = c_cand.get("email") or c_cand.get("Email")
            if c_cand_email == unified_email:
                if proto == "vless":
                    if not harvested_uuid and c_cand.get("id"): harvested_uuid = c_cand.get("id")
                    if not harvested_sub_id and c_cand.get("subId"): harvested_sub_id = c_cand.get("subId")
                elif proto == "hysteria":
                    if not harvested_hy2_pass and (c_cand.get("id") or c_cand.get("password") or c_cand.get("auth")):
                        harvested_hy2_pass = c_cand.get("id") or c_cand.get("password") or c_cand.get("auth")
                elif proto == "shadowsocks":
                    if not harvested_ss_client_pass and c_cand.get("password"):
                        harvested_ss_client_pass = c_cand.get("password")
                elif proto == "tuic":
                    if not harvested_tuic_uuid and c_cand.get("uuid"):
                        harvested_tuic_uuid = c_cand.get("uuid")
                    elif not harvested_tuic_uuid and c_cand.get("id"):
                        harvested_tuic_uuid = c_cand.get("id")
                    if not harvested_tuic_pass and c_cand.get("password"):
                        harvested_tuic_pass = c_cand.get("password")
                elif proto == "mtproto":
                    if not harvested_mtp_secret and c_cand.get("secret"):
                        harvested_mtp_secret = c_cand.get("secret")
                    if not harvested_mtp_adtag and (c_cand.get("ad_tag") or c_cand.get("adTag")):
                        harvested_mtp_adtag = c_cand.get("ad_tag") or c_cand.get("adTag")
                elif proto == "amneziawg":
                    if not harvested_wg_c_priv and c_cand.get("privateKey"):
                        harvested_wg_c_priv = c_cand.get("privateKey")
                        harvested_wg_c_pub = c_cand.get("publicKey")
                    srv_conf = s_obj.get("server", {})
                    if srv_conf.get("headerProtectionKey") and not harvested_wg_hpk:
                        harvested_wg_hpk = srv_conf["headerProtectionKey"]
    if proto == "vless":
        if s_obj.get("decryption") and s_obj["decryption"] != "none":
            if not harvested_vless_dekey: harvested_vless_dekey = s_obj["decryption"]
            if not harvested_vless_enkey and s_obj.get("encryption"):
                harvested_vless_enkey = s_obj["encryption"]
        if not harvested_vless_enkey and c_list:
            for _c in c_list:
                if _c.get("encryption"):
                    harvested_vless_enkey = _c["encryption"]
                    break
    if proto == "shadowsocks":
        if not harvested_ss_server_pass and s_obj.get("password"):
            harvested_ss_server_pass = s_obj.get("password")
    if raw_st and not harvested_reality_priv:
        try:
            st_obj = json.loads(raw_st)
            r_set = st_obj.get("realitySettings", {})
            if r_set.get("privateKey"):
                harvested_reality_priv = r_set.get("privateKey")
                harvested_reality_pub = r_set.get("settings", {}).get("publicKey") or r_set.get("publicKey") or curve25519_reality_pubkey(harvested_reality_priv)
                if r_set.get("shortIds"):
                    harvested_reality_sids = r_set.get("shortIds")
        except Exception:
            pass

# Итоговые эталонные согласованные реквизиты единого клиента
unified_uuid = harvested_uuid or str(uuid.uuid4())
unified_sub_id = harvested_sub_id or secrets.token_hex(8)
unified_hy2_pass = harvested_hy2_pass or secrets.token_hex(12)

# Реквизиты Shadowsocks 2022
ss_method = "2022-blake3-aes-256-gcm"
if harvested_ss_server_pass and validate_ss2022_key(harvested_ss_server_pass, ss_method):
    unified_ss_server_pass = harvested_ss_server_pass
else:
    unified_ss_server_pass = generate_ss2022_key(ss_method)

if harvested_ss_client_pass and validate_ss2022_key(harvested_ss_client_pass, ss_method):
    unified_ss_client_pass = harvested_ss_client_pass
else:
    unified_ss_client_pass = generate_ss2022_key(ss_method)

# Реквизиты TUIC v5
unified_tuic_uuid = harvested_tuic_uuid or unified_uuid
# ВАЖНО: Пароль TUIC v5 должен строго совпадать с clients.password (unified_ss_client_pass),
# чтобы прямая ссылка tuic:// и экспорт подписки Clash/Mihomo содержали один и тот же пароль
unified_tuic_pass = unified_ss_client_pass
tuic_cert, tuic_key = resolve_cert_key_paths(domain, os.environ.get("TUIC_CERT_PATH", ""), os.environ.get("TUIC_KEY_PATH", ""))

# Реквизиты Telegram MTProxy
if harvested_mtp_secret and validate_mtproto_secret(harvested_mtp_secret):
    unified_mtp_secret = harvested_mtp_secret
else:
    unified_mtp_secret = generate_mtproto_secret(mtproto_faketls_domain)

unified_mtp_adtag = mtproto_adtag or harvested_mtp_adtag or ""
if unified_mtp_adtag and not validate_mtproto_adtag(unified_mtp_adtag):
    unified_mtp_adtag = ""

if harvested_reality_priv:
    def_reality_priv = harvested_reality_priv
    def_reality_pub = harvested_reality_pub or curve25519_reality_pubkey(def_reality_priv)
    def_reality_sids = harvested_reality_sids or ([unified_sub_id] + [secrets.token_hex(n) for n in (1, 2, 3, 6)])
    print(f"  [СОХРАНЕНО] Серверные ключи VLESS-REALITY сохранены из базы SQLite")
else:
    def_reality_priv, def_reality_pub = generate_reality_keypair()
    def_reality_sid = unified_sub_id
    def_reality_sids = [def_reality_sid] + [secrets.token_hex(n) for n in (1, 2, 3, 6)]

def_wg_s_priv, def_wg_s_pub = generate_wg_keypair()
if harvested_wg_c_priv and harvested_wg_c_pub:
    def_wg_c_priv, def_wg_c_pub = harvested_wg_c_priv, harvested_wg_c_pub
else:
    def_wg_c_priv, def_wg_c_pub = generate_wg_keypair()

# AWG v3.1: Защита заголовков Handshake (HeaderProtectionKey) и RandomTrailers
unified_awg_hpk = awg_hpk_env or harvested_wg_hpk or base64.b64encode(secrets.token_bytes(32)).decode()
unified_awg_random_trailers = awg_random_trailers_env

# Защита от потери данных: деструктивное удаление клиентов (DELETE FROM clients) заблокировано
obsolete_emails = []
print(f"  [ЕДИНЫЙ КЛИЕНТ] Профиль: '{unified_email}' (привязка ко всем инбаундам, subId: {unified_sub_id[:6]}...)")

# @include "xray/inbounds.py"


# --- Применение эталонных конфигураций инбаундов с единым клиентом ---

# 1. Steal-Oneself REALITY (45443)
if enable_steal:
    s_set = {"clients": [{"id": unified_uuid, "flow": "xtls-rprx-vision", "email": unified_email, "subId": unified_sub_id, "enable": True}], "decryption": "none", "testseed": [900, 500, 900, 256]}
    s_str = {
        "network": "tcp",
        "tcpSettings": {"acceptProxyProtocol": True, "header": {"type": "none"}},
        "security": "reality",
        "realitySettings": {
            "show": False, "xver": 1, "dest": f"127.0.0.1:{reality_fallback_port}", "target": f"127.0.0.1:{reality_fallback_port}",
            "serverNames": [steal_dom], "privateKey": def_reality_priv, "minClientVer": "1.0.0",
            "shortIds": def_reality_sids,
            "settings": {"publicKey": def_reality_pub, "fingerprint": "firefox", "serverName": steal_dom, "spiderX": "/"}
        },
        "externalProxy": [{"dest": domain, "port": 443, "forceTls": "same", "sni": steal_dom, "fingerprint": "firefox", "remark": make_remark("VLESS Steal")}]
    }
    steal_remark = make_remark("VLESS Steal")
    steal_ib_id = smart_reconcile_inbound(steal_port, "vless", "in-steal-reality", steal_remark, s_set, s_str, listen="127.0.0.1")

# 2. Classic REALITY (46443)
if enable_classic:
    c_set = {"clients": [{"id": unified_uuid, "flow": "xtls-rprx-vision", "email": unified_email, "subId": unified_sub_id, "enable": True}], "decryption": "none", "testseed": [900, 500, 900, 256]}
    c_str = {
        "network": "tcp",
        "tcpSettings": {"acceptProxyProtocol": True, "header": {"type": "none"}},
        "security": "reality",
        "realitySettings": {
            "show": False, "xver": 0, "dest": f"{classic_sni}:443", "target": f"{classic_sni}:443",
            "serverNames": [classic_sni], "privateKey": def_reality_priv, "minClientVer": "1.0.0",
            "shortIds": def_reality_sids,
            "settings": {"publicKey": def_reality_pub, "fingerprint": "firefox", "serverName": classic_sni, "spiderX": "/"}
        },
        "externalProxy": [{"dest": domain, "port": 443, "forceTls": "same", "sni": classic_sni, "fingerprint": "firefox", "remark": make_remark("VLESS Classic")}]
    }
    classic_remark = make_remark("VLESS Classic")
    classic_ib_id = smart_reconcile_inbound(classic_port, "vless", "in-classic-reality", classic_remark, c_set, c_str, listen="127.0.0.1")

# 3. VLESS xHTTP (50443)
if harvested_vless_dekey and harvested_vless_enkey:
    vless_dekey, vless_enkey = harvested_vless_dekey, harvested_vless_enkey
else:
    vless_dekey, vless_enkey = generate_vlessenc_keypair()

xhttp_client = {"id": unified_uuid, "flow": "", "email": unified_email, "subId": unified_sub_id, "enable": True}
if vless_dekey and vless_enkey:
    xhttp_client["encryption"] = vless_enkey
    x_set = {"clients": [xhttp_client], "decryption": vless_dekey, "encryption": vless_enkey}
else:
    x_set = {"clients": [xhttp_client], "decryption": "none"}
x_str = {
    "network": "xhttp",
    "xhttpSettings": {
        "path": f"/{xhttp_path.strip('/')}/", "host": domain, "mode": "stream-one",
        "noSSEHeader": True,
        "xPaddingBytes": "100-500", "xPaddingObfsMode": False, "xPaddingKey": "",
        "xmux": {
            "maxConcurrency": "0",
            "maxConnections": "1-3",
            "cMaxReuseTimes": "300-600",
            "hKeepAlivePeriod": 600,
            "hMaxRequestTimes": "1000-2000",
            "hMaxReusableSecs": "1200-2400"
        }
    },
    "security": "none",
    "externalProxy": [{"dest": domain, "port": 443, "forceTls": "tls", "sni": domain, "fingerprint": "firefox", "alpn": "h2", "remark": make_remark("VLESS xHTTP")}]
}
xhttp_remark = make_remark("VLESS xHTTP")
xhttp_ib_id = smart_reconcile_inbound(xhttp_port, "vless", "in-xhttp-stream", xhttp_remark, x_set, x_str, listen="127.0.0.1")

unified_vless_enkey = ""
cur.execute("SELECT settings FROM inbounds WHERE id = ? OR port = ?", (xhttp_ib_id, xhttp_port))
_row_xh = cur.fetchone()
if _row_xh and _row_xh[0]:
    try:
        _s_xh = json.loads(_row_xh[0])
        unified_vless_enkey = _s_xh.get("encryption", "") or ""
        if not unified_vless_enkey and _s_xh.get("clients"):
            for _c in _s_xh["clients"]:
                if _c.get("encryption"):
                    unified_vless_enkey = _c["encryption"]
                    break
    except Exception:
        pass
if not unified_vless_enkey:
    unified_vless_enkey = vless_enkey or ""

# 4. Hysteria 2 (443)
if enable_hy2:
    h_set = {"clients": [{"id": unified_hy2_pass, "auth": unified_hy2_pass, "password": unified_hy2_pass, "email": unified_email, "subId": unified_sub_id, "enable": True}], "version": 2}
    h_str = {
        "network": "hysteria",
        "hysteriaSettings": {"version": 2, "udpIdleTimeout": 60, "masquerade": {"type": "proxy", "url": "http://127.0.0.1:80"}},
        "security": "tls",
        "tlsSettings": {
            "serverName": hy2_domain, "minVersion": "1.3", "maxVersion": "1.3",
            "certificates": [{"certificateFile": hy2_cert, "keyFile": hy2_key}], "alpn": ["h3"]
        },
        "externalProxy": [{"dest": hy2_domain, "port": hy2_port, "forceTls": "tls", "remark": make_remark("Hysteria 2")}]
    }
    hy2_remark = make_remark("Hysteria 2")
    smart_reconcile_inbound(hy2_port, "hysteria", "in-hysteria2", hy2_remark, h_set, h_str, listen="0.0.0.0")

# 5. AmneziaWG v3.1 (8443)
if enable_awg_v3:
    awg_i1_env = os.environ.get("AWG_I1", "").strip()
    if awg_i1_env.lower() == "dns":
        awg_i1_env = "<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>"
    a3_set = {
        "clients": [{
            "privateKey": def_wg_c_priv, "publicKey": def_wg_c_pub,
            "allowedIPs": ["10.8.1.2/32"], "email": unified_email, "subId": unified_sub_id, "enable": True
        }],
        "server": {
            "h1": "1", "h2": "2", "h3": "3", "h4": "4",
            "jc": 4, "jmin": 40, "jmax": 70,
            "s1": 16, "s2": 16, "s3": 16, "s4": 16,
            "mtu": 1280,
            "primaryDns": awg_primary_dns, "secondaryDns": awg_secondary_dns,
            "privateKey": def_wg_s_priv, "publicKey": def_wg_s_pub,
            "headerProtectionKey": unified_awg_hpk,
            "randomTrailers": True,
            "disableCookies": False,
            "keepaliveTimeout": "15-20",
            "rekeyAfterTime": "120-170",
            "rekeyTimeout": "3-4",
            "rejectAfterTime": "180-210",
            "maxHandshakeAttempts": "20-25",
            "subnetCidr": awg_subnet_cidr, "subnetIp": awg_subnet_ip,
            "i1": awg_i1_env
        }
    }
    a3_str = {"externalProxy": [{"dest": domain, "port": awg_v3_port, "remark": make_remark("AmneziaWG v3")}]}
    awg_v3_remark = make_remark("AmneziaWG v3")
    smart_reconcile_inbound(awg_v3_port, "amneziawg", "in-8443-udp", awg_v3_remark, a3_set, a3_str, listen="0.0.0.0")

# 6. AmneziaWG v2.0 (8444)
if enable_awg_v2:
    a2_set = {
        "clients": [{
            "privateKey": def_wg_c_priv, "publicKey": def_wg_c_pub,
            "allowedIPs": ["10.8.2.2/32"], "email": unified_email, "subId": unified_sub_id, "enable": True
        }],
        "server": {
            "h1": "149419586", "h2": "878791997", "h3": "1251051976", "h4": "1657628296",
            "jc": 2, "jmin": 20, "jmax": 50, "mtu": 1280,
            "primaryDns": awg_primary_dns, "secondaryDns": awg_secondary_dns,
            "privateKey": def_wg_s_priv, "publicKey": def_wg_s_pub,
            "s1": 16, "s2": 20, "s3": 24, "s4": 16,
            "subnetCidr": 24, "subnetIp": "10.8.2.0"
        }
    }
    a2_str = {"externalProxy": [{"dest": domain, "port": awg_v2_port, "remark": make_remark("AmneziaWG v2")}]}
    awg_v2_remark = make_remark("AmneziaWG v2")
    smart_reconcile_inbound(awg_v2_port, "amneziawg", "in-awg-v2", awg_v2_remark, a2_set, a2_str, listen="0.0.0.0")

# 7. Shadowsocks 2022 (8388)
if enable_ss2022:
    ss_set = {
        "method": ss_method,
        "password": unified_ss_server_pass,
        "network": "tcp,udp",
        "udpOverTcp": True,
        "udp_over_tcp": True,
        "clients": [{
            "email": unified_email,
            "password": unified_ss_client_pass,
            "subId": unified_sub_id,
            "enable": True
        }]
    }
    ss_ext_proxies = [{"dest": domain, "port": ss2022_port, "forceTls": "none", "remark": make_remark("Shadowsocks 2022")}]
    if enable_shadowtls:
        ss_ext_proxies.append({"dest": domain, "port": shadowtls_port, "forceTls": "tls", "remark": make_remark("ShadowTLS v4 + SS-2022")})
    ss_str = {
        "network": "tcp",
        "security": "none",
        "externalProxy": ss_ext_proxies
    }
    ss_remark = make_remark("Shadowsocks 2022")
    smart_reconcile_inbound(ss2022_port, "shadowsocks", "in-shadowsocks-2022", ss_remark, ss_set, ss_str, listen="0.0.0.0")

# 8. TUIC v5 (8448)
if enable_tuic:
    tuic_set = {
        "certificate": tuic_cert,
        "private_key": tuic_key,
        "congestion_control": "bbr",
        "alpn": ["h3", "spdy/3.1"],
        "udp_relay_mode": "native",
        "zero_rtt_handshake": False,
        "max_idle_time": 15,
        "authentication_timeout": 3,
        "max_udp_relay_packet_size": 1500,
        "sni": domain,
        "clients": [{
            "uuid": unified_tuic_uuid,
            "password": unified_tuic_pass,
            "email": unified_email,
            "subId": unified_sub_id,
            "enable": True
        }]
    }
    tuic_str = {
        "network": "quic",
        "security": "tls",
        "externalProxy": [{"dest": domain, "port": tuic_port, "forceTls": "tls", "remark": make_remark("TUIC v5")}]
    }
    tuic_remark = make_remark("TUIC v5")
    smart_reconcile_inbound(tuic_port, "tuic", "in-tuic-v5", tuic_remark, tuic_set, tuic_str, listen="0.0.0.0")

# 9. Telegram MTProxy FakeTLS (8444)
if enable_mtproto:
    mtp_set = {
        "preferIp": "prefer-ipv4",
        "domainFronting": {
            "ip": mtproto_faketls_domain,
            "port": 443,
            "proxyProtocol": False
        },
        "clients": [{
            "email": unified_email,
            "secret": unified_mtp_secret,
            "adTag": unified_mtp_adtag,
            "subId": unified_sub_id,
            "enable": True
        }]
    }
    mtp_str = {
        "network": "tcp",
        "security": "none",
        "externalProxy": [{"dest": domain, "port": mtproto_port, "forceTls": "none", "remark": make_remark("Telegram MTProxy")}]
    }
    mtp_remark = make_remark("Telegram MTProxy")
    smart_reconcile_inbound(mtproto_port, "mtproto", "in-mtproto-faketls", mtp_remark, mtp_set, mtp_str, listen="0.0.0.0")

# --- Синхронизация реестра Hosts для персональных подписок 3X-UI ---
cur.execute("""
    CREATE TABLE IF NOT EXISTS hosts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        group_id TEXT DEFAULT '',
        inbound_id INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER DEFAULT 0,
        remark TEXT DEFAULT '',
        address TEXT DEFAULT '',
        port INTEGER DEFAULT 443,
        security TEXT DEFAULT 'same',
        sni TEXT DEFAULT '',
        host_header TEXT DEFAULT '',
        path TEXT DEFAULT '',
        alpn TEXT DEFAULT '',
        fingerprint TEXT DEFAULT '',
        allow_insecure INTEGER DEFAULT 0,
        is_disabled INTEGER DEFAULT 0,
        is_hidden INTEGER DEFAULT 0,
        tags TEXT DEFAULT '',
        ech_config_list TEXT DEFAULT '',
        mux_params TEXT DEFAULT '',
        sockopt_params TEXT DEFAULT '',
        final_mask TEXT DEFAULT '',
        exclude_from_sub_types TEXT DEFAULT ''
    )
""")
cur.execute("PRAGMA table_info(hosts)")
active_host_cols = {r[1] for r in cur.fetchall()}

def sync_host_entry(ib_id, host_remark, addr, host_port, sec, host_sni="", host_path="", host_alpn="", host_fp="firefox", sort_order=0):
    if ib_id is None:
        return
    cur.execute("SELECT id, remark FROM hosts WHERE inbound_id = ?", (ib_id,))
    h_row = cur.fetchone()
    if h_row:
        h_id, existing_rem = h_row
        final_h_remark = existing_rem if (existing_rem and existing_rem.strip()) else host_remark
        if not dry_run:
            cur.execute("""
                UPDATE hosts
                SET address = ?, port = ?, security = ?, sni = ?, path = ?, alpn = ?, fingerprint = ?, sort_order = ?, remark = ?
                WHERE id = ?
            """, (addr, host_port, sec, host_sni, host_path, host_alpn, host_fp, sort_order, final_h_remark, h_id))
    else:
        gid = str(uuid.uuid4())
        col_candidates = {
            "group_id": gid, "groupId": gid,
            "inbound_id": ib_id, "inboundId": ib_id,
            "sort_order": sort_order, "sortOrder": sort_order,
            "remark": host_remark, "address": addr, "port": host_port, "security": sec,
            "sni": host_sni, "host_header": "", "hostHeader": "", "path": host_path,
            "alpn": host_alpn, "fingerprint": host_fp, "allow_insecure": 0, "allowInsecure": 0,
            "is_disabled": 0, "isDisabled": 0, "is_hidden": 0, "isHidden": 0,
            "tags": "", "ech_config_list": "", "mux_params": "", "sockopt_params": "",
            "final_mask": "", "exclude_from_sub_types": ""
        }
        insert_data = {k: v for k, v in col_candidates.items() if k in active_host_cols}
        keys = list(insert_data.keys())
        vals = [insert_data[k] for k in keys]
        placeholders = ",".join(["?"] * len(keys))
        if not dry_run:
            cur.execute(f"INSERT INTO hosts ({','.join(keys)}) VALUES ({placeholders})", vals)

def lookup_inbound_id(tag_val, port_val):
    cur.execute("SELECT id FROM inbounds WHERE tag = ? OR port = ?", (tag_val, port_val))
    r = cur.fetchone()
    return r[0] if r else None

if enable_steal:
    s_iid = steal_ib_id if ('steal_ib_id' in locals() and steal_ib_id) else lookup_inbound_id("in-steal-reality", steal_port)
    if s_iid:
        sync_host_entry(s_iid, steal_remark, domain, 443, "same", host_sni=steal_dom, host_fp="firefox", sort_order=1)

if enable_classic:
    c_iid = classic_ib_id if ('classic_ib_id' in locals() and classic_ib_id) else lookup_inbound_id("in-classic-reality", classic_port)
    if c_iid:
        sync_host_entry(c_iid, classic_remark, domain, 443, "same", host_sni=classic_sni, host_fp="firefox", sort_order=1)

x_iid = xhttp_ib_id if ('xhttp_ib_id' in locals() and xhttp_ib_id) else lookup_inbound_id("in-xhttp-stream", xhttp_port)
if x_iid:
    sync_host_entry(x_iid, xhttp_remark, domain, 443, "tls", host_sni=domain, host_path=f"/{xhttp_path.strip('/')}/", host_alpn=json.dumps(["h2"]), host_fp="firefox", sort_order=2)


# Формирование клиентских ссылок для новых протоколов
# SIP002 Base64: ss://BASE64(method:server_psk:user_psk)@host:port#name (совместим с Happ, Shadowrocket, v2rayNG)
raw_ss_userinfo = f"{ss_method}:{unified_ss_server_pass}:{unified_ss_client_pass}"
b64_ss_userinfo = base64.urlsafe_b64encode(raw_ss_userinfo.encode("utf-8")).decode("utf-8").rstrip("=")
ss2022_uri = f"ss://{b64_ss_userinfo}@{domain}:{ss2022_port}#{urllib.parse.quote(make_remark('Shadowsocks 2022'))}"
tuic_uri = f"tuic://{unified_tuic_uuid}:{unified_tuic_pass}@{domain}:{tuic_port}?congestion_control=bbr&alpn=h3&udp_relay_mode=native&sni={domain}#{urllib.parse.quote(make_remark('TUIC v5'))}"
mtproto_tg_uri = f"tg://proxy?server={domain}&port={mtproto_port}&secret={unified_mtp_secret}"
mtproto_https_uri = f"https://t.me/proxy?server={domain}&port={mtproto_port}&secret={unified_mtp_secret}"
mtproto_bot_secret = unified_mtp_secret[2:34] if len(unified_mtp_secret) >= 34 else unified_mtp_secret

# Формирование клиентских реквизитов для протоколов нового поколения (Next-Gen Protocols)
enable_masque = os.environ.get("ENABLE_MASQUE", "n").lower() in ("1", "y", "true")
masque_port = int(os.environ.get("MASQUE_PORT") or "8449")
masque_user = (os.environ.get("MASQUE_USER") or "client").strip()
masque_password = os.environ.get("MASQUE_PASSWORD", "").strip() or unified_ss_client_pass
masque_uri = f"masque://{masque_user}:{masque_password}@{domain}:{masque_port}?alpn=h3#{urllib.parse.quote(make_remark('MASQUE RFC 9484'))}"

enable_shadowtls = os.environ.get("ENABLE_SHADOWTLS", "n").lower() in ("1", "y", "true")
shadowtls_port = int(os.environ.get("SHADOWTLS_PORT") or "8543")
shadowtls_sni = (os.environ.get("SHADOWTLS_SNI") or "gateway.icloud.com").strip()
shadowtls_password = os.environ.get("SHADOWTLS_PASSWORD", "").strip()
shadowtls_uri = f"shadowtls://{shadowtls_password}@{domain}:443?sni={shadowtls_sni}&version=4#{urllib.parse.quote(make_remark('ShadowTLS v4'))}"
ss_shadowtls_uri = f"ss://{b64_ss_userinfo}@{domain}:443?plugin=shadow-tls;host={shadowtls_sni};password={shadowtls_password};version=4#{urllib.parse.quote(make_remark('ShadowTLS + SS-2022'))}"

enable_wstunnel = os.environ.get("ENABLE_WSTUNNEL", "n").lower() in ("1", "y", "true")
wstunnel_port = int(os.environ.get("WSTUNNEL_PORT") or "8080")
wstunnel_prefix = resolve_wstunnel_prefix(os.environ.get("WSTUNNEL_PREFIX"))
wstunnel_cli = f"wstunnel client -L socks5://127.0.0.1:1080 --http-upgrade-path-prefix {wstunnel_prefix} wss://{domain}:443"
wstunnel_uri = f"wstunnel://{domain}:443/{wstunnel_prefix}"

enable_zapret = os.environ.get("ENABLE_ZAPRET", "n").lower() in ("1", "y", "true")
zapret_qnum = os.environ.get("ZAPRET_QNUM", "200").strip()
zapret_desync = os.environ.get("ZAPRET_DESYNC", "split2").strip()
zapret_fooling = os.environ.get("ZAPRET_FOOLING", "md5sig,badseq").strip()
zapret_info = f"Active (NFQUEUE {zapret_qnum}, desync: {zapret_desync}, fooling: {zapret_fooling})"

enable_naive = os.environ.get("ENABLE_NAIVE", "n").lower() in ("1", "y", "true")
naive_port = int(os.environ.get("NAIVE_PORT") or "8446")
naive_domain = (os.environ.get("NAIVE_DOMAIN") or (f"naive.{domain}" if domain else "localhost")).strip()
naive_user = (os.environ.get("NAIVE_USER") or "user").strip()
naive_pass = (os.environ.get("NAIVE_PASS") or "").strip()
if not naive_pass and os.path.isfile("/etc/caddy/Caddyfile"):
    try:
        with open("/etc/caddy/Caddyfile", "r") as cf:
            for cline in cf:
                if "basic_auth" in cline:
                    cparts = cline.strip().split()
                    if len(cparts) >= 3:
                        naive_user = cparts[1]
                        naive_pass = cparts[2]
                        break
    except Exception:
        pass
if not naive_pass:
    naive_pass = unified_ss_client_pass
naive_uri = f"naive+https://{naive_user}:{naive_pass}@{naive_domain}:443#{urllib.parse.quote(make_remark('NaïveProxy'))}"

enable_dnstt = os.environ.get("ENABLE_DNSTT", "n").lower() in ("1", "y", "true")
dnstt_port = int(os.environ.get("DNSTT_PORT") or "53053")
dnstt_domain = (os.environ.get("DNSTT_DOMAIN") or (f"t.{domain}" if domain else "t.example.com")).strip()
dnstt_pubkey = os.environ.get("DNSTT_PUBKEY", "").strip()
if not dnstt_pubkey and os.path.isfile("/etc/dnstt/server.pub"):
    try:
        with open("/etc/dnstt/server.pub", "r") as pf:
            dnstt_pubkey = pf.read().strip()
    except Exception:
        pass
if not dnstt_pubkey and enable_dnstt and not dry_run:
    try:
        _P = 2**255 - 19
        def _clamp(kb):
            b = bytearray(kb)
            b[0] &= 248; b[31] &= 127; b[31] |= 64
            return int.from_bytes(b, "little")
        def _x25519(k, u=9):
            x1, x2, z2, x3, z3 = u, 1, 0, u, 1
            for i in range(254, -1, -1):
                bit = (k >> i) & 1
                if bit: x2, x3 = x3, x2; z2, z3 = z3, z2
                A = (x2 + z2) % _P; AA = (A * A) % _P; B = (x2 - z2) % _P; BB = (B * B) % _P; E = (AA - BB) % _P
                x3 = ((x2 * x3 - z2 * z3)**2) % _P; z3 = (x1 * ((x2 * z3 - z2 * x3)**2)) % _P
                x2 = (AA * BB) % _P; z2 = (E * (AA + ((121665 * E) % _P))) % _P
                if bit: x2, x3 = x3, x2; z2, z3 = z3, z2
            return (x2 * pow(z2, _P - 2, _P)) % _P
        _raw_priv = os.urandom(32)
        _k = _clamp(_raw_priv)
        dnstt_pubkey = ((_x25519(_k, 9)) % _P).to_bytes(32, "little").hex()
        os.makedirs("/etc/dnstt", exist_ok=True)
        with open("/etc/dnstt/server.key", "w") as kf:
            kf.write(_raw_priv.hex() + "\n")
        with open("/etc/dnstt/server.pub", "w") as pf:
            pf.write(dnstt_pubkey + "\n")
        os.chmod("/etc/dnstt/server.key", 0o600)
        os.chmod("/etc/dnstt/server.pub", 0o600)
    except Exception:
        pass
dnstt_cli = f"dnstt-client -doh https://dns.google/dns-query -pubkey {dnstt_pubkey} {dnstt_domain} 127.0.0.1:1080"

if enable_mieru and mieru_user and mieru_pass:
    client_m_port = int(mieru_port.split("-")[0].split(":")[0]) if "-" not in mieru_port and ":" not in mieru_port else mieru_port
    mieru_client_config = {
        "profiles": [{
            "profileName": "default",
            "user": {
                "name": mieru_user,
                "password": mieru_pass
            },
            "servers": [{
                "ipAddress": domain,
                "portBindings": [
                    {"port": client_m_port, "protocol": "TCP"} if isinstance(client_m_port, int) else {"portRange": str(client_m_port), "protocol": "TCP"}
                ]
            }],
            "handshakeMode": "HANDSHAKE_STANDARD"
        }],
        "activeProfile": "default",
        "rpcPort": 0,
        "socks5Port": 1080,
        "loggingLevel": "INFO",
        "httpProxyPort": 8080
    }
    if not dry_run:
        try:
            with open("/root/mieru-client.json", "w", encoding="utf-8") as mcf:
                json.dump(mieru_client_config, mcf, indent=2)
            os.chmod("/root/mieru-client.json", 0o600)
        except Exception:
            pass

if not dry_run:
    try:
        cur.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    except Exception:
        pass
    conn.commit()

    # Сохранение параметров единого клиента во временный файл в /run (tmpfs) с безопасными правами
    try:
        run_file = "/run/3xui_unified_client.env" if os.path.isdir("/run") else "/tmp/3xui_unified_client.env"
        old_umask = os.umask(0o077)
        with open(run_file, "w") as f:
            f.write(f"PRIMARY_DOMAIN={shlex.quote(domain)}\n")
            f.write(f"PANEL_PATH={shlex.quote(panel_path)}\n")
            f.write(f"UNIFIED_CLIENT_TAG='{unified_email}'\n")
            f.write(f"UNIFIED_SUB_ID='{unified_sub_id}'\n")
            f.write(f"UNIFIED_UUID='{unified_uuid}'\n")
            f.write(f"UNIFIED_AWG_HPK='{unified_awg_hpk}'\n")
            f.write(f"UNIFIED_AWG_PORT='{awg_v3_port}'\n")
            if unified_vless_enkey:
                f.write(f"UNIFIED_VLESS_ENKEY='{unified_vless_enkey}'\n")
            if enable_ss2022:
                f.write(f"SS2022_URI='{ss2022_uri}'\n")
                f.write(f"SS2022_PORT='{ss2022_port}'\n")
            if enable_tuic:
                f.write(f"TUIC_URI='{tuic_uri}'\n")
                f.write(f"TUIC_PORT='{tuic_port}'\n")
            if enable_mtproto:
                f.write(f"MTPROTO_TG_URI='{mtproto_tg_uri}'\n")
                f.write(f"MTPROTO_HTTPS_URI='{mtproto_https_uri}'\n")
                f.write(f"MTPROTO_SECRET='{unified_mtp_secret}'\n")
                f.write(f"MTPROTO_BOT_SECRET='{mtproto_bot_secret}'\n")
                f.write(f"MTPROTO_PORT='{mtproto_port}'\n")
            if enable_masque:
                f.write(f"MASQUE_URI='{masque_uri}'\n")
                f.write(f"MASQUE_PORT='{masque_port}'\n")
                f.write(f"MASQUE_USER='{masque_user}'\n")
                f.write(f"MASQUE_PASSWORD='{masque_password}'\n")
            if enable_shadowtls:
                f.write(f"SHADOWTLS_URI='{shadowtls_uri}'\n")
                f.write(f"SS_SHADOWTLS_URI='{ss_shadowtls_uri}'\n")
                f.write(f"SHADOWTLS_PORT='{shadowtls_port}'\n")
                f.write(f"SHADOWTLS_SNI='{shadowtls_sni}'\n")
                f.write(f"SHADOWTLS_PASSWORD='{shadowtls_password}'\n")
            if enable_wstunnel and wstunnel_prefix:
                f.write(f"WSTUNNEL_CLI='{wstunnel_cli}'\n")
                f.write(f"WSTUNNEL_URI='{wstunnel_uri}'\n")
                f.write(f"WSTUNNEL_PREFIX='{wstunnel_prefix}'\n")
                f.write(f"WSTUNNEL_PORT='{wstunnel_port}'\n")
            if enable_zapret:
                f.write(f"ZAPRET_INFO='{zapret_info}'\n")
            if enable_naive:
                f.write(f"NAIVE_URI='{naive_uri}'\n")
                f.write(f"NAIVE_PORT='{naive_port}'\n")
                f.write(f"NAIVE_USER='{naive_user}'\n")
                f.write(f"NAIVE_PASS='{naive_pass}'\n")
            if enable_dnstt:
                f.write(f"DNSTT_CLI='{dnstt_cli}'\n")
                f.write(f"DNSTT_PORT='{dnstt_port}'\n")
                f.write(f"DNSTT_DOMAIN='{dnstt_domain}'\n")
                f.write(f"DNSTT_PUBKEY='{dnstt_pubkey}'\n")
            if enable_mieru:
                f.write(f"ENABLE_MIERU='1'\n")
                f.write(f"MIERU_PORT='{mieru_port}'\n")
                f.write(f"MIERU_PORT_MODE='{mieru_port_mode}'\n")
                f.write(f"MIERU_USER='{mieru_user}'\n")
                f.write(f"MIERU_PASS='{mieru_pass}'\n")
                if 'mieru_node_name' in locals():
                    f.write(f"MIERU_NODE_NAME='{mieru_node_name}'\n")
        os.umask(old_umask)
        os.chmod(run_file, 0o600)
    except Exception:
        pass

conn.close()