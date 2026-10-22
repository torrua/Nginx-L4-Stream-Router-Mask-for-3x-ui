#!/usr/bin/env bash
# ==============================================================================
#  UNINSTALL ENTRYPOINT (v9.4.0)
# ==============================================================================
#  Standalone tool to revert server to initial state using initial snapshot.
# ==============================================================================

set -euo pipefail

# Terminal Colors & Styles
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
MAGENTA=$'\033[0;35m'
CYAN=$'\033[0;36m'
WHITE=$'\033[1;37m'
DIM=$'\033[2m'
BOLD=$'\033[1m'
NC=$'\033[0m'
RESET=$'\033[0m'

# Status Symbols
CHECK="✔"
CROSS="✖"
ARROW="➜"
STAR="★"
INFO="ℹ"
LOCK="🔒"
SHIELD="🛡"
# Standard Logging Functions
log()  { echo -e "  ${CYAN}[+]${NC} $*"; }
ok()   { echo -e "  ${GREEN}${CHECK:-✔}${NC} $*"; }
warn() { echo -e "  ${YELLOW}[!]${NC} $*"; }
die()  { echo -e "  ${RED}${CROSS:-✖} $*${NC}" >&2; exit 1; }
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
#  SNAPSHOT ENGINE: Initial System State Capture & Verification
# ==============================================================================
#  Creates a secure, immutable snapshot of server packages, services, SSH config,
#  firewall rules, and network tuning before any installer modifications.
# ==============================================================================

SNAPSHOT_DIR="${SNAPSHOT_DIR:-${TARGET_ROOT:-}/var/backups/server_setup}"
SNAPSHOT_ARCHIVE="${SNAPSHOT_ARCHIVE:-${SNAPSHOT_DIR}/initial_state.tar.gz}"
SNAPSHOT_MANIFEST="${SNAPSHOT_MANIFEST:-${SNAPSHOT_DIR}/snapshot_manifest.json}"

