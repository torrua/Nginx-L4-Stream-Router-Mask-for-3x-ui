#!/usr/bin/env bash
# ==============================================================================
# mieru-mgr.sh - Менеджер пользователей Mieru Proxy (mita daemon)
# ==============================================================================
# Управление пользователями Mieru: просмотр, добавление, удаление,
# генерация персональных конфигурационных файлов /root/mieru-client-<user>.json
# и готовых YAML-блоков для Clash / Mihomo.
# ==============================================================================

set -euo pipefail

# Цветовое оформление при автономном запуске
RED="${RED:-$'\033[0;31m'}"
GREEN="${GREEN:-$'\033[0;32m'}"
YELLOW="${YELLOW:-$'\033[1;33m'}"
CYAN="${CYAN:-$'\033[0;36m'}"
WHITE="${WHITE:-$'\033[1;37m'}"
BOLD="${BOLD:-$'\033[1m'}"
DIM="${DIM:-$'\033[2m'}"
NC="${NC:-$'\033[0m'}"

export PYTHONIOENCODING=utf-8

if ! declare -f log >/dev/null 2>&1; then
    log()  { echo -e "  ${CYAN}[+]${NC} $*"; }
    ok()   { echo -e "  ${GREEN}✔${NC} $*"; }
    warn() { echo -e "  ${YELLOW}[!]${NC} $*"; }
    die()  { echo -e "  ${RED}✖ $*${NC}" >&2; exit 1; }
fi

MIERU_SERVER_CONFIG="${MIERU_SERVER_CONFIG:-/etc/mita/config.json}"
MIERU_SERVER_COMPAT_CONFIG="/etc/mita_server_config.json"
MIERU_CLIENT_DIR="${MIERU_CLIENT_DIR:-/root}"

resolve_python_cmd() {
    local candidate
    for candidate in "${PYTHON_CMD:-}" python3 python; do
        if [ -n "$candidate" ] && "$candidate" -c "import sys, json" >/dev/null 2>&1; then
            echo "$candidate"
            return 0
        fi
    done
    echo "python3"
}

resolve_mieru_config_path() {
    if [ -f "$MIERU_SERVER_CONFIG" ]; then
        echo "$MIERU_SERVER_CONFIG"
    elif [ -f "$MIERU_SERVER_COMPAT_CONFIG" ]; then
        echo "$MIERU_SERVER_COMPAT_CONFIG"
    else
        echo ""
    fi
}

resolve_server_domain() {
    local dom="${PRIMARY_DOMAIN:-}"
    if [ -z "$dom" ] && [ -f "/etc/server-setup.env" ]; then
        dom="$(grep -E '^PRIMARY_DOMAIN=' /etc/server-setup.env 2>/dev/null | cut -d'=' -f2 | tr -d '"'\'' ' || true)"
    fi
    if [ -z "$dom" ] && [ -f "server-setup.env" ]; then
        dom="$(grep -E '^PRIMARY_DOMAIN=' server-setup.env 2>/dev/null | cut -d'=' -f2 | tr -d '"'\'' ' || true)"
    fi
    if [ -z "$dom" ] && [ -f "/root/mieru-client.json" ]; then
        local py_cmd; py_cmd="$(resolve_python_cmd)"
        dom="$("$py_cmd" -c "
import json
try:
    with open('/root/mieru-client.json', 'r') as f:
        data = json.load(f)
    print(data['profiles'][0]['servers'][0]['ipAddress'])
except Exception:
    pass
" 2>/dev/null || true)"
    fi
    if [ -z "$dom" ]; then
        dom="$(curl -s4 -m 3 https://icanhazip.com 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")"
        dom="$(echo "$dom" | tr -d '[:space:]')"
    fi
    echo "$dom"
}

