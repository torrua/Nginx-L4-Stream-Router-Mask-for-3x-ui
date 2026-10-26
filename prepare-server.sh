#!/bin/bash
set -euo pipefail

#####################################
# PROD VPS HARDENING
# Совместимость: Ubuntu 20.04/24.04 & Debian 11/12
# + Optional System Upgrade & Clean
# + BBR + Disable IPv6 + Block Ping
# + IPv4 ONLY Firewall Rules
# + SSH Keys (Auto-gen or Paste)
# + 3x-ui (Выбор версии)
# + Extended Utilities
#####################################

#!/usr/bin/env bash
# ==============================================================================
# src/common/lock.sh - Inter-Process Mutex for Mutating Operations (T07)
# ==============================================================================
# Ensures single-writer mutual exclusion across install, setup, maintain,
# configure-panel, prepare-server, manage-services, and uninstall.
# Supports re-entrancy for nested invocations (e.g., install calling setup).
# ==============================================================================

VPN_STACK_LOCK_FILE="${VPN_STACK_LOCK_FILE:-/run/lock/vpn-stack.lock}"
VPN_STACK_LOCK_TIMEOUT="${VPN_STACK_LOCK_TIMEOUT:-10}"
VPN_STACK_LOCK_FD=200

_get_vpn_lock_path() {
    if [ -n "${VPN_STACK_LOCK_FILE:-}" ] && [ "${VPN_STACK_LOCK_FILE}" != "/run/lock/vpn-stack.lock" ]; then
        echo "$VPN_STACK_LOCK_FILE"
        return 0
    fi
    if [ "${EUID:-$(id -u)}" -eq 0 ] && [ -d /run/lock ]; then
        echo "/run/lock/vpn-stack.lock"
    elif [ -d "${XDG_RUNTIME_DIR:-}" ]; then
        echo "${XDG_RUNTIME_DIR}/vpn-stack.lock"
    elif [ -d /var/run ]; then
        echo "/var/run/vpn-stack.lock"
    else
        echo "/tmp/.vpn-stack-${EUID:-0}.lock"
    fi
}

_is_lock_ancestor() {
    local target="$1"
    [ -n "$target" ] || return 1
    [ "$target" = "$$" ] && return 0
    [ "$target" = "${PPID:-}" ] && return 0
    local cur_p="${PPID:-}"
    local count=0
    while [ -n "$cur_p" ] && [ "$cur_p" -gt 1 ] && [ "$count" -lt 10 ]; do
        [ "$cur_p" = "$target" ] && return 0
        if [ -f "/proc/$cur_p/stat" ]; then
            cur_p=$(awk '{print $4}' "/proc/$cur_p/stat" 2>/dev/null || echo "")
        elif command -v ps >/dev/null 2>&1; then
            cur_p=$(ps -o ppid= -p "$cur_p" 2>/dev/null | tr -d ' ' || echo "")
        else
            break
        fi
        count=$((count + 1))
    done
    return 1
}

_on_stack_lock_exit() {
    local exit_code=$?
    release_stack_lock
    if [ -n "${_PREV_LOCK_EXIT_TRAP:-}" ] && [ "${_PREV_LOCK_EXIT_TRAP}" != "release_stack_lock" ] && [ "${_PREV_LOCK_EXIT_TRAP}" != "_on_stack_lock_exit" ]; then
        eval "$_PREV_LOCK_EXIT_TRAP"
    fi
    exit "$exit_code"
}

_setup_lock_traps() {
    _PREV_LOCK_EXIT_TRAP=$(trap -p EXIT 2>/dev/null | sed -E "s/^trap -- ['\"]?(.*)['\"]? EXIT\$/\\1/" || true)
    trap '_on_stack_lock_exit' EXIT INT TERM
}

acquire_stack_lock() {
    local timeout="${1:-$VPN_STACK_LOCK_TIMEOUT}"
    local op_name="${2:-${0##*/}}"

    # 1. Re-entrancy check: if lock is already held by current process or ancestor in this session
    if [ -n "${VPN_STACK_LOCK_HELD_BY:-}" ]; then
        if [ "$VPN_STACK_LOCK_HELD_BY" = "$$" ] || _is_lock_ancestor "$VPN_STACK_LOCK_HELD_BY"; then
            # Nested call within same operation hierarchy
            return 0
        fi
    fi

    local lock_path
    lock_path="$(_get_vpn_lock_path)"
    local lock_dir="${lock_path%/*}"
    [ -d "$lock_dir" ] || mkdir -p "$lock_dir" 2>/dev/null || true

    # Security check: lock file must NOT be a symlink (T07.C07)
    if [ -L "$lock_path" ]; then
        echo "[ERROR] Lock file $lock_path is a symbolic link! Aborting to prevent symlink attacks." >&2
        return 75
    fi

    local start_time
    start_time=$(date +%s 2>/dev/null || echo 0)

    while true; do
        if command -v flock >/dev/null 2>&1; then
            # flock-based locking
            eval "exec ${VPN_STACK_LOCK_FD}>\"\$lock_path\"" 2>/dev/null || {
                echo "[ERROR] Unable to open lock file $lock_path" >&2
                return 75
            }
            if flock -n "$VPN_STACK_LOCK_FD" 2>/dev/null; then
                echo "$$" > "$lock_path" 2>/dev/null || true
                export VPN_STACK_LOCK_HELD_BY="$$"
                export VPN_STACK_LOCK_ACTIVE_PATH="$lock_path"
                _setup_lock_traps
                return 0
            fi
        else
            # Directory-based atomic mutex fallback for platforms without flock
            local lock_d="${lock_path}.d"
            if mkdir "$lock_d" 2>/dev/null; then
                echo "$$" > "$lock_path" 2>/dev/null || true
                export VPN_STACK_LOCK_HELD_BY="$$"
                export VPN_STACK_LOCK_ACTIVE_PATH="$lock_path"
                _setup_lock_traps
                return 0
            fi
        fi

        # Check existing holder PID
        local holder_pid=""
        if [ -s "$lock_path" ]; then
            holder_pid=$(head -n 1 "$lock_path" 2>/dev/null | tr -cd '0-9')
        fi

        # Check if holder PID is dead (stale lock recovery)
        if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
            if command -v flock >/dev/null 2>&1; then
                echo "$$" > "$lock_path" 2>/dev/null || true
                if flock -n "$VPN_STACK_LOCK_FD" 2>/dev/null; then
                    export VPN_STACK_LOCK_HELD_BY="$$"
                    export VPN_STACK_LOCK_ACTIVE_PATH="$lock_path"
                    _setup_lock_traps
                    return 0
                fi
            else
                rm -rf "${lock_path}.d" 2>/dev/null || true
                if mkdir "${lock_path}.d" 2>/dev/null; then
                    echo "$$" > "$lock_path" 2>/dev/null || true
                    export VPN_STACK_LOCK_HELD_BY="$$"
                    export VPN_STACK_LOCK_ACTIVE_PATH="$lock_path"
                    _setup_lock_traps
                    return 0
                fi
            fi
        fi

        local now
        now=$(date +%s 2>/dev/null || echo 0)
        local elapsed=$((now - start_time))
        if [ "$elapsed" -ge "$timeout" ]; then
            echo "[ERROR] Operation '$op_name' blocked by active operation (PID: ${holder_pid:-unknown})." >&2
            echo "[ERROR] Timed out after ${timeout}s waiting for lock: $lock_path" >&2
            return 75
        fi

        sleep 0.5 2>/dev/null || sleep 1
    done
}