create_initial_state_snapshot() {
    local target_root="${TARGET_ROOT:-}"

    # 1. Защита от повторной перезаписи: если снимок уже сделан, сохраняем его
    if [ -f "$SNAPSHOT_ARCHIVE" ] && [ -f "$SNAPSHOT_MANIFEST" ]; then
        if [ -s "$SNAPSHOT_ARCHIVE" ] && [ -s "$SNAPSHOT_MANIFEST" ]; then
            log "Исходный снимок состояния сервера уже существует: $SNAPSHOT_MANIFEST (сохранен без изменений)."
            return 0
        fi
    fi

    log "Создание снимка исходного состояния сервера перед установкой..."
    local tmp_dir
    tmp_dir="$(mktemp -d 2>/dev/null || echo "/tmp/server_snapshot_$$")"
    mkdir -p "$tmp_dir" 2>/dev/null || true

    # 2. Фиксация установленных пакетов
    if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -f '${binary:Package}\n' -W > "$tmp_dir/packages_installed.list" 2>/dev/null || true
    elif command -v rpm >/dev/null 2>&1; then
        rpm -qa --qf '%{NAME}\n' > "$tmp_dir/packages_installed.list" 2>/dev/null || true
    else
        : > "$tmp_dir/packages_installed.list"
    fi

    # 3. Фиксация состояния служб systemd
    if command -v systemctl >/dev/null 2>&1; then
        systemctl list-unit-files --state=enabled --no-legend 2>/dev/null | awk '{print $1}' > "$tmp_dir/services_enabled.list" || true
        systemctl list-units --state=running --no-legend 2>/dev/null | awk '{print $1}' > "$tmp_dir/services_running.list" || true
    else
        : > "$tmp_dir/services_enabled.list"
        : > "$tmp_dir/services_running.list"
    fi

    # 4. Фиксация SSH конфигурации и активного порта
    local active_ssh_port=22
    if command -v detect_active_ssh_port >/dev/null 2>&1; then
        active_ssh_port="$(detect_active_ssh_port)"
    elif [ -n "${SSH_PORT:-}" ]; then
        active_ssh_port="${SSH_PORT}"
    fi
    echo "$active_ssh_port" > "$tmp_dir/ssh_port.txt"

    if [ -d "${target_root}/etc/ssh" ]; then
        tar --force-local -czf "$tmp_dir/ssh_config.tar.gz" -C "${target_root}/etc" "ssh" 2>/dev/null || true
    fi

    # 5. Фиксация состояния Firewall (UFW & iptables)
    mkdir -p "$tmp_dir/firewall"
    if [ -d "${target_root}/etc/ufw" ]; then
        tar --force-local -czf "$tmp_dir/firewall/ufw_config.tar.gz" -C "${target_root}/etc" "ufw" 2>/dev/null || true
    fi
    if command -v ufw >/dev/null 2>&1; then
        ufw status verbose > "$tmp_dir/firewall/ufw_status.txt" 2>/dev/null || true
    fi
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > "$tmp_dir/firewall/iptables.rules" 2>/dev/null || true
    fi
    if command -v ip6tables-save >/dev/null 2>&1; then
        ip6tables-save > "$tmp_dir/firewall/ip6tables.rules" 2>/dev/null || true
    fi

    # 6. Фиксация сетевых параметров sysctl и limits
    mkdir -p "$tmp_dir/sysctl"
    [ -f "${target_root}/etc/sysctl.conf" ] && cp "${target_root}/etc/sysctl.conf" "$tmp_dir/sysctl/" 2>/dev/null || true
    [ -d "${target_root}/etc/sysctl.d" ] && tar --force-local -czf "$tmp_dir/sysctl/sysctl.d.tar.gz" -C "${target_root}/etc" "sysctl.d" 2>/dev/null || true
    [ -d "${target_root}/etc/security/limits.d" ] && tar --force-local -czf "$tmp_dir/sysctl/limits.d.tar.gz" -C "${target_root}/etc/security" "limits.d" 2>/dev/null || true

    # 7. Фиксация предсуществования Nginx и Fail2ban
    local nginx_preexisted=0
    local fail2ban_preexisted=0
    local agh_preexisted=0
    local xui_preexisted=0

    if command -v nginx >/dev/null 2>&1 && [ -d "${target_root}/etc/nginx" ]; then
        nginx_preexisted=1
        tar --force-local -czf "$tmp_dir/nginx_config.tar.gz" -C "${target_root}/etc" "nginx" 2>/dev/null || true
    fi
    if command -v fail2ban-client >/dev/null 2>&1 && [ -d "${target_root}/etc/fail2ban" ]; then
        fail2ban_preexisted=1
        tar --force-local -czf "$tmp_dir/fail2ban_config.tar.gz" -C "${target_root}/etc" "fail2ban" 2>/dev/null || true
    fi
    if [ -f "${target_root}/opt/AdGuardHome/AdGuardHome" ] || [ -d "${target_root}/opt/AdGuardHome" ]; then
        agh_preexisted=1
    fi
    if [ -f "${target_root}/etc/x-ui/x-ui.db" ] || [ -f "${target_root}/usr/local/x-ui/bin/x-ui.db" ]; then
        xui_preexisted=1
    fi

    # 8. Упаковка архива снимка
    mkdir -p "$SNAPSHOT_DIR"
    chmod 700 "$SNAPSHOT_DIR" 2>/dev/null || true
    if ! tar --force-local -czf "$SNAPSHOT_ARCHIVE" -C "$tmp_dir" . 2>/dev/null; then
        rm -rf "$tmp_dir" 2>/dev/null || true
        warn "Не удалось упаковать архив снимка $SNAPSHOT_ARCHIVE."
        return 1
    fi
    chmod 600 "$SNAPSHOT_ARCHIVE" 2>/dev/null || true

    # 9. Расчет контрольной суммы архива
    local archive_sha256=""
    if command -v sha256sum >/dev/null 2>&1; then
        archive_sha256="$(sha256sum "$SNAPSHOT_ARCHIVE" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        archive_sha256="$(shasum -a 256 "$SNAPSHOT_ARCHIVE" | awk '{print $1}')"
    fi

    # 10. Формирование манифеста
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")"
    local os_id os_codename k_rel
    os_id="$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "linux")"
    os_codename="$(lsb_release -cs 2>/dev/null || echo "generic")"
    k_rel="$(uname -r 2>/dev/null || echo "unknown")"

    cat << EOF > "$SNAPSHOT_MANIFEST"
{
  "version": "1.0",
  "timestamp": "$ts",
  "os_id": "$os_id",
  "os_codename": "$os_codename",
  "kernel_release": "$k_rel",
  "ssh_active_port": $active_ssh_port,
  "nginx_preexisted": $nginx_preexisted,
  "fail2ban_preexisted": $fail2ban_preexisted,
  "adguard_preexisted": $agh_preexisted,
  "xui_preexisted": $xui_preexisted,
  "archive_file": "initial_state.tar.gz",
  "archive_sha256": "$archive_sha256"
}
EOF
    chmod 600 "$SNAPSHOT_MANIFEST" 2>/dev/null || true
    rm -rf "$tmp_dir" 2>/dev/null || true

    ok "Снимок исходного состояния сервера успешно сохранен в $SNAPSHOT_DIR"
    return 0
}

verify_initial_state_snapshot() {
    if [ ! -f "$SNAPSHOT_ARCHIVE" ] || [ ! -f "$SNAPSHOT_MANIFEST" ]; then
        return 1
    fi
    if [ ! -s "$SNAPSHOT_ARCHIVE" ] || [ ! -s "$SNAPSHOT_MANIFEST" ]; then
        return 1
    fi
    # Валидация gzip-целостности
    tar --force-local -tzf "$SNAPSHOT_ARCHIVE" >/dev/null 2>&1 || return 1
    return 0
}
#!/usr/bin/env bash
# ==============================================================================
#  UNINSTALL & ROLLBACK ENGINE
# ==============================================================================
#  Safely tears down VPN/proxy stack, restores initial network, SSH, firewall,
#  and system settings from snapshot with strict Anti-Lockout protection.
# ==============================================================================

# Terminal Colors & Styles
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
MAGENTA=$'\033[0;35m'
CYAN=$'\033[0;36m'
WHITE=$'\033[1;37m'
DIM=$'\033[2m'
BOLD=$'\033[1m'
NC=$'\033[0m'
RESET=$'\033[0m'

