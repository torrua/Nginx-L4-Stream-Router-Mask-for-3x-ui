# --- Модуль AmneziaWG: Универсальный контроллер и сервис управления (v3.1 / v2.0) ---
# На базе концепций проекта: https://github.com/bivlked/amneziawg-installer (@bivlked)

AMNEZIA_PPA_GPG_B64="xsFNBGV0UhsBEAC33rMndHSN/k+u7gcZbh9/FjgYfGltQAtVe2QDxzn7UV+k/ChXOrYRw6Izw/DrhaapkNCThK2jwJE64e0NjboLH7UrrmSJLXMfOlDFbyGJVRA+1sTBlo7kKHY0xiZ1CHDzjKNV3czbesu80A9nuTZYyWHEn9ax6wsqKG3N8SvzQkUrIOVD2wZjh0p273CCEGkBnax1ghAV3MF8OrsPU6FRJ+ZakzKbu54g68xoV+2813YECme0JKsWfUUe/1uEJOXCvuACURSxnYr0sihJd8QI/jHSGlfeq72e5MflFEOrnu5xaDSJr2W5lvUetG7EGSxtNKd7Jm/KhUV04g7arA0qydRjRToW3QqyzG7VB2nXKz3AOBYNearWAuBcTkfPvRVchxbjiYonKZA5tIlVrpawMZsdxKvYwl6LVnpBcccFWPhpudfy4TpCqCxRoAanOCvSirI3/y7TcZMBw643SaxXi1ifGeg6eyMzrLtP3CeonKBHGzrt1eeKGtEw/PFN4RmwpBePxi+uj0CoTD6zjCQa3c8EeB4Qz7tt6PnpibxdtZE8sBdd51wSA/fPGi2tFph8IVAsws7oxcQxZYl8CyncKDLcoR4dxVHYdFEDDf1GjRjoQ3AinD7fxD5qYzExe50DBVpuUbWcAiGICNxfvzQtUSRRtMoSHDcvzsy03KC6VwARAQABzR5MYXVuY2hwYWQgUFBBIGZvciBJdXJpaSBFZ29yb3bCwY4EEwEKADgWIQR1yd1yx5mHDjEFQuJBZvLCVykIKAUCZXRSGwIbAwULCQgHAgYVCgkICwIEFgIDAQIeAQIXgAAKCRBBZvLCVykIKBu5D/9akmHCHlUqm2RTTBeTMbLNGc0l6YugpPaCM6vz0O9kBFP5PfRaNSRzyF7wHFHNY3JUHcor28my1fD8AE4+C3PwXz8tVYLh57UUsp4wjqHY+MTl/1ngDViPGD3PRjB8ZlO+19yerfplZv1Jaw7FZZv2BZOAXb+ddqUG4EmlzOnCEhcSDdFrzEBB3RGthjIb3QkKWKGbELDiMfogmsO9BE139Raiw23blagDrbnWsG4jReZeu3atjG6AW8eL7m+i7bKKshD2CYVMznI5cYGLMKo9w7sb33uylPj1Vx9O7joP2GFf2rTpCY8wgzk7i1RqsipJ80u1/DY91Xdizv3f2BBe6UY7qHKoK00O11J0y8yUis2Asycy33Wy51pf6rCFUBLQu+c1fEypHF6jqANmQwaH7pPBliy4gGWvrVggzV4mxv7SnRiMi4PFyVwjKWm8dmuMxi/B9s++VG/ed+5aYgJYL58MohG3MUI/L58eitSCDDcQ1iAnBmawnGMKPqzMgRFB3OU3wDwfh7LNVvQqWpQ4q7pr4Cq1CvZvGoggXWDo1/vylPsRmiiuNetfsoVYmrkgtj1om07m5Xp1v4SyXJH11c3dc/xfMmn/4RlMWIpq86IsOjpr3avsw3FVUNCgD5Wf5+rHG+7gNmM6Cm/F8MDfAnnRmsw4h6hgvcJNQT5Dig=="

