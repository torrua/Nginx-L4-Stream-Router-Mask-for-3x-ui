install_step_awg() {
        ensure_amneziawg_installed
        setup_amneziawg_controller
        deploy_amneziawg_backend
        awg_p="${AWG_STANDALONE_PORT:-8445}"
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw allow "${awg_p}/udp" comment "AmneziaWG UDP Port" >/dev/null 2>&1 || true
            if [ -n "${OLD_AWG_PORT:-}" ] && [ "${OLD_AWG_PORT}" != "${awg_p}" ]; then
                ufw delete allow "${OLD_AWG_PORT}/udp" >/dev/null 2>&1 || true
            fi
            ok "Правило файрвола UFW: разрешен порт ${awg_p}/udp (AmneziaWG)"
        else
            command -v iptables >/dev/null 2>&1 && iptables -I INPUT -p udp --dport "${awg_p}" -j ACCEPT >/dev/null 2>&1 || true
            ok "Правило файрвола iptables: разрешен порт ${awg_p}/udp (AmneziaWG)"
        fi
}