# Status Symbols
CHECK="✔"
CROSS="✖"
ARROW="➜"
STAR="★"
INFO="ℹ"
LOCK="🔒"
SHIELD="🛡"
# Standard Logging Functions
log()  { echo -e "  ${CYAN}[+]${NC} $*"; }
ok()   { echo -e "  ${GREEN}${CHECK:-✔}${NC} $*"; }
warn() { echo -e "  ${YELLOW}[!]${NC} $*"; }
die()  { echo -e "  ${RED}${CROSS:-✖} $*${NC}" >&2; exit 1; }
#!/usr/bin/env bash
# ==============================================================================
#  SNAPSHOT ENGINE: Initial System State Capture & Verification
# ==============================================================================
#  Creates a secure, immutable snapshot of server packages, services, SSH config,
#  firewall rules, and network tuning before any installer modifications.
# ==============================================================================

SNAPSHOT_DIR="${SNAPSHOT_DIR:-${TARGET_ROOT:-}/var/backups/server_setup}"
SNAPSHOT_ARCHIVE="${SNAPSHOT_ARCHIVE:-${SNAPSHOT_DIR}/initial_state.tar.gz}"
SNAPSHOT_MANIFEST="${SNAPSHOT_MANIFEST:-${SNAPSHOT_DIR}/snapshot_manifest.json}"

create_initial_state_snapshot() {
    local target_root="${TARGET_ROOT:-}"

    # 1. Защита от повторной перезаписи: если снимок уже сделан, сохраняем его
    if [ -f "$SNAPSHOT_ARCHIVE" ] && [ -f "$SNAPSHOT_MANIFEST" ]; then
        if [ -s "$SNAPSHOT_ARCHIVE" ] && [ -s "$SNAPSHOT_MANIFEST" ]; then
            log "Исходный снимок состояния сервера уже существует: $SNAPSHOT_MANIFEST (сохранен без изменений)."
            return 0
        fi
    fi

    log "Создание снимка исходного состояния сервера перед установкой..."
    local tmp_dir
    tmp_dir="$(mktemp -d 2>/dev/null || echo "/tmp/server_snapshot_$$")"
    mkdir -p "$tmp_dir" 2>/dev/null || true

    # 2. Фиксация установленных пакетов
    if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -f '${binary:Package}\n' -W > "$tmp_dir/packages_installed.list" 2>/dev/null || true
    elif command -v rpm >/dev/null 2>&1; then
        rpm -qa --qf '%{NAME}\n' > "$tmp_dir/packages_installed.list" 2>/dev/null || true
    else
        : > "$tmp_dir/packages_installed.list"
    fi

    # 3. Фиксация состояния служб systemd
    if command -v systemctl >/dev/null 2>&1; then
        systemctl list-unit-files --state=enabled --no-legend 2>/dev/null | awk '{print $1}' > "$tmp_dir/services_enabled.list" || true
        systemctl list-units --state=running --no-legend 2>/dev/null | awk '{print $1}' > "$tmp_dir/services_running.list" || true
    else
        : > "$tmp_dir/services_enabled.list"
        : > "$tmp_dir/services_running.list"
    fi

    # 4. Фиксация SSH конфигурации и активного порта
    local active_ssh_port=22
    if command -v detect_active_ssh_port >/dev/null 2>&1; then
        active_ssh_port="$(detect_active_ssh_port)"
    elif [ -n "${SSH_PORT:-}" ]; then
        active_ssh_port="${SSH_PORT}"
    fi
    echo "$active_ssh_port" > "$tmp_dir/ssh_port.txt"

    if [ -d "${target_root}/etc/ssh" ]; then
        tar --force-local -czf "$tmp_dir/ssh_config.tar.gz" -C "${target_root}/etc" "ssh" 2>/dev/null || true
    fi

    # 5. Фиксация состояния Firewall (UFW & iptables)
    mkdir -p "$tmp_dir/firewall"
    if [ -d "${target_root}/etc/ufw" ]; then
        tar --force-local -czf "$tmp_dir/firewall/ufw_config.tar.gz" -C "${target_root}/etc" "ufw" 2>/dev/null || true
    fi
    if command -v ufw >/dev/null 2>&1; then
        ufw status verbose > "$tmp_dir/firewall/ufw_status.txt" 2>/dev/null || true
    fi
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > "$tmp_dir/firewall/iptables.rules" 2>/dev/null || true
    fi
    if command -v ip6tables-save >/dev/null 2>&1; then
        ip6tables-save > "$tmp_dir/firewall/ip6tables.rules" 2>/dev/null || true
    fi

    # 6. Фиксация сетевых параметров sysctl и limits
    mkdir -p "$tmp_dir/sysctl"
    [ -f "${target_root}/etc/sysctl.conf" ] && cp "${target_root}/etc/sysctl.conf" "$tmp_dir/sysctl/" 2>/dev/null || true
    [ -d "${target_root}/etc/sysctl.d" ] && tar --force-local -czf "$tmp_dir/sysctl/sysctl.d.tar.gz" -C "${target_root}/etc" "sysctl.d" 2>/dev/null || true
    [ -d "${target_root}/etc/security/limits.d" ] && tar --force-local -czf "$tmp_dir/sysctl/limits.d.tar.gz" -C "${target_root}/etc/security" "limits.d" 2>/dev/null || true

    # 7. Фиксация предсуществования Nginx и Fail2ban
    local nginx_preexisted=0
    local fail2ban_preexisted=0
    local agh_preexisted=0
    local xui_preexisted=0

    if command -v nginx >/dev/null 2>&1 && [ -d "${target_root}/etc/nginx" ]; then
        nginx_preexisted=1
        tar --force-local -czf "$tmp_dir/nginx_config.tar.gz" -C "${target_root}/etc" "nginx" 2>/dev/null || true
    fi
    if command -v fail2ban-client >/dev/null 2>&1 && [ -d "${target_root}/etc/fail2ban" ]; then
        fail2ban_preexisted=1
        tar --force-local -czf "$tmp_dir/fail2ban_config.tar.gz" -C "${target_root}/etc" "fail2ban" 2>/dev/null || true
    fi
    if [ -f "${target_root}/opt/AdGuardHome/AdGuardHome" ] || [ -d "${target_root}/opt/AdGuardHome" ]; then
        agh_preexisted=1
    fi
    if [ -f "${target_root}/etc/x-ui/x-ui.db" ] || [ -f "${target_root}/usr/local/x-ui/bin/x-ui.db" ]; then
        xui_preexisted=1
    fi

    # 8. Упаковка архива снимка
    mkdir -p "$SNAPSHOT_DIR"
    chmod 700 "$SNAPSHOT_DIR" 2>/dev/null || true
    if ! tar --force-local -czf "$SNAPSHOT_ARCHIVE" -C "$tmp_dir" . 2>/dev/null; then
        rm -rf "$tmp_dir" 2>/dev/null || true
        warn "Не удалось упаковать архив снимка $SNAPSHOT_ARCHIVE."
        return 1
    fi
    chmod 600 "$SNAPSHOT_ARCHIVE" 2>/dev/null || true

    # 9. Расчет контрольной суммы архива
    local archive_sha256=""
    if command -v sha256sum >/dev/null 2>&1; then
        archive_sha256="$(sha256sum "$SNAPSHOT_ARCHIVE" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        archive_sha256="$(shasum -a 256 "$SNAPSHOT_ARCHIVE" | awk '{print $1}')"
    fi

    # 10. Формирование манифеста
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")"
    local os_id os_codename k_rel
    os_id="$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "linux")"
    os_codename="$(lsb_release -cs 2>/dev/null || echo "generic")"
    k_rel="$(uname -r 2>/dev/null || echo "unknown")"

    cat << EOF > "$SNAPSHOT_MANIFEST"
{
  "version": "1.0",
  "timestamp": "$ts",
  "os_id": "$os_id",
  "os_codename": "$os_codename",
  "kernel_release": "$k_rel",
  "ssh_active_port": $active_ssh_port,
  "nginx_preexisted": $nginx_preexisted,
  "fail2ban_preexisted": $fail2ban_preexisted,
  "adguard_preexisted": $agh_preexisted,
  "xui_preexisted": $xui_preexisted,
  "archive_file": "initial_state.tar.gz",
  "archive_sha256": "$archive_sha256"
}
EOF
    chmod 600 "$SNAPSHOT_MANIFEST" 2>/dev/null || true
    rm -rf "$tmp_dir" 2>/dev/null || true

    ok "Снимок исходного состояния сервера успешно сохранен в $SNAPSHOT_DIR"
    return 0
}