install_amneziawg_packages_task() {
    export DEBIAN_FRONTEND=noninteractive
    local os_id=""
    local os_codename=""
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        os_id="$ID"
        os_codename="${VERSION_CODENAME:-$VERSION_ID}"
    fi

    # 1. Если бинарник awg уже доступен в системе — ничего делать не нужно
    if command -v awg >/dev/null 2>&1; then
        return 0
    fi

    # Ожидание освобождения блокировок apt другими процессами
    local wait_count=0
    while { command -v fuser >/dev/null 2>&1 && { fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; }; }; do
        sleep 1
        wait_count=$((wait_count + 1))
        [ "$wait_count" -ge 60 ] && break
    done

    # 2. Подключение репозитория Amnezia PPA напрямую через GPG ключ (без зависающего add-apt-repository при disable_ipv6)
    if [[ "$os_id" == "ubuntu" ]]; then
        mkdir -p /etc/apt/keyrings /etc/apt/sources.list.d
        echo "$AMNEZIA_PPA_GPG_B64" | base64 -d > /etc/apt/keyrings/amnezia-ppa.gpg 2>/dev/null || true
        chmod 644 /etc/apt/keyrings/amnezia-ppa.gpg 2>/dev/null || true

        cat << EOF_PPA > /etc/apt/sources.list.d/amnezia-ppa.sources
Types: deb
URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu
Suites: ${os_codename}
Components: main
Signed-By: /etc/apt/keyrings/amnezia-ppa.gpg
EOF_PPA
        chmod 644 /etc/apt/sources.list.d/amnezia-ppa.sources 2>/dev/null || true
    fi

    local apt_flags=("-o" "Acquire::Retries=3" "-o" "Acquire::http::Timeout=15")
    apt-get update -q "${apt_flags[@]}" 2>/dev/null || apt-get update -q || true

    # 3. Установка ядра, заголовков и пакетов AmneziaWG
    local kheaders="linux-headers-$(uname -r)"
    apt-get install -y --no-install-recommends "${apt_flags[@]}" \
        "$kheaders" build-essential dkms wireguard-tools amneziawg-tools amneziawg-dkms qrencode -q 2>/dev/null || \
    apt-get install -y --no-install-recommends "${apt_flags[@]}" \
        wireguard-tools amneziawg-tools amneziawg-dkms qrencode -q 2>/dev/null || true

    # 4. Проверка и загрузка модуля ядра
    modprobe amneziawg 2>/dev/null || true
}

ensure_amneziawg_installed() {
    # Пропускаем, если бэкенд развернут в Docker-контейнере
    if command -v docker >/dev/null 2>&1; then
        for c_cand in "amnezia-awg2" "amnezia-awg" "awg-server"; do
            if docker inspect -f '{{.State.Running}}' "$c_cand" 2>/dev/null | grep -q "true"; then
                return 0
            fi
        done
    fi

    # 1. Если уже установлен в системе — отлично
    if command -v awg >/dev/null 2>&1; then
        modprobe amneziawg 2>/dev/null || true
        return 0
    fi

    # 2. Если была запущена фоновая сборка — дожидаемся её
    if ! command -v awg >/dev/null 2>&1; then
        run_with_spinner "Установка и компиляция модуля ядра AmneziaWG (DKMS)" install_amneziawg_packages_task
    fi

    # 4. Проверяем результат
    if command -v awg >/dev/null 2>&1; then
        modprobe amneziawg 2>/dev/null || true
        ok "Модуль ядра и утилита AmneziaWG успешно подготовлены: $(which awg)"
    else
        warn "Не удалось установить утилиту awg в ядро ОС. manage_amneziawg переключится в резервный режим."
    fi
}

