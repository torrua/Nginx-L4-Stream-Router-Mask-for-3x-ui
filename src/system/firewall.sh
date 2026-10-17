# =============================================================
#  PORT HOPPING ДЛЯ HYSTERIA 2 (UDP → NAT REDIRECT)
# =============================================================
if [[ "${ENABLE_HY2:-0}" == "1" || "${ENABLE_HY2,,}" == "y" ]] && \
   [[ "${HY2_PORT_HOPPING,,}" == "y" || "${HY2_PORT_HOPPING:-}" == "1" ]] && \
   [ -n "${HY2_PORT:-}" ] && [ -n "${HY2_PORT_HOPPING_RANGE:-}" ]; then

    PH_RANGE="${HY2_PORT_HOPPING_RANGE}"

    # 1. Применяем NAT REDIRECT правила (runtime, идемпотентно)
    # IPv4
    if ! iptables -t nat -C PREROUTING -p udp --dport "$PH_RANGE" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null; then
        iptables -t nat -A PREROUTING -p udp --dport "$PH_RANGE" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null || true
    fi
    # IPv6 (если стек IPv6 активен и ip6tables доступен)
    hy2_v6_status=""
    if [ -d /proc/sys/net/ipv6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != "1" ] && command -v ip6tables >/dev/null 2>&1; then
        if ! ip6tables -t nat -C PREROUTING -p udp --dport "$PH_RANGE" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null; then
            ip6tables -t nat -A PREROUTING -p udp --dport "$PH_RANGE" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null || true
        fi
        hy2_v6_status="+IPv6"
    fi
    ok "Port Hopping: NAT REDIRECT UDP ${PH_RANGE} → порт ${HY2_PORT} (IPv4${hy2_v6_status}) [Активирован]"

    # 2. Персистентность через /etc/ufw/before.rules (IPv4, секция *nat)
    if [ -f /etc/ufw/before.rules ] && ! grep -q "Hy2 Port Hopping" /etc/ufw/before.rules 2>/dev/null; then
        if grep -q '^\*nat' /etc/ufw/before.rules 2>/dev/null; then
            sed -i "/^\*nat/,/^COMMIT/{/^COMMIT/i\\# Hy2 Port Hopping\n-A PREROUTING -p udp --dport ${PH_RANGE} -j REDIRECT --to-ports ${HY2_PORT}
            }" /etc/ufw/before.rules
        else
            insert_before="*filter"
            grep -q '^\*mangle' /etc/ufw/before.rules 2>/dev/null && insert_before="*mangle"
            grep -q '^# TCP MSS Clamping' /etc/ufw/before.rules 2>/dev/null && insert_before="# TCP MSS Clamping"
            sed -i "/${insert_before}/i\\# Port Hopping for Hysteria 2 (added by setup_mask.sh)\n*nat\n:PREROUTING ACCEPT [0:0]\n# Hy2 Port Hopping\n-A PREROUTING -p udp --dport ${PH_RANGE} -j REDIRECT --to-ports ${HY2_PORT}\nCOMMIT\n" /etc/ufw/before.rules
        fi
    fi

    # 3. Персистентность через /etc/ufw/before6.rules (IPv6, секция *nat, если IPv6 включен в UFW)
    if [ -f /etc/ufw/before6.rules ] && grep -q '^IPV6=yes' /etc/default/ufw 2>/dev/null && ! grep -q "Hy2 Port Hopping" /etc/ufw/before6.rules 2>/dev/null; then
        if grep -q '^\*nat' /etc/ufw/before6.rules 2>/dev/null; then
            sed -i "/^\*nat/,/^COMMIT/{/^COMMIT/i\\# Hy2 Port Hopping\n-A PREROUTING -p udp --dport ${PH_RANGE} -j REDIRECT --to-ports ${HY2_PORT}
            }" /etc/ufw/before6.rules
        else
            sed -i '/^\*filter/i\# Port Hopping for Hysteria 2 - IPv6 (added by setup_mask.sh)\n*nat\n:PREROUTING ACCEPT [0:0]\n# Hy2 Port Hopping\n-A PREROUTING -p udp --dport '"${PH_RANGE}"' -j REDIRECT --to-ports '"${HY2_PORT}"'\nCOMMIT\n' /etc/ufw/before6.rules
        fi
    fi
else
    # Очистка Port Hopping, если отключен (чистый стелс-режим)
    if [ -n "${HY2_PORT_HOPPING_RANGE:-}" ] && [ -n "${HY2_PORT:-}" ]; then
        PH_RANGE="${HY2_PORT_HOPPING_RANGE}"
        while iptables -t nat -C PREROUTING -p udp --dport "$PH_RANGE" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null; do
            iptables -t nat -D PREROUTING -p udp --dport "$PH_RANGE" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null || break
        done
        if [ -d /proc/sys/net/ipv6 ] && command -v ip6tables >/dev/null 2>&1; then
            while ip6tables -t nat -C PREROUTING -p udp --dport "$PH_RANGE" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null; do
                ip6tables -t nat -D PREROUTING -p udp --dport "$PH_RANGE" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null || break
            done
        fi
        if [ -f /etc/ufw/before.rules ] && grep -q "Hy2 Port Hopping" /etc/ufw/before.rules 2>/dev/null; then
            sed -i '/# Port Hopping for Hysteria 2/,/COMMIT/d' /etc/ufw/before.rules 2>/dev/null || true
            sed -i '/# Hy2 Port Hopping/d' /etc/ufw/before.rules 2>/dev/null || true
            sed -i '/-A PREROUTING -p udp --dport '"${PH_RANGE}"' -j REDIRECT/d' /etc/ufw/before.rules 2>/dev/null || true
        fi
        if [ -f /etc/ufw/before6.rules ] && grep -q "Hy2 Port Hopping" /etc/ufw/before6.rules 2>/dev/null; then
            sed -i '/# Port Hopping for Hysteria 2/,/COMMIT/d' /etc/ufw/before6.rules 2>/dev/null || true
            sed -i '/# Hy2 Port Hopping/d' /etc/ufw/before6.rules 2>/dev/null || true
            sed -i '/-A PREROUTING -p udp --dport '"${PH_RANGE}"' -j REDIRECT/d' /etc/ufw/before6.rules 2>/dev/null || true
        fi
        ufw delete allow "${PH_RANGE//:/ }/udp" >/dev/null 2>&1 || true
    fi
fi