verify_initial_state_snapshot() {
    if [ ! -f "$SNAPSHOT_ARCHIVE" ] || [ ! -f "$SNAPSHOT_MANIFEST" ]; then
        return 1
    fi
    if [ ! -s "$SNAPSHOT_ARCHIVE" ] || [ ! -s "$SNAPSHOT_MANIFEST" ]; then
        return 1
    fi
    # Валидация gzip-целостности
    tar --force-local -tzf "$SNAPSHOT_ARCHIVE" >/dev/null 2>&1 || return 1
    return 0
}

UNINSTALL_FORCE="${UNINSTALL_FORCE:-0}"
UNINSTALL_PURGE_PKGS="${UNINSTALL_PURGE_PKGS:-0}"
UNINSTALL_KEEP_CERTS="${UNINSTALL_KEEP_CERTS:-1}"
UNINSTALL_CERTS_EXPLICIT="${UNINSTALL_CERTS_EXPLICIT:-0}"

parse_manifest_field() {
    local field="$1"
    local manifest="${2:-$SNAPSHOT_MANIFEST}"
    if [ ! -f "$manifest" ]; then
        echo ""
        return
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import json, sys; d=json.load(open('$manifest')); print(d.get('$field', ''))" 2>/dev/null || true
    else
        grep "\"$field\":" "$manifest" 2>/dev/null | head -n1 | sed -E 's/.*:[[:space:]]*"?([^",]+)"?.*/\1/' || true
    fi
}

