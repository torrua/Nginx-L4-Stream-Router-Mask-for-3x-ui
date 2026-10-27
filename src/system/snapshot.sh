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
    if command -v apk >/dev/null 2>&1; then
        apk info -q > "$tmp_dir/packages_installed.list" 2>/dev/null || true
    elif command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -f '${binary:Package}\n' -W > "$tmp_dir/packages_installed.list" 2>/dev/null || true
    elif command -v rpm >/dev/null 2>&1; then
        rpm -qa --qf '%{NAME}\n' > "$tmp_dir/packages_installed.list" 2>/dev/null || true
    else
        : > "$tmp_dir/packages_installed.list"
    fi

    # 3. Фиксация состояния служб
    if is_openrc; then
        rc-update show 2>/dev/null | awk '{print $1}' > "$tmp_dir/services_enabled.list" || true
        rc-status -a 2>/dev/null | grep -E '\[ *(started|running) *\]' | awk '{print $1}' > "$tmp_dir/services_running.list" || true
    elif command -v systemctl >/dev/null 2>&1; then
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
    [ -d "${target_root}/etc/local.d" ] && tar --force-local -czf "$tmp_dir/sysctl/local.d.tar.gz" -C "${target_root}/etc" "local.d" 2>/dev/null || true

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
    local os_id="${ID:-linux}" os_codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-generic}}" k_rel
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        os_id="${ID:-linux}"
        os_codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-generic}}"
    fi
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
