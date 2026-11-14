#!/usr/bin/env bash
# ==============================================================================
# src/system/service.sh — Unified Service Manager & OS Abstraction Layer
# ==============================================================================
# Transparently abstracts service management between systemd and OpenRC.
# Ensures 100% native execution on Alpine Linux while preserving full
# backward compatibility with Ubuntu / Debian.
# ==============================================================================

is_openrc() {
    if [ -f /sbin/openrc-run ] || [ -f /etc/init.d/rc ] || [ -f /etc/alpine-release ]; then
        return 0
    fi
    if ! command -v systemctl >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
        return 0
    fi
    if [ -f /etc/os-release ]; then
        local os_id=""
        os_id=$(. /etc/os-release 2>/dev/null; echo "${ID:-}")
        if [ "$os_id" = "alpine" ] && ! command -v systemctl >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

is_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

svc_daemon_reload() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

svc_start() {
    local name="$1"
    if is_openrc; then
        rc-service "$name" start
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl start "$name"
    elif [ -x "/etc/init.d/$name" ]; then
        "/etc/init.d/$name" start
    else
        return 1
    fi
}

svc_stop() {
    local name="$1"
    if is_openrc; then
        rc-service "$name" stop
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl stop "$name"
    elif [ -x "/etc/init.d/$name" ]; then
        "/etc/init.d/$name" stop
    else
        return 1
    fi
}

svc_restart() {
    local name="$1"
    if is_openrc; then
        rc-service "$name" restart
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl restart "$name"
    elif [ -x "/etc/init.d/$name" ]; then
        "/etc/init.d/$name" restart
    else
        return 1
    fi
}

svc_reload() {
    local name="$1"
    if is_openrc; then
        rc-service "$name" reload 2>/dev/null || rc-service "$name" restart
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl reload "$name" 2>/dev/null || systemctl restart "$name"
    elif [ -x "/etc/init.d/$name" ]; then
        "/etc/init.d/$name" reload 2>/dev/null || "/etc/init.d/$name" restart
    else
        return 1
    fi
}

svc_enable() {
    local name="$1"
    if is_openrc; then
        rc-update add "$name" default >/dev/null 2>&1 || true
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl enable "$name" >/dev/null 2>&1 || true
    fi
}

svc_disable() {
    local name="$1"
    if is_openrc; then
        rc-update del "$name" default >/dev/null 2>&1 || rc-update del "$name" >/dev/null 2>&1 || true
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl disable "$name" >/dev/null 2>&1 || true
    fi
}

svc_is_active() {
    local name="$1"
    if is_openrc; then
        rc-service "$name" status >/dev/null 2>&1
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet "$name" 2>/dev/null
    elif [ -x "/etc/init.d/$name" ]; then
        "/etc/init.d/$name" status >/dev/null 2>&1
    else
        return 1
    fi
}

svc_create_daemon() {
    local name="$1"
    local desc="$2"
    local cmd="$3"
    local args="${4:-}"
    local respawn_delay="${5:-3}"
    local pre_start="${6:-}"
    local post_stop="${7:-}"
    local user="${8:-}"
    local group="${9:-}"

    if is_openrc; then
        mkdir -p /etc/init.d /run/openrc 2>/dev/null || true
        touch /run/openrc/softlevel 2>/dev/null || true
        local init_file="/etc/init.d/${name}"

        {
            echo "#!/sbin/openrc-run"
            echo "description=\"${desc}\""
            echo "supervisor=\"supervise-daemon\""
            echo "command=\"${cmd}\""
            [ -n "${args}" ] && echo "command_args=\"${args}\""
            echo "pidfile=\"/run/\${RC_SVCNAME}.pid\""
            echo "respawn_delay=${respawn_delay}"
            echo "respawn_max=5"
            [ -n "${user}" ] && echo "command_user=\"${user}${group:+:$group}\""
            echo ""
            if [ -n "${pre_start}" ]; then
                echo "start_pre() {"
                echo "    ${pre_start}"
                echo "}"
                echo ""
            fi
            if [ -n "${post_stop}" ]; then
                echo "stop_post() {"
                echo "    ${post_stop}"
                echo "}"
                echo ""
            fi
            echo "depend() {"
            echo "    need net"
            echo "    after firewall"
            echo "}"
        } > "$init_file"

        chmod 755 "$init_file"
    else
        mkdir -p /etc/systemd/system 2>/dev/null || true
        local unit_file="/etc/systemd/system/${name}.service"

        {
            echo "[Unit]"
            echo "Description=${desc}"
            echo "After=network.target network-online.target"
            echo "Wants=network-online.target"
            echo ""
            echo "[Service]"
            echo "Type=simple"
            [ -n "${user}" ] && echo "User=${user}"
            [ -n "${group}" ] && echo "Group=${group}"
            if [ -n "${pre_start}" ]; then
                # Split multiple commands if delimited by semicolon or emit as is
                echo "ExecStartPre=${pre_start}"
            fi
            echo "ExecStart=${cmd}${args:+ $args}"
            if [ -n "${post_stop}" ]; then
                echo "ExecStopPost=${post_stop}"
            fi
            echo "Restart=always"
            echo "RestartSec=${respawn_delay}s"
            echo "LimitNOFILE=65535"
            echo ""
            echo "[Install]"
            echo "WantedBy=multi-user.target"
        } > "$unit_file"

        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
    fi
}


get_hardware_memory_limits() {
    local total_ram_mb
    total_ram_mb=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}' || echo "1024")
    [ -n "$total_ram_mb" ] && [ "$total_ram_mb" -gt 0 ] 2>/dev/null || total_ram_mb=1024

    if [ "$total_ram_mb" -lt 1500 ]; then
        XUI_GOMEMLIMIT="90MiB"
        XUI_GOGC="50"
        XUI_MEM_HIGH="110M"
        XUI_MEM_MAX="140M"
        AGH_GOMEMLIMIT="40MiB"
        AGH_MEM_HIGH="55M"
        AGH_MEM_MAX="70M"
    elif [ "$total_ram_mb" -lt 3500 ]; then
        XUI_GOMEMLIMIT="350MiB"
        XUI_GOGC="80"
        XUI_MEM_HIGH="450M"
        XUI_MEM_MAX="600M"
        AGH_GOMEMLIMIT="100MiB"
        AGH_MEM_HIGH="150M"
        AGH_MEM_MAX="200M"
    elif [ "$total_ram_mb" -lt 7500 ]; then
        XUI_GOMEMLIMIT="1024MiB"
        XUI_GOGC="100"
        XUI_MEM_HIGH="1400M"
        XUI_MEM_MAX="1800M"
        AGH_GOMEMLIMIT="250MiB"
        AGH_MEM_HIGH="350M"
        AGH_MEM_MAX="450M"
    else
        XUI_GOMEMLIMIT="2048MiB"
        XUI_GOGC="100"
        XUI_MEM_HIGH="2800M"
        XUI_MEM_MAX="3500M"
        AGH_GOMEMLIMIT="500MiB"
        AGH_MEM_HIGH="700M"
        AGH_MEM_MAX="900M"
    fi
}