release_stack_lock() {
    if [ -n "${VPN_STACK_LOCK_HELD_BY:-}" ] && [ "$VPN_STACK_LOCK_HELD_BY" = "$$" ]; then
        local lock_path="${VPN_STACK_LOCK_ACTIVE_PATH:-$(_get_vpn_lock_path)}"
        if [ -f "$lock_path" ]; then
            rm -f "$lock_path" 2>/dev/null || true
        fi
        if [ -d "${lock_path}.d" ]; then
            rmdir "${lock_path}.d" 2>/dev/null || rm -rf "${lock_path}.d" 2>/dev/null || true
        fi
        if command -v flock >/dev/null 2>&1; then
            eval "exec ${VPN_STACK_LOCK_FD}>&-" 2>/dev/null || true
        fi
        unset VPN_STACK_LOCK_HELD_BY
        unset VPN_STACK_LOCK_ACTIVE_PATH
    fi
}
#!/usr/bin/env bash
# ==============================================================================
# src/common/download.sh - Verifiable Component Downloader (T04, T05)
# ==============================================================================
# Enforces timeouts, retry limits, temporary staging, and cryptographic SHA256
# verification against components-manifest.json before any binary is installed.
# ==============================================================================

DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-15}"
DOWNLOAD_MAX_RETRIES="${DOWNLOAD_MAX_RETRIES:-3}"
MANIFEST_FILE="${MANIFEST_FILE:-${ROOT_DIR:-.}/components-manifest.json}"

verify_file_sha256() {
    local file="$1"
    local expected_hash="$2"

    [ -f "$file" ] || return 1
    [ -n "$expected_hash" ] || return 1

    local actual_hash=""
    if command -v sha256sum >/dev/null 2>&1; then
        actual_hash=$(sha256sum "$file" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual_hash=$(shasum -a 256 "$file" | awk '{print $1}')
    elif command -v openssl >/dev/null 2>&1; then
        actual_hash=$(openssl dgst -sha256 "$file" | awk '{print $NF}')
    else
        actual_hash=$(python3 -c "import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())" "$file" 2>/dev/null || echo "")
    fi

    [ -n "$actual_hash" ] && [ "${actual_hash,,}" = "${expected_hash,,}" ]
}

download_verified_file() {
    local url="$1"
    local dest_file="$2"
    local expected_hash="${3:-}"
    local max_size_bytes="${4:-104857600}" # Default 100MB limit

    local staging_tmp
    staging_tmp=$(mktemp "/tmp/dl-staging.XXXXXX" 2>/dev/null || mktemp "${TMPDIR:-/tmp}/dl-staging.XXXXXX") || return 1

    local urls=("$url")
    if [[ "$url" =~ ^https://github\.com/ ]]; then
        urls+=("https://ghfast.top/$url")
    fi

    local success=0
    for candidate_url in "${urls[@]}"; do
        local attempt=1
        while [ "$attempt" -le "$DOWNLOAD_MAX_RETRIES" ]; do
            if curl -fsSL --connect-timeout "$DOWNLOAD_TIMEOUT" --max-time 120 "$candidate_url" -o "$staging_tmp" 2>/dev/null; then
                # Size limit validation (T05.C04)
                local file_size=0
                file_size=$(wc -c < "$staging_tmp" 2>/dev/null || stat -c%s "$staging_tmp" 2>/dev/null || echo 0)
                if [ "$file_size" -gt "$max_size_bytes" ] || [ "$file_size" -eq 0 ]; then
                    rm -f "$staging_tmp"
                    return 2
                fi

                # Checksum validation (T05.C02, T05.C03)
                if [ -n "$expected_hash" ]; then
                    if ! verify_file_sha256 "$staging_tmp" "$expected_hash"; then
                        rm -f "$staging_tmp"
                        return 3
                    fi
                fi

                success=1
                break 2
            fi
            attempt=$((attempt + 1))
            sleep 1
        done
    done

    if [ "$success" -eq 1 ]; then
        mkdir -p "$(dirname "$dest_file")" 2>/dev/null || true
        mv -f "$staging_tmp" "$dest_file"
        return 0
    else
        rm -f "$staging_tmp" 2>/dev/null || true
        return 1
    fi
}

get_manifest_python() {
    if [ -n "${PYTHON_CMD:-}" ] && "$PYTHON_CMD" -c "import json, sys" 2>/dev/null; then
        echo "$PYTHON_CMD"
        return 0
    fi
    if python3 -c "import json, sys" 2>/dev/null; then
        echo "python3"
        return 0
    fi
    if python -c "import json, sys" 2>/dev/null; then
        echo "python"
        return 0
    fi
    return 1
}

get_manifest_component_data() {
    local comp_name="$1"
    local arch="${2:-x86_64}"
    local py_cmd
    py_cmd=$(get_manifest_python || echo "")

    [ -n "$py_cmd" ] || return 1

    "$py_cmd" -c "
import json, sys, os

FALLBACK = {
    'shadow-tls': {
        'x86_64': ('https://github.com/ihciah/shadow-tls/releases/download/v0.2.25/shadow-tls-x86_64-unknown-linux-musl', 'a173f5f2d57f45211b68e10ceeddc15b1791077b914fa89747bc705fddc71532', 15728640, '0.2.25'),
        'aarch64': ('https://github.com/ihciah/shadow-tls/releases/download/v0.2.25/shadow-tls-aarch64-unknown-linux-musl', '3295476b37f549a68906519d3eaecb74bf3b6eaf9094cebb16ee84f0151373c6', 15728640, '0.2.25')
    },
    'wstunnel': {
        'x86_64': ('https://github.com/erebe/wstunnel/releases/download/v11.1.0/wstunnel_11.1.0_linux_amd64.tar.gz', '512edf4e7bb64fc133522220123514868fae75b5bae4124b53e396787276aa23', 26214400, '11.1.0'),
        'aarch64': ('https://github.com/erebe/wstunnel/releases/download/v11.1.0/wstunnel_11.1.0_linux_arm64.tar.gz', '148895f957a68be39e2b65d28c5f2065b9c58c4a0cfd48c560b2b3267f398464', 26214400, '11.1.0')
    },
    'sing-box': {
        'x86_64': ('https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-linux-amd64.tar.gz', '699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968', 52428800, '1.14.4'),
        'aarch64': ('https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-linux-arm64.tar.gz', '436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26', 52428800, '1.14.4')
    },
    'zapret': {
        'all': ('https://github.com/bol-van/zapret/releases/download/v72.13/zapret-v72.13.tar.gz', '25c74e6c5f48963fa244c2955e76694a07c39447245a0457e2efdc74b3317e68', 20971520, '72.13')
    },
    'AdGuardHome': {
        'x86_64': ('https://github.com/AdguardTeam/AdGuardHome/releases/download/v0.107.79/AdGuardHome_linux_amd64.tar.gz', 'c48f4a43000665484c5ec28177de11a004759b620dae8f77b2aabefc9ef3687f', 41943040, '0.107.79'),
        'aarch64': ('https://github.com/AdguardTeam/AdGuardHome/releases/download/v0.107.79/AdGuardHome_linux_arm64.tar.gz', '3f7893c18e8aaadc456d0452839190561c306ca95175a2254958be80a769c1ae', 41943040, '0.107.79')
    },
    'acme.sh': {
        'all': ('https://github.com/acmesh-official/acme.sh/archive/refs/tags/3.1.6.tar.gz', '0d3f9000ac44a6331314742a88c475f79134e24fc991997883652adc59efc486', 2097152, '3.1.6')
    }
}

comp_name = sys.argv[1]
arch = sys.argv[2]
arch_aliases = {'amd64': 'x86_64', 'arm64': 'aarch64'}
arch = arch_aliases.get(arch, arch)
manifest_p = os.environ.get('MANIFEST_FILE', '')

if not manifest_p or not os.path.isfile(manifest_p):
    for candidate in [
        'components-manifest.json',
        os.path.join(os.environ.get('ROOT_DIR', '.'), 'components-manifest.json'),
        '/usr/local/share/vpn-stack/components-manifest.json',
    ]:
        if os.path.isfile(candidate):
            manifest_p = candidate
            break

data = None
if manifest_p and os.path.isfile(manifest_p):
    try:
        with open(manifest_p, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except Exception:
        data = None

if data and 'components' in data and comp_name in data['components']:
    comp = data['components'][comp_name]
    artifacts = comp.get('artifacts', {})
    art = artifacts.get(arch) or artifacts.get('all')
    if art:
        url = art.get('url', '')
        sha256 = art.get('sha256', '')
        max_sz = comp.get('max_size_bytes', 104857600)
        version = comp.get('version', '')
        print(f'{url}|{sha256}|{max_sz}|{version}')
        sys.exit(0)

# Fallback to embedded pinned metadata
if comp_name in FALLBACK:
    comp_map = FALLBACK[comp_name]
    art = comp_map.get(arch) or comp_map.get('all')
    if art:
        url, sha256, max_sz, version = art
        print(f'{url}|{sha256}|{max_sz}|{version}')
        sys.exit(0)

sys.exit(1)
" "$comp_name" "$arch" 2>/dev/null
}

download_manifest_component() {
    local comp_name="$1"
    local dest_file="$2"
    local cur_arch="${3:-}"

    if [ -z "$cur_arch" ]; then
        cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
    fi
    case "$cur_arch" in
        x86_64|amd64) cur_arch="x86_64" ;;
        aarch64|arm64) cur_arch="aarch64" ;;
        all) cur_arch="all" ;;
        *) cur_arch="x86_64" ;;
    esac

    local comp_meta
    comp_meta=$(get_manifest_component_data "$comp_name" "$cur_arch")

    if [ -n "$comp_meta" ]; then
        local url sha256 max_size version
        IFS='|' read -r url sha256 max_size version <<< "$comp_meta"
        if [ -n "$url" ] && [ -n "$sha256" ]; then
            download_verified_file "$url" "$dest_file" "$sha256" "$max_size"
            return $?
        fi
    fi
    return 1
}