run_uninstall() {
    local target_root="${TARGET_ROOT:-}"
    local snap_dir="${SNAPSHOT_DIR:-${target_root}/var/backups/server_setup}"
    local manifest="${SNAPSHOT_MANIFEST:-${snap_dir}/snapshot_manifest.json}"
    local archive="${SNAPSHOT_ARCHIVE:-${snap_dir}/initial_state.tar.gz}"

    echo -e "\n${BOLD}${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${RED}║      МАСТЕР ПОЛНОГО УДАЛЕНИЯ И ОТКАТА СЕРВЕРА К ИСХОДНОМУ        ║${NC}"
    echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════════════════╝${NC}\n"

    local has_snapshot=0
    if [ -f "$manifest" ] && [ -f "$archive" ]; then
        has_snapshot=1
        ok "Обнаружен снимок исходного состояния сервера: $manifest"
    else
        warn "Снимок исходного состояния не найден ($manifest). Будет выполнена стандартная зачистка известных компонентов."
    fi

    # Чтение метаданных из снимка
    local orig_ssh_port=22
    local nginx_preexisted=0
    local fail2ban_preexisted=0
    local agh_preexisted=0
    local xui_preexisted=0

    if [ "$has_snapshot" -eq 1 ]; then
        orig_ssh_port="$(parse_manifest_field "ssh_active_port" "$manifest")"
        [ -n "$orig_ssh_port" ] || orig_ssh_port=22
        nginx_preexisted="$(parse_manifest_field "nginx_preexisted" "$manifest")"
        [ "$nginx_preexisted" = "1" ] || nginx_preexisted=0
        fail2ban_preexisted="$(parse_manifest_field "fail2ban_preexisted" "$manifest")"
        [ "$fail2ban_preexisted" = "1" ] || fail2ban_preexisted=0
        agh_preexisted="$(parse_manifest_field "adguard_preexisted" "$manifest")"
        [ "$agh_preexisted" = "1" ] || agh_preexisted=0
        xui_preexisted="$(parse_manifest_field "xui_preexisted" "$manifest")"
        [ "$xui_preexisted" = "1" ] || xui_preexisted=0
    fi

    echo -e "Будут выполнены следующие действия:"
    echo -e "  1. Остановка и отключение всех VPN/прокси служб (3X-UI, AWG, MASQUE, ShadowTLS, Naïve, DNSTT, Wstunnel, Zapret);"
    echo -e "  2. Удаление custom systemd юнитов и cron/timer задач;"
    echo -e "  3. Восстановление конфигурации Firewall (UFW) и очистка правил Port Hopping;"
    echo -e "  4. Восстановление конфигурации SSH (с проверкой sshd -t во избежание блокировки);"
    echo -e "  5. Удаление параметров оптимизации ядра sysctl и limits.d;"
    if [ "$nginx_preexisted" -eq 1 ]; then
        echo -e "  6. Восстановление исходной конфигурации Nginx (существовавшей до запуска скрипта);"
    else
        echo -e "  6. Полное удаление Nginx и очистка веб-маскировок;"
    fi
    echo -e "  7. Удаление конфигурационных и рабочих каталогов стека;\n"

    if [ "${UNINSTALL_FORCE:-0}" -ne 1 ]; then
        read -r -p "Вы уверены, что хотите продолжить? [y/N]: " confirm_uninstall
        if [[ ! "$confirm_uninstall" =~ ^[YyДд1] ]]; then
            echo -e "${YELLOW}Удаление отменено пользователем.${NC}"
            return 0
        fi

        # Интерактивный запрос по SSL-сертификатам Let's Encrypt
        if [ "${UNINSTALL_CERTS_EXPLICIT:-0}" -eq 0 ]; then
            echo ""
            echo -e "${CYAN}Управление SSL-сертификатами:${NC}"
            echo -e "  Сохранение сертификатов предотвращает исчерпание недельных лимитов Let's Encrypt при повторной настройке."
            read -r -p "Удалить выпущенные SSL-сертификаты (/etc/letsencrypt, /etc/ssl/acme, ~/.acme.sh)? [y/N]: " confirm_certs
            if [[ "$confirm_certs" =~ ^[YyДд1] ]]; then
                UNINSTALL_KEEP_CERTS=0
            else
                UNINSTALL_KEEP_CERTS=1
            fi
            echo ""
        fi
    fi

    log "Шаг 1/8: Остановка и отключение служб..."
    local services_to_stop=(
        "x-ui" "xray-geo-update.timer" "xray-geo-update.service"
        "awg-quick@awg0" "sing-box-masque" "shadow-tls" "wstunnel"
        "dnstt" "caddy-naive" "zapret"
    )
    [ "$agh_preexisted" -eq 0 ] && services_to_stop+=("AdGuardHome")
    [ "$fail2ban_preexisted" -eq 0 ] && services_to_stop+=("fail2ban")
    [ "$nginx_preexisted" -eq 0 ] && services_to_stop+=("nginx")

    for svc in "${services_to_stop[@]}"; do
        if command -v systemctl >/dev/null 2>&1; then
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
        fi
    done
    ok "Службы остановлены и отключены."

    log "Шаг 2/8: Удаление созданных systemd units и cron-задач..."
    local units_to_remove=(
        "${target_root}/etc/systemd/system/x-ui.service"
        "${target_root}/etc/systemd/system/xray-geo-update.service"
        "${target_root}/etc/systemd/system/xray-geo-update.timer"
        "${target_root}/etc/systemd/system/sing-box-masque.service"
        "${target_root}/etc/systemd/system/shadow-tls.service"
        "${target_root}/etc/systemd/system/wstunnel.service"
        "${target_root}/etc/systemd/system/dnstt.service"
        "${target_root}/etc/systemd/system/caddy-naive.service"
        "${target_root}/etc/systemd/system/mita.service"
        "${target_root}/etc/systemd/system/zapret.service"
        "${target_root}/etc/systemd/system/nginx.service.d/override.conf"
    )
    [ "$agh_preexisted" -eq 0 ] && units_to_remove+=("${target_root}/etc/systemd/system/AdGuardHome.service")

    for unit in "${units_to_remove[@]}"; do
        rm -f "$unit" 2>/dev/null || true
    done
    if [ -d "${target_root}/etc/systemd/system/nginx.service.d" ]; then
        rmdir "${target_root}/etc/systemd/system/nginx.service.d" 2>/dev/null || true
    fi

    # Удаление cron-файлов и периодических задач
    rm -f "${target_root}/etc/cron.d/awg-purge-expired" 2>/dev/null || true
    if command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -v "sysctl --system" || true) | crontab - 2>/dev/null || true
    fi

    # Зачистка tunnel-интерфейса awg0, если остался активен
    if command -v ip >/dev/null 2>&1; then
        ip link delete dev awg0 2>/dev/null || true
    fi

    # Очистка резолвера AdGuard Home в systemd-resolved
    if [ "$agh_preexisted" -eq 0 ]; then
        rm -f "${target_root}/etc/systemd/resolved.conf.d/adguard.conf" 2>/dev/null || true
        if [ -d "${target_root}/etc/systemd/resolved.conf.d" ]; then
            rmdir "${target_root}/etc/systemd/resolved.conf.d" 2>/dev/null || true
        fi
        if command -v systemctl >/dev/null 2>&1; then
            systemctl restart systemd-resolved 2>/dev/null || true
        fi
    fi

    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload 2>/dev/null || true
    ok "Systemd units, cron-задачи и сетевые интерфейсы очищены."

    log "Шаг 3/8: Восстановление Firewall и очистка правил UFW..."
    # Удаление правил port hopping и MSS clamping из UFW
    for rule_file in "${target_root}/etc/ufw/before.rules" "${target_root}/etc/ufw/before6.rules"; do
        if [ -f "$rule_file" ]; then
            sed -i '/# Port Hopping for Hysteria 2/,/COMMIT/d' "$rule_file" 2>/dev/null || true
            sed -i '/# Hy2 Port Hopping/d' "$rule_file" 2>/dev/null || true
            sed -i '/-A PREROUTING -p udp --dport .* -j REDIRECT/d' "$rule_file" 2>/dev/null || true
            sed -i '/# TCP MSS Clamping/,/COMMIT/d' "$rule_file" 2>/dev/null || true
            sed -i '/TCPMSS --clamp-mss-to-pmtu/d' "$rule_file" 2>/dev/null || true
        fi
    done

    # Гарантируем, что активный порт SSH открыт в UFW во избежание lockout
    if command -v ufw >/dev/null 2>&1; then
        local current_ssh_port
        current_ssh_port=$(command -v detect_active_ssh_port >/dev/null 2>&1 && detect_active_ssh_port || echo 22)
        ufw allow "${current_ssh_port}/tcp" comment 'SSH (Active)' 2>/dev/null || true
        [ -n "$orig_ssh_port" ] && ufw allow "${orig_ssh_port}/tcp" comment 'SSH (Restored)' 2>/dev/null || true
        ufw reload 2>/dev/null || true
    fi
    ok "Правила Firewall очищены (SSH-порты защищены)."

    log "Шаг 4/8: Восстановление конфигурации SSH (Anti-Lockout)..."
    local ssh_restored=0
    local tmp_extract
    tmp_extract="$(mktemp -d 2>/dev/null || echo "/tmp/ssh_extract_$$")"

    if [ "$has_snapshot" -eq 1 ] && tar --force-local -tzf "$archive" "ssh_config.tar.gz" >/dev/null 2>&1; then
        tar --force-local -xzf "$archive" -C "$tmp_extract" "ssh_config.tar.gz" 2>/dev/null || true
        if [ -f "$tmp_extract/ssh_config.tar.gz" ]; then
            mkdir -p "$tmp_extract/ssh_root"
            tar --force-local -xzf "$tmp_extract/ssh_config.tar.gz" -C "$tmp_extract/ssh_root" 2>/dev/null || true

            # Проверка синтаксиса sshd перед применением
            local sshd_valid=1
            if command -v sshd >/dev/null 2>&1 && [ -f "$tmp_extract/ssh_root/ssh/sshd_config" ]; then
                if ! sshd -t -f "$tmp_extract/ssh_root/ssh/sshd_config" 2>/dev/null; then
                    sshd_valid=0
                fi
            fi

            if [ "$sshd_valid" -eq 1 ] && [ -d "$tmp_extract/ssh_root/ssh" ]; then
                cp -a "$tmp_extract/ssh_root/ssh/." "${target_root}/etc/ssh/" 2>/dev/null || true
                ssh_restored=1
                ok "Конфигурация SSH успешно восстановлена из снимка."
            else
                warn "Синтаксис восстанавливаемого sshd_config не прошел проверку sshd -t. Конфигурация SSH сохранена без изменений для защиты доступа."
            fi
        fi
    fi

    # Очистка добавленных скриптом hardening-файлов
    rm -f "${target_root}/etc/ssh/sshd_config.d/99-hardening.conf" 2>/dev/null || true
    rm -f "${target_root}/usr/local/bin/ssh-port-watcher.sh" 2>/dev/null || true

    # Перезапуск SSH-службы
    if [ "$ssh_restored" -eq 1 ] && command -v systemctl >/dev/null 2>&1; then
        local ssh_svc="ssh"
        systemctl is-active --quiet sshd 2>/dev/null && ssh_svc="sshd"
        systemctl reload "$ssh_svc" 2>/dev/null || systemctl restart "$ssh_svc" 2>/dev/null || true
    fi
    rm -rf "$tmp_extract" 2>/dev/null || true

    log "Шаг 5/8: Удаление настроек ядра sysctl и limits..."
    rm -f "${target_root}/etc/sysctl.d/99-vless-tuning.conf" 2>/dev/null || true
    rm -f "${target_root}/etc/security/limits.d/99-proxy-limits.conf" 2>/dev/null || true
    rm -f "${target_root}/etc/systemd/journald.conf.d/00-volatile.conf" 2>/dev/null || true
    command -v sysctl >/dev/null 2>&1 && sysctl --system >/dev/null 2>&1 || true
    ok "Сетевые параметры ядра возвращены к значениям по умолчанию."

    log "Шаг 6/8: Очистка или восстановление Nginx..."
    if [ "$nginx_preexisted" -eq 1 ]; then
        # Nginx существовал до нас: восстанавливаем исходную конфигурацию
        rm -f "${target_root}/etc/nginx/conf.d/01-main.conf" \
              "${target_root}/etc/nginx/conf.d/02-"*.conf \
              "${target_root}/etc/nginx/conf.d/03-adguard.conf \
              ${target_root}/etc/nginx/conf.d/vpn_mask.conf" \
              "${target_root}/etc/nginx/stream.d/00-stream.conf" \
              "${target_root}/etc/nginx/modules-enabled/50-mod-stream.conf" 2>/dev/null || true
        
        tmp_extract="$(mktemp -d 2>/dev/null || echo "/tmp/nginx_extract_$$")"
        if [ "$has_snapshot" -eq 1 ] && tar --force-local -tzf "$archive" "nginx_config.tar.gz" >/dev/null 2>&1; then
            tar --force-local -xzf "$archive" -C "$tmp_extract" "nginx_config.tar.gz" 2>/dev/null || true
            if [ -f "$tmp_extract/nginx_config.tar.gz" ]; then
                tar --force-local -xzf "$tmp_extract/nginx_config.tar.gz" -C "${target_root}/etc" 2>/dev/null || true
                ok "Исходная конфигурация Nginx восстановлена из снимка."
            fi
        fi
        rm -rf "$tmp_extract" 2>/dev/null || true
        command -v systemctl >/dev/null 2>&1 && systemctl restart nginx 2>/dev/null || true
    else
        # Nginx был установлен нами: удаляем его конфиги и кэш
        rm -rf "${target_root}/etc/nginx/conf.d" \
               "${target_root}/etc/nginx/stream.d" \
               "${target_root}/etc/nginx/modules-enabled" \
               "${target_root}/var/cache/nginx" 2>/dev/null || true
        if [ "${UNINSTALL_PURGE_PKGS:-0}" -eq 1 ] && command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get purge -y nginx nginx-common nginx-core libnginx-mod-stream nginx-module-stream >/dev/null 2>&1 || true
            rm -f "${target_root}/etc/apt/sources.list.d/nginx.list" "${target_root}/etc/apt/preferences.d/99nginx" 2>/dev/null || true
        fi
        ok "Конфигурация Nginx удалена."
    fi

    log "Шаг 7/8: Очистка рабочих директорий и исполняемых файлов..."
    local dirs_to_remove=(
        "${target_root}/opt/zapret"
        "${target_root}/etc/sing-box"
        "${target_root}/etc/caddy"
        "${target_root}/etc/amnezia"
        "${target_root}/etc/mita"
        "${target_root}/var/lib/mita"
        "${target_root}/var/run/mita"
        "${target_root}/root/awg"
        "${target_root}/var/www/mirror"
        "${target_root}/root/.server_setup"
    )
    [ "$agh_preexisted" -eq 0 ] && dirs_to_remove+=("${target_root}/opt/AdGuardHome")
    [ "$xui_preexisted" -eq 0 ] && dirs_to_remove+=("${target_root}/usr/local/x-ui" "${target_root}/etc/x-ui")

    for dir in "${dirs_to_remove[@]}"; do
        rm -rf "$dir" 2>/dev/null || true
    done

    # Удаление standalone бинарников
    local bins_to_remove=(
        "${target_root}/usr/local/bin/sing-box"
        "${target_root}/usr/local/bin/shadow-tls"
        "${target_root}/usr/local/bin/wstunnel"
        "${target_root}/usr/local/bin/dnstt-server"
        "${target_root}/usr/local/bin/caddy-naive"
        "${target_root}/usr/local/bin/mita"
        "${target_root}/usr/local/bin/mieru-mgr"
        "${target_root}/usr/local/bin/mieru-cli"
        "${target_root}/usr/local/bin/awg-mgr"
        "${target_root}/usr/local/bin/manage-services"
    )
    for b in "${bins_to_remove[@]}"; do
        rm -f "$b" 2>/dev/null || true
    done

    # Очистка временных файлов и учетных данных
    rm -f "${target_root}/root/vpn_credentials.txt" \
          "${target_root}/root/mieru-client"*.json \
          "${target_root}/etc/mita_server_config.json" \
          "${target_root}/run/3xui_unified_client.env" \
          "${target_root}/var/run/server_setup.checkpoint" \
          "${target_root}/var/run/server_setup.failed_step" \
          "${target_root}/var/run/server_setup_active_step.log" 2>/dev/null || true

    # SSL сертификаты (по умолчанию сохраняются, если не запрошена очистка)
    if [ "${UNINSTALL_KEEP_CERTS:-1}" -eq 0 ]; then
        rm -rf "${target_root}/etc/letsencrypt" "${target_root}/etc/ssl/acme" "${target_root}/root/.acme.sh" 2>/dev/null || true
        if command -v crontab >/dev/null 2>&1; then
            (crontab -l 2>/dev/null | grep -v "acme.sh" || true) | crontab - 2>/dev/null || true
        fi
        ok "SSL-сертификаты и acme.sh успешно удалены."
    else
        log "SSL-сертификаты сохранены в /etc/letsencrypt и /etc/ssl/acme (защита от исчерпания лимитов)."
    fi
    ok "Рабочие директории и бинарники успешно удалены."

    log "Шаг 8/8: Завершение отката..."
    if [ "${UNINSTALL_PURGE_PKGS:-0}" -eq 1 ] && [ "$has_snapshot" -eq 1 ] && command -v apt-get >/dev/null 2>&1; then
        local snap_pkgs="$snap_dir/packages_installed.list"
        if [ -f "$snap_pkgs" ]; then
            log "Вычисление и удаление добавленных пакетов (--purge)..."
            local cur_pkgs
            cur_pkgs="$(mktemp 2>/dev/null || echo "/tmp/cur_pkgs_$$")"
            dpkg-query -f '${binary:Package}\n' -W > "$cur_pkgs" 2>/dev/null || true
            local diff_pkgs
            diff_pkgs="$(comm -13 <(sort "$snap_pkgs") <(sort "$cur_pkgs") | grep -E '^(amneziawg|wireguard)' || true)"
            if [ -n "$diff_pkgs" ]; then
                export DEBIAN_FRONTEND=noninteractive
                # shellcheck disable=SC2086
                apt-get purge -y $diff_pkgs >/dev/null 2>&1 || true
            fi
            rm -f "$cur_pkgs" 2>/dev/null || true
        fi
    fi

    echo -e "\n${BOLD}${GREEN}✔ Сервер успешно возвращен в исходное состояние!${NC}"
    echo -e "Все компоненты стека удалены, правила безопасности и доступ по SSH сохранены.\n"
    return 0
}

