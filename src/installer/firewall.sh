# Apply only the ports owned by this installation, preserving existing rules.
command -v ufw >/dev/null 2>&1 || die "UFW is not installed."

# SSH Management access
local active_ssh="${SSH_ACTIVE_PORT:-22}"
local target_ssh="${SSH_PORT:-${active_ssh}}"
ufw allow "${active_ssh}/tcp" comment 'SSH (Active)'
if [ -n "$target_ssh" ] && [ "$target_ssh" != "$active_ssh" ]; then
    ufw allow "${target_ssh}/tcp" comment 'SSH (Target)'
fi

# Web endpoints: HTTP Let's Encrypt / Decoy and HTTPS Nginx L4 Stream Router
ufw allow 80/tcp comment 'HTTP (Let'\''s Encrypt / Decoy)'
ufw allow 443/tcp comment 'HTTPS (Nginx L4 Stream Router)'

# Internal stack ports (deny direct external access to prevent bypass of Nginx and scanner discovery)
for private_port in "${PANEL_PORT:-10443}" "${SUB_PORT:-55443}" "${XHTTP_STREAM_PORT:-50443}" "${REALITY_FALLBACK_PORT:-9443}" "${ALL_REALITY_PORTS[@]:-}"; do
    [ -z "$private_port" ] && continue
    ufw deny "$private_port/tcp" comment 'Stack Internal (Anti-Scanning)'
done

# Protocol listeners: allow public entrypoints, deny non-public internal proxies
while read -r protocol transport port; do
    local ufw_port="${port//-/:}"
    if protocol_is_public "$protocol"; then
        ufw allow "$ufw_port/$transport" comment "VPN: $protocol"
    else
        ufw deny "$ufw_port/$transport" comment "Internal: $protocol"
    fi
done < <(selected_protocol_ports)

# Port Hopping for Hysteria 2
if is_true "${ENABLE_HY2:-n}" && is_true "${HY2_PORT_HOPPING:-n}" && [ -n "${HY2_PORT_HOPPING_RANGE:-}" ]; then
    ufw allow "${HY2_PORT_HOPPING_RANGE}/udp" comment 'VPN: Hysteria 2 Port Hopping'
fi
if ! ufw status | grep -qw active; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw --force enable
fi
# @include "system/firewall.sh"
