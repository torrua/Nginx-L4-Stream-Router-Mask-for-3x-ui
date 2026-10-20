# Pure plan construction. Express and Expert differ only in how they collect input.
# @include "common/protocols.sh"
declare -a INSTALLATION_PLAN=()
declare -A STEP_IDS=() STEP_NUMBERS=()
declare -A INSTALLATION_TITLES=(
    [packages]="Базовые системные зависимости"
    [kernel]="Сетевые параметры и лимиты"
    [security]="Безопасность SSH и Fail2ban"
    [nginx]="Установка Nginx и подготовка HTTP для ACME"
    [certificates]="Выпуск SSL-сертификатов"
    [decoy]="Развертывание выбранного сайта"
    [nginx_config]="Конфигурация и проверка Nginx"
    [firewall]="Правила доступа и маршрутизации"
    [panel]="Панель 3X-UI и выбранные протоколы"
    [adguard]="AdGuard Home и DNS"
    [awg]="Автономный сервер AmneziaWG"
    [verify]="Проверка всех выбранных компонентов"
)

build_installation_plan() {
    INSTALLATION_PLAN=(packages kernel)
    if is_true "${ENABLE_HOST_SECURITY:-n}" || is_true "${ENABLE_FAIL2BAN:-n}" ||
       is_true "${DISABLE_PASSWORD_AUTH:-n}" || [ -n "${SSH_PUBLIC_KEY:-}" ] ||
       [ "${SSH_PORT:-${SSH_ACTIVE_PORT:-22}}" != "${SSH_ACTIVE_PORT:-22}" ]; then
        INSTALLATION_PLAN+=(security)
    fi
    if is_true "${ENABLE_WEB_STACK:-y}"; then
        INSTALLATION_PLAN+=(nginx certificates decoy nginx_config firewall)
        if is_true "${AUTO_SETUP_3XUI:-y}"; then INSTALLATION_PLAN+=(panel); fi
        if is_true "${ENABLE_AGH:-n}"; then INSTALLATION_PLAN+=(adguard); fi
    fi
    if is_true "${ENABLE_AWG_STANDALONE:-n}"; then INSTALLATION_PLAN+=(awg); fi
    INSTALLATION_PLAN+=(verify)
    TOTAL_STEPS=${#INSTALLATION_PLAN[@]}
    STEP_IDS=(); STEP_NUMBERS=(); STEP_NAMES=()
    local index=1 id
    for id in "${INSTALLATION_PLAN[@]}"; do
        STEP_IDS[$index]="$id"
        STEP_NUMBERS[$id]=$index
        STEP_NAMES[$index]="${INSTALLATION_TITLES[$id]}"
        index=$((index + 1))
    done
}

show_installation_plan() {
    printf '\nПлан установки (%s этапов):\n' "$TOTAL_STEPS"
    local id
    for id in "${INSTALLATION_PLAN[@]}"; do
        printf '  %2s. %s\n' "${STEP_NUMBERS[$id]}" "${INSTALLATION_TITLES[$id]}"
    done
    printf '  SSH: %s → %s; настройки: %s\n' "${SSH_ACTIVE_PORT:-22}" \
        "${SSH_PORT:-${SSH_ACTIVE_PORT:-22}}" "${SAVED_CONFIG_FILE:-server-setup.env}"
    if is_true "${ENABLE_WEB_STACK:-y}"; then
        printf '  Домен: %s; SSL: %s\n' "${PRIMARY_DOMAIN:-}" "${SSL_ENGINE_CHOICE:-1}"
    fi
    local name transport port scope
    while read -r name transport port; do
        scope="публичный"
        if ! protocol_is_public "$name"; then scope="локальный, через Nginx"; fi
        printf '  %s: %s/%s (%s)\n' "$name" "$port" "$transport" "$scope"
    done < <(selected_protocol_ports)
}

confirm_installation_plan() {
    show_installation_plan
    [ "${NON_INTERACTIVE:-0}" -eq 1 ] && return 0
    local answer=""
    printf '\nПрименить этот план? [Y/n]: '
    read -r answer </dev/tty 2>/dev/null || read -r answer || return 1
    answer="${answer//[[:space:]]/}"
    case "${answer,,}" in
        ''|y|yes|д|да) return 0 ;;
        *) warn "Установка отменена. Изменения системы не применялись."; return 1 ;;
    esac
}

validate_installation_config() {
    if ! is_true "${ENABLE_WEB_STACK:-y}" && ! is_true "${ENABLE_AWG_STANDALONE:-n}"; then
        die "Не выбран ни один компонент установки."
    fi
    if is_true "${ENABLE_WEB_STACK:-y}"; then
        [[ "${PRIMARY_DOMAIN:-}" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || die "Некорректный основной домен."
        if [ -z "${LE_EMAIL:-}" ]; then
            LE_EMAIL="admin@${PRIMARY_DOMAIN}"
        fi
    else
        [ -n "${AWG_SERVER_HOST:-}" ] || die "Не задан Endpoint автономного AmneziaWG."
    fi
    local name value transport binding
    local -A claimed=()
    while read -r name transport value; do
        [[ "$value" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$value))" -ge 1 ] && [ "$((10#$value))" -le 65535 ] || die "Некорректный порт $name: $value"
        binding="$transport:$((10#$value))"
        [ -z "${claimed[$binding]:-}" ] || die "Конфликт порта $value/$transport: ${claimed[$binding]} и $name. Измените порт одного из компонентов."
        claimed[$binding]="$name"
    done < <(installation_listeners)
}

run_installation() {
    validate_installation_config
    inspect_port_conflicts
    build_installation_plan
    confirm_installation_plan
    save_session_state "${SAVED_CONFIG_FILE:-server-setup.env}"
    if command -v create_initial_state_snapshot >/dev/null 2>&1; then
        create_initial_state_snapshot || true
    fi
    WEBROOT="/var/www/html"
    NGINX_USER=nginx
    if ! id -u nginx >/dev/null 2>&1; then NGINX_USER=www-data; fi
    if [ "${SSL_ENGINE_CHOICE:-1}" = 1 ]; then SSL_BASE_DIR=/etc/letsencrypt/live; else SSL_BASE_DIR=/etc/ssl/acme; fi
    local id
    for id in "${INSTALLATION_PLAN[@]}"; do
        if should_skip_step "$id"; then continue; fi
        step_begin "$id"
        "install_step_$id"
        step_finish "$id"
    done
    record_step_completed 0
    save_session_state "${SAVED_CONFIG_FILE:-server-setup.env}"
    report_installation
}
