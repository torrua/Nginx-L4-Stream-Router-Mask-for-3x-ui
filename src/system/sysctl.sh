# =============================================================
#  ФУНКЦИИ ФАЗЫ УСТАНОВКИ (определены до фазы для читаемости и --debug)
# =============================================================

apply_sysctl_and_limits() {
    # Загрузка модуля nf_conntrack и сохранение для автозагрузки при старте ОС
    modprobe nf_conntrack 2>/dev/null || true
    if [ -d /etc/modules-load.d ] && [ -w /etc/modules-load.d ]; then
        { echo "nf_conntrack" > /etc/modules-load.d/99-vless-conntrack.conf; } 2>/dev/null || true
    elif [ -f /etc/modules ] && [ -w /etc/modules ]; then
        if ! grep -q "^nf_conntrack" /etc/modules 2>/dev/null; then
            { echo "nf_conntrack" >> /etc/modules; } 2>/dev/null || true
        fi
    fi

    mkdir -p /etc/sysctl.d 2>/dev/null || true
    cat << 'EOF' > /etc/sysctl.d/99-vless-tuning.conf
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.ip_nonlocal_bind = 1
vm.swappiness = 10

# Отключение IPv6 (защита от утечек трафика)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# Защита таблицы conntrack от зависших сессий (разрывы ТСПУ/DPI без FIN/RST)
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

net.ipv4.ip_local_port_range = 1024 65535
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_max_tw_buckets = 524288
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_orphan_retries = 2
net.ipv4.tcp_slow_start_after_idle = 0

net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 212992
net.core.wmem_default = 212992
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 131072 16777216
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

vm.dirty_ratio = 6
vm.dirty_background_ratio = 3

net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_mtu_probe_floor = 1024

fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
net.ipv4.tcp_notsent_lowat = 16384
EOF

    sysctl --system >/dev/null 2>&1 || true

    # Оптимизация резолвера gai.conf (приоритет IPv4 для исключения таймаутов mtg/Go QUIC)
    if [ -f /etc/gai.conf ] && [ -w /etc/gai.conf ]; then
        sed -i 's/#precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf 2>/dev/null || true
    fi

    # Хранение системных логов journald в RAM (Storage=volatile, без записи на диск)
    if is_systemd; then
        mkdir -p /etc/systemd/journald.conf.d/ 2>/dev/null || true
        cat << 'EOF' > /etc/systemd/journald.conf.d/00-volatile.conf
[Journal]
Storage=volatile
RuntimeMaxUse=64M
MaxRetentionSec=1day
EOF
        systemctl restart systemd-journald 2>/dev/null || true
    fi

    # Disable IPv6 immediately on all active interfaces (runtime)
    if [ -d /proc/sys/net/ipv6/conf ]; then
        for iface in $(ls /proc/sys/net/ipv6/conf/ 2>/dev/null); do
            sysctl -w net.ipv6.conf."$iface".disable_ipv6=1 >/dev/null 2>&1 || true
        done
    fi

    # Hardware/Kernel level disable via GRUB (survives cloud network resets upon reboot)
    if [ -f /etc/default/grub ] && [ -w /etc/default/grub ]; then
        if ! grep -q "ipv6.disable=1" /etc/default/grub; then
            cp /etc/default/grub /etc/default/grub.bak 2>/dev/null || true
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1 /' /etc/default/grub 2>/dev/null || true
            sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT='/GRUB_CMDLINE_LINUX_DEFAULT='ipv6.disable=1 /" /etc/default/grub 2>/dev/null || true
            sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="ipv6.disable=1 /' /etc/default/grub 2>/dev/null || true
            sed -i "s/GRUB_CMDLINE_LINUX='/GRUB_CMDLINE_LINUX='ipv6.disable=1 /" /etc/default/grub 2>/dev/null || true
            if command -v update-grub &>/dev/null; then
                update-grub >/dev/null 2>&1 || true
            elif command -v grub-mkconfig &>/dev/null; then
                grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
            fi
        fi
    fi

    # Boot guard against cloud-init / network daemon sysctl overrides on boot
    if is_openrc; then
        mkdir -p /etc/local.d 2>/dev/null || true
        cat << 'EOF_LOCAL' > /etc/local.d/99-sysctl.start
#!/bin/sh
sleep 10 && sysctl --system
EOF_LOCAL
        chmod +x /etc/local.d/99-sysctl.start 2>/dev/null || true
        rc-update add local default 2>/dev/null || true
    elif command -v crontab &>/dev/null; then
        local cron_job="@reboot sleep 10 && sysctl --system"
        if ! crontab -l 2>/dev/null | grep -Fq "$cron_job"; then
            (crontab -l 2>/dev/null || true; echo "$cron_job") | crontab - 2>/dev/null || true
        fi
    fi

    # Disable IPv6 in UFW configuration
    if [ -f /etc/default/ufw ] && [ -w /etc/default/ufw ]; then
        if grep -q "^IPV6=" /etc/default/ufw; then
            sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw 2>/dev/null || true
        else
            echo "IPV6=no" >> /etc/default/ufw 2>/dev/null || true
        fi
    fi

    mkdir -p /etc/security/limits.d 2>/dev/null || true
    cat << 'EOF' > /etc/security/limits.d/99-proxy-limits.conf
* soft nofile 524288
* hard nofile 524288
root soft nofile 524288
root hard nofile 524288
www-data soft nofile 524288
www-data hard nofile 524288
nginx soft nofile 524288
nginx hard nofile 524288
EOF

    # TCP MSS Clamping — предотвращение PMTU Blackhole при блокировке ICMP (для ядро/TUN/FORWARD трафика)
    # Примечание: действует на маршрутизируемый трафик ядра Linux; не влияет на userspace gVisor в 3X-UI.
    if ! iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        if ! ip6tables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
            ip6tables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        fi
    fi

    # Персистентность MSS Clamping через /etc/ufw/before.rules и before6.rules
    if [ -f /etc/ufw/before.rules ] && [ -w /etc/ufw/before.rules ] && ! grep -q 'TCPMSS --clamp-mss-to-pmtu' /etc/ufw/before.rules 2>/dev/null; then
        if ! grep -q '^\*mangle' /etc/ufw/before.rules 2>/dev/null; then
            sed -i '/^\*filter/i\# TCP MSS Clamping - prevents PMTU blackhole (added by setup.sh)\n*mangle\n:FORWARD ACCEPT [0:0]\n-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\nCOMMIT\n' /etc/ufw/before.rules 2>/dev/null || true
        else
            sed -i '/^\*mangle/a\-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' /etc/ufw/before.rules 2>/dev/null || true
        fi
    fi
    if [ -f /etc/ufw/before6.rules ] && [ -w /etc/ufw/before6.rules ] && ! grep -q 'TCPMSS --clamp-mss-to-pmtu' /etc/ufw/before6.rules 2>/dev/null; then
        if ! grep -q '^\*mangle' /etc/ufw/before6.rules 2>/dev/null; then
            sed -i '/^\*filter/i\# TCP MSS Clamping IPv6 - prevents PMTU blackhole (added by setup.sh)\n*mangle\n:FORWARD ACCEPT [0:0]\n-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\nCOMMIT\n' /etc/ufw/before6.rules 2>/dev/null || true
        else
            sed -i '/^\*mangle/a\-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' /etc/ufw/before6.rules 2>/dev/null || true
        fi
    fi
}

supports_x86_64_v3() {
    local arch
    arch=$(uname -m 2>/dev/null || echo "unknown")
    if [ "$arch" != "x86_64" ]; then
        return 0
    fi
    if [ -x /lib64/ld-linux-x86-64.so.2 ]; then
        if /lib64/ld-linux-x86-64.so.2 --help 2>&1 | grep -E 'x86-64-v3' | grep -q 'supported'; then
            return 0
        fi
    fi
    if grep -q "avx2" /proc/cpuinfo 2>/dev/null && grep -q "bmi2" /proc/cpuinfo 2>/dev/null; then
        return 0
    fi
    return 1
}