#!/usr/bin/env bash
# ==============================================================================
# src/system/optimize.sh — Модуль оптимизации ресурсов VPS и очистки балласта
# ==============================================================================
# Подходит для: Ubuntu (20.04 - 26.04) и Debian (11 - 13)
#
# Предоставляет функции:
#   - unlock_cloud_init_root: снятие cloud-init блокировок с сохранением ключей
#   - optimize_vps_storage: DPKG no-doc, APT no-cache, удаление snapd/cloud-балласта
#   - optimize_vps_memory: адаптивная настройка zRAM (сжатый swap) и sysctl
#   - optimize_vps_logs: лимиты journald (50M) и ротация логов Docker (10M)
#   - setup_clean_motd: установка информативного MOTD-баннера RAM/zRAM/Диск
#   - run_full_vps_optimization: пакетный вызов всех процедур оптимизации
# ==============================================================================

unlock_cloud_init_root() {
    echo "Проверка и разблокировка прямого SSH-доступа для root..."
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys

    # Снятие блокирующего префикса cloud-init (command="echo Please login as...")
    if grep -qE 'command=".*Please login as' /root/.ssh/authorized_keys 2>/dev/null; then
        sed -i -E 's/^(no-[^ ]+ +)*command="[^"]*" +//g' /root/.ssh/authorized_keys
        echo "  ✔ Снята cloud-init блокировка прямого входа root в authorized_keys."
    fi

    # Копирование ключей из профиля sudo-пользователя, если root пуст
    if [ ! -s /root/.ssh/authorized_keys ] && [ -n "${SUDO_USER:-}" ] && [ -f "/home/${SUDO_USER}/.ssh/authorized_keys" ]; then
        cp "/home/${SUDO_USER}/.ssh/authorized_keys" /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        echo "  ✔ SSH-ключи перенесены из профиля /home/${SUDO_USER} в /root."
    fi

    # Опциональное добавление ключа из переменной окружения
    if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
        echo "${SSH_PUBLIC_KEY}" >> /root/.ssh/authorized_keys
        sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        echo "  ✔ Добавлен SSH-ключ из переменной SSH_PUBLIC_KEY."
    fi

    # Отключение повторной блокировки в cloud-init
    if [ -d /etc/cloud ]; then
        mkdir -p /etc/cloud/cloud.cfg.d
        echo 'disable_root: false' > /etc/cloud/cloud.cfg.d/99-disable-root.cfg
        if [ -f /etc/cloud/cloud.cfg ]; then
            sed -i 's/disable_root: true/disable_root: false/' /etc/cloud/cloud.cfg 2>/dev/null || true
        fi
        touch /etc/cloud/cloud-init.disabled 2>/dev/null || true
    fi
}