apply_xui_memory_limits() {
    # Guard: skip if running in container without host systemd
    if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
        return 0
    fi

    get_hardware_memory_limits

    if is_systemd; then
        mkdir -p /etc/systemd/system/x-ui.service.d 2>/dev/null || true
        cat << EOF > /etc/systemd/system/x-ui.service.d/10-memory-limit.conf
[Service]
Environment="GOMEMLIMIT=${XUI_GOMEMLIMIT:-350MiB}"
Environment="GOGC=${XUI_GOGC:-80}"
Environment="GODEBUG=madvdontneed=1"
MemoryHigh=${XUI_MEM_HIGH:-450M}
MemoryMax=${XUI_MEM_MAX:-600M}
EOF
        chmod 0644 /etc/systemd/system/x-ui.service.d/10-memory-limit.conf 2>/dev/null || true
        svc_daemon_reload
    elif is_openrc; then
        mkdir -p /etc/conf.d 2>/dev/null || true
        if [ -f /etc/conf.d/x-ui ]; then
            sed -i '/GOMEMLIMIT/d;/GODEBUG/d;/GOGC/d' /etc/conf.d/x-ui 2>/dev/null || true
        fi
        cat << EOF >> /etc/conf.d/x-ui
export GOMEMLIMIT="${XUI_GOMEMLIMIT:-350MiB}"
export GOGC="${XUI_GOGC:-80}"
export GODEBUG="madvdontneed=1"
EOF
    fi
}