setup_amneziawg_controller() {
    local awg_dir="/root/awg"
    mkdir -p "$awg_dir/keys"
    chmod 700 "$awg_dir"

    log "Развертывание универсального контроллера AmneziaWG в $awg_dir..."

    # Копирование или запись manage_clients.py и crypto_engine.py
    local src_py="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/manage_clients.py"
    if [ -f "$src_py" ]; then
        cp -f "$src_py" "$awg_dir/manage_clients.py"
    fi
    local src_crypto="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../common" 2>/dev/null && pwd)/crypto_engine.py"
    if [ -f "$src_crypto" ]; then
        cp -f "$src_crypto" "$awg_dir/crypto_engine.py"
    fi

    # Если файл не существует (например, запуск через curl монолита), пишем встроенную версию
    if [ ! -f "$awg_dir/manage_clients.py" ]; then
        cat << 'EOF_AWG_PY' > "$awg_dir/manage_clients.py"
# @include "awg/manage_clients.py"
EOF_AWG_PY
    fi
    if [ ! -f "$awg_dir/crypto_engine.py" ]; then
        cat << 'EOF_AWG_CRYPTO' > "$awg_dir/crypto_engine.py"
# @include "common/crypto_engine.py"
EOF_AWG_CRYPTO
    fi
    chmod 750 "$awg_dir/manage_clients.py"
    chmod 640 "$awg_dir/crypto_engine.py" 2>/dev/null || true

    # Настройка порта и хоста
    local awg_port="${AWG_SERVER_PORT:-${AWG_STANDALONE_PORT:-}}"
    if [ -z "$awg_port" ]; then
        if [ "${AWG_V3_PORT:-}" = "8443" ] && [[ "${ENABLE_AWG_V3:-}" == "1" || "${ENABLE_AWG_V3,,}" == "y" ]]; then
            awg_port="8445"
        else
            awg_port="8443"
        fi
    fi
    local awg_host="${AWG_SERVER_HOST:-${SERVER_PUBLIC_HOST:-}}"

    # Запись скрипта-лаунчера
    cat << EOF_AWG_SH > "$awg_dir/manage-clients.sh"