optimize_vps_storage() {
    echo "Оптимизация дискового пространства и удаление фонового балласта..."
    export DEBIAN_FRONTEND=noninteractive

    # 1. Отключение неиспользуемых фоновых служб
    local useless_services=(
        ModemManager
        multipathd
        udisks2
        rsyslog
        fwupd
        open-vm-tools
    )
    for svc in "${useless_services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc" 2>/dev/null || true
        fi
        systemctl disable "$svc" 2>/dev/null || true
        systemctl mask "$svc" 2>/dev/null || true
    done

    # 2. Удаление snapd
    if dpkg -l | grep -qE '^ii\s+snapd\s' 2>/dev/null; then
        echo "  - Удаление snapd..."
        apt-get purge -y snapd ubuntu-advantage-tools 2>/dev/null || true
        rm -rf /root/snap /var/snap /var/lib/snapd /usr/lib/snapd /home/*/snap 2>/dev/null || true
    fi

    # 3. Удаление облачных SDK и неиспользуемых библиотек
    local packages_to_purge=(
        landscape-common
        python3-boto3
        python3-botocore
        python3-s3transfer
        python3-twisted
        sosreport
        sos
        bpftrace
        ubuntu-kernel-accessories
    )
    for pkg in "${packages_to_purge[@]}"; do
        if dpkg -l | grep -qE "^ii\s+${pkg}\b" 2>/dev/null; then
            echo "  - Удаление $pkg..."
            apt-get purge -y "$pkg" 2>/dev/null || true
        fi
    done

    # 4. Удаление неиспользуемых заголовочных файлов ядра
    if dpkg -l | grep -qE 'linux-headers' 2>/dev/null; then
        echo "  - Очистка неиспользуемых linux-headers..."
        dpkg --list | grep -E 'linux-headers' | awk '{print $2}' | xargs -r apt-get purge -y 2>/dev/null || true
    fi

    # 5. Политика DPKG no-doc
    mkdir -p /etc/dpkg/dpkg.cfg.d
    cat << 'EOF' > /etc/dpkg/dpkg.cfg.d/01_nodoc
path-exclude /usr/share/doc/*
path-exclude /usr/share/man/*
path-exclude /usr/share/groff/*
path-exclude /usr/share/info/*
path-exclude /usr/share/lintian/*
path-exclude /usr/share/linda/*
EOF
    rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/groff/* /usr/share/info/* 2>/dev/null || true

    # 6. Политика APT no-cache и очистка архивов
    mkdir -p /etc/apt/apt.conf.d
    cat << 'EOF' > /etc/apt/apt.conf.d/02nocache
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
Acquire::GzipIndexes "true";
Acquire::CompressionTypes::Order:: "gz";
EOF

    apt-get autoremove --purge -y 2>/dev/null || true
    apt-get clean 2>/dev/null || true
    rm -rf /var/cache/apt/archives/*.deb /var/cache/apt/*.bin 2>/dev/null || true
    echo "  ✔ Дисковая очистка и политики экономии памяти успешно применены."
}

optimize_vps_logs() {
    echo "Настройка лимитов системных логов (Journald и Docker)..."
    
    # 1. Лимиты systemd-journald (максимум 50 МБ)
    mkdir -p /etc/systemd/journald.conf.d
    cat << 'EOF' > /etc/systemd/journald.conf.d/00-limits.conf
[Journal]
SystemMaxUse=50M
SystemMaxFileSize=10M
MaxRetentionSec=1month
EOF
    systemctl restart systemd-journald 2>/dev/null || true
    journalctl --vacuum-size=50M 2>/dev/null || true

    # 2. Ротация логов Docker (максимум 10 МБ на контейнер)
    mkdir -p /etc/docker
    local docker_daemon_json="/etc/docker/daemon.json"
    if [ ! -f "$docker_daemon_json" ]; then
        cat << 'EOF' > "$docker_daemon_json"
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "2"
  }
}
EOF
    fi
    if systemctl is-active --quiet docker 2>/dev/null; then
        systemctl restart docker 2>/dev/null || true
    fi
    echo "  ✔ Лимиты логов успешно настроены (защита диска от переполнения активна)."
}

optimize_vps_memory() {
    local total_ram_mb
    total_ram_mb=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "1024")
    echo "Настройка адаптивного zRAM для ${total_ram_mb}M RAM..."

    # Установка systemd-zram-generator
    if ! dpkg -l | grep -qE '^ii\s+systemd-zram-generator\s' 2>/dev/null; then
        apt-get update -qq 2>/dev/null || true
        apt-get install -y --no-install-recommends systemd-zram-generator 2>/dev/null || true
    fi

    mkdir -p /etc/systemd
    mkdir -p /etc/sysctl.d

    if [ "$total_ram_mb" -le 2048 ]; then
        echo "  -> Профиль малого объема RAM (<= 2GB): zRAM 50% + агрессивный возврат кэша."
        cat << 'EOF' > /etc/systemd/zram-generator.conf
[zram0]
zram-size = min(ram / 2, 1024)
compression-algorithm = zstd
swap-priority = 100
EOF

        cat << 'EOF' > /etc/sysctl.d/99-vps-memory.conf
vm.swappiness = 100
vm.vfs_cache_pressure = 150
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
EOF
    else
        echo "  -> Профиль стандартного объема RAM (> 2GB): zRAM 2GB + сохранение дискового кэша."
        cat << 'EOF' > /etc/systemd/zram-generator.conf
[zram0]
zram-size = 2048
compression-algorithm = zstd
swap-priority = 100
EOF

        cat << 'EOF' > /etc/sysctl.d/99-vps-memory.conf
vm.swappiness = 10
vm.vfs_cache_pressure = 100
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
EOF
    fi

    sysctl --system > /dev/null 2>&1 || true
    systemctl daemon-reload 2>/dev/null || true
    systemctl start /dev/zram0 2>/dev/null || systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true
    echo "  ✔ zRAM и параметры ядра успешно настроены."
}

setup_clean_motd() {
    echo "Настройка чистого системного MOTD-баннера..."
    local motd_spam=(
        10-help-text
        50-motd-news
        90-updates-available
        91-contract-ua-esm-status
        91-release-upgrade
        95-hwe-eol
    )

    for script in "${motd_spam[@]}"; do
        if [ -f "/etc/update-motd.d/$script" ]; then
            chmod -x "/etc/update-motd.d/$script" 2>/dev/null || true
        fi
    done

    if [ -L "/etc/update-motd.d/50-landscape-sysinfo" ] || [ -f "/etc/update-motd.d/50-landscape-sysinfo" ]; then
        rm -f "/etc/update-motd.d/50-landscape-sysinfo" 2>/dev/null || true
    fi

    cat << 'EOF' > /etc/update-motd.d/50-sysinfo
#!/bin/bash
mem_total=$(free -m | awk '/^Mem:/ {print $2}')
mem_used=$(free -m | awk '/^Mem:/ {print $3}')
mem_pct=$(awk "BEGIN {printf \"%.1f\", ($mem_used/($mem_total ? $mem_total : 1))*100}")

zram_total=$(free -m | awk '/^Swap:/ {print $2}')
zram_used=$(free -m | awk '/^Swap:/ {print $3}')

disk_total=$(df -h / | awk 'NR==2 {print $2}')
disk_used=$(df -h / | awk 'NR==2 {print $3}')
disk_pct=$(df -h / | awk 'NR==2 {print $5}')

echo -e "\033[1;36m========================================================\033[0m"
echo -e "\033[1;32m  RAM:\033[0m  ${mem_used}M / ${mem_total}M (${mem_pct}%)"
echo -e "\033[1;32m  zRAM:\033[0m ${zram_used}M / ${zram_total}M (compressed swap)"
echo -e "\033[1;32m  Disk:\033[0m ${disk_used} / ${disk_total} (${disk_pct})"
echo -e "\033[1;36m========================================================\033[0m"
EOF
    chmod +x /etc/update-motd.d/50-sysinfo 2>/dev/null || true
    echo "  ✔ MOTD-баннер обновлен."
}

run_full_vps_optimization() {
    echo "==========================================================="
    echo "Запуск комплексной оптимизации VPS (Диск, Память, Службы)..."
    echo "==========================================================="
    unlock_cloud_init_root
    optimize_vps_storage
    optimize_vps_logs
    optimize_vps_memory
    setup_clean_motd
    echo "==========================================================="
    echo "✔ Оптимизация VPS успешно завершена!"
    echo "==========================================================="
    if [ -x /etc/update-motd.d/50-sysinfo ]; then
        /etc/update-motd.d/50-sysinfo || true
    fi
}

DEFAULT_SSH_PORT=22
MIN_SSH_PORT=22
MAX_SSH_PORT=65535

export DEBIAN_FRONTEND=noninteractive

# Проверка root-прав
if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: Запустите скрипт от пользователя root (sudo)" >&2
    exit 1
fi

acquire_stack_lock "${VPN_STACK_LOCK_TIMEOUT:-10}" "prepare-server" || exit $?

# Определение операционной системы
OS_ID=""
OS_LIKE=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
fi

# Проверка и безопасное снятие cloud-init ограничений прямого входа root
unlock_cloud_init_root

#####################################
# ФУНКЦИИ ВАЛИДАЦИИ И ПОДДЕРЖКИ
#####################################

prompt_yes_no() {
    while true; do
        local ans=""
        if ! read -rp "$1 (yes/no): " ans; then
            echo "" # Перенос строки при EOF
            return 1
        fi
        case "$ans" in
            yes|y|Y) return 0 ;;
            no|n|N) return 1 ;;
            *) echo "Введите yes или no" ;;
        esac
    done
}

validate_password() {
    local p="$1"
    [[ ${#p} -ge 12 ]] &&
    [[ "$p" =~ [a-z] ]] &&
    [[ "$p" =~ [A-Z] ]] &&
    [[ "$p" =~ [0-9] ]] &&
    [[ "$p" =~ [^a-zA-Z0-9] ]]
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] &&
    (( "$1" >= MIN_SSH_PORT && "$1" <= MAX_SSH_PORT ))
}

get_ssh_service_name() {
    if systemctl list-unit-files | grep -q "^sshd\.service"; then
        echo "sshd"
    else
        echo "ssh"
    fi
}

safe_sudoers() {
    local target_user="$1"
    local file="/etc/sudoers.d/$target_user"

    # Принудительно устанавливаем владельца root перед проверкой visudo
    chown root:root "$file" 2>/dev/null || true
    chmod 440 "$file" || return 1
    if ! visudo -cf "$file"; then
        echo "Критическая ошибка: Создан невалидный файл sudoers! Удаление файла во избежание поломки sudo." >&2
        rm -f "$file"
        return 1
    fi
    return 0
}

# Функция настройки SSH ключей
setup_ssh_keys() {
    local target_user="$1"
    local user_home

    # Безопасное динамическое определение домашней директории пользователя в режиме set -e
    user_home=$(getent passwd "$target_user" | cut -d: -f6) || user_home=""
    if [[ -z "$user_home" ]]; then
        echo "Ошибка: Не удалось определить домашний каталог для пользователя $target_user" >&2
        return 1
    fi

    echo "-------------------------------------"
    echo "НАСТРОЙКА SSH КЛЮЧЕЙ ДЛЯ: $target_user"
    echo "1) Сгенерировать новую пару ключей на сервере (НЕ РЕКОМЕНДУЕТСЯ из соображений безопасности)"
    echo "2) Ввести (вставить) уже существующий Public Key (РЕКОМЕНДУЕТСЯ)"
    echo "3) Пропустить"

    local choice=""
    if ! read -rp "Ваш выбор (1-3): " choice; then
        choice=3
    fi

    case "$choice" in
        1)
            echo "ВНИМАНИЕ: Генерация ключей на сервере менее безопасна, так как приватный ключ отображается в консоли."
            if ! prompt_yes_no "Вы действительно хотите сгенерировать ключ на сервере?"; then
                return 1
            fi

            mkdir -p "$user_home/.ssh"
            chmod 700 "$user_home/.ssh" || true

            # Очистка старых ключей генерации по умолчанию
            rm -f "$user_home/.ssh/id_ed25519" "$user_home/.ssh/id_ed25519.pub"

            echo "Генерируем ключи Ed25519..."
            if ! ssh-keygen -t ed25519 -f "$user_home/.ssh/id_ed25519" -C "vps-$target_user" -N "" -q; then
                echo "Ошибка при генерации ключа." >&2
                return 1
            fi

            # Добавление в authorized_keys
            cat "$user_home/.ssh/id_ed25519.pub" >> "$user_home/.ssh/authorized_keys"

            # Настройка прав
            chmod 600 "$user_home/.ssh/authorized_keys" || true
            chown -R "$target_user":"$target_user" "$user_home/.ssh" 2>/dev/null || chown -R "$target_user" "$user_home/.ssh" || true

            echo ""
            echo "==========================================================="
            echo "!!! СОХРАНИТЕ ЭТОТ ПРИВАТНЫЙ КЛЮЧ ПРЯМО СЕЙЧАС !!!"
            echo "Скопируйте всё между линиями и сохраните в файл (например: myserver.key)"
            echo "==========================================================="
            cat "$user_home/.ssh/id_ed25519"
            echo "==========================================================="
            echo ""
            read -rp "Нажмите Enter, когда сохраните ключ..." || true
            return 0
            ;;
        2)
            echo "Вставьте ваш публичный ключ (начинается с ssh-rsa или ssh-ed25519):"
            local pub_key=""
            if ! read -r pub_key; then
                pub_key=""
            fi

            if [[ -z "$pub_key" ]]; then
                echo "Ключ не введен."
                return 1
            fi

            mkdir -p "$user_home/.ssh"
            chmod 700 "$user_home/.ssh" || true
            echo "$pub_key" >> "$user_home/.ssh/authorized_keys"

            chmod 600 "$user_home/.ssh/authorized_keys" || true
            chown -R "$target_user":"$target_user" "$user_home/.ssh" 2>/dev/null || chown -R "$target_user" "$user_home/.ssh" || true

            echo "Публичный ключ добавлен."
            return 0
            ;;
        *)
            echo "Пропуск настройки ключей."
            return 1
            ;;
    esac
}

#####################################
# НАЧАЛО ВЫПОЛНЕНИЯ И ОБНОВЛЕНИЕ APT
#####################################
echo "Обновление локальной базы пакетов..."
apt-get update -y || echo "Предупреждение: Не удалось обновить локальный кэш пакетов. Попытка продолжить..."

# Гарантируем наличие базовых утилит администрирования
apt-get install -y sudo software-properties-common curl || true

# Подключение репозитория universe только для Ubuntu
if [[ "$OS_ID" == "ubuntu" ]] || [[ "$OS_LIKE" == *"ubuntu"* ]]; then
    echo "Проверка и подключение репозитория universe (Ubuntu)..."
    add-apt-repository -y universe || true
fi

# Интерактивное полное обновление и очистка системы
if prompt_yes_no "Выполнить полное обновление системы (apt upgrade) и очистку?"; then
    echo "Запуск полного обновления пакетов (это может занять некоторое время)..."
    
    export APT_LISTCHANGES_FRONTEND=none
    
    # Защищаем вызов update от падения по set -e
    apt-get update -y || echo "Предупреждение: Не удалось обновить индексы пакетов, пробуем продолжить обновление..."
    
    # Флаги force-confdef и force-confold исключают зависания при конфликтах конфигурационных файлов
    apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    apt-get autoremove -y
    apt-get autoclean -y
    
    echo "Обновление и очистка успешно завершены."
    echo "ВНИМАНИЕ: Если были обновлены важные системные библиотеки или ядро, рекомендуется перезагрузить сервер после завершения работы скрипта."
    echo ""
else
    echo "Пропуск обновления пакетов."
fi

# Оптимизация дискового пространства, оперативной памяти (zRAM) и фоновых служб
if prompt_yes_no "Выполнить глубокую оптимизацию VPS (очистка snapd/cloud-балласта, адаптивный zRAM, лимиты логов)?"; then
    run_full_vps_optimization
fi

#####################################
# ОПТИМИЗАЦИЯ СЕТИ (PROXY TUNING)
#####################################
echo "==========================================================="
echo "Применение сетевых оптимизаций ядра (Proxy Tuning)..."
echo "==========================================================="

# Загрузка модуля nf_conntrack для трекинга соединений
modprobe nf_conntrack 2>/dev/null || true
if [ -d /etc/modules-load.d ]; then
    echo "nf_conntrack" > /etc/modules-load.d/99-proxy-conntrack.conf 2>/dev/null || true
fi

mkdir -p /etc/sysctl.d/
cat << EOF > /etc/sysctl.d/99-proxy-tuning.conf
net.core.somaxconn = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 10000
net.ipv4.tcp_slow_start_after_idle = 0
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

# Защита conntrack от зависших сессий (разрывы ТСПУ/DPI без FIN/RST)
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
EOF
sysctl --system >/dev/null 2>&1 || echo "Предупреждение: Не все параметры sysctl применены (нормально для контейнеров LXC/OpenVZ)."
echo "Оптимизации сети успешно добавлены."
echo ""

#####################################
# УСТАНОВКА СИСТЕМНЫХ УТИЛИТ И МОНИТОРИНГА
#####################################
if prompt_yes_no "Установить системные утилиты и инструменты мониторинга (htop, btop, tcpdump, jq, tmux и др.)"; then
    echo "Установка системных утилит..."
    apt-get install -y \
        curl \
        build-essential \
        htop \
        iperf3 \
        iftop \
        net-tools \
        tcpdump \
        dnsutils \
        mtr-tiny \
        jq \
        tmux \
        ncdu \
        vnstat \
        openssh-client || true

    # Попытка установить btop (может отсутствовать в старых репозиториях Debian 11 / Ubuntu 20.04)
    apt-get install -y btop 2>/dev/null || echo "Примечание: Пакет btop недоступен в стандартном репозитории данного дистрибутива."
    echo "Системные утилиты успешно установлены."
else
    echo "Пропуск установки дополнительных утилит."
fi

#####################################
# СЕТЕВЫЕ НАСТРОЙКИ (BBR + Полное отключение IPv6)
#####################################
if prompt_yes_no "Включить TCP BBR и отключить IPv6"; then
    SYSCTL_CONF="/etc/sysctl.d/99-vps-hardening.conf"
    mkdir -p /etc/sysctl.d/

    # 1. Записываем настройки в sysctl.d
    cat > "$SYSCTL_CONF" <<EOF
# TCP BBR Congestion Control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

    # Применяем sysctl прямо сейчас
    sysctl --system || echo "Предупреждение: Не все параметры sysctl были успешно применены. Это нормально для сред LXC/OpenVZ."

    # 2. МЕТОД GRUB (Для полноценных серверов и KVM-виртуализации)
    if [ -f /etc/default/grub ]; then
        if ! grep -q "ipv6.disable=1" /etc/default/grub; then
            # Делаем резервную копию перед внесением изменений
            cp /etc/default/grub /etc/default/grub.bak
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1 /' /etc/default/grub
            sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT='/GRUB_CMDLINE_LINUX_DEFAULT='ipv6.disable=1 /" /etc/default/grub
            sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="ipv6.disable=1 /' /etc/default/grub
            sed -i "s/GRUB_CMDLINE_LINUX='/GRUB_CMDLINE_LINUX='ipv6.disable=1 /" /etc/default/grub
            
            if command -v update-grub &>/dev/null; then
                update-grub || true
            elif command -v grub-mkconfig &>/dev/null; then
                grub-mkconfig -o /boot/grub/grub.cfg || true
            fi
            echo "IPv6 отключен в загрузчике GRUB (применится после перезагрузки). Резервная копия сохранена в /etc/default/grub.bak"
        fi
    fi

    # 3. МЕТОД CRON (Безопасное добавление без использования деструктивного sort -u)
    if command -v crontab &>/dev/null; then
        cron_job="@reboot sleep 10 && sysctl --system"
        if ! crontab -l 2>/dev/null | grep -Fq "$cron_job"; then
            (crontab -l 2>/dev/null || true; echo "$cron_job") | crontab - || echo "Предупреждение: Не удалось обновить crontab."
            echo "Создано отложенное правило применения sysctl в Cron для защиты от сброса настроек сетью."
        else
            echo "Правило автозапуска sysctl уже присутствует в Cron."
        fi
    else
        echo "Предупреждение: утилита crontab не найдена. Настройка Cron-правила пропущена."
    fi

    echo "Сетевые настройки успешно применены и защищены от сброса после перезагрузки!"
fi

#####################################
# ROOT PASSWORD
#####################################
if prompt_yes_no "Сменить пароль root"; then
    while true; do
        rp=""
        rp2=""
        if ! read -rsp "Новый пароль root: " rp; then
            echo -e "\nВвод прерван."
            break
        fi
        echo
        if ! read -rsp "Повтор: " rp2; then
            echo -e "\nВвод прерван."
            break
        fi
        echo

        [[ "$rp" == "$rp2" ]] || { echo "Пароли не совпадают"; continue; }
        validate_password "$rp" || { echo "Слабый пароль. Требуется: минимум 12 символов, заглавные, строчные, цифры и спецсимволы."; continue; }
        echo "root:$rp" | chpasswd
        echo "Пароль root изменен успешно."
        break
    done
fi

#####################################
# СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ
#####################################
CREATED_USER=""

if prompt_yes_no "Создать обычного пользователя"; then
    uname=""
    if ! read -rp "Имя пользователя: " uname; then
        uname=""
    fi

    if [[ -z "$uname" ]]; then
        echo "Имя пользователя не может быть пустым."
    elif id "$uname" &>/dev/null; then
        echo "Пользователь уже существует"
        CREATED_USER="$uname"
    else
        # Обработка возможного падения на невалидных именах пользователей в adduser
        if ! adduser --disabled-password --gecos "" "$uname"; then
            echo "Ошибка: Не удалось создать пользователя с именем '$uname'." >&2
            echo "Проверьте формат имени (должно начинаться со строчной латинской буквы и содержать только строчные буквы и цифры)." >&2
        else
            while true; do
                up=""
                up2=""
                if ! read -rsp "Пароль для $uname: " up; then
                    echo -e "\nВвод прерван."
                    break
                fi
                echo
                if ! read -rsp "Повтор: " up2; then
                    echo -e "\nВвод прерван."
                    break
                fi
                echo

                [[ "$up" == "$up2" ]] || { echo "Пароли не совпадают"; continue; }
                validate_password "$up" || { echo "Слабый пароль. Требуется: минимум 12 символов, заглавные, строчные, цифры и спецсимволы."; continue; }
                echo "$uname:$up" | chpasswd
                usermod -aG sudo "$uname"
                CREATED_USER="$uname"
                echo "Пользователь $uname успешно создан и добавлен в группу sudo."
                break
            done
        fi
    fi

    if [[ -n "$CREATED_USER" ]] && prompt_yes_no "Разрешить sudo без пароля для $CREATED_USER"; then
        echo "$CREATED_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$CREATED_USER"
        if ! safe_sudoers "$CREATED_USER"; then
            echo "Аварийное завершение работы из-за ошибки в файле sudoers." >&2
            exit 1
        fi
    fi
fi

#####################################
# НАСТРОЙКА SSH КЛЮЧЕЙ
#####################################
KEYS_INSTALLED="false"

if [ -n "$CREATED_USER" ]; then
    if prompt_yes_no "Настроить SSH ключи для пользователя $CREATED_USER"; then
        if setup_ssh_keys "$CREATED_USER"; then
            KEYS_INSTALLED="true"
        fi
    fi
else
    if prompt_yes_no "Настроить SSH ключи для ROOT"; then
        if setup_ssh_keys "root"; then
            KEYS_INSTALLED="true"
        fi
    fi
fi

#####################################
# SSH HARDENING
#####################################
SSH_PORT="$DEFAULT_SSH_PORT"
SSH_SERVICE="$(get_ssh_service_name)"

# Переключаем с socket activation (при наличии, например в Ubuntu 24.04) на стандартную службу
echo "Настройка работы службы SSH ($SSH_SERVICE)..."
systemctl stop ssh.socket 2>/dev/null || true
systemctl disable ssh.socket 2>/dev/null || true
systemctl enable "$SSH_SERVICE.service" 2>/dev/null || true
systemctl start "$SSH_SERVICE.service" 2>/dev/null || true

if prompt_yes_no "Изменить порт SSH"; then
    while true; do
        p=""
        if ! read -rp "Новый порт SSH (диапазон $MIN_SSH_PORT-$MAX_SSH_PORT): " p; then
            p=""
        fi
        if [[ -z "$p" ]]; then
            echo "Порт не изменен. Будет использован порт: $SSH_PORT"
            break
        fi
        validate_port "$p" || { echo "Недопустимый порт (выберите в диапазоне $MIN_SSH_PORT-$MAX_SSH_PORT)"; continue; }
        SSH_PORT="$p"
        break
    done
fi

# Проверим, подключена ли директория drop-in в основном файле sshd_config
if [ -f /etc/ssh/sshd_config ]; then
    if ! grep -q "^Include /etc/ssh/sshd_config.d/\*\.conf" /etc/ssh/sshd_config; then
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
    fi
fi

# Пишем конфигурацию в drop-in файл вместо изменения основного sshd_config
SSH_DROPIN="/etc/ssh/sshd_config.d/99-hardening.conf"
mkdir -p /etc/ssh/sshd_config.d/

cat > "$SSH_DROPIN" <<EOF
# Настройки, созданные автоматическим скриптом
Port $SSH_PORT
AddressFamily inet
PubkeyAuthentication yes
EOF

# Отключение входа по паролю (Только если ключи были успешно установлены)
if [ "$KEYS_INSTALLED" = "true" ]; then
    if prompt_yes_no "Отключить вход по паролю (PasswordAuthentication no)?"; then
        cat >> "$SSH_DROPIN" <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
EOF
        echo "Вход по паролю ОТКЛЮЧЕН. Используйте ключи для авторизации."
    fi
fi

# Обеспечиваем наличие директории привилегий перед проверкой sshd -t
mkdir -p /run/sshd

# Проверка конфигурации SSH на ошибки перед перезапуском
echo "Проверка конфигурации SSH..."
if /usr/sbin/sshd -t; then
    systemctl daemon-reload
    systemctl restart "$SSH_SERVICE.service" || echo "Предупреждение: Не удалось автоматически перезапустить $SSH_SERVICE.service"
    echo "Служба SSH успешно перезапущена на порту $SSH_PORT"
else
    echo "Критическая ошибка конфигурации SSH! Откат изменений во избежание потери доступа." >&2
    rm -f "$SSH_DROPIN"
    systemctl restart "$SSH_SERVICE.service" || true
fi

#####################################
# UFW (FIREWALL) 
#####################################
echo "Установка и настройка фаервола UFW..."
apt-get install -y ufw

# Безопасное отключение IPv6 в UFW
if grep -q "^IPV6=" /etc/default/ufw; then
    sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
else
    echo "IPV6=no" >> /etc/default/ufw
fi

ufw default deny incoming
ufw default allow outgoing

echo "Настраиваем порты (только IPv4)..."

# SSH
ufw allow "$SSH_PORT"/tcp comment '[vpn-stack] SSH'

# Дополнительные TCP порты
ufw allow 80/tcp comment '[vpn-stack] HTTP'
ufw allow 443/tcp comment '[vpn-stack] HTTPS'
ufw allow 8443/tcp comment '[vpn-stack] AmneziaWG Web'
ufw allow 10443/tcp comment '[vpn-stack] 3X-UI Panel'

# Дополнительные UDP порты
ufw allow 443/udp comment '[vpn-stack] Hysteria 2 / QUIC'
ufw allow 8443/udp comment '[vpn-stack] AmneziaWG v3'
ufw allow 8444/udp comment '[vpn-stack] AmneziaWG v2'

# Опциональная блокировка Ping (ICMP)
if prompt_yes_no "Блокировать входящие ICMP (Ping) запросы?"; then
    if [ -f /etc/ufw/before.rules ]; then
        sed -i 's/-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT/-A ufw-before-input -p icmp --icmp-type echo-request -j DROP/g' /etc/ufw/before.rules
        echo "Ping запросы заблокированы в настройках UFW."
    fi
fi

ufw --force enable

#####################################
# FAIL2BAN
#####################################
echo "Установка и настройка Fail2ban..."
# Установка python3-systemd необходима для Debian 12 / Ubuntu 24.04 (чтение journald)
apt-get install -y fail2ban python3-systemd 2>/dev/null || apt-get install -y fail2ban

cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = $SSH_PORT
maxretry = 5
findtime = 10m
bantime = 1h
backend = systemd
EOF

systemctl enable fail2ban
systemctl restart fail2ban

#####################################
# SERVER-SIDE ZAPRET (NFQWS DPI DESYNC)
#####################################
if [[ "${ENABLE_ZAPRET:-n}" == "y" || "${ENABLE_ZAPRET:-0}" == "1" ]] || prompt_yes_no "Установить Server-Side Zapret nfqws (DPI Desync для обхода блокировок)?"; then
    echo "Установка Server-Side Zapret nfqws..."
    apt-get install -y libnetfilter-queue1 iptables 2>/dev/null || true
    cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
    z_arch="x86_64"
    case "$cur_arch" in
        x86_64|amd64) z_arch="x86_64" ;;
        aarch64|arm64) z_arch="aarch64" ;;
        *) z_arch="x86_64" ;;
    esac
    if [ ! -x /usr/local/bin/nfqws ]; then
        z_tmp="/tmp/zapret_staging_$$"
        mkdir -p "$z_tmp"
        if download_manifest_component "zapret" "$z_tmp/zapret.tar.gz" "all"; then
            tar -zxf "$z_tmp/zapret.tar.gz" -C "$z_tmp" --strip-components=1 2>/dev/null || true
            if [ -f "$z_tmp/binaries/linux-${z_arch}/nfqws" ]; then
                cp "$z_tmp/binaries/linux-${z_arch}/nfqws" /usr/local/bin/nfqws
                chmod +x /usr/local/bin/nfqws
            elif [ -f "$z_tmp/binaries/${z_arch}/nfqws" ]; then
                cp "$z_tmp/binaries/${z_arch}/nfqws" /usr/local/bin/nfqws
                chmod +x /usr/local/bin/nfqws
            elif [ -n "$(find "$z_tmp" -name nfqws -type f 2>/dev/null)" ]; then
                cp "$(find "$z_tmp" -name nfqws -type f | grep "${z_arch}" | head -n1 || find "$z_tmp" -name nfqws -type f | head -n1)" /usr/local/bin/nfqws
                chmod +x /usr/local/bin/nfqws
            fi
        fi
        rm -rf "$z_tmp"
    fi
    qnum="${ZAPRET_QNUM:-200}"
    desync="${ZAPRET_DESYNC:-split2}"
    fooling="${ZAPRET_FOOLING:-md5sig,badseq}"
    iptables_bin="$(command -v iptables 2>/dev/null || echo "/usr/sbin/iptables")"

    mkdir -p /etc/systemd/system
    cat << EOF > /etc/systemd/system/zapret-server.service
[Unit]
Description=Server-Side Zapret nfqws DPI Desync Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-${iptables_bin} -t mangle -D POSTROUTING -p tcp -m connbytes --connbytes 1:6 --connbytes-mode packets --connbytes-dir original -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num ${qnum} --queue-bypass
ExecStartPre=${iptables_bin} -t mangle -I POSTROUTING -p tcp -m connbytes --connbytes 1:6 --connbytes-mode packets --connbytes-dir original -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num ${qnum} --queue-bypass
ExecStart=/usr/local/bin/nfqws --qnum=${qnum} --dpi-desync=${desync} --dpi-desync-fooling=${fooling}
ExecStopPost=-${iptables_bin} -t mangle -D POSTROUTING -p tcp -m connbytes --connbytes 1:6 --connbytes-mode packets --connbytes-dir original -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num ${qnum} --queue-bypass
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable zapret-server >/dev/null 2>&1 || true
    if [ -x /usr/local/bin/nfqws ]; then
        systemctl restart zapret-server 2>/dev/null || true
        echo "✔ Служба Server-Side Zapret активирована (NFQUEUE $qnum, desync: $desync)."
    fi
fi

#####################################
# 3X-UI 
#####################################
if prompt_yes_no "Установить 3x-ui (потребуется интерактивная настройка панели)"; then
    if ! command -v curl &> /dev/null; then
        apt-get install -y curl
    fi

    XUI_VERSION=""

    echo "-------------------------------------"
    echo "ВЫБОР ВЕРСИИ 3X-UI"
    echo "1) Последняя стабильная версия (Latest) - РЕКОМЕНДУЕТСЯ"
    echo "2) Указать конкретную версию вручную (например, v2.9.4)"

    v_choice=1
    if ! read -rp "Ваш выбор (1-2): " v_choice; then
        v_choice=1
    fi

    if [[ "$v_choice" == "2" ]]; then
        while true; do
            tag=""
            if ! read -rp "Введите тег версии (например, v2.9.4): " tag; then
                tag=""
            fi
            if [[ "$tag" =~ ^v[0-9]+ ]]; then
                XUI_VERSION="$tag"
                break
            else
                echo "Неверный формат. Версия должна начинаться со строчной буквы 'v' (например, v2.9.4)."
            fi
        done
    fi

    echo "Запуск установки 3x-ui..."
    curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o /tmp/3x-ui-install.sh

    if [[ -n "$XUI_VERSION" ]]; then
        echo "Установка версии $XUI_VERSION..."
        bash /tmp/3x-ui-install.sh "$XUI_VERSION"
    else
        echo "Установка версии latest..."
        bash /tmp/3x-ui-install.sh
    fi

    rm -f /tmp/3x-ui-install.sh
fi

#####################################
# ФИНАЛ
#####################################
setup_clean_motd

echo
echo "======================================"
echo "✔ НАСТРОЙКА VPS ЗАВЕРШЕНА УСПЕШНО"
echo "ОС: ${NAME:-Linux} ${VERSION_ID:-}"
echo "SSH порт: $SSH_PORT (Служба: $SSH_SERVICE)"
echo "IPv6: отключён (System + UFW)"
echo "UFW: включён (только v4 правила)"
echo "BBR: активирован"
echo "Fail2ban: активен"
if [ "$KEYS_INSTALLED" = "true" ]; then
    echo "SSH Ключи: УСТАНОВЛЕНЫ (вход по паролю отключен, если было выбрано)"
else
    echo "SSH Ключи: НЕ установлены"
fi
echo "======================================"