show_uninstall_help() {
    cat << 'EOF'
Использование: ./uninstall.sh [ОПЦИИ]

Утилита полного удаления VPN/прокси стека и отката сервера к исходному состоянию.
Использует снимок исходного состояния (/var/backups/server_setup/).

Опции:
  -y, --yes, -f, --force      Пропустить интерактивное подтверждение
  --purge                     Полное удаление установленных пакетов (Nginx, AWG DKMS)
  --remove-certs              Удалить выданные SSL-сертификаты (/etc/letsencrypt, /etc/ssl/acme)
  --keep-certs                Сохранить SSL-сертификаты (по умолчанию: да)
  -v, --version               Показать версию и выйти
  -h, --help                  Показать эту справку и выйти

Примеры:
  ./uninstall.sh
  ./uninstall.sh -y
  ./uninstall.sh -y --purge --remove-certs
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes|-f|--force)
            UNINSTALL_FORCE=1
            shift
            ;;
        --purge)
            UNINSTALL_PURGE_PKGS=1
            shift
            ;;
        --remove-certs|--purge-certs)
            UNINSTALL_KEEP_CERTS=0
            UNINSTALL_CERTS_EXPLICIT=1
            shift
            ;;
        --keep-certs)
            UNINSTALL_KEEP_CERTS=1
            UNINSTALL_CERTS_EXPLICIT=1
            shift
            ;;
        -v|--version)
            echo "uninstall.sh (Nginx L4 Stream Router Mask for 3X-UI) v9.4.0"
            exit 0
            ;;
        -h|--help)
            show_uninstall_help
            exit 0
            ;;
        *)
            warn "Неизвестный параметр: $1"
            show_uninstall_help
            exit 1
            ;;
    esac
done

acquire_stack_lock "${VPN_STACK_LOCK_TIMEOUT:-10}" "uninstall" || exit $?
run_uninstall
