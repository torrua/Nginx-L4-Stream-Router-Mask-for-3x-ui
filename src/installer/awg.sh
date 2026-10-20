install_step_awg() {
        ensure_amneziawg_installed
        setup_amneziawg_controller
        deploy_amneziawg_backend
        if command -v ufw >/dev/null 2>&1; then
            awg_p="${AWG_STANDALONE_PORT:-8445}"
            ufw allow "${awg_p}/udp" comment "AmneziaWG Standalone Server" >/dev/null 2>&1 || true
            ok "Правило файрвола: разрешен порт ${awg_p}/udp (AmneziaWG)"
        fi
}