setup_system_autoupdate() {
    # Guard: strictly only for bare-metal systemd Linux (Ubuntu/Debian host)
    if is_openrc || [ -f /.dockerenv ] || [ -f /run/.containerenv ] || [ "${DOKPLOY_COEXISTENCE:-n}" = "y" ]; then
        return 0
    fi
    command -v systemctl >/dev/null 2>&1 || return 0

    mkdir -p /usr/local/bin /var/backups/vpn-autoupdate 2>/dev/null || true

    cat << 'EOF_AUTO_MAINT' > /usr/local/bin/system-autoupdate.sh
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'
	'
umask 077

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

LOCK_FILE="/var/run/system-autoupdate.lock"
exec 201>"$LOCK_FILE"
if ! flock -n 201; then
    echo "[!] Процесс регламентного автообновления уже выполняется."
    exit 0
fi

log()  { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [+] $*"; }
warn() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [!] $*" >&2; }

BACKUP_DIR="/var/backups/vpn-autoupdate"
mkdir -p "$BACKUP_DIR"
TS=$(date +%F_%H%M%S)

if [ -d /etc/amnezia/amneziawg ]; then
    tar -czf "$BACKUP_DIR/awg_backup_${TS}.tar.gz" -C /etc/amnezia amneziawg 2>/dev/null || true
fi
if [ -f /etc/x-ui/x-ui.db ]; then
    sqlite3 /etc/x-ui/x-ui.db "PRAGMA wal_checkpoint(FULL);" 2>/dev/null || true
    cp -a /etc/x-ui/x-ui.db "$BACKUP_DIR/x-ui_backup_${TS}.db" 2>/dev/null || true
fi
find "$BACKUP_DIR" -type f -mtime +28 -delete 2>/dev/null || true

# Безопасное ожидание блокировки APT
count=0
while command -v fuser >/dev/null 2>&1 && fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do
    sleep 2
    count=$((count + 2))
    [ "$count" -ge 120 ] && { warn "APT заблокирован более 120 с. Отмена итерации."; exit 1; }
done

apt-get update -q || true
if dpkg -l linux-image-generic >/dev/null 2>&1; then
    apt-get install -y -q linux-headers-generic 2>/dev/null || true
elif dpkg -l linux-image-amd64 >/dev/null 2>&1; then
    apt-get install -y -q linux-headers-amd64 2>/dev/null || true
fi

apt-get upgrade -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || true
apt-get autoremove -y -q || true

REBOOT_NEEDED=0
[ -f /var/run/reboot-required ] && REBOOT_NEEDED=1

NEW_KERNEL=$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -n1 || echo "")
RUNNING_KERNEL=$(uname -r)

if [ -n "$NEW_KERNEL" ] && { [ "$REBOOT_NEEDED" -eq 1 ] || [ "$NEW_KERNEL" != "$RUNNING_KERNEL" ]; }; then
    if command -v dkms >/dev/null 2>&1 && dkms status 2>/dev/null | grep -q "amneziawg"; then
        log "Проверка компиляции модуля AmneziaWG для нового ядра $NEW_KERNEL..."
        if ! dkms status -m amneziawg -k "$NEW_KERNEL" 2>/dev/null | grep -q "installed"; then
            dkms build -m amneziawg -k "$NEW_KERNEL" 2>/dev/null || true
            dkms install -m amneziawg -k "$NEW_KERNEL" 2>/dev/null || true
        fi

        if dkms status -m amneziawg -k "$NEW_KERNEL" 2>/dev/null | grep -q "installed"; then
            log "Модуль amneziawg успешно верифицирован для ядра $NEW_KERNEL. Перезагрузка сервера..."
            systemctl reboot
        else
            warn "ВНИМАНИЕ (CIRCUIT BREAKER): amneziawg НЕ скомпилировался под ядро $NEW_KERNEL!"
            warn "Перезагрузка заблокирована для защиты работы туннелей. Сервер остаётся на стабильном ядре $RUNNING_KERNEL."
            exit 0
        fi
    else
        systemctl reboot
    fi
fi
EOF_AUTO_MAINT
    chmod 0700 /usr/local/bin/system-autoupdate.sh 2>/dev/null || true

    cat << 'EOF_SERVICE' > /etc/systemd/system/system-autoupdate.service
[Unit]
Description=Weekly System and AmneziaWG Kernel Maintenance
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/system-autoupdate.sh
TimeoutStartSec=1800
EOF_SERVICE
    chmod 0644 /etc/systemd/system/system-autoupdate.service 2>/dev/null || true

    cat << 'EOF_TIMER' > /etc/systemd/system/system-autoupdate.timer
[Unit]
Description=Weekly System and AmneziaWG Kernel Maintenance Timer

[Timer]
OnCalendar=Sun *-*-* 04:00:00 UTC
Persistent=true
RandomizedDelaySec=1800

[Install]
WantedBy=timers.target
EOF_TIMER
    chmod 0644 /etc/systemd/system/system-autoupdate.timer 2>/dev/null || true

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now system-autoupdate.timer >/dev/null 2>&1 || true
}
