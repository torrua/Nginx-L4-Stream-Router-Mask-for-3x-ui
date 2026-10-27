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
