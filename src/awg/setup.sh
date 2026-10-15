# --- Модуль AmneziaWG: Универсальный контроллер и сервис управления (v3.1 / v2.0) ---
# На базе концепций проекта: https://github.com/bivlked/amneziawg-installer (@bivlked)

setup_amneziawg_controller() {
    local awg_dir="/root/awg"
    mkdir -p "$awg_dir/keys"
    chmod 700 "$awg_dir"

    log "Развертывание универсального контроллера AmneziaWG в $awg_dir..."

    # Копирование или запись manage_amneziawg.py
    local src_py="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/manage_amneziawg.py"
    if [ -f "$src_py" ]; then
        cp -f "$src_py" "$awg_dir/manage_amneziawg.py"
    fi

    # Если файл не существует (например, запуск через curl монолита), пишем встроенную версию
    if [ ! -f "$awg_dir/manage_amneziawg.py" ]; then
        cat << 'EOF_AWG_PY' > "$awg_dir/manage_amneziawg.py"
# @include "awg/manage_amneziawg.py"
EOF_AWG_PY
    fi
    chmod 750 "$awg_dir/manage_amneziawg.py"

    # Запись скрипта-лаунчера
    cat << 'EOF_AWG_SH' > "$awg_dir/manage_amneziawg.sh"
#!/usr/bin/env bash
set -euo pipefail
AWG_DIR="${AWG_DIR:-/root/awg}"
PYTHON_BIN="$(command -v python3 2>/dev/null || echo /usr/bin/python3)"
exec "$PYTHON_BIN" "$AWG_DIR/manage_amneziawg.py" "$@"
EOF_AWG_SH
    chmod 755 "$awg_dir/manage_amneziawg.sh"

    # Создание глобальных симлинков для удобного управления из консоли
    ln -sf "$awg_dir/manage_amneziawg.sh" /usr/local/bin/awg-mgr 2>/dev/null || true
    ln -sf "$awg_dir/manage_amneziawg.sh" /usr/local/bin/awg-cli 2>/dev/null || true

    # Настройка правил файрвола UFW
    local awg_port="${AWG_SERVER_PORT:-${AWG_STANDALONE_PORT:-}}"
    if [ -z "$awg_port" ]; then
        if [ "${AWG_V3_PORT:-}" = "8443" ] && [[ "${ENABLE_AWG_V3:-}" == "1" || "${ENABLE_AWG_V3,,}" == "y" ]]; then
            awg_port="8445"
        else
            awg_port="8443"
        fi
    fi
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${awg_port}/udp" comment "AmneziaWG Server Engine" >/dev/null 2>&1 || true
    fi

    # Настройка периодической очистки просроченных клиентов (cron)
    if [ -d /etc/cron.d ]; then
        cat << 'EOF_CRON' > /etc/cron.d/awg-purge-expired
0 * * * * root /usr/local/bin/awg-mgr purge-expired --quiet >/dev/null 2>&1
EOF_CRON
        chmod 644 /etc/cron.d/awg-purge-expired 2>/dev/null || true
    fi

    ok "Контроллер AmneziaWG готов: утилита awg-mgr доступна в системе."
}