mieru_list_users() {
    local cfg
    cfg="$(resolve_mieru_config_path)"
    if [ -z "$cfg" ]; then
        die "Конфигурационный файл Mieru не найден (/etc/mita/config.json). Убедитесь, что Mieru установлен."
    fi

    local svc_status="не установлена"
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet mita 2>/dev/null; then
            svc_status="${GREEN}активна (running)${NC}"
        elif systemctl list-unit-files mita.service >/dev/null 2>&1; then
            svc_status="${RED}остановлена (inactive)${NC}"
        fi
    fi

    local py_cmd; py_cmd="$(resolve_python_cmd)"
    "$py_cmd" - "$cfg" "$svc_status" << 'EOF_LIST'
import json
import os
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

cfg_path = sys.argv[1]
svc_status = sys.argv[2]

try:
    with open(cfg_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"  \033[0;31m[x] Ошибка чтения {cfg_path}: {e}\033[0m", file=sys.stderr)
    sys.exit(1)

bindings = data.get("portBindings", [])
port_desc = []
for b in bindings:
    p = b.get("portRange") or b.get("port")
    proto = b.get("protocol", "TCP")
    if p:
        port_desc.append(f"{p}/{proto}")
ports_str = ", ".join(port_desc) if port_desc else "8450/TCP,UDP (default)"

users = data.get("users", [])

print("")
print("  \033[1;37mКонфигурация Mieru Proxy (mita):\033[0m")
print("  \033[2m------------------------------------------------------------\033[0m")
print(f"  Файл конфигурации: \033[0;36m{cfg_path}\033[0m")
print(f"  Порты службы:      \033[1;37m{ports_str}\033[0m")
print(f"  Статус службы:     {svc_status}")
print("")
print(f"  \033[1;37mСписок активных пользователей (Всего: {len(users)}):\033[0m")
print("  \033[2m----------------------------------------------------------------------------------\033[0m")
print(f"  {'#':<4} {'Пользователь (Username)':<26} {'Пароль (Password)':<22} {'Клиентский файл'}")
print("  \033[2m----------------------------------------------------------------------------------\033[0m")

for idx, u in enumerate(users, start=1):
    uname = u.get("name", "unknown")
    upass = u.get("password", "")
    masked_pass = upass if len(upass) <= 12 else (upass[:4] + "..." + upass[-4:])
    
    # Check potential client file
    client_dir = os.environ.get("MIERU_CLIENT_DIR") or "/root"
    cfile = os.path.join(client_dir, f"mieru-client-{uname}.json")
    if not os.path.isfile(cfile) and idx == 1 and os.path.isfile(os.path.join(client_dir, "mieru-client.json")):
        cfile = os.path.join(client_dir, "mieru-client.json")
    
    status_cf = f"\033[0;32m{cfile}\033[0m" if os.path.isfile(cfile) else "\033[2m(нет файла)\033[0m"
    print(f"  {idx:<4} \033[1;37m{uname:<26}\033[0m {masked_pass:<22} {status_cf}")

print("  \033[2m----------------------------------------------------------------------------------\033[0m")
print("")
EOF_LIST
}

mieru_add_user() {
    local target_user="${1:-}"
    local target_pass="${2:-}"

    if [ "${EUID:-$(id -u)}" -ne 0 ] && [ "${MIERU_MGR_FORCE:-0}" -ne 1 ]; then
        die "Для добавления пользователя Mieru требуются права суперпользователя (sudo)."
    fi

    if [ -z "$target_user" ]; then
        die "Использование: mieru-mgr add <USERNAME> [PASSWORD]"
    fi

    if [[ ! "$target_user" =~ ^[a-zA-Z0-9_-]{3,32}$ ]]; then
        die "Имя пользователя '$target_user' некорректно. Разрешены только латиница, цифры, дефис и подчеркивание (3-32 символа)."
    fi

    local cfg
    cfg="$(resolve_mieru_config_path)"
    if [ -z "$cfg" ]; then
        die "Конфигурационный файл Mieru не найден (/etc/mita/config.json). Убедитесь, что Mieru установлен."
    fi

    local py_cmd; py_cmd="$(resolve_python_cmd)"

    if [ -z "$target_pass" ]; then
        target_pass="$("$py_cmd" -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(16)))" 2>/dev/null || echo "mieru$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 12 || echo "${RANDOM}${RANDOM}")")"
    fi

    local domain
    domain="$(resolve_server_domain)"

    "$py_cmd" - "$cfg" "$target_user" "$target_pass" "$domain" << 'EOF_ADD'
import json
import os
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

cfg_path = sys.argv[1]
username = sys.argv[2]
password = sys.argv[3]
domain = sys.argv[4]

try:
    with open(cfg_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"  \033[0;31m✖ Ошибка чтения {cfg_path}: {e}\033[0m", file=sys.stderr)
    sys.exit(1)

users = data.setdefault("users", [])
found = False
for u in users:
    if u.get("name") == username:
        u["password"] = password
        found = True
        break

if not found:
    users.append({"name": username, "password": password})

