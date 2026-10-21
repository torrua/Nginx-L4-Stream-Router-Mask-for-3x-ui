# Listener declarations shared by planning, validation and final health checks.
protocol_is_public() {
    case "$1" in ShadowTLS|Wstunnel|NaiveProxy) return 1 ;; esac
}

selected_protocol_ports() {
    local flag transport variable fallback name
    if is_true "${ENABLE_WEB_STACK:-y}"; then
        while read -r flag transport variable fallback name; do
            if is_true "${!flag:-n}"; then
                if [ "$flag" = "ENABLE_MIERU" ]; then
                    local m_trans="${MIERU_TRANSPORT:-BOTH}"
                    case "${m_trans^^}" in
                        TCP) [ "$transport" = "udp" ] && continue ;;
                        UDP) [ "$transport" = "tcp" ] && continue ;;
                    esac
                fi
                printf '%s %s %s\n' "$name" "$transport" "${!variable:-$fallback}"
            fi
        done <<'PROTOCOL_PORTS'
ENABLE_HY2 udp HY2_PORT 443 Hysteria2
ENABLE_AWG_V3 udp AWG_V3_PORT 8443 AWG-v3
ENABLE_AWG_V2 udp AWG_V2_PORT 8444 AWG-v2
ENABLE_SS2022 tcp SS2022_PORT 8388 SS2022
ENABLE_SS2022 udp SS2022_PORT 8388 SS2022
ENABLE_TUIC udp TUIC_PORT 8448 TUIC
ENABLE_MTPROTO tcp MTPROTO_PORT 8444 MTProto
ENABLE_MASQUE udp MASQUE_PORT 8449 MASQUE
ENABLE_SHADOWTLS tcp SHADOWTLS_PORT 8543 ShadowTLS
ENABLE_WSTUNNEL tcp WSTUNNEL_PORT 8080 Wstunnel
ENABLE_NAIVE tcp NAIVE_PORT 8446 NaiveProxy
ENABLE_DNSTT udp DNSTT_PORT 53053 DNSTT
ENABLE_MIERU tcp MIERU_PORT 8450 Mieru
ENABLE_MIERU udp MIERU_PORT 8450 Mieru
PROTOCOL_PORTS
    fi
    if is_true "${ENABLE_AWG_STANDALONE:-n}"; then
        printf 'AWG-standalone udp %s\n' "${AWG_STANDALONE_PORT:-8445}"
    fi
    return 0
}

installation_listeners() {
    printf 'SSH tcp %s\n' "${SSH_PORT:-${SSH_ACTIVE_PORT:-22}}"
    if is_true "${ENABLE_WEB_STACK:-y}"; then
        printf 'HTTP tcp 80\nHTTPS tcp 443\n'
        printf 'Panel tcp %s\nSubscription tcp %s\nxHTTP tcp %s\n' \
            "${PANEL_PORT:-10443}" "${SUB_PORT:-55443}" "${XHTTP_STREAM_PORT:-50443}"
        local port
        if is_true "${ENABLE_STEAL:-n}"; then
            for port in "${STEAL_PORTS_LIST[@]:-${STEAL_PORT:-45443}}"; do printf 'Reality-own tcp %s\n' "$port"; done
        fi
        if is_true "${ENABLE_CLASSIC:-n}"; then
            for port in "${CLASSIC_PORTS_LIST[@]:-${CLASSIC_PORT:-46443}}"; do printf 'Reality-external tcp %s\n' "$port"; done
        fi
        if is_true "${ENABLE_AGH:-n}"; then
            printf 'AdGuard-web tcp %s\nAdGuard-DNS tcp 53\nAdGuard-DNS udp 53\n' "${PORT_AGH_WEB:-3000}"
        fi
    fi
    selected_protocol_ports
}