deploy_amneziawg_backend() {
    local awg_port="${AWG_SERVER_PORT:-${AWG_STANDALONE_PORT:-}}"
    if [ -z "$awg_port" ]; then
        if [ "${AWG_V3_PORT:-}" = "8443" ] && [[ "${ENABLE_AWG_V3:-}" == "1" || "${ENABLE_AWG_V3,,}" == "y" ]]; then
            awg_port="8445"
        else
            awg_port="8443"
        fi
    fi
    local awg_dir="/root/awg"

    # 1. Проверяем, работает ли уже какой-либо бэкенд AmneziaWG
    local active_backend=0
    if command -v docker >/dev/null 2>&1; then
        for c_cand in "amnezia-awg2" "amnezia-awg" "awg-server"; do
            if docker inspect -f '{{.State.Running}}' "$c_cand" 2>/dev/null | grep -q "true"; then
                active_backend=1
                ok "Обнаружен активный контейнер AmneziaWG: $c_cand"
                break
            fi
        done
    fi

    if [ "$active_backend" -eq 0 ] && [ -f /etc/amnezia/amneziawg/awg0.conf ]; then
        active_backend=1
        ok "Обнаружена существующая конфигурация AmneziaWG (/etc/amnezia/amneziawg/awg0.conf) — сохраняем без изменений."
    fi

    # 2. Если активного бэкенда нет, подготавливаем конфигурационный шаблон
    if [ "$active_backend" -eq 0 ]; then
        log "Генерация базовой конфигурации AmneziaWG (профиль 3.1)..."
        local srv_priv=""
        local srv_pub=""

        # Проверяем наличие ранее сгенерированных серверных ключей
        if [ -f "$awg_dir/keys/server_private.key" ]; then
            srv_priv=$(cat "$awg_dir/keys/server_private.key" | tr -d '[:space:]')
            if [ -f "$awg_dir/keys/server_public.key" ]; then
                srv_pub=$(cat "$awg_dir/keys/server_public.key" | tr -d '[:space:]')
            fi
        fi

        if [ -z "$srv_priv" ]; then
            if command -v awg >/dev/null 2>&1; then
                srv_priv=$(awg genkey 2>/dev/null || openssl rand -base64 32)
                srv_pub=$(echo "$srv_priv" | awg pubkey 2>/dev/null || true)
            else
                srv_priv=$(openssl rand -base64 32)
                srv_pub=$(python3 -c "
import base64, os
P = 2**255 - 19
def x25519(k, u=9):
    x1, x2, z2, x3, z3 = u, 1, 0, u, 1
    for i in range(254, -1, -1):
        bit = (k >> i) & 1
        if bit: x2, x3 = x3, x2; z2, z3 = z3, z2
        A = (x2 + z2) % P; AA = (A * A) % P; B = (x2 - z2) % P; BB = (B * B) % P
        E = (AA - BB) % P; C = (x3 + z3) % P; D = (x3 - z3) % P
        x3 = pow(D * A + C * B, 2, P); z3 = (x1 * pow(D * A - C * B, 2, P)) % P
        x2 = (AA * BB) % P; z2 = (E * (AA + 121665 * E)) % P
        if bit: x2, x3 = x3, x2; z2, z3 = z3, z2
    return (x2 * pow(z2, P - 2, P)) % P
raw = bytearray(base64.b64decode('$srv_priv'))
raw[0] &= 248; raw[31] &= 127; raw[31] |= 64
k = int.from_bytes(raw, 'little')
pub = x25519(k, 9).to_bytes(32, 'little')
print(base64.b64encode(pub).decode())
" 2>/dev/null || echo "")
            fi
        fi

        local srv_psk=""
        if [ -f "$awg_dir/keys/server_psk.key" ]; then
            srv_psk=$(cat "$awg_dir/keys/server_psk.key" | tr -d '[:space:]')
        else
            srv_psk=$(openssl rand -base64 32)
        fi
        local hpk="${AWG_HEADER_PROTECTION_KEY:-$(openssl rand -base64 32)}"

        mkdir -p "$awg_dir/keys"
        [ ! -f "$awg_dir/keys/server_private.key" ] && echo "$srv_priv" > "$awg_dir/keys/server_private.key"
        [ ! -f "$awg_dir/keys/server_public.key" ] && echo "$srv_pub" > "$awg_dir/keys/server_public.key"
        [ ! -f "$awg_dir/keys/server_psk.key" ] && echo "$srv_psk" > "$awg_dir/keys/server_psk.key"
        chmod 600 "$awg_dir/keys/"*

        # Сохраняем шаблон awg0.conf, только если его ещё нет
        if [ ! -f /etc/amnezia/amneziawg/awg0.conf ]; then
            mkdir -p /etc/amnezia/amneziawg
            cat << EOF_AWG0 > /etc/amnezia/amneziawg/awg0.conf
[Interface]
Address = 10.8.0.1/22
ListenPort = ${awg_port}
PrivateKey = ${srv_priv}
MTU = 1280
Jc = 4
Jmin = 40
Jmax = 70
S1 = 16
S2 = 16
S3 = 16
S4 = 16
H1 = 1
H2 = 2
H3 = 3
H4 = 4
HeaderProtectionKey = ${hpk}
RandomTrailers = on
DisableCookies = off
EOF_AWG0
            chmod 600 /etc/amnezia/amneziawg/awg0.conf
        fi
    fi

    # 3. Создание первого административного клиента, если таблица клиентов пуста и client-1.conf не существует
    if [ -f "$awg_dir/client-1.conf" ]; then
        ok "Существующий профиль администратора сохранен: $awg_dir/client-1.conf"
    else
        local client_count=$(/root/awg/manage_amneziawg.sh status 2>/dev/null | grep -o '"total": [0-9]*' | awk '{print $2}' || echo "0")
        if [ "$client_count" = "0" ] || [ -z "$client_count" ]; then
            log "Создание первичного профиля администратора (client-1)..."
            /root/awg/manage_amneziawg.sh add client-1 >/dev/null 2>&1 || true
        fi
    fi
}