# Write to both possible locations
for p in [cfg_path, "/etc/mita/config.json", "/etc/mita_server_config.json"]:
    if p == cfg_path or os.path.isfile(p):
        try:
            with open(p, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
            os.chmod(p, 0o600)
        except Exception:
            pass

# Determine port binding and transport for client
bindings = data.get("portBindings", [])
port_val = None
server_protos = []
for b in bindings:
    if "port" in b and not port_val:
        port_val = b["port"]
    elif "portRange" in b and not port_val:
        port_val = b["portRange"]
    if "protocol" in b:
        server_protos.append(str(b["protocol"]).upper())

if not port_val:
    port_val = 8450

env_trans = (os.environ.get("MIERU_TRANSPORT") or os.environ.get("MIERU_CONFIG_TRANSPORT") or "").strip().upper()
if env_trans in ("TCP", "UDP", "BOTH"):
    effective_trans = env_trans
elif "UDP" in server_protos and "TCP" not in server_protos:
    effective_trans = "UDP"
elif "TCP" in server_protos and "UDP" not in server_protos:
    effective_trans = "TCP"
elif "TCP" in server_protos and "UDP" in server_protos:
    effective_trans = "BOTH"
else:
    effective_trans = "TCP"

if effective_trans == "UDP":
    client_protocols = ["UDP"]
    yaml_transport = "UDP"
elif effective_trans == "TCP":
    client_protocols = ["TCP"]
    yaml_transport = "TCP"
else:
    client_protocols = ["TCP", "UDP"]
    yaml_transport = "TCP"

client_bindings = []
for proto in client_protocols:
    if isinstance(port_val, int) or ("-" not in str(port_val)):
        client_bindings.append({"port": int(str(port_val).split("-")[0].split(":")[0]), "protocol": proto})
    else:
        client_bindings.append({"portRange": str(port_val), "protocol": proto})

# Generate client json
client_config = {
    "profiles": [{
        "profileName": "default",
        "user": {
            "name": username,
            "password": password
        },
        "servers": [{
            "ipAddress": domain,
            "portBindings": client_bindings
        }],
        "handshakeMode": "HANDSHAKE_STANDARD"
    }],
    "activeProfile": "default",
    "rpcPort": 0,
    "socks5Port": 1080,
    "loggingLevel": "INFO",
    "httpProxyPort": 8080
}

client_dir = os.environ.get("MIERU_CLIENT_DIR") or "/root"
os.makedirs(client_dir, exist_ok=True)
client_file = os.path.join(client_dir, f"mieru-client-{username}.json")
try:
    with open(client_file, "w", encoding="utf-8") as cf:
        json.dump(client_config, cf, indent=2)
    os.chmod(client_file, 0o600)
except Exception as e:
    print(f"  \033[1;33m[!] Предупреждение: не удалось сохранить {client_file}: {e}\033[0m")

# Mihomo YAML proxy
yaml_port_key = f"port: {port_val}" if isinstance(port_val, int) or ("-" not in str(port_val)) else f"port-range: {port_val}"
mihomo_yaml = f"""  - name: "Mieru - {username}"
    type: mieru
    server: {domain}
    {yaml_port_key}
    username: {username}
    password: {password}
    transport: {yaml_transport}
    multiplexing: MULTIPLEXING_LOW
    handshake-mode: HANDSHAKE_STANDARD
    udp: true"""

action_word = "обновлен" if found else "добавлен"
print(f"ACTION={action_word}")
print(f"CLIENT_FILE={client_file}")
print(f"MIHOMO_YAML<<EOF\n{mihomo_yaml}\nEOF")
EOF_ADD

    if command -v chown >/dev/null 2>&1 && id -u mita >/dev/null 2>&1; then
        chown mita:mita /etc/mita/config.json /etc/mita_server_config.json 2>/dev/null || true
    fi
    chmod 600 /etc/mita/config.json /etc/mita_server_config.json 2>/dev/null || true

    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart mita 2>/dev/null || true
    fi

    local client_file="${MIERU_CLIENT_DIR:-/root}/mieru-client-${target_user}.json"

    echo ""
    ok "Пользователь '${BOLD}${target_user}${NC}' успешно настроен в Mieru Proxy!"
    echo -e "  - ${YELLOW}Логин (Username):${NC}    ${WHITE}${target_user}${NC}"
    echo -e "  - ${YELLOW}Пароль (Password):${NC}   ${WHITE}${target_pass}${NC}"
    echo -e "  - ${YELLOW}Клиентский конфиг:${NC}   ${CYAN}${client_file}${NC} (chmod 600)"
    echo ""
    echo -e "  ${BOLD}Команда применения в официальном клиенте Mieru:${NC}"
    echo -e "  ${GREEN}mieru apply config ${client_file}${NC}"
    echo ""
    echo -e "  ${BOLD}Конфигурация для Mihomo / Clash Meta (proxies):${NC}"
    echo -e "${CYAN}  - name: \"Mieru - ${target_user}\""
    echo -e "    type: mieru"
    echo -e "    server: ${domain}"
    if [ -f "$client_file" ] && grep -q "portRange" "$client_file" 2>/dev/null; then
        local pr
        pr="$(grep "portRange" "$client_file" | head -n1 | cut -d'"' -f4)"
        echo -e "    port-range: ${pr}"
    else
        local p
        p="$(grep "port" "$client_file" 2>/dev/null | grep -oE '[0-9]+' | head -n1 || echo 8450)"
        echo -e "    port: ${p}"
    fi
    echo -e "    username: ${target_user}"
    echo -e "    password: ${target_pass}"
    local cli_trans="TCP"
    if [ -f "$client_file" ]; then
        if grep -q '"protocol": *"UDP"' "$client_file" 2>/dev/null && ! grep -q '"protocol": *"TCP"' "$client_file" 2>/dev/null; then
            cli_trans="UDP"
        fi
    fi
    echo -e "    transport: ${cli_trans}"
    echo -e "    multiplexing: MULTIPLEXING_LOW"
    echo -e "    handshake-mode: HANDSHAKE_STANDARD"
    echo -e "    udp: true${NC}"
    echo ""
}

