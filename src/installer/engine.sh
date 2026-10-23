install_step_packages() {
    run_with_spinner "Установка базовых зависимостей" install_prerequisites
}

install_step_kernel() {
    run_with_spinner "Применение сетевых параметров" apply_sysctl_and_limits
}

install_step_security() {
    local_active_ssh="${SSH_ACTIVE_PORT:-22}"
    local_target_ssh="${SSH_PORT:-$local_active_ssh}"
    if is_true "${ENABLE_HOST_SECURITY:-n}" || [ "$local_target_ssh" -ne "$local_active_ssh" ] || is_true "${ENABLE_FAIL2BAN:-n}" || is_true "${DISABLE_PASSWORD_AUTH:-n}" || [ -n "${SSH_PUBLIC_KEY:-}" ]; then
        if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
            add_authorized_key "$SSH_PUBLIC_KEY" "root"
        fi
        if [ "$local_target_ssh" -ne "$local_active_ssh" ] || is_true "${DISABLE_PASSWORD_AUTH:-n}"; then
            run_with_spinner "Применение конфигурации OpenSSH (порт $local_target_ssh)" apply_ssh_configuration "$local_target_ssh" "$local_active_ssh" "${DISABLE_PASSWORD_AUTH:-n}" || die "Не удалось применить конфигурацию SSH."
            if command -v ufw >/dev/null 2>&1; then
                ufw allow "${local_active_ssh}/tcp" comment '[vpn-stack] Current SSH Port' >/dev/null 2>&1 || true
                ufw allow "${local_target_ssh}/tcp" comment '[vpn-stack] Target SSH Port' >/dev/null 2>&1 || true
            fi
        fi
        if is_true "${ENABLE_FAIL2BAN:-n}"; then
            run_with_spinner "Установка и настройка службы Fail2ban" apply_fail2ban_configuration "$local_target_ssh" "$local_active_ssh" || die "Не удалось настроить Fail2ban."
        fi
    fi

    # Настройка Strict DNS-over-TLS для системного резолвера ОС
    run_with_spinner "Настройка Strict DNS-over-TLS (systemd-resolved)" setup_strict_dot_dns || warn "Не удалось настроить systemd-resolved DoT."

    # Настройка автоматических ночных обновлений безопасности (ребут в 04:38)
    run_with_spinner "Настройка автоматических обновлений (unattended-upgrades)" setup_unattended_upgrades || warn "Не удалось настроить unattended-upgrades."
}

# @include "installer/web.sh"
install_step_decoy() {
    :
# @include "nginx/decoys.sh"
}
install_step_nginx_config() {
    :
# @include "nginx/config.sh"
}
apply_firewall_rules() {
    :
# @include "installer/firewall.sh"
}

install_step_firewall() {
    if command -v run_with_spinner >/dev/null 2>&1; then
        run_with_spinner "Применение правил доступа и портов UFW" apply_firewall_rules
    else
        apply_firewall_rules
    fi
}
# @include "installer/panel.sh"
install_step_adguard() {
    :
# @include "adguard/setup.sh"
}
# @include "installer/awg.sh"
install_step_verify() {
    post_install_sanity_check
    if [ "${SSH_PORT:-${SSH_ACTIVE_PORT:-22}}" != "${SSH_ACTIVE_PORT:-22}" ]; then
        wait_and_finalize_ssh_transition "$SSH_PORT" "${SSH_ACTIVE_PORT:-22}"
    fi
}
# @include "installer/report.sh"
