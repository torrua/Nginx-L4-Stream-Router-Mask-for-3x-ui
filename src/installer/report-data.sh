# =============================================================
#  ФОРМИРОВАНИЕ ИТОГОВ И ИНСТРУКЦИИ ДЛЯ 3X-UI
# =============================================================
UFW_DENY_LIST=""
for port in "${ALL_REALITY_PORTS[@]:-}"; do
    if [ -n "$port" ]; then
        UFW_DENY_LIST="${UFW_DENY_LIST} && ufw deny ${port}/tcp"
    fi
done

UFW_ALLOW_LIST="ufw allow 80/tcp && ufw allow 443/tcp"
if [[ "${ENABLE_HY2:-}" == "1" || "${ENABLE_HY2,,}" == "y" ]] && [ -n "${HY2_PORT:-}" ]; then
    if [ "${HY2_PORT}" != "443" ]; then
        UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${HY2_PORT}/udp"
    else
        UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow 443/udp"
    fi
    # Port Hopping: открываем диапазон UDP-портов
    if [[ "${HY2_PORT_HOPPING,,}" == "y" || "${HY2_PORT_HOPPING:-}" == "1" ]] && [ -n "${HY2_PORT_HOPPING_RANGE:-}" ]; then
        UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${HY2_PORT_HOPPING_RANGE//:/ }/udp"
    fi
fi
if [[ "${ENABLE_AWG_V3:-}" == "1" || "${ENABLE_AWG_V3,,}" == "y" ]] && [ -n "${AWG_V3_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${AWG_V3_PORT}/udp"
fi
if [[ "${ENABLE_AWG_V2:-}" == "1" || "${ENABLE_AWG_V2,,}" == "y" ]] && [ -n "${AWG_V2_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${AWG_V2_PORT}/udp"
fi
if [[ "${ENABLE_AWG_STANDALONE:-}" == "1" || "${ENABLE_AWG_STANDALONE,,}" == "y" ]] && [ -n "${AWG_STANDALONE_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${AWG_STANDALONE_PORT}/udp"
fi
if [[ "${ENABLE_SS2022:-}" == "1" || "${ENABLE_SS2022,,}" == "y" ]] && [ -n "${SS2022_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${SS2022_PORT}/tcp && ufw allow ${SS2022_PORT}/udp"
fi
if [[ "${ENABLE_TUIC:-}" == "1" || "${ENABLE_TUIC,,}" == "y" ]] && [ -n "${TUIC_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${TUIC_PORT}/udp"
fi
if [[ "${ENABLE_MTPROTO:-}" == "1" || "${ENABLE_MTPROTO,,}" == "y" ]] && [ -n "${MTPROTO_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${MTPROTO_PORT}/tcp"
fi
if [[ "${ENABLE_MASQUE:-}" == "1" || "${ENABLE_MASQUE,,}" == "y" ]] && [ -n "${MASQUE_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${MASQUE_PORT}/udp"
fi
if [[ "${ENABLE_DNSTT:-}" == "1" || "${ENABLE_DNSTT,,}" == "y" ]] && [ -n "${DNSTT_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${DNSTT_PORT}/udp"
fi
if [[ "${ENABLE_MIERU:-}" == "1" || "${ENABLE_MIERU,,}" == "y" ]] && [ -n "${MIERU_PORT:-}" ]; then
    _ufw_m_p="${MIERU_PORT//-/:}"
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${_ufw_m_p}/tcp && ufw allow ${_ufw_m_p}/udp"
fi

SSL_CERT_REPORT=""
for dom in "${ALL_DOMAINS[@]}"; do
    if [ -f "${SSL_BASE_DIR}/$dom/fullchain.pem" ]; then
        SSL_CERT_REPORT+="  - Домен: ${CYAN}${dom}${NC}\n"
        SSL_CERT_REPORT+="    Cert: ${GREEN}${SSL_BASE_DIR}/${dom}/fullchain.pem${NC}\n"
        SSL_CERT_REPORT+="    Key:  ${GREEN}${SSL_BASE_DIR}/${dom}/privkey.pem${NC}\n\n"
    fi
done

REALITY_INBOUNDS_REPORT=""
if is_true "${STEAL_ENABLED:-0}"; then
    REALITY_INBOUNDS_REPORT+="\n  ${BOLD}[Сценарий 1: VLESS REALITY (маскировка под свой сайт с защитой Anti-Loop)]${NC}\n"
    for port in "${STEAL_PORTS_LIST[@]}"; do
        p_doms=()
        for s_dom in "${STEAL_DOMAINS[@]}"; do
            [ -n "$s_dom" ] || continue
            if [ "${DOMAIN_TO_PORT[$s_dom]:-}" = "$port" ]; then
                p_doms+=("$s_dom")
            fi
        done
        [ ${#p_doms[@]} -gt 0 ] || continue

        REALITY_INBOUNDS_REPORT+="    - Инбаунд для порта ${GREEN}${port}${NC} (Домены: ${CYAN}${p_doms[*]}${NC}):
      * ${YELLOW}Вкладка «Основное»:${NC} Протокол: ${GREEN}vless${NC} | Адрес: ${GREEN}127.0.0.1${NC} | Порт: ${GREEN}${port}${NC}
      * ${YELLOW}Вкладка «Поток»:${NC} Транспорт: ${GREEN}RAW (tcp)${NC} | Accept Proxy Protocol: ${GREEN}Включить (xver: 1)${NC}
      * ${YELLOW}Вкладка «Безопасность»:${NC} ${GREEN}Reality${NC} | uTLS: ${GREEN}chrome / firefox${NC}
        - Dest (Anti-Loop Fallback): ${GREEN}127.0.0.1:${REALITY_FALLBACK_PORT}${NC}
        - Proxy Protocol для Dest: ${GREEN}Включить (xver: 1)${NC}
        - Server Names (SNI): ${CYAN}${p_doms[*]}${NC}
      * ${YELLOW}Вкладка «Сниффинг»:${NC} Включить (${GREEN}HTTP, TLS, QUIC, FAKEDNS${NC})\n\n"
    done
fi

if is_true "${CLASSIC_ENABLED:-0}"; then
    REALITY_INBOUNDS_REPORT+="\n  ${BOLD}[Сценарий 2: VLESS REALITY (маскировка под популярные внешние сервисы)]${NC}\n"
    for port in "${CLASSIC_PORTS_LIST[@]}"; do
        p_snis=()
        for ext_sni in "${!EXT_SNI_TO_PORT[@]}"; do
            if [ "${EXT_SNI_TO_PORT[$ext_sni]:-}" = "$port" ]; then
                p_snis+=("$ext_sni")
            fi
        done
        [ ${#p_snis[@]} -gt 0 ] || p_snis=("gateway.icloud.com")
        primary_ext="${p_snis[0]}"

        REALITY_INBOUNDS_REPORT+="    - Инбаунд для порта ${GREEN}${port}${NC} (SNI: ${CYAN}${p_snis[*]}${NC}):
      * ${YELLOW}Вкладка «Основное»:${NC} Протокол: ${GREEN}vless${NC} | Адрес: ${GREEN}127.0.0.1${NC} | Порт: ${GREEN}${port}${NC}
      * ${YELLOW}Вкладка «Поток»:${NC} Транспорт: ${GREEN}RAW (tcp)${NC} | Accept Proxy Protocol: ${GREEN}Включить (xver: 1)${NC}
      * ${YELLOW}Вкладка «Безопасность»:${NC} ${GREEN}Reality${NC} | uTLS: ${GREEN}chrome / firefox${NC}
        - Dest (Target): ${CYAN}${primary_ext}:443${NC}
        - Proxy Protocol для Dest: ${RED}Выключить (xver: 0)${NC}
        - Server Names (SNI): ${CYAN}${p_snis[*]}${NC}
      * ${YELLOW}Вкладка «Сниффинг»:${NC} Включить (${GREEN}HTTP, TLS, QUIC, FAKEDNS${NC})\n\n"
    done
fi