#!/usr/bin/env bash
set -euo pipefail
AWG_DIR="\${AWG_DIR:-/root/awg}"
PYTHON_BIN="\$(command -v python3 2>/dev/null || echo /usr/bin/python3)"
[ -n "${awg_host}" ] && export SERVER_PUBLIC_HOST="\${SERVER_PUBLIC_HOST:-${awg_host}}"
[ -n "${awg_port}" ] && export SERVER_PORT="\${SERVER_PORT:-${awg_port}}"
[ -n "${SUB_TITLE:-}" ] && export SUB_TITLE="\${SUB_TITLE:-${SUB_TITLE}}"
[ -n "${SERVER_PREFIX:-}" ] && export SERVER_PREFIX="\${SERVER_PREFIX:-${SERVER_PREFIX}}"
exec "\$PYTHON_BIN" "\$AWG_DIR/manage_clients.py" "\$@"
EOF_AWG_SH
    chmod 755 "$awg_dir/manage-clients.sh"

    # Existing automation may still call the previous filenames directly.
    ln -sf manage-clients.sh "$awg_dir/manage_amneziawg.sh"
    ln -sf manage_clients.py "$awg_dir/manage_amneziawg.py"

    # Создание глобальных симлинков для удобного управления из консоли
    ln -sf "$awg_dir/manage-clients.sh" /usr/local/bin/awg-mgr 2>/dev/null || true
    ln -sf "$awg_dir/manage-clients.sh" /usr/local/bin/awg-cli 2>/dev/null || true

    # Настройка правил файрвола UFW
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${awg_port}/udp" comment "[vpn-stack] AmneziaWG Server Engine" >/dev/null 2>&1 || true
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

    # 1. Проверяем наличие пакетов и модуля ядра на хосте (при необходимости устанавливаем)
    ensure_amneziawg_installed

    # 2. Проверяем, работает ли уже какой-либо бэкенд AmneziaWG
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

    if [ "$active_backend" -eq 0 ] && systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
        active_backend=1
        ok "Обнаружена активная служба awg-quick@awg0 — сохраняем без изменений."
    fi

    local def_iface
    def_iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1 || echo "")
    [ -z "$def_iface" ] && def_iface="eth0"

    # 3. Если активного бэкенда нет, подготавливаем конфигурационный шаблон
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
                srv_priv=$(awg genkey 2>/dev/null || generate_base64_token 32)
                srv_pub=$(echo "$srv_priv" | awg pubkey 2>/dev/null || true)
            else
                srv_priv="$(generate_base64_token 32)"
                srv_pub=$(python3 - "$srv_priv" << 'EOF_CRYPTO_PUB' 2>/dev/null || true
try:
    from src.common.crypto_engine import curve25519_pubkey
except ImportError:
    try:
        from common.crypto_engine import curve25519_pubkey
    except ImportError:
        pass
# @include "common/crypto_engine.py"
import sys
if len(sys.argv) > 1:
    print(curve25519_pubkey(sys.argv[1]) or "")
EOF_CRYPTO_PUB
)
            fi
        fi

        local srv_psk=""
        if [ -f "$awg_dir/keys/server_psk.key" ]; then
            srv_psk=$(cat "$awg_dir/keys/server_psk.key" | tr -d '[:space:]')
        else
            srv_psk="$(generate_base64_token 32)"
        fi
        local hpk="${AWG_HEADER_PROTECTION_KEY:-$(generate_base64_token 32)}"

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
PostUp = iptables -I FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${def_iface} -j MASQUERADE; iptables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240; iptables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${def_iface} -j MASQUERADE; iptables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240; iptables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240
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
        else
            # Если конфиг уже был, проверяем наличие правил PostUp
            if ! grep -q "PostUp" /etc/amnezia/amneziawg/awg0.conf 2>/dev/null; then
                sed -i "/PrivateKey =/a PostUp = iptables -I FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${def_iface} -j MASQUERADE; iptables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240; iptables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240\\nPostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${def_iface} -j MASQUERADE; iptables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240; iptables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240" /etc/amnezia/amneziawg/awg0.conf 2>/dev/null || true
            fi
        fi

        # Активация и запуск системной службы WireGuard / AmneziaWG
        if command -v systemctl >/dev/null 2>&1 && [ -f /lib/systemd/system/awg-quick@.service -o -f /etc/systemd/system/awg-quick@.service -o -f /usr/lib/systemd/system/awg-quick@.service ]; then
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable --now awg-quick@awg0.service >/dev/null 2>&1 || true
            ok "Системная служба awg-quick@awg0 запущена на порту ${awg_port}/udp"
        fi
    fi

    if [ -f "$awg_dir/client-1.conf" ]; then
        if [ -n "${AWG_SERVER_HOST:-}" ]; then
            sed -i "s|^Endpoint = .*|Endpoint = ${AWG_SERVER_HOST}:${awg_port}|" "$awg_dir/client-1.conf" 2>/dev/null || true
        fi
        ok "Существующий профиль администратора сохранен: $awg_dir/client-1.conf"
    else
        local client_count=$(/root/awg/manage-clients.sh status 2>/dev/null | grep -o '"total": [0-9]*' | awk '{print $2}' || echo "0")
        if [ "$client_count" = "0" ] || [ -z "$client_count" ]; then
            log "Создание первичного профиля администратора (client-1)..."
            export SERVER_PUBLIC_HOST="${AWG_SERVER_HOST:-${SERVER_PUBLIC_HOST:-}}"
            export SERVER_PORT="${awg_port}"
            if ! /root/awg/manage-clients.sh add client-1 >/dev/null 2>&1; then
                warn "Не удалось автоматически сгенерировать первичного клиента client-1. Попробуйте вручную: awg-mgr add <имя>"
            else
                ok "Первичный профиль администратора создан: $awg_dir/client-1.conf"
                if [ -f "$awg_dir/client-1.vpnuri" ]; then
                    ok "Ссылка Amnezia VPN (vpn://): $(head -n 1 "$awg_dir/client-1.vpnuri" | tr -d '[:space:]')"
                fi
            fi
        fi
    fi
}