mieru_del_user() {
    local target_user="${1:-}"

    if [ "${EUID:-$(id -u)}" -ne 0 ] && [ "${MIERU_MGR_FORCE:-0}" -ne 1 ]; then
        die "Для удаления пользователя Mieru требуются права суперпользователя (sudo)."
    fi

    if [ -z "$target_user" ]; then
        die "Использование: mieru-mgr del <USERNAME>"
    fi

    local cfg
    cfg="$(resolve_mieru_config_path)"
    if [ -z "$cfg" ]; then
        die "Конфигурационный файл Mieru не найден (/etc/mita/config.json). Убедитесь, что Mieru установлен."
    fi

    local py_cmd; py_cmd="$(resolve_python_cmd)"
    "$py_cmd" - "$cfg" "$target_user" << 'EOF_DEL'
import json
import os
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

cfg_path = sys.argv[1]
username = sys.argv[2]

try:
    with open(cfg_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"  \033[0;31m✖ Ошибка чтения {cfg_path}: {e}\033[0m", file=sys.stderr)
    sys.exit(1)

users = data.get("users", [])
user_names = [u.get("name") for u in users]

if username not in user_names:
    print(f"  \033[0;31m✖ Пользователь '{username}' не найден в конфигурации Mieru.\033[0m", file=sys.stderr)
    sys.exit(2)

if len(users) <= 1:
    print(f"  \033[0;31m✖ Нельзя удалить '{username}': это единственный пользователь Mieru.\033[0m", file=sys.stderr)
    print("    Служба mita не может работать с пустым списком пользователей.", file=sys.stderr)
    sys.exit(3)

data["users"] = [u for u in users if u.get("name") != username]

for p in [cfg_path, "/etc/mita/config.json", "/etc/mita_server_config.json"]:
    if p == cfg_path or os.path.isfile(p):
        try:
            with open(p, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
            os.chmod(p, 0o600)
        except Exception:
            pass

client_dir = os.environ.get("MIERU_CLIENT_DIR") or "/root"
client_file = os.path.join(client_dir, f"mieru-client-{username}.json")
if os.path.isfile(client_file):
    try:
        os.remove(client_file)
    except Exception:
        pass

sys.exit(0)
EOF_DEL
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        exit "$rc"
    fi

    if command -v chown >/dev/null 2>&1 && id -u mita >/dev/null 2>&1; then
        chown mita:mita /etc/mita/config.json /etc/mita_server_config.json 2>/dev/null || true
    fi
    chmod 600 /etc/mita/config.json /etc/mita_server_config.json 2>/dev/null || true

    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart mita 2>/dev/null || true
    fi

    echo ""
    ok "Пользователь '${BOLD}${target_user}${NC}' успешно удален из Mieru Proxy."
    echo ""
}

show_mieru_mgr_help() {
    cat << EOF_HELP

${BOLD}mieru-mgr${NC} - Менеджер пользователей Mieru Proxy (mita)

${BOLD}Использование:${NC}
  mieru-mgr list                       Показать список всех пользователей и статус службы
  mieru-mgr add <USERNAME> [PASSWORD]  Добавить пользователя и создать клиентский профиль .json
  mieru-mgr del <USERNAME>             Удалить пользователя из Mieru Proxy
  mieru-mgr help                       Показать эту справку

${BOLD}Примеры:${NC}
  mieru-mgr list
  mieru-mgr add alice
  mieru-mgr add bob MyStrongPass123
  mieru-mgr del bob

EOF_HELP
}

# Standalone entry point
mieru_mgr_main() {
    local cmd="${1:-list}"
    case "$cmd" in
        list|ls|show)
            mieru_list_users
            ;;
        add|create|new)
            shift || true
            mieru_add_user "${1:-}" "${2:-}"
            ;;
        del|delete|rm|remove)
            shift || true
            mieru_del_user "${1:-}"
            ;;
        help|-h|--help)
            show_mieru_mgr_help
            ;;
        *)
            warn "Неизвестная команда: $cmd"
            show_mieru_mgr_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]] && [[ "$(basename "${0:-}")" == *"mieru-"* ]]; then
    mieru_mgr_main "$@"
fi
