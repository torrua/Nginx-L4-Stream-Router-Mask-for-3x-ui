# =============================================================
#  PORT HOPPING ДЛЯ HYSTERIA 2 (UDP → NAT REDIRECT)
# =============================================================
if is_true "${ENABLE_HY2:-0}" && \
   is_true "${HY2_PORT_HOPPING:-0}" && \
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
        if command -v python3 >/dev/null 2>&1; then
            if grep -q '^\*nat' /etc/ufw/before.rules 2>/dev/null; then
                python3 - "/etc/ufw/before.rules" "${PH_RANGE}" "${HY2_PORT}" << 'EOF_UFW_PY' 2>/dev/null || true
import sys
rule_file, r_range, r_port = sys.argv[1], sys.argv[2], sys.argv[3]
with open(rule_file, "r", encoding="utf-8") as f:
    lines = f.readlines()
out = []
in_nat = False
inserted = False
for line in lines:
    if line.strip() == "*nat":
        in_nat = True
    if in_nat and line.strip() == "COMMIT" and not inserted:
        out.append("# Hy2 Port Hopping\n")
        out.append(f"-A PREROUTING -p udp --dport {r_range} -j REDIRECT --to-ports {r_port}\n")
        inserted = True
        in_nat = False
    out.append(line)
with open(rule_file, "w", encoding="utf-8") as f:
    f.writelines(out)
EOF_UFW_PY
            else
                python3 - "/etc/ufw/before.rules" "${PH_RANGE}" "${HY2_PORT}" << 'EOF_UFW_PY2' 2>/dev/null || true
import sys
rule_file, r_range, r_port = sys.argv[1], sys.argv[2], sys.argv[3]
with open(rule_file, "r", encoding="utf-8") as f:
    content = f.read()
nat_block = f"# Port Hopping for Hysteria 2 (added by setup.sh)\n*nat\n:PREROUTING ACCEPT [0:0]\n# Hy2 Port Hopping\n-A PREROUTING -p udp --dport {r_range} -j REDIRECT --to-ports {r_port}\nCOMMIT\n\n"
if "*filter" in content:
    content = content.replace("*filter", nat_block + "*filter", 1)
else:
    content = nat_block + content
with open(rule_file, "w", encoding="utf-8") as f:
    f.write(content)
EOF_UFW_PY2
            fi
        elif grep -q '^\*nat' /etc/ufw/before.rules 2>/dev/null; then
            sed -i "/^\*nat/,/^COMMIT/{/^COMMIT/i\\# Hy2 Port Hopping\n-A PREROUTING -p udp --dport ${PH_RANGE} -j REDIRECT --to-ports ${HY2_PORT}
            }" /etc/ufw/before.rules
        else
            insert_before="*filter"
            grep -q '^\*mangle' /etc/ufw/before.rules 2>/dev/null && insert_before="*mangle"
            grep -q '^# TCP MSS Clamping' /etc/ufw/before.rules 2>/dev/null && insert_before="# TCP MSS Clamping"
            sed -i "/${insert_before}/i\\# Port Hopping for Hysteria 2 (added by setup.sh)\n*nat\n:PREROUTING ACCEPT [0:0]\n# Hy2 Port Hopping\n-A PREROUTING -p udp --dport ${PH_RANGE} -j REDIRECT --to-ports ${HY2_PORT}\nCOMMIT\n" /etc/ufw/before.rules
        fi
    fi

    # 3. Персистентность через /etc/ufw/before6.rules (IPv6, секция *nat, если IPv6 включен в UFW)
    if [ -f /etc/ufw/before6.rules ] && grep -q '^IPV6=yes' /etc/default/ufw 2>/dev/null && ! grep -q "Hy2 Port Hopping" /etc/ufw/before6.rules 2>/dev/null; then
        if command -v python3 >/dev/null 2>&1; then
            if grep -q '^\*nat' /etc/ufw/before6.rules 2>/dev/null; then
                python3 - "/etc/ufw/before6.rules" "${PH_RANGE}" "${HY2_PORT}" << 'EOF_UFW6_PY' 2>/dev/null || true
import sys
rule_file, r_range, r_port = sys.argv[1], sys.argv[2], sys.argv[3]
with open(rule_file, "r", encoding="utf-8") as f:
    lines = f.readlines()
out = []
in_nat = False
inserted = False
for line in lines:
    if line.strip() == "*nat":
        in_nat = True
    if in_nat and line.strip() == "COMMIT" and not inserted:
        out.append("# Hy2 Port Hopping\n")
        out.append(f"-A PREROUTING -p udp --dport {r_range} -j REDIRECT --to-ports {r_port}\n")
        inserted = True
        in_nat = False
    out.append(line)
with open(rule_file, "w", encoding="utf-8") as f:
    f.writelines(out)
EOF_UFW6_PY
            else
                python3 - "/etc/ufw/before6.rules" "${PH_RANGE}" "${HY2_PORT}" << 'EOF_UFW6_PY2' 2>/dev/null || true
import sys
rule_file, r_range, r_port = sys.argv[1], sys.argv[2], sys.argv[3]
with open(rule_file, "r", encoding="utf-8") as f:
    content = f.read()
nat_block = f"# Port Hopping for Hysteria 2 - IPv6 (added by setup.sh)\n*nat\n:PREROUTING ACCEPT [0:0]\n# Hy2 Port Hopping\n-A PREROUTING -p udp --dport {r_range} -j REDIRECT --to-ports {r_port}\nCOMMIT\n\n"
if "*filter" in content:
    content = content.replace("*filter", nat_block + "*filter", 1)
else:
    content = nat_block + content
with open(rule_file, "w", encoding="utf-8") as f:
    f.write(content)
EOF_UFW6_PY2
            fi
        elif grep -q '^\*nat' /etc/ufw/before6.rules 2>/dev/null; then
            sed -i "/^\*nat/,/^COMMIT/{/^COMMIT/i\\# Hy2 Port Hopping\n-A PREROUTING -p udp --dport ${PH_RANGE} -j REDIRECT --to-ports ${HY2_PORT}
            }" /etc/ufw/before6.rules
        else
            sed -i '/^\*filter/i\# Port Hopping for Hysteria 2 - IPv6 (added by setup.sh)\n*nat\n:PREROUTING ACCEPT [0:0]\n# Hy2 Port Hopping\n-A PREROUTING -p udp --dport '"${PH_RANGE}"' -j REDIRECT --to-ports '"${HY2_PORT}"'\nCOMMIT\n' /etc/ufw/before6.rules
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

