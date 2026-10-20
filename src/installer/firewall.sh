# Apply only the ports owned by this installation, preserving existing rules.
command -v ufw >/dev/null 2>&1 || die "UFW is not installed."
ufw allow "${SSH_ACTIVE_PORT:-22}/tcp"
ufw allow "${SSH_PORT:-${SSH_ACTIVE_PORT:-22}}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
for private_port in "${PANEL_PORT:-10443}" "${SUB_PORT:-55443}" "${XHTTP_STREAM_PORT:-50443}" "${REALITY_FALLBACK_PORT:-9443}" "${ALL_REALITY_PORTS[@]:-}"; do
    [ -z "$private_port" ] && continue
    ufw deny "$private_port/tcp"
done
while read -r protocol transport port; do
    if protocol_is_public "$protocol"; then
        ufw allow "$port/$transport"
    else
        ufw deny "$port/$transport"
    fi
done < <(selected_protocol_ports)
if is_true "${ENABLE_HY2:-n}" && is_true "${HY2_PORT_HOPPING:-n}" && [ -n "${HY2_PORT_HOPPING_RANGE:-}" ]; then
    ufw allow "${HY2_PORT_HOPPING_RANGE}/udp"
fi
if ! ufw status | grep -qw active; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw --force enable
fi
# @include "system/firewall.sh"
