# =============================================================
#  ИНТЕРАКТИВНАЯ КОНФИГУРАЦИЯ И СЦЕНАРИИ МАРШРУТИЗАЦИИ
# =============================================================
EXPRESS_MODE=${EXPRESS_MODE:-0}
EXPERT_MODE=${EXPERT_MODE:-0}

# Проверка сохраненной контрольной точки (Resume Checkpoint)
SKIP_INTERVIEW=0
if [ "$NON_INTERACTIVE" -eq 0 ]; then
    print_mask_banner
    if [ "$LAST_COMPLETED_STEP" -gt 0 ] && [ "$LAST_COMPLETED_STEP" -lt "$TOTAL_STEPS" ]; then
        NEXT_STEP=$(( LAST_COMPLETED_STEP + 1 ))
        echo -e "  ${YELLOW}${BOLD}Обнаружена незавершенная установка!${NC}"
        echo -e "  ${DIM}Последний успешно завершенный шаг: ${WHITE}Шаг $LAST_COMPLETED_STEP из $TOTAL_STEPS (${STEP_NAMES[$LAST_COMPLETED_STEP]:-})${NC}"
        echo -e "    ${CYAN}${BOLD}[1] Продолжить с шага $NEXT_STEP (${STEP_NAMES[$NEXT_STEP]:-})${NC} (Рекомендуется)"
        echo -e "    ${YELLOW}[2] Начать установку заново (с шага 1)${NC}\n"
        read -rp "  Ваш выбор [1/2] (по умолчанию: 1): " RESUME_CHOICE </dev/tty || read -r RESUME_CHOICE || RESUME_CHOICE="1"
        RESUME_CHOICE=$(echo "${RESUME_CHOICE:-1}" | tr -d '[:space:]')
        if [ "$RESUME_CHOICE" != "2" ]; then
            RESUME_STEP="$NEXT_STEP"
            SKIP_INTERVIEW=1
            ok "Возобновление установки с шага $RESUME_STEP..."
        else
            LAST_COMPLETED_STEP=0
            RESUME_STEP=1
            record_step_completed 0
            ok "Сброс контрольной точки. Установка будет начата с первого шага."
        fi
        echo ""
    fi
else
    # В неинтерактивном режиме с переданным конфигом пропускаем интервью и возобновляем
    SKIP_INTERVIEW=1
    if [ "$LAST_COMPLETED_STEP" -gt 0 ] && [ "$LAST_COMPLETED_STEP" -lt "$TOTAL_STEPS" ]; then
        RESUME_STEP=$(( LAST_COMPLETED_STEP + 1 ))
        ok "Неинтерактивный режим: возобновление с шага $RESUME_STEP..."
    fi
fi

if [ "$SKIP_INTERVIEW" -eq 1 ]; then
    # Восстановление массивов из сохраненных скалярных параметров конфигурации
    reconstruct_arrays_from_vars
    REALITY_FALLBACK_PORT="9443"
    if [ "$SSL_ENGINE_CHOICE" = "1" ]; then
        SSL_BASE_DIR="/etc/letsencrypt/live"
    else
        SSL_BASE_DIR="/etc/ssl/acme"
    fi
else
    run_standalone_awg_wizard() {
        echo ""
        echo -e "  ${GREEN}${STAR} ${BOLD}Настройка автономного сервера AmneziaWG (awg-mgr)${NC}"
        echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Подключение клиентов (Endpoint):${NC}"
            echo -e "     Вы можете использовать как IP-адрес сервера, так и ваше доменное имя."
            echo -e "     ${GREEN}SSL-сертификаты НЕ требуются:${NC} WireGuard/AmneziaWG работает по UDP"
            echo -e "     и шифрует трафик ключами Curve25519. Достаточно обычной A-записи домена на IP сервера."
            echo ""
        fi

        local def_host="${AWG_SERVER_HOST:-${PRIMARY_DOMAIN:-$(get_wan_ip)}}"
        prompt_default "Домен или IP-адрес сервера для подключения клиентов (Endpoint)" "$def_host" AWG_SERVER_HOST

        local def_port="${AWG_STANDALONE_PORT:-8445}"
        prompt_default "Внешний UDP-порт для сервера AmneziaWG" "$def_port" AWG_STANDALONE_PORT

        prompt_default "Основной DNS для клиентов AmneziaWG" "${AWG_PRIMARY_DNS:-9.9.9.9}" AWG_PRIMARY_DNS
        prompt_default "Резервный DNS для клиентов AmneziaWG" "${AWG_SECONDARY_DNS:-76.76.2.0}" AWG_SECONDARY_DNS

        ENABLE_AWG_STANDALONE=1
        ENABLE_WEB_STACK=0

        echo ""
        echo -e "  ${YELLOW}━━━ Подтверждение параметров AmneziaWG ━━━${NC}"
        echo -e "    ${DIM}• Хост / Домен (Endpoint):${NC} ${GREEN}${BOLD}${AWG_SERVER_HOST}${NC}"
        echo -e "    ${DIM}• Внешний UDP-порт:${NC}        ${WHITE}${BOLD}${AWG_STANDALONE_PORT}/udp${NC}"
        echo -e "    ${DIM}• Клиентская подсеть:${NC}      ${WHITE}10.8.0.0/22 (до 1022 клиентов)${NC}"
        echo -e "    ${DIM}• DNS-серверы:${NC}             ${WHITE}${AWG_PRIMARY_DNS}, ${AWG_SECONDARY_DNS}${NC}"
        echo -e "    ${DIM}• Профиль обфускации:${NC}      ${WHITE}AmneziaWG 3.1 (Jc=4, Jmin=40, Jmax=70, S1-S4=16, H1-H4)${NC}"
        echo -e "    ${DIM}• Служба на хосте:${NC}         ${GREEN}awg-quick@awg0${NC}"
        echo -e "    ${DIM}• Утилита управления:${NC}      ${GREEN}awg-mgr${NC} (CLI)"
        echo ""

        while true; do
            local choice=""
            echo -ne "  ${WHITE}${ARROW} Начать установку? [${GREEN}Enter = начать${WHITE}, q = отмена]: ${NC}"
            read -r choice </dev/tty || read -r choice || true
            choice=$(echo "${choice:-}" | tr -d '[:space:]')
            if [ -z "$choice" ] || [[ "${choice,,}" == "y" ]] || [[ "${choice,,}" == "yes" ]]; then
                save_session_state "$SAVED_CONFIG_FILE" >/dev/null 2>&1 || true
                return 0
            fi
            if [[ "${choice,,}" == "q" || "${choice,,}" == "quit" || "${choice,,}" == "exit" ]]; then
                die "Установка отменена пользователем."
            fi
            warn "  Некорректный ввод. Нажмите Enter для старта или 'q' для выхода."
        done
    }

    if [ "$NON_INTERACTIVE" -eq 0 ]; then
        START_AT_REVIEW=0
        has_saved_config=0
        if is_true "${ENABLE_WEB_STACK:-y}" && [ -n "${PRIMARY_DOMAIN:-}" ]; then
            has_saved_config=1
        elif ! is_true "${ENABLE_WEB_STACK:-y}" && [ -n "${AWG_SERVER_HOST:-}" ]; then
            has_saved_config=1
        fi

        if [ "$has_saved_config" -eq 1 ]; then
            echo
            echo -e "  ${YELLOW}${BOLD}Обнаружена сохраненная конфигурация предыдущей сессии!${NC}"
            if is_true "${ENABLE_WEB_STACK:-y}"; then
                echo -e "    ${DIM}• Домен:${NC} ${GREEN}${PRIMARY_DOMAIN}${NC}  ${DIM}• Префикс сервера:${NC} ${WHITE}${SERVER_PREFIX:-Server}${NC}"
            else
                echo -e "    ${DIM}• Режим:${NC} ${CYAN}Только автономный AmneziaWG${NC}  ${DIM}• Хост (Endpoint):${NC} ${GREEN}${AWG_SERVER_HOST:-$WAN_IP}${NC}"
            fi
            echo
            echo -e "    ${CYAN}${BOLD}[1] Перейти сразу к экрану подтверждения (Review) и установке${NC} (Рекомендуется)"
            echo -e "    ${GREEN}[2] Пошагово проверить/изменить параметры${NC} (ранее выбранные значения будут по умолчанию)"
            echo -e "    ${RED}[3] Начать заново с чистого листа${NC}"
            echo
            cfg_choice=""
            read -rp "  Ваш выбор [1/2/3] (по умолчанию: 1): " cfg_choice </dev/tty || read -r cfg_choice || cfg_choice="1"
            cfg_choice=$(echo "${cfg_choice:-1}" | tr -d '[:space:]')
            case "$cfg_choice" in
                2)
                    EXPRESS_MODE=0
                    EXPERT_MODE=1
                    START_AT_REVIEW=0
                    ok "Пошаговый режим: сохраненные значения подставлены по умолчанию."
                    ;;
                3)
                    PRIMARY_DOMAIN=""
                    SERVER_PREFIX=""
                    ADD_WWW=""
                    ENABLE_WEB_STACK=""
                    ENABLE_AWG_STANDALONE=""
                    AWG_STANDALONE_PORT=""
                    AWG_SERVER_HOST=""
                    ENABLE_STEAL=""
                    ENABLE_CLASSIC=""
                    ENABLE_HY2=""
                    ENABLE_AWG_V3=""
                    ENABLE_AWG_V2=""
                    ENABLE_AGH=""
                    ENABLE_NODE_TOKEN=""
                    ENABLE_WARP=""
                    AUTO_SETUP_3XUI=""
                    STEAL_DOMAINS=()
                    EXT_SNI_LIST=()
                    STEAL_PORTS_LIST=()
                    CLASSIC_PORTS_LIST=()
                    ALL_REALITY_PORTS=()
                    declare -g -A DOMAIN_TO_PORT=()
                    declare -g -A EXT_SNI_TO_PORT=()
                    START_AT_REVIEW=0
                    ok "Параметры сброшены. Начинаем с чистого листа."
                    ;;
                *)
                    EXPRESS_MODE=0
                    EXPERT_MODE=1
                    START_AT_REVIEW=1
                    ok "Переход к подтверждению конфигурации (Review)..."
                    ;;
            esac
        fi

        if [ "$START_AT_REVIEW" -eq 0 ]; then
            echo
            echo -e "  ${WHITE}${BOLD}Шаг 0: Выбор компонентов для установки:${NC}\n"
            echo -e "  ${CYAN}${BOLD}[1] Комплекс веб-маскировки Nginx + панель 3X-UI${NC}"
            echo -e "      ${DIM}• VLESS REALITY, VLESS xHTTP, Trojan, Hysteria 2, инбаунды 3X-UI${NC}"
            echo -e "      ${DIM}• Автоматический выпуск SSL (Let's Encrypt / Cloudflare), веб-маскировка${NC}"
            prompt_yes_no "  Установить комплекс веб-маскировки Nginx + 3X-UI?" "${ENABLE_WEB_STACK:-y}" ENABLE_WEB_STACK
            echo
            echo -e "  ${CYAN}${BOLD}[2] Автономный сервер AmneziaWG (awg-mgr)${NC}"
            echo -e "      ${DIM}• Работает как системная служба ядра Linux (awg-quick@awg0)${NC}"
            echo -e "      ${DIM}• Управление клиентами через CLI: awg-mgr add/list/qr/remove${NC}"
            echo -e "      ${DIM}• Защита от блокировок по протоколу AmneziaWG (Junk packets, S1-S4, H1-H4)${NC}"
            prompt_yes_no "  Установить автономный сервер AmneziaWG (awg-mgr)?" "${ENABLE_AWG_STANDALONE:-y}" ENABLE_AWG_STANDALONE

            while ! is_true "${ENABLE_WEB_STACK:-y}" && ! is_true "${ENABLE_AWG_STANDALONE:-y}"; do
                echo
                warn "Не выбран ни один компонент для установки! Выберите хотя бы один сервис."
                prompt_yes_no "  Установить комплекс веб-маскировки Nginx + 3X-UI?" "y" ENABLE_WEB_STACK
                prompt_yes_no "  Установить автономный сервер AmneziaWG (awg-mgr)?" "y" ENABLE_AWG_STANDALONE
            done
        fi

        # Запуск фоновой пред-установки с учетом выбранных компонентов
        start_background_preinstall
        if is_true "${ENABLE_AWG_STANDALONE:-0}"; then
            start_amneziawg_preinstall_bg
        fi

        if ! is_true "${ENABLE_WEB_STACK:-y}"; then
            # Сценарий только автономного сервера AmneziaWG
            EXPRESS_MODE=0
            EXPERT_MODE=0
            run_standalone_awg_wizard
            SKIP_WIZARD_STEPS=1
        fi

        if [ "${SKIP_WIZARD_STEPS:-0}" -eq 0 ] && [ -z "${PRIMARY_DOMAIN:-}" ] && [ "$EXPRESS_MODE" -eq 0 ] && [ "$EXPERT_MODE" -eq 0 ]; then
            echo -e "  ${WHITE}${BOLD}Выберите режим настройки:${NC}\n"
            echo -e "    ${CYAN}${BOLD}[1] Экспресс-установка (Рекомендуется)${NC} — Настройка в 2 вопроса"
            echo -e "        ${DIM}• Ввод только домена и email для Let's Encrypt.${NC}"
            echo -e "        ${DIM}• Автоматический выбор лучших протоколов (VLESS REALITY, VLESS xHTTP, AmneziaWG).${NC}"
            echo -e "        ${DIM}• Готовый сайт-маскировка DataSphere Analytics + автогенерация безопасных путей.${NC}\n"
            echo -e "    ${YELLOW}${BOLD}[2] Экспертная детальная настройка${NC} — Полный контроль параметров"
            echo -e "        ${DIM}• Пошаговый выбор всех портов, путей подписок, Hysteria 2 и AmneziaWG.${NC}\n"
            
            while true; do
                echo -ne "  ${WHITE}${ARROW} Ваш выбор [1/2] (по умолчанию: 1): ${NC}"
                read -r MODE_INPUT </dev/tty || read -r MODE_INPUT || MODE_INPUT="1"
                MODE_INPUT=$(echo "${MODE_INPUT:-1}" | tr -d '[:space:]')
                if [ "$MODE_INPUT" = "1" ]; then
                    EXPRESS_MODE=1
                    break
                elif [ "$MODE_INPUT" = "2" ]; then
                    EXPRESS_MODE=0
                    EXPERT_MODE=1
                    break
                fi
                echo -e "  ${RED}Пожалуйста, введите 1 или 2.${NC}"
            done
        fi
    fi

if [ "${SKIP_WIZARD_STEPS:-0}" -eq 1 ]; then
    rebuild_all_domains
    sync_reality_ports
elif [ "$EXPRESS_MODE" -eq 1 ]; then
    echo ""
    echo -e "  ${GREEN}${STAR} ${BOLD}Включен режим: Экспресс-установка${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
    
    echo -e "  ${YELLOW}[i] Важно о DNS:${NC} ${DIM}Для маскировки требуются A-записи основного домена и поддомена cdn.<домен>${NC}"
    if [ -z "${PRIMARY_DOMAIN:-}" ]; then
        while true; do
            echo -ne "  ${WHITE}${ARROW} Введите ваш основной домен (напр. domain.com): ${NC}"
            read -r PRIMARY_DOMAIN </dev/tty || read -r PRIMARY_DOMAIN || true
            PRIMARY_DOMAIN=$(echo "${PRIMARY_DOMAIN:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            if [[ -n "$PRIMARY_DOMAIN" && "$PRIMARY_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
                break
            fi
            echo -e "  ${RED}${CROSS} Некорректный формат домена. Попробуйте еще раз.${NC}"
        done
    fi
    
    if [ -z "${LE_EMAIL:-}" ]; then
        echo -ne "  ${WHITE}${ARROW} Введите Email для сертификатов Let's Encrypt: ${NC}"
        read -r LE_EMAIL </dev/tty || read -r LE_EMAIL || true
        LE_EMAIL=$(echo "${LE_EMAIL:-}" | tr -d '[:space:]')
    fi
    
    # Автоматические пресеты для Экспресс-режима
    ADD_WWW="n"
    ENABLE_STEAL="y"
    STEAL_PORT="45443"
    STEAL_DOMAINS=("cdn.$PRIMARY_DOMAIN")
    ENABLE_CLASSIC="y"
    CLASSIC_PORT="46443"
    CLASSIC_SNI_LIST=("avito.ru")
    PANEL_PORT="${PANEL_PORT:-10443}"
    ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(head -c 128 /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 12 || echo "Admin1234567")}"
    SERVER_PREFIX="${SERVER_PREFIX:-Server}"
    if [ -n "${PANEL_PATH:-}" ]; then
        RAW_PATH="${PANEL_PATH#/}"
        RAW_PATH="${RAW_PATH%/}"
        PANEL_PATH="/${RAW_PATH}/"
    else
        RAW_PATH="panel-$(head -c 64 /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 6 || echo "${RANDOM}")"
        PANEL_PATH="/${RAW_PATH}/"
    fi
    SUB_PORT="55443"
    RAW_SUB_PATH="sub-$(head -c 64 /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 6 || echo "${RANDOM}")"
    SUB_PATH="/${RAW_SUB_PATH}/"
    SUB_JSON_PATH="${SUB_PATH%/}/json/"
    SUB_CLASH_PATH="${SUB_PATH%/}/clash/"
    XHTTP_STREAM_PORT="50443"
    RAW_XHTTP_STREAM_PATH="$(head -c 64 /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "xh${RANDOM}")"
    XHTTP_STREAM_PATH="/${RAW_XHTTP_STREAM_PATH}/"
    ENABLE_HY2="1"
    HY2_PORT="443"
    HY2_DOMAIN="$PRIMARY_DOMAIN"
    HY2_PORT_HOPPING="${HY2_PORT_HOPPING:-n}"
    HY2_PORT_HOPPING_RANGE="${HY2_PORT_HOPPING_RANGE:-20000:50000}"
    ENABLE_AWG_V3="1"
    AWG_V3_PORT="8443"
    ENABLE_AWG_V2="0"
    AWG_V2_PORT=""
    if is_true "${ENABLE_AWG_STANDALONE:-n}"; then
        ENABLE_AWG_STANDALONE=1
        AWG_STANDALONE_PORT="${AWG_STANDALONE_PORT:-8445}"
        AWG_SERVER_HOST="${AWG_SERVER_HOST:-$PRIMARY_DOMAIN}"
    else
        ENABLE_AWG_STANDALONE=0
        AWG_STANDALONE_PORT=""
    fi
    DECOY_MODE="1"
    SSL_ENGINE_CHOICE="1"
    AUTO_SETUP_3XUI="y"
    ENABLE_NODE_TOKEN="${ENABLE_NODE_TOKEN:-n}"
    NODE_TOKEN_NAME="${NODE_TOKEN_NAME:-}"
    NODE_TOKEN="${NODE_TOKEN:-}"
    ENABLE_WARP="${ENABLE_WARP:-y}"
    WARP_LICENSE_KEY="${WARP_LICENSE_KEY:-}"
    ENABLE_AGH="${ENABLE_AGH:-y}"
    AGH_MODE="${AGH_MODE:-1}"
    AGH_DOMAIN=""
    AGH_USER="${AGH_USER:-admin}"
    DEFAULT_AG_PASS="AgHome_$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 8 || echo 'Pass1234')"
    AGH_PASS="${AGH_PASS:-$DEFAULT_AG_PASS}"
    AGH_CLIENT_ID="${AGH_CLIENT_ID:-home-router}"
    AGH_XRAY_DNS="${AGH_XRAY_DNS:-y}"
    STEAL_ENABLED=1
    CLASSIC_ENABLED=1
    
    ALL_DOMAINS=("$PRIMARY_DOMAIN")
    declare -A DOMAIN_TO_PORT=()
    declare -A EXT_SNI_TO_PORT=()
    STEAL_PORTS_LIST=("$STEAL_PORT")
    CLASSIC_PORTS_LIST=("$CLASSIC_PORT")
    ALL_REALITY_PORTS=("$STEAL_PORT" "$CLASSIC_PORT")
    REALITY_FALLBACK_PORT="9443"
    
    ALL_DOMAINS+=("cdn.$PRIMARY_DOMAIN")
    DOMAIN_TO_PORT["cdn.$PRIMARY_DOMAIN"]="$STEAL_PORT"
    
    ALL_EXT_SNIS=("avito.ru")
    EXT_SNI_TO_PORT["avito.ru"]="$CLASSIC_PORT"
    
    echo -e "  ${GREEN}${CHECK} Экспресс-параметры применены:${NC}"
    echo -e "    ${DIM}• Домен:${NC}          ${WHITE}${BOLD}$PRIMARY_DOMAIN${NC}"
    echo -e "    ${DIM}• REALITY (свой сайт):${NC}  ${WHITE}cdn.$PRIMARY_DOMAIN -> 127.0.0.1:$STEAL_PORT${NC}"
    echo -e "    ${DIM}• REALITY (внешний):${NC}    ${WHITE}avito.ru -> 127.0.0.1:$CLASSIC_PORT${NC}"
    echo -e "    ${DIM}• VLESS xHTTP:${NC}    ${WHITE}$XHTTP_STREAM_PATH -> 127.0.0.1:$XHTTP_STREAM_PORT${NC}"
    udp_stack_summary="Hysteria 2 (:443), AWG v3 (:8443)"
    is_true "${ENABLE_AWG_STANDALONE:-0}" && udp_stack_summary="${udp_stack_summary}, Standalone (:8445)"
    echo -e "    ${DIM}• UDP Стек:${NC}       ${WHITE}${udp_stack_summary}${NC}"
    echo -e "    ${DIM}• Cloudflare WARP:${NC} ${WHITE}Активирован (Google, Gemini, AI / YouTube direct)${NC}"
    echo -e "    ${DIM}• Веб-маска:${NC}      ${WHITE}DataSphere Analytics${NC}"
    echo ""
    start_amneziawg_preinstall_bg
else
    # Инициализация глобальных структур и вспомогательных функций мастера настройки
    [[ -v DOMAIN_TO_PORT ]] || declare -g -A DOMAIN_TO_PORT=()
    [[ -v EXT_SNI_TO_PORT ]] || declare -g -A EXT_SNI_TO_PORT=()
    [ -n "${STEAL_PORTS_LIST[*]:-}" ] || STEAL_PORTS_LIST=()
    [ -n "${CLASSIC_PORTS_LIST[*]:-}" ] || CLASSIC_PORTS_LIST=()
    [ -n "${ALL_REALITY_PORTS[*]:-}" ] || ALL_REALITY_PORTS=()
    [ -n "${STEAL_DOMAINS[*]:-}" ] || STEAL_DOMAINS=()
    [ -n "${EXT_SNI_LIST[*]:-}" ] || EXT_SNI_LIST=()
    [ -n "${ALL_EXT_SNIS[*]:-}" ] || ALL_EXT_SNIS=()
    [ -n "${EXTRA_DOMAINS_USER[*]:-}" ] || EXTRA_DOMAINS_USER=()
    REALITY_FALLBACK_PORT="${REALITY_FALLBACK_PORT:-9443}"
    reconstruct_arrays_from_vars

    rebuild_all_domains() {
        ALL_DOMAINS=("$PRIMARY_DOMAIN")
        if [[ "${ADD_WWW,,}" == "y" && ! "$PRIMARY_DOMAIN" =~ ^www\. ]]; then
            ALL_DOMAINS+=("www.$PRIMARY_DOMAIN")
        fi
        if is_true "${STEAL_ENABLED:-0}"; then
            for s_dom in "${STEAL_DOMAINS[@]}"; do
                [ -n "$s_dom" ] || continue
                if [[ ! " ${ALL_DOMAINS[*]} " == *" ${s_dom} "* ]]; then
                    ALL_DOMAINS+=("$s_dom")
                fi
            done
        fi
        if is_true "${ENABLE_HY2:-0}" && [ -n "${HY2_DOMAIN:-}" ]; then
            if [[ ! " ${ALL_DOMAINS[*]} " == *" ${HY2_DOMAIN} "* ]]; then
                ALL_DOMAINS+=("$HY2_DOMAIN")
            fi
        fi
        if is_true "${ENABLE_AGH:-0}" && [ "${AGH_MODE:-1}" = "2" ] && [ -n "${AGH_DOMAIN:-}" ]; then
            if [[ ! " ${ALL_DOMAINS[*]} " == *" ${AGH_DOMAIN} "* ]]; then
                ALL_DOMAINS+=("$AGH_DOMAIN")
            fi
        fi
        for extra_d in "${EXTRA_DOMAINS_USER[@]:-}"; do
            if [[ -n "$extra_d" && ! " ${ALL_DOMAINS[*]} " == *" ${extra_d} "* ]]; then
                ALL_DOMAINS+=("$extra_d")
            fi
        done
    }

    sync_reality_ports() {
        ALL_REALITY_PORTS=()
        if is_true "${STEAL_ENABLED:-0}"; then
            for p in "${STEAL_PORTS_LIST[@]:-}"; do
                [ -n "$p" ] && ALL_REALITY_PORTS+=("$p")
            done
        fi
        if is_true "${CLASSIC_ENABLED:-0}"; then
            for p in "${CLASSIC_PORTS_LIST[@]:-}"; do
                [ -n "$p" ] && ALL_REALITY_PORTS+=("$p")
            done
        fi
    }

    scan_reality_candidates() {
        python3 -c "
import ssl, socket, time, concurrent.futures

CANDIDATES = [
    'avito.ru',
    'www.avito.ru',
    'dl.google.com',
    'www.apple.com',
    'itunes.apple.com',
    'www.samsung.com',
    'www.nvidia.com',
    'www.microsoft.com',
    'www.amazon.com',
    'www.amd.com',
    'www.sony.com',
    'cdn.discordapp.com',
]

def probe(host):
    ctx = ssl.create_default_context()
    ctx.set_alpn_protocols(['h2'])
    t0 = time.time()
    try:
        with socket.create_connection((host, 443), timeout=3.0) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as ssock:
                lat = int((time.time() - t0) * 1000)
                ver = ssock.version()
                alpn = ssock.selected_alpn_protocol()
                feasible = (ver == 'TLSv1.3' and alpn == 'h2')
                return {'host': host, 'feasible': feasible, 'lat': lat}
    except Exception:
        return {'host': host, 'feasible': False, 'lat': 9999}

with concurrent.futures.ThreadPoolExecutor(max_workers=len(CANDIDATES)) as ex:
    res = list(ex.map(probe, CANDIDATES))

res.sort(key=lambda x: (0 if x['feasible'] else 1, x['lat']))
for item in res:
    if item['feasible']:
        print(item['host'] + ' ' + str(item['lat']))
" 2>/dev/null || true
    }

    run_non_interactive_setup() {
        if is_true "${ENABLE_WEB_STACK:-y}"; then
            [ -n "${PRIMARY_DOMAIN:-}" ] || die "Ошибка: PRIMARY_DOMAIN не задан в конфигурации или аргументах!"
            [[ "$PRIMARY_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || die "Некорректный формат доменного имени: $PRIMARY_DOMAIN"
            ok "Основной домен (из конфигурации): $PRIMARY_DOMAIN"
        else
            ok "Режим установки: Только автономный сервер AmneziaWG (веб-стек Nginx/3X-UI отключен)."
            [ -n "${AWG_SERVER_HOST:-}" ] || AWG_SERVER_HOST="$(get_wan_ip)"
            ok "Хост подключения AmneziaWG (Endpoint): $AWG_SERVER_HOST"
        fi

        SERVER_PREFIX="${SERVER_PREFIX:-$(hostname -s 2>/dev/null || echo "Server")}"
        [[ "$SERVER_PREFIX" =~ ^(localhost|ubuntu|debian|centos|vps.*)$ ]] && SERVER_PREFIX="Server"

        ADD_WWW="${ADD_WWW:-n}"

        # Steal-Oneself
        if [[ "${ENABLE_STEAL,,}" == "y" || "${ENABLE_STEAL:-}" == "1" ]]; then
            STEAL_ENABLED=1
            local s_port="${STEAL_PORT:-45443}"
            STEAL_PORTS_LIST+=("$s_port")
            local default_steal_dom="cdn.$PRIMARY_DOMAIN"
            local steal_dom_list="${STEAL_DOMAINS[*]:-$default_steal_dom}"
            STEAL_DOMAINS=()
            for s_dom in $steal_dom_list; do
                [[ "$s_dom" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || continue
                STEAL_DOMAINS+=("$s_dom")
                DOMAIN_TO_PORT["$s_dom"]="$s_port"
                ok "    Домен $s_dom привязан к инбаунд-порту $s_port"
            done
        else
            STEAL_ENABLED=0
        fi

        # Classic REALITY
        if [[ "${ENABLE_CLASSIC,,}" == "y" || "${ENABLE_CLASSIC:-}" == "1" ]]; then
            CLASSIC_ENABLED=1
            local c_port="${CLASSIC_PORT:-46443}"
            CLASSIC_PORTS_LIST+=("$c_port")
            local classic_sni_list="${CLASSIC_SNI:-avito.ru}"
            EXT_SNI_LIST=()
            for ext_sni in $classic_sni_list; do
                [[ "$ext_sni" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || continue
                EXT_SNI_TO_PORT["$ext_sni"]="$c_port"
                EXT_SNI_LIST+=("$ext_sni")
                ALL_EXT_SNIS+=("$ext_sni")
                ok "    Внешний SNI $ext_sni привязан к инбаунд-порту $c_port"
            done
        else
            CLASSIC_ENABLED=0
        fi

        # Порты и пути
        PANEL_PORT="${PANEL_PORT:-10443}"
        ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
        ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 12 || echo "Admin1234567")}"
        if [ -n "${PANEL_PATH:-}" ]; then
            RAW_PATH="${PANEL_PATH#/}"; RAW_PATH="${RAW_PATH%/}"
        elif [ -z "${RAW_PATH:-}" ]; then
            RAW_PATH="panel-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "3xui${RANDOM}")"
        fi
        RAW_PATH="${RAW_PATH#/}"; RAW_PATH="${RAW_PATH%/}"
        validate_path_segment "$RAW_PATH" "URI панели"
        PANEL_PATH="/${RAW_PATH#/}"; PANEL_PATH="${PANEL_PATH%/}/"

        SUB_PORT="${SUB_PORT:-55443}"
        RAW_SUB_PATH="${RAW_SUB_PATH:-${SUB_PATH:-sub-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "sub${RANDOM}")}}"
        RAW_SUB_PATH="${RAW_SUB_PATH#/}"; RAW_SUB_PATH="${RAW_SUB_PATH%/}"
        validate_path_segment "$RAW_SUB_PATH" "URI подписок"
        SUB_PATH="/${RAW_SUB_PATH#/}"; SUB_PATH="${SUB_PATH%/}/"
        SUB_JSON_PATH="${SUB_PATH%/}/json/"
        SUB_CLASH_PATH="${SUB_PATH%/}/clash/"

        XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-50443}"
        RAW_XHTTP_STREAM_PATH="${RAW_XHTTP_STREAM_PATH:-${XHTTP_STREAM_PATH:-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "xh${RANDOM}")}}"
        RAW_XHTTP_STREAM_PATH="${RAW_XHTTP_STREAM_PATH#/}"; RAW_XHTTP_STREAM_PATH="${RAW_XHTTP_STREAM_PATH%/}"
        validate_path_segment "$RAW_XHTTP_STREAM_PATH" "URI xHTTP"
        XHTTP_STREAM_PATH="/${RAW_XHTTP_STREAM_PATH#/}"; XHTTP_STREAM_PATH="${XHTTP_STREAM_PATH%/}/"

        # UDP Протоколы
        if [[ "${ENABLE_HY2,,}" == "y" || "${ENABLE_HY2:-}" == "1" ]]; then
            ENABLE_HY2=1
            HY2_PORT="${HY2_PORT:-443}"
            HY2_DOMAIN="${HY2_DOMAIN:-$PRIMARY_DOMAIN}"
            HY2_PORT_HOPPING="${HY2_PORT_HOPPING:-n}"
            HY2_PORT_HOPPING_RANGE="${HY2_PORT_HOPPING_RANGE:-20000:50000}"
        else
            ENABLE_HY2=0
        fi

        if [[ "${ENABLE_AWG_V3,,}" == "y" || "${ENABLE_AWG_V3:-}" == "1" ]]; then
            ENABLE_AWG_V3=1
            AWG_V3_PORT="${AWG_V3_PORT:-8443}"
        else
            ENABLE_AWG_V3=0
        fi

        if [[ "${ENABLE_AWG_V2,,}" == "y" || "${ENABLE_AWG_V2:-}" == "1" ]]; then
            ENABLE_AWG_V2=1
            AWG_V2_PORT="${AWG_V2_PORT:-8444}"
        else
            ENABLE_AWG_V2=0
        fi

        if [[ "${ENABLE_AWG_STANDALONE,,}" == "y" || "${ENABLE_AWG_STANDALONE:-}" == "1" ]]; then
            ENABLE_AWG_STANDALONE=1
            AWG_STANDALONE_PORT="${AWG_STANDALONE_PORT:-8445}"
        else
            ENABLE_AWG_STANDALONE=0
        fi

        if [[ "${ENABLE_SS2022,,}" == "y" || "${ENABLE_SS2022:-}" == "1" ]]; then
            ENABLE_SS2022=1
            SS2022_PORT="${SS2022_PORT:-8388}"
        else
            ENABLE_SS2022=0
        fi

        if [[ "${ENABLE_TUIC,,}" == "y" || "${ENABLE_TUIC:-}" == "1" ]]; then
            ENABLE_TUIC=1
            TUIC_PORT="${TUIC_PORT:-8448}"
        else
            ENABLE_TUIC=0
        fi

        if [[ "${ENABLE_MTPROTO,,}" == "y" || "${ENABLE_MTPROTO:-}" == "1" ]]; then
            ENABLE_MTPROTO=1
            MTPROTO_PORT="${MTPROTO_PORT:-8444}"
            MTPROTO_FAKETLS_DOMAIN="${MTPROTO_FAKETLS_DOMAIN:-gateway.icloud.com}"
            MTPROTO_ADTAG="${MTPROTO_ADTAG:-}"
        else
            ENABLE_MTPROTO=0
        fi

        if is_true "${ENABLE_AWG_V3:-0}" || is_true "${ENABLE_AWG_V2:-0}" || is_true "${ENABLE_AWG_STANDALONE:-0}"; then
            start_amneziawg_preinstall_bg
        fi

        # AdGuard Home
        if [[ "${ENABLE_AGH,,}" == "y" || "${ENABLE_AGH:-}" == "1" ]]; then
            ENABLE_AGH=1
            AGH_MODE="${AGH_MODE:-1}"
            [ "$AGH_MODE" = "2" ] && AGH_DOMAIN="${AGH_DOMAIN:-dns.$PRIMARY_DOMAIN}" || AGH_DOMAIN=""
            AGH_USER="${AGH_USER:-admin}"
            AGH_PASS="${AGH_PASS:-AgHome_$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 8 || echo 'Pass1234')}"
            AGH_CLIENT_ID="${AGH_CLIENT_ID:-home-router}"
            [[ "${AGH_XRAY_DNS,,}" == "y" || "${AGH_XRAY_DNS:-}" == "1" ]] && AGH_XRAY_DNS="y" || AGH_XRAY_DNS="n"
        else
            ENABLE_AGH=0
            AGH_DOMAIN=""
        fi

        DECOY_MODE="${DECOY_MODE:-1}"
        EXTRA_DOMAINS_USER=()
        if [ -n "${EXTRA_SSL_DOMAINS:-}" ]; then
            for extra_d in $EXTRA_SSL_DOMAINS; do
                [[ "$extra_d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] && EXTRA_DOMAINS_USER+=("$extra_d")
            done
        fi

        SSL_ENGINE_CHOICE="${SSL_ENGINE_CHOICE:-1}"
        LE_EMAIL="${LE_EMAIL:-}"
        CF_AUTH_METHOD="${CF_AUTH_METHOD:-1}"
        AUTO_SETUP_3XUI="${AUTO_SETUP_3XUI:-y}"
        if [[ "${ENABLE_NODE_TOKEN,,}" == "y" || "${ENABLE_NODE_TOKEN:-}" == "1" ]]; then
            ENABLE_NODE_TOKEN="y"
            if [ -z "${NODE_TOKEN_NAME:-}" ]; then
                local def_token_name="${SERVER_PREFIX:+$SERVER_PREFIX-Node}"
                if [[ -z "$SERVER_PREFIX" || "${SERVER_PREFIX,,}" =~ ^(-|none|off|no)$ ]]; then
                    def_token_name="Master-Node-Cluster"
                fi
                NODE_TOKEN_NAME="$def_token_name"
            fi
        else
            ENABLE_NODE_TOKEN="n"
            NODE_TOKEN_NAME=""
        fi
        if [[ "${ENABLE_WARP,,}" == "y" || "${ENABLE_WARP:-}" == "1" ]]; then
            ENABLE_WARP="y"
            WARP_LICENSE_KEY="${WARP_LICENSE_KEY:-}"
        else
            ENABLE_WARP="n"
            WARP_LICENSE_KEY=""
        fi

        rebuild_all_domains
        sync_reality_ports
    }

    # ==============================================================================
    # ШАГИ ИНТЕРАКТИВНОГО МАСТЕРА НАСТРОЙКИ (WIZARD STATE MACHINE)
    # ==============================================================================

    q_step_domain() {
        echo
        echo -e "${YELLOW}━━━ Шаг 1/12: Конфигурация главного сайта (домена) ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Ваш основной домен (например, ${BOLD}yourdomain.online${NC})."
            echo -e "     На нем будет работать веб-маска (декой-сайт), панель 3X-UI,"
            echo -e "     сервер подписок и протокол VLESS xHTTP (HTTP/2 Stream-One)."
            echo
        fi

        while true; do
            if [ -n "${PRIMARY_DOMAIN:-}" ]; then
                prompt_default "  Введите ваш основной домен" "$PRIMARY_DOMAIN" PRIMARY_DOMAIN || return $?
            else
                echo -ne "  ${WHITE}${ARROW} Введите ваш основной домен (например, yourdomain.online) ${DIM}(b - назад)${NC}: "
                local d_input=""
                read -r d_input </dev/tty || read -r d_input || true
                if [[ "${d_input,,}" == "b" || "${d_input,,}" == "back" || "${d_input,,}" == "назад" ]]; then
                    warn "  Вы уже на первом шаге мастера."
                    continue
                fi
                PRIMARY_DOMAIN=$(echo "${d_input:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            fi
            PRIMARY_DOMAIN=$(echo "${PRIMARY_DOMAIN:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            if [[ "$PRIMARY_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
                break
            fi
            warn "  Некорректный формат доменного имени: '$PRIMARY_DOMAIN'. Попробуйте снова."
            PRIMARY_DOMAIN=""
        done

        local def_srv="${SERVER_PREFIX:-$(hostname -s 2>/dev/null || echo "Server")}"
        [[ "$def_srv" =~ ^(localhost|ubuntu|debian|centos|vps.*)$ ]] && def_srv="Server"
        prompt_default "  Префикс названия сервера для клиентов (например: NL, Frankfurt, MyServer)" "$def_srv" SERVER_PREFIX || return $?
        SERVER_PREFIX="${SERVER_PREFIX:-Server}"

        if [[ ! "$PRIMARY_DOMAIN" =~ ^www\. ]]; then
            [ "${SHOW_TIPS:-y}" = "y" ] && echo -e "  ${DIM}• Рекомендуется выпустить сертификат и для www.$PRIMARY_DOMAIN для защиты от ошибок SSL.${NC}"
            prompt_yes_no "  Добавить алиас 'www.$PRIMARY_DOMAIN' для выпуска SSL и привязки к Nginx?" "${ADD_WWW:-y}" ADD_WWW || return $?
        else
            ADD_WWW="n"
        fi

        rebuild_all_domains
        ok "Основной домен настроен: $PRIMARY_DOMAIN (префикс: $SERVER_PREFIX)"
        return 0
    }

    q_step_steal() {
        echo
        echo -e "${YELLOW}━━━ Шаг 2/12: Настройка VLESS REALITY (маскировка под свой сайт) ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Режим REALITY, маскирующийся под ${BOLD}собственный поддомен${NC} (напр. cdn.$PRIMARY_DOMAIN)."
            echo -e "     ${GREEN}Преимущество:${NC} Трафик выглядит как обычный просмотр вашего сайта."
            echo -e "     Защищает от блокировок сторонних адресов маскировки со стороны систем фильтрации."
            echo
        fi

        prompt_yes_no "Включить VLESS REALITY (маскировка под свой сайт)?" "${ENABLE_STEAL:-y}" ENABLE_STEAL || return $?

        if is_true "${ENABLE_STEAL:-y}"; then
            STEAL_ENABLED=1
            local old_steal_dom="${STEAL_DOMAINS[0]:-${STEAL_DOMAINS_STR:-cdn.$PRIMARY_DOMAIN}}"
            local old_steal_port="${STEAL_PORTS_LIST[0]:-${STEAL_PORT:-45443}}"
            STEAL_PORTS_LIST=()
            STEAL_DOMAINS=()

            local port_input=""
            prompt_default "  Локальный порт Xray для REALITY (свой сайт)" "$old_steal_port" port_input || return $?
            STEAL_PORT="$port_input"
            if [[ ! "$STEAL_PORT" =~ ^[0-9]+$ ]] || [ "$STEAL_PORT" -le 0 ] || [ "$STEAL_PORT" -gt 65535 ]; then
                warn "  Некорректный номер порта. Установлен порт по умолчанию: 45443."
                STEAL_PORT="45443"
            fi
            STEAL_PORTS_LIST+=("$STEAL_PORT")

            local s_dom_in=""
            prompt_default "  Домен/поддомен для маскировки REALITY на порту $STEAL_PORT" "$old_steal_dom" s_dom_in || return $?
            s_dom_in=$(echo "${s_dom_in:-$old_steal_dom}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

            if [[ ! "$s_dom_in" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
                warn "  Некорректный синтаксис домена '$s_dom_in'. Использован $old_steal_dom."
                s_dom_in="$old_steal_dom"
            fi

            if [ "$s_dom_in" = "$PRIMARY_DOMAIN" ]; then
                warn "  Коллизия: '$s_dom_in' совпадает с главным доменом (PRIMARY_DOMAIN)!"
                warn "  Главный домен зарезервирован за Nginx L7 (панель, веб-маска, подписки, xHTTP)."
                warn "  Для REALITY со своим сайтом укажите поддомен (например, cdn.$PRIMARY_DOMAIN)."
                s_dom_in="$old_steal_dom"
            fi

            STEAL_DOMAINS=("$s_dom_in")
            DOMAIN_TO_PORT["$s_dom_in"]="$STEAL_PORT"
            ok "  Домен $s_dom_in привязан к инбаунд-порту $STEAL_PORT"

            echo ""
            [ "${SHOW_TIPS:-y}" = "y" ] && echo -e "  ${CYAN}[i]${NC} ${DIM}Одного подключения REALITY (свой сайт) достаточно для всех ваших устройств.${NC}"
            local add_more=""
            prompt_yes_no "  Создать еще одно изолированное подключение (на другом порту)?" "n" add_more || return $?
            if [[ "${add_more,,}" == "y" ]]; then
                local extra_port="" extra_dom=""
                prompt_default "    Второй порт REALITY (свой сайт)" "45444" extra_port || return $?
                prompt_default "    Второй поддомен (напр. xr.$PRIMARY_DOMAIN)" "xr.$PRIMARY_DOMAIN" extra_dom || return $?
                extra_dom=$(echo "${extra_dom:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
                if [[ "$extra_dom" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
                    STEAL_PORTS_LIST+=("$extra_port")
                    STEAL_DOMAINS+=("$extra_dom")
                    DOMAIN_TO_PORT["$extra_dom"]="$extra_port"
                    ok "    Второй домен $extra_dom привязан к порту $extra_port"
                fi
            fi
        else
            STEAL_ENABLED=0
            STEAL_PORTS_LIST=()
            STEAL_DOMAINS=()
            log "Сценарий VLESS REALITY (свой сайт) отключен."
        fi

        rebuild_all_domains
        sync_reality_ports
        return 0
    }

    q_step_classic() {
        echo
        echo -e "${YELLOW}━━━ Шаг 3/12: Настройка VLESS REALITY (маскировка под популярные сервисы) ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Режим REALITY, маскирующийся под ${BOLD}известные сервисы${NC} (Apple, Microsoft, Samsung)."
            echo -e "     ${GREEN}Преимущество:${NC} Даже если ваш собственный домен окажется недоступен, это подключение продолжит"
            echo -e "     работать, используя валидные TLS 1.3 сертификаты внешних ресурсов."
            echo
        fi

        prompt_yes_no "Включить VLESS REALITY (маскировка под популярные сервисы)?" "${ENABLE_CLASSIC:-y}" ENABLE_CLASSIC || return $?

        if [[ "${ENABLE_CLASSIC,,}" == "y" || "${ENABLE_CLASSIC:-}" == "1" ]]; then
            CLASSIC_ENABLED=1
            CLASSIC_PORTS_LIST=()
            EXT_SNI_LIST=()

            local port_input=""
            prompt_default "  Локальный порт Xray для REALITY (внешние сервисы)" "${CLASSIC_PORT:-46443}" port_input || return $?
            CLASSIC_PORT="$port_input"
            if [[ ! "$CLASSIC_PORT" =~ ^[0-9]+$ ]] || [ "$CLASSIC_PORT" -le 0 ] || [ "$CLASSIC_PORT" -gt 65535 ]; then
                warn "  Некорректный номер порта. Установлен порт по умолчанию: 46443."
                CLASSIC_PORT="46443"
            fi
            CLASSIC_PORTS_LIST+=("$CLASSIC_PORT")

            local scanned_snis=()
            local scanned_lats=()
            if command -v python3 >/dev/null 2>&1; then
                echo -e "  ${CYAN}[*] Сканирование лучших REALITY-доменов по задержке (TLS 1.3 + h2)...${NC}"
                while read -r s_host s_lat; do
                    [ -n "$s_host" ] || continue
                    scanned_snis+=("$s_host")
                    scanned_lats+=("$s_lat")
                done < <(scan_reality_candidates)
            fi

            if [ "${#scanned_snis[@]}" -eq 0 ]; then
                scanned_snis=("avito.ru" "www.avito.ru" "dl.google.com" "www.apple.com" "www.samsung.com" "www.nvidia.com" "www.microsoft.com")
                scanned_lats=("fast" "fast" "fast" "fast" "fast" "fast" "fast")
            fi

            local default_classic_sni="${CLASSIC_SNI:-${scanned_snis[0]}}"

            echo ""
            echo -e "  ${BOLD}Доступные проверенные кандидаты маскировки (REALITY Targets):${NC}"
            for idx in "${!scanned_snis[@]}"; do
                local num=$((idx + 1))
                local h="${scanned_snis[$idx]}"
                local lat="${scanned_lats[$idx]}"
                local marker="  "
                [ "$h" = "$default_classic_sni" ] && marker="${GREEN}★ ${NC}"
                local lat_str="${DIM}(${lat} ms)${NC}"
                [ "$lat" = "fast" ] && lat_str=""
                echo -e "    ${CYAN}[$num]${NC} $marker${WHITE}$h${NC} $lat_str"
            done
            echo -e "    ${CYAN}[C]${NC}   ${DIM}Ввести свой собственный домен вручную${NC}"
            echo ""

            while true; do
                echo -ne "  ${WHITE}${ARROW} Выберите номер [1-${#scanned_snis[@]}], домен или Enter для [${GREEN}${default_classic_sni}${WHITE}] ${DIM}(b - назад)${NC}: "
                local ext_input=""
                read -r ext_input </dev/tty || read -r ext_input || true
                ext_input=$(echo "${ext_input:-}" | tr -d '[:space:]')
                if [[ "${ext_input,,}" == "b" || "${ext_input,,}" == "back" || "${ext_input,,}" == "назад" ]]; then
                    return 10
                fi

                local ext_sni=""
                if [ -z "$ext_input" ]; then
                    ext_sni="$default_classic_sni"
                elif [[ "$ext_input" =~ ^[0-9]+$ ]] && [ "$ext_input" -ge 1 ] && [ "$ext_input" -le "${#scanned_snis[@]}" ]; then
                    ext_sni="${scanned_snis[$((ext_input - 1))]}"
                elif [[ "${ext_input,,}" == "c" ]]; then
                    prompt_default "    Введите свой домен SNI (например, dl.google.com)" "dl.google.com" ext_sni || return $?
                    ext_sni=$(echo "${ext_sni:-}" | tr -d '[:space:]')
                else
                    ext_sni="$ext_input"
                fi

                if [[ ! "$ext_sni" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
                    warn "    Некорректный формат SNI: '$ext_sni'. Попробуйте снова."
                    continue
                fi

                CLASSIC_SNI="$ext_sni"
                EXT_SNI_LIST=("$ext_sni")
                EXT_SNI_TO_PORT["$ext_sni"]="$CLASSIC_PORT"
                ALL_EXT_SNIS=("$ext_sni")
                ok "  Внешний SNI $ext_sni привязан к порту $CLASSIC_PORT"
                break
            done
        else
            CLASSIC_ENABLED=0
            CLASSIC_PORTS_LIST=()
            EXT_SNI_LIST=()
            ALL_EXT_SNIS=()
            log "Сценарий VLESS REALITY (внешние сервисы) отключен."
        fi

        sync_reality_ports
        return 0
    }

    q_step_ports() {
        echo
        echo -e "${YELLOW}━━━ Шаг 4/12: Настройка путей и внутренних портов (3X-UI и VLESS xHTTP) ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Внутренние порты и секретные URI-пути для веб-панели 3X-UI,"
            echo -e "     сервера подписок для клиентов и инбаунда VLESS xHTTP (HTTP/2 Stream-One)."
            echo
            echo -e "  ${BOLD}Выберите вариант настройки:${NC}"
            echo -e "    ${GREEN}[1] Рекомендованные безопасные настройки (Enter / Быстро)${NC}"
            echo -e "        ${DIM}• Порты: Панель :10443, Подписки :55443, xHTTP :50443${NC}"
            echo -e "        ${DIM}• Пути: Случайные криптостойкие URI (защита от сетевых сканеров и ботов)${NC}"
            echo -e "        ${DIM}• Логин: admin, Пароль: случайный стойкий хэш${NC}"
            echo -e "    ${CYAN}[2] Ручная экспертная настройка (задать все порты, логин, пароль и пути вручную)${NC}"
            echo
        else
            echo -e "  ${BOLD}Вариант настройки:${NC} [1] Рекомендованные порты/пути (Enter)  [2] Ручная экспертная настройка"
        fi

        prompt_default "  Ваш выбор (1 или 2)" "${PORTS_SETUP_MODE:-1}" PORTS_SETUP_MODE || return $?

        if [ "$PORTS_SETUP_MODE" = "2" ]; then
            prompt_default "  Внутренний порт панели 3X-UI" "${PANEL_PORT:-10443}" PANEL_PORT || return $?
            prompt_default "  Логин администратора 3X-UI" "${ADMIN_USERNAME:-admin}" ADMIN_USERNAME || return $?
            local def_pass="${ADMIN_PASSWORD:-$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 12 || echo "Admin1234567")}"
            prompt_default "  Пароль администратора 3X-UI" "$def_pass" ADMIN_PASSWORD || return $?

            local rand_p_path="panel-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "3xui${RANDOM}")"
            local r_path="${RAW_PATH:-${PANEL_PATH:-$rand_p_path}}"
            r_path="${r_path#/}"; r_path="${r_path%/}"
            prompt_default "  Секретный URI-путь к веб-панели (без слэшей)" "$r_path" RAW_PATH || return $?
            validate_path_segment "$RAW_PATH" "URI панели"
            PANEL_PATH="/${RAW_PATH#/}"; PANEL_PATH="${PANEL_PATH%/}/"

            prompt_default "  Внутренний порт сервера подписок 3X-UI" "${SUB_PORT:-55443}" SUB_PORT || return $?
            local rand_s_path="sub-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "sub${RANDOM}")"
            local r_sub="${RAW_SUB_PATH:-${SUB_PATH:-$rand_s_path}}"
            r_sub="${r_sub#/}"; r_sub="${r_sub%/}"
            prompt_default "  Секретный URI-путь подписок (без слэшей)" "$r_sub" RAW_SUB_PATH || return $?
            validate_path_segment "$RAW_SUB_PATH" "URI подписок"
            SUB_PATH="/${RAW_SUB_PATH#/}"; SUB_PATH="${SUB_PATH%/}/"
            SUB_JSON_PATH="${SUB_PATH%/}/json/"
            SUB_CLASH_PATH="${SUB_PATH%/}/clash/"
            prompt_default "  Заголовок подписки для клиентов (Enter - без заголовка)" "${SUB_TITLE:-}" SUB_TITLE || return $?

            prompt_default "  Внутренний порт инбаунда VLESS xHTTP" "${XHTTP_STREAM_PORT:-50443}" XHTTP_STREAM_PORT || return $?
            local rand_x_path="$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "xh${RANDOM}")"
            local r_xhttp="${RAW_XHTTP_STREAM_PATH:-${XHTTP_STREAM_PATH:-$rand_x_path}}"
            r_xhttp="${r_xhttp#/}"; r_xhttp="${r_xhttp%/}"
            prompt_default "  URI-путь для xHTTP Stream-One" "$r_xhttp" RAW_XHTTP_STREAM_PATH || return $?
            validate_path_segment "$RAW_XHTTP_STREAM_PATH" "URI xHTTP"
            XHTTP_STREAM_PATH="/${RAW_XHTTP_STREAM_PATH#/}"; XHTTP_STREAM_PATH="${XHTTP_STREAM_PATH%/}/"
        else
            PANEL_PORT="${PANEL_PORT:-10443}"
            ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
            [ -n "${ADMIN_PASSWORD:-}" ] || ADMIN_PASSWORD="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 12 || echo "Admin1234567")"

            if [ -n "${PANEL_PATH:-}" ]; then
                RAW_PATH="${PANEL_PATH#/}"; RAW_PATH="${RAW_PATH%/}"
            elif [ -z "${RAW_PATH:-}" ]; then
                RAW_PATH="panel-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "3xui${RANDOM}")"
            fi
            RAW_PATH="${RAW_PATH#/}"; RAW_PATH="${RAW_PATH%/}"
            PANEL_PATH="/${RAW_PATH#/}"; PANEL_PATH="${PANEL_PATH%/}/"

            SUB_PORT="${SUB_PORT:-55443}"
            [ -n "${RAW_SUB_PATH:-}" ] || RAW_SUB_PATH="sub-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "sub${RANDOM}")"
            RAW_SUB_PATH="${RAW_SUB_PATH#/}"; RAW_SUB_PATH="${RAW_SUB_PATH%/}"
            SUB_PATH="/${RAW_SUB_PATH#/}"; SUB_PATH="${SUB_PATH%/}/"
            SUB_JSON_PATH="${SUB_PATH%/}/json/"
            SUB_CLASH_PATH="${SUB_PATH%/}/clash/"

            XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-50443}"
            [ -n "${RAW_XHTTP_STREAM_PATH:-}" ] || RAW_XHTTP_STREAM_PATH="$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "xh${RANDOM}")"
            RAW_XHTTP_STREAM_PATH="${RAW_XHTTP_STREAM_PATH#/}"; RAW_XHTTP_STREAM_PATH="${RAW_XHTTP_STREAM_PATH%/}"
            XHTTP_STREAM_PATH="/${RAW_XHTTP_STREAM_PATH#/}"; XHTTP_STREAM_PATH="${XHTTP_STREAM_PATH%/}/"

            echo -e "  ${GREEN}${CHECK} Настройки применены автоматически:${NC}"
            echo -e "    ${DIM}• Порты:${NC}   Панель :$PANEL_PORT, Подписки :$SUB_PORT, xHTTP :$XHTTP_STREAM_PORT"
            echo -e "    ${DIM}• Пути:${NC}    Панель: $PANEL_PATH, Подписки: $SUB_PATH, Clash: $SUB_CLASH_PATH, xHTTP: $XHTTP_STREAM_PATH"
            echo -e "    ${DIM}• Доступ:${NC}  Логин: ${BOLD}$ADMIN_USERNAME${NC}, Пароль: ${YELLOW}$ADMIN_PASSWORD${NC}"
        fi

        ok "Внутренние порты и пути сконфигурированы."
        return 0
    }

    q_step_protocols() {
        echo
        echo -e "${YELLOW}━━━ Шаг 5/12: Выбор протоколов и транспортов (VPN / Прокси) ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Выберите протоколы подключения, которые будут развернуты на сервере."
            echo -e "     • ${GREEN}Hysteria 2${NC}: сверхбыстрый QUIC/UDP протокол с BBR Brutal для стриминга и мобильного интернета."
            echo -e "     • ${GREEN}AmneziaWG v3.1${NC}: защита от блокировок ТСПУ/DPI с обфускацией пакетов (внутри 3X-UI)."
            echo -e "     • ${GREEN}AmneziaWG v2.0${NC}: совместимость со старыми роутерами (Keenetic, OpenWrt)."
            echo -e "     • ${GREEN}Автономный AmneziaWG${NC}: независимый сервис ядра Linux (awg-quick@awg0, утилита awg-mgr)."
            echo -e "     • ${GREEN}TUIC v5${NC}: 0-RTT рукопожатие на чистом QUIC для мгновенного отклика."
            echo -e "     • ${GREEN}Shadowsocks 2022${NC}: устойчивый к зондированию шифрованный протокол."
            echo -e "     • ${GREEN}Telegram MTProxy${NC}: прямой доступ для клиентов Telegram без дополнительных VPN-приложений."
            echo
        fi

        local proto_keys=(
            "ENABLE_HY2"
            "ENABLE_AWG_V3"
            "ENABLE_AWG_V2"
            "ENABLE_AWG_STANDALONE"
            "ENABLE_TUIC"
            "ENABLE_SS2022"
            "ENABLE_MTPROTO"
        )
        local proto_labels=(
            "Hysteria 2 (UDP/QUIC Brutal CC, :${HY2_PORT:-443})"
            "AmneziaWG v3.1 (инбаунд 3X-UI, :${AWG_V3_PORT:-8443}/udp)"
            "AmneziaWG v2.0 (роутеры Keenetic/OpenWrt, :${AWG_V2_PORT:-8444}/udp)"
            "Автономный сервер AmneziaWG (awg-mgr, :${AWG_STANDALONE_PORT:-8445}/udp)"
            "TUIC v5 (QUIC 0-RTT + BBR, :${TUIC_PORT:-8448}/udp)"
            "Shadowsocks 2022 (2022-blake3-aes-256-gcm, :${SS2022_PORT:-8388})"
            "Telegram MTProxy (FakeTLS прямой доступ, :${MTPROTO_PORT:-8444}/tcp)"
        )

        prompt_multiselect "Выберите протоколы для установки" proto_keys proto_labels || return $?

        # Установка портов по умолчанию и опрос кастомных параметров в экспертном режиме
        if is_true "$ENABLE_HY2"; then
            [ -n "${HY2_PORT:-}" ] || HY2_PORT="443"
            [ -n "${HY2_DOMAIN:-}" ] || HY2_DOMAIN="$PRIMARY_DOMAIN"
            HY2_PORT_HOPPING="${HY2_PORT_HOPPING:-n}"
            HY2_PORT_HOPPING_RANGE="${HY2_PORT_HOPPING_RANGE:-20000:50000}"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  UDP-порт для Hysteria 2" "$HY2_PORT" HY2_PORT || return $?
                prompt_default "  Домен/поддомен для Hysteria 2" "$HY2_DOMAIN" HY2_DOMAIN || return $?
                prompt_yes_no "  Включить Port Hopping для Hysteria 2 (UDP 20000:50000)?" "$HY2_PORT_HOPPING" HY2_PORT_HOPPING || return $?
                if is_true "$HY2_PORT_HOPPING"; then
                    prompt_default "  Диапазон портов Port Hopping" "$HY2_PORT_HOPPING_RANGE" HY2_PORT_HOPPING_RANGE || return $?
                fi
            fi
        else
            HY2_PORT=""
            HY2_DOMAIN=""
            HY2_PORT_HOPPING="n"
        fi

        if is_true "$ENABLE_AWG_V3"; then
            [ -n "${AWG_V3_PORT:-}" ] || AWG_V3_PORT="8443"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  UDP-порт для AmneziaWG v3.1 (3X-UI)" "$AWG_V3_PORT" AWG_V3_PORT || return $?
            fi
        else
            AWG_V3_PORT=""
        fi

        if is_true "$ENABLE_AWG_V2"; then
            [ -n "${AWG_V2_PORT:-}" ] || AWG_V2_PORT="8444"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  UDP-порт для AmneziaWG v2.0 (3X-UI)" "$AWG_V2_PORT" AWG_V2_PORT || return $?
            fi
        else
            AWG_V2_PORT=""
        fi

        if is_true "$ENABLE_AWG_STANDALONE"; then
            [ -n "${AWG_STANDALONE_PORT:-}" ] || AWG_STANDALONE_PORT="8445"
            [ -n "${AWG_SERVER_HOST:-}" ] || AWG_SERVER_HOST="${PRIMARY_DOMAIN:-$WAN_IP}"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  UDP-порт для автономного AmneziaWG" "$AWG_STANDALONE_PORT" AWG_STANDALONE_PORT || return $?
                prompt_default "  Хост/IP для подключения клиентов AmneziaWG" "$AWG_SERVER_HOST" AWG_SERVER_HOST || return $?
            fi
        else
            AWG_STANDALONE_PORT=""
        fi

        if is_true "$ENABLE_AWG_V3" || is_true "$ENABLE_AWG_V2" || is_true "$ENABLE_AWG_STANDALONE"; then
            start_amneziawg_preinstall_bg
        fi

        if is_true "$ENABLE_TUIC"; then
            [ -n "${TUIC_PORT:-}" ] || TUIC_PORT="8448"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  UDP-порт для TUIC v5" "$TUIC_PORT" TUIC_PORT || return $?
            fi
        else
            TUIC_PORT=""
        fi

        if is_true "$ENABLE_SS2022"; then
            [ -n "${SS2022_PORT:-}" ] || SS2022_PORT="8388"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  Порт для Shadowsocks 2022 (TCP/UDP)" "$SS2022_PORT" SS2022_PORT || return $?
            fi
        else
            SS2022_PORT=""
        fi

        if is_true "$ENABLE_MTPROTO"; then
            [ -n "${MTPROTO_PORT:-}" ] || MTPROTO_PORT="8444"
            [ -n "${MTPROTO_FAKETLS_DOMAIN:-}" ] || MTPROTO_FAKETLS_DOMAIN="gateway.icloud.com"
            MTPROTO_ADTAG="${MTPROTO_ADTAG:-}"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  TCP-порт для Telegram MTProxy" "$MTPROTO_PORT" MTPROTO_PORT || return $?
                prompt_default "  FakeTLS домен маскировки для MTProxy" "$MTPROTO_FAKETLS_DOMAIN" MTPROTO_FAKETLS_DOMAIN || return $?
                prompt_default "  Спонсорский promo-тег adTag (опционально, 32 hex)" "$MTPROTO_ADTAG" MTPROTO_ADTAG || return $?
            fi
        else
            MTPROTO_PORT=""
            MTPROTO_FAKETLS_DOMAIN=""
            MTPROTO_ADTAG=""
        fi

        rebuild_all_domains
        return 0
    }

    q_step_awg_v3() {
        prompt_yes_no "Установить и настроить AmneziaWG v3.1 (инбаунд 3X-UI)?" "${ENABLE_AWG_V3:-y}" ENABLE_AWG_V3 || return $?
        if is_true "${ENABLE_AWG_V3:-y}"; then
            ENABLE_AWG_V3=1
            start_amneziawg_preinstall_bg
            prompt_default "  Внешний UDP-порт для AmneziaWG v3.1 (3X-UI)" "${AWG_V3_PORT:-8443}" AWG_V3_PORT || return $?
        else
            ENABLE_AWG_V3=0
            AWG_V3_PORT=""
        fi
        return 0
    }

    q_step_awg_v2() {
        prompt_yes_no "Установить и настроить AmneziaWG v2.0 / Legacy (инбаунд 3X-UI)?" "${ENABLE_AWG_V2:-n}" ENABLE_AWG_V2 || return $?
        if is_true "${ENABLE_AWG_V2:-y}"; then
            ENABLE_AWG_V2=1
            start_amneziawg_preinstall_bg
            prompt_default "  Внешний UDP-порт для AmneziaWG v2.0 (3X-UI)" "${AWG_V2_PORT:-8444}" AWG_V2_PORT || return $?
        else
            ENABLE_AWG_V2=0
            AWG_V2_PORT=""
        fi
        return 0
    }

    q_step_awg_standalone() {
        prompt_yes_no "Установить автономный сервер AmneziaWG (awg-mgr / системная служба на хосте)?" "${ENABLE_AWG_STANDALONE:-n}" ENABLE_AWG_STANDALONE || return $?
        if is_true "${ENABLE_AWG_STANDALONE:-y}"; then
            ENABLE_AWG_STANDALONE=1
            start_amneziawg_preinstall_bg
            prompt_default "  Внешний UDP-порт для автономного сервера AmneziaWG" "${AWG_STANDALONE_PORT:-8445}" AWG_STANDALONE_PORT || return $?
            prompt_default "  Домен или IP-адрес для подключения клиентов (Endpoint)" "${AWG_SERVER_HOST:-${PRIMARY_DOMAIN:-$WAN_IP}}" AWG_SERVER_HOST || return $?
        else
            ENABLE_AWG_STANDALONE=0
            AWG_STANDALONE_PORT=""
        fi
        return 0
    }

    q_step_agh() {
        echo
        echo -e "${YELLOW}━━━ Шаг 6/12: Настройка приватного AdGuard Home DoH + Split-DNS ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Приватный шифрованный DNS (DNS-over-HTTPS) с защитой от рекламы и трекеров."
            echo -e "     ${GREEN}Split-DNS:${NC} Запросы к российским сайтам (.ru, банки, Госуслуги) направляются"
            echo -e "     через надежные локальные DNS, предотвращая ошибки доступа и сбои авторизации."
            echo
        fi

        prompt_yes_no "Установить приватный AdGuard Home DoH со Split-DNS?" "${ENABLE_AGH:-y}" ENABLE_AGH || return $?
        if [[ "${ENABLE_AGH,,}" == "y" || "${ENABLE_AGH:-}" == "1" ]]; then
            ENABLE_AGH=1
            echo
            echo -e "  ${BOLD}Режим доступа к AdGuard Home DoH:${NC}"
            echo -e "    ${GREEN}1)${NC} На основном домене (${PRIMARY_DOMAIN}/dns-query/)"
            [ "${SHOW_TIPS:-y}" = "y" ] && echo -e "       ${DIM}— Не нужен отдельный поддомен и дополнительный сертификат${NC}"
            [ "${SHOW_TIPS:-y}" = "y" ] && echo -e "       ${DIM}— Быстрая настройка, рекомендовано для большинства${NC}"
            echo -e "    ${GREEN}2)${NC} На отдельном поддомене (dns.${PRIMARY_DOMAIN})"
            [ "${SHOW_TIPS:-y}" = "y" ] && echo -e "       ${DIM}— Требуется A-запись у регистратора, полная изоляция DNS${NC}"
            echo
            prompt_default "  Ваш выбор (1 или 2)" "${AGH_MODE:-1}" AGH_MODE || return $?
            if [ "$AGH_MODE" = "2" ]; then
                prompt_default "  Поддомен для AdGuard Home DoH" "${AGH_DOMAIN:-dns.$PRIMARY_DOMAIN}" AGH_DOMAIN || return $?
                AGH_DOMAIN=$(echo "$AGH_DOMAIN" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            else
                AGH_MODE="1"
                AGH_DOMAIN=""
            fi

            prompt_default "  Логин администратора AdGuard Home" "${AGH_USER:-admin}" AGH_USER || return $?
            local def_ag_pass="${AGH_PASS:-AgHome_$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 8 || echo 'Pass1234')}"
            prompt_default "  Пароль администратора AdGuard Home" "$def_ag_pass" AGH_PASS || return $?
            prompt_default "  Секретный ClientID токен для роутера" "${AGH_CLIENT_ID:-home-router}" AGH_CLIENT_ID || return $?
            prompt_yes_no "  Использовать AdGuard Home как DNS для VPN-клиентов (Xray)?" "${AGH_XRAY_DNS:-y}" AGH_XRAY_DNS || return $?
            ok "AdGuard Home настроен (Режим: $AGH_MODE, ClientID: $AGH_CLIENT_ID)"
        else
            ENABLE_AGH=0
            AGH_DOMAIN=""
            log "AdGuard Home DoH отключен."
        fi

        rebuild_all_domains
        return 0
    }

    q_step_decoy() {
        echo
        echo -e "${YELLOW}━━━ Шаг 7/12: Выбор темы для сайта-маскировки (Decoy Site) ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Веб-сайт, который отображается в браузере при обращении к вашему домену."
            echo -e "     Защищает сервер от выявления цензорами, активными сканерами и сетевыми ботами."
            echo
            echo -e "  ${BOLD}Доступные варианты маскировки:${NC}"
            echo -e "    ${GREEN}[1] DataSphere Analytics (Рекомендуется)${NC}"
            echo -e "        ${DIM}• Корпоративный портал распределенной аналитики данных${NC}"
            echo -e "        ${DIM}• Интерактивная 3D-сфера узлов, Anycast-телеметрия потока и Web CLI${NC}"
            echo -e "        ${DIM}• Документация API, статус сервисов и строгая политика CSP (без unsafe-inline)${NC}"
            echo
            echo -e "    ${GREEN}[2] CosmosCloud NextGen${NC}"
            echo -e "        ${DIM}• Корпоративное облачное хранилище файлов (аналог Nextcloud / OwnCloud)${NC}"
            echo -e "        ${DIM}• Форма входа в хранилище, сессионные cookies, реалистичный брендинг${NC}"
            echo
            echo -e "    ${GREEN}[3] Стандартная заглушка Nginx${NC}"
            echo -e "        ${DIM}• Классическая системная страница «Welcome to nginx!»${NC}"
            echo
        else
            echo -e "  ${BOLD}Варианты маскировки:${NC} [1] DataSphere Analytics (Рекомендуется)  [2] CosmosCloud  [3] Заглушка Nginx"
        fi

        prompt_default "  Выберите вариант маскировки (1, 2 или 3)" "${DECOY_MODE:-1}" DECOY_MODE || return $?
        case "$DECOY_MODE" in
            2) ok "Выбрана тема: CosmosCloud NextGen" ;;
            3) ok "Выбрана стандартная заглушка Nginx" ;;
            *) DECOY_MODE="1"; ok "Выбрана тема: DataSphere Analytics" ;;
        esac
        return 0
    }

    q_step_ssl_domains() {
        echo
        echo -e "${YELLOW}━━━ Шаг 8/12: Реестр SSL-сертификатов и дополнительные домены ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Список доменов, для которых будут автоматически получены SSL-сертификаты."
            echo -e "  ${DIM}Следующие домены уже включены автоматически из предыдущих шагов:${NC}"
        fi
        rebuild_all_domains
        for d in "${ALL_DOMAINS[@]}"; do
            echo -e "    ${GREEN}✔ ${WHITE}$d${NC}"
        done
        echo

        while true; do
            echo -ne "  ${WHITE}${ARROW} Добавить дополнительный домен в сертификат? (Enter = пропустить) ${DIM}(b - назад)${NC}: "
            local extra_d=""
            read -r extra_d </dev/tty || read -r extra_d || true
            extra_d=$(echo "${extra_d:-}" | tr -d '[:space:]')
            if [[ "${extra_d,,}" == "b" || "${extra_d,,}" == "back" || "${extra_d,,}" == "назад" ]]; then
                return 10
            fi
            [ -z "$extra_d" ] && break

            if [[ "$extra_d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
                if [[ " ${ALL_DOMAINS[*]} " == *" ${extra_d} "* ]]; then
                    warn "  Домен '$extra_d' уже есть в списке."
                else
                    EXTRA_DOMAINS_USER+=("$extra_d")
                    ALL_DOMAINS+=("$extra_d")
                    ok "  Добавлен дополнительный SSL-домен: $extra_d"
                fi
            else
                warn "  Некорректный формат доменного имени: '$extra_d'."
            fi
        done
        return 0
    }

    q_step_ssl_engine() {
        echo
        echo -e "${YELLOW}━━━ Шаг 9/12: Выбор метода выпуска SSL-сертификатов ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Способ валидации владения доменом для Let's Encrypt."
            echo -e "    ${GREEN}[1] Классический Certbot (HTTP-01, Рекомендуется)${NC}"
            echo -e "        ${DIM}• Простая валидация через порт 80 Nginx. Не требует API-ключей.${NC}"
            echo -e "    ${GREEN}[2] acme.sh + Cloudflare DNS-01${NC}"
            echo -e "        ${DIM}• Валидация через DNS API Cloudflare. Позволяет выпускать Wildcard (*.domain).${NC}"
            echo
        else
            echo -e "  ${BOLD}Метод SSL:${NC} [1] Certbot (HTTP-01)  [2] acme.sh + Cloudflare DNS-01"
        fi

        prompt_default "  Выберите метод сертификации (1 или 2)" "${SSL_ENGINE_CHOICE:-1}" SSL_ENGINE_CHOICE || return $?
        prompt_default "  Email для Let's Encrypt уведомлений (Enter - без почты)" "${LE_EMAIL:-}" LE_EMAIL || return $?

        if [ "$SSL_ENGINE_CHOICE" = "2" ]; then
            echo
            echo -e "  ${YELLOW}Аутентификация в Cloudflare API (acme.sh):${NC}"
            echo -e "    ${GREEN}1)${NC} API Token (Рекомендуется: Zone.DNS:Edit, Zone.Zone:Read)"
            echo -e "    ${GREEN}2)${NC} Global API Key (Email + Global Key)"
            prompt_default "  Выберите вариант (1 или 2)" "${CF_AUTH_METHOD:-1}" CF_AUTH_METHOD || return $?

            if [ "$CF_AUTH_METHOD" = "1" ]; then
                prompt_secret "  Введите Cloudflare API Token" "${CF_Token:-}" CF_Token || return $?
                [ -n "$CF_Token" ] || die "API Token не может быть пустым."
                prompt_default "  Введите Cloudflare Account ID (Enter для пропуска)" "${CF_Account_ID:-}" CF_Account_ID || return $?
                export CF_Token
                [ -n "${CF_Account_ID:-}" ] && export CF_Account_ID="$CF_Account_ID"
            else
                prompt_default "  Введите ваш Cloudflare Email" "${CF_Email:-}" CF_Email || return $?
                [ -n "$CF_Email" ] || die "Email не может быть пустым."
                prompt_secret "  Введите Cloudflare Global API Key" "${CF_Key:-}" CF_Key || return $?
                [ -n "$CF_Key" ] || die "Global API Key не может быть пустым."
                export CF_Email
                export CF_Key
            fi
        fi
        return 0
    }

    q_step_3xui_auto() {
        echo
        echo -e "${YELLOW}━━━ Шаг 10/12: Автоматическая настройка базы данных панели 3X-UI ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Автоматическое создание подключений (REALITY со своим сайтом, внешними сервисами, xHTTP)"
            echo -e "     в базе данных панели 3X-UI, а также настройка секретных путей и подписок."
            echo -e "     Вам не придется добавлять подключения вручную через браузер."
            echo
        fi

        prompt_yes_no "Автоматически настроить инбаунды и пути в панели 3X-UI?" "${AUTO_SETUP_3XUI:-y}" AUTO_SETUP_3XUI || return $?
        if [[ "${AUTO_SETUP_3XUI,,}" == "y" || "${AUTO_SETUP_3XUI:-}" == "1" ]]; then
            AUTO_SETUP_3XUI="y"
            if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
                echo
                echo -e "  ${CYAN}💡 3X-UI Node:${NC} Генерация API-токена позволяет подключить этот сервер"
                echo -e "     как ведомый узел (Node) к другой мастер-панели 3X-UI или внешней системе управления."
                echo
            fi

            prompt_yes_no "Создать API-токен для подключения сервера как узла (3X-UI Node)?" "${ENABLE_NODE_TOKEN:-n}" ENABLE_NODE_TOKEN || return $?
            if [[ "${ENABLE_NODE_TOKEN,,}" == "y" || "${ENABLE_NODE_TOKEN:-}" == "1" ]]; then
                ENABLE_NODE_TOKEN="y"
                local def_token_name="${SERVER_PREFIX:+$SERVER_PREFIX-Node}"
                if [[ -z "$SERVER_PREFIX" || "${SERVER_PREFIX,,}" =~ ^(-|none|off|no)$ ]]; then
                    def_token_name="Master-Node-Cluster"
                fi
                if [[ "${PORTS_SETUP_MODE:-1}" == "2" ]]; then
                    prompt_default "  Имя API-токена ноды" "${NODE_TOKEN_NAME:-$def_token_name}" NODE_TOKEN_NAME || return $?
                else
                    NODE_TOKEN_NAME="${NODE_TOKEN_NAME:-$def_token_name}"
                fi
                ok "API-токен ноды будет создан с именем: ${WHITE}$NODE_TOKEN_NAME${NC}"
            else
                ENABLE_NODE_TOKEN="n"
                NODE_TOKEN_NAME=""
            fi
        else
            AUTO_SETUP_3XUI="n"
            ENABLE_NODE_TOKEN="n"
            NODE_TOKEN_NAME=""
        fi
        return 0
    }

    q_step_warp() {
        echo
        echo -e "${YELLOW}━━━ Шаг 11/12: Исходящий туннель Cloudflare WARP ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Исходящий WireGuard туннель от вашего VPS в сеть Cloudflare."
            echo -e "     ${GREEN}Преимущество:${NC} Полностью избавляет от капч Google/Cloudflare и разблокирует"
            echo -e "     доступ к зарубежным AI-сервисам (ChatGPT, Claude, Gemini). Видео YouTube и"
            echo -e "     российские сайты продолжают работать напрямую на полной скорости."
            echo
        fi

        prompt_yes_no "Включить интеграцию Cloudflare WARP?" "${ENABLE_WARP:-n}" ENABLE_WARP || return $?
        if [[ "${ENABLE_WARP,,}" == "y" || "${ENABLE_WARP:-}" == "1" ]]; then
            ENABLE_WARP="y"
            prompt_default "  Лицензионный ключ WARP+ (Enter - использовать бесплатный безлимитный)" "${WARP_LICENSE_KEY:-}" WARP_LICENSE_KEY || return $?
            ok "Интеграция Cloudflare WARP активирована."
        else
            ENABLE_WARP="n"
            WARP_LICENSE_KEY=""
            log "Интеграция Cloudflare WARP отключена."
        fi
        return 0
    }

    q_step_review() {
        rebuild_all_domains
        sync_reality_ports
        clear 2>/dev/null || echo ""
        echo
        echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}             ${WHITE}${BOLD}📋 ПРОВЕРКА КОНФИГУРАЦИИ ПЕРЕД УСТАНОВКОЙ (REVIEW)${NC}                 ${CYAN}║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo
        echo -e "  ${CYAN}[1]${NC} ${BOLD}Основной домен:${NC}       ${WHITE}$PRIMARY_DOMAIN${NC} (Префикс клиентов: ${GREEN}$SERVER_PREFIX${NC}, www: ${ADD_WWW})"

        local steal_status="${RED}Отключен${NC}"
        if is_true "${STEAL_ENABLED:-0}"; then
            steal_status="${GREEN}Включен${NC} (${WHITE}${STEAL_DOMAINS[*]}${NC} -> 127.0.0.1:${STEAL_PORTS_LIST[*]})"
        fi
        echo -e "  ${CYAN}[2]${NC} ${BOLD}REALITY (свой сайт):${NC}  $steal_status"

        local classic_status="${RED}Отключен${NC}"
        if is_true "${CLASSIC_ENABLED:-0}"; then
            classic_status="${GREEN}Включен${NC} (SNI: ${WHITE}${EXT_SNI_LIST[*]}${NC} -> 127.0.0.1:${CLASSIC_PORTS_LIST[*]})"
        fi
        echo -e "  ${CYAN}[3]${NC} ${BOLD}REALITY (внешний):${NC}    $classic_status"

        echo -e "  ${CYAN}[4]${NC} ${BOLD}Внутренние порты:${NC}     Панель :${WHITE}$PANEL_PORT${NC} (${DIM}$PANEL_PATH${NC}), Подписки :${WHITE}$SUB_PORT${NC} (${DIM}$SUB_PATH, Clash: $SUB_CLASH_PATH${NC}), xHTTP :${WHITE}$XHTTP_STREAM_PORT${NC}"
        echo -e "      ${DIM}Доступ в 3X-UI:${NC}       Логин: ${WHITE}$ADMIN_USERNAME${NC}, Пароль: ${YELLOW}$ADMIN_PASSWORD${NC}"

        echo -e "  ${CYAN}[5]${NC} ${BOLD}Протоколы VPN/Прокси:${NC}"
        local hy2_status="${RED}Отключена${NC}"
        if is_true "${ENABLE_HY2:-0}"; then
            local hop_str=""
            [ "$HY2_PORT_HOPPING" = "y" ] && hop_str=" + Hopping $HY2_PORT_HOPPING_RANGE"
            hy2_status="${GREEN}Включена${NC} (:${HY2_PORT}/udp, ${HY2_DOMAIN}${hop_str})"
        fi
        echo -e "      ${DIM}• Hysteria 2:${NC}           $hy2_status"

        local awg3_status="${RED}Отключен${NC}"
        is_true "${ENABLE_AWG_V3:-0}" && awg3_status="${GREEN}Включен${NC} (:${AWG_V3_PORT}/udp)"
        echo -e "      ${DIM}• AmneziaWG v3.1 (3X-UI):${NC} $awg3_status"

        local awg2_status="${RED}Отключен${NC}"
        is_true "${ENABLE_AWG_V2:-0}" && awg2_status="${GREEN}Включен${NC} (:${AWG_V2_PORT}/udp)"
        echo -e "      ${DIM}• AmneziaWG v2.0 (3X-UI):${NC} $awg2_status"

        local awg_sa_status="${RED}Отключен${NC}"
        if is_true "${ENABLE_AWG_STANDALONE:-0}"; then
            local host_disp="${AWG_SERVER_HOST:-${PRIMARY_DOMAIN:-$WAN_IP}}"
            awg_sa_status="${GREEN}Включен${NC} (:${AWG_STANDALONE_PORT:-8445}/udp, Endpoint: ${host_disp}, awg-mgr)"
        fi
        echo -e "      ${DIM}• Автономный AmneziaWG:${NC}   $awg_sa_status"

        local ss_status="${RED}Отключен${NC}"
        is_true "${ENABLE_SS2022:-0}" && ss_status="${GREEN}Включен${NC} (:${SS2022_PORT:-8388})"
        echo -e "      ${DIM}• Shadowsocks 2022:${NC}     $ss_status"

        local tuic_status="${RED}Отключен${NC}"
        is_true "${ENABLE_TUIC:-0}" && tuic_status="${GREEN}Включен${NC} (:${TUIC_PORT:-8448}/udp)"
        echo -e "      ${DIM}• TUIC v5 (QUIC):${NC}       $tuic_status"

        local mtp_status="${RED}Отключен${NC}"
        is_true "${ENABLE_MTPROTO:-0}" && mtp_status="${GREEN}Включен${NC} (:${MTPROTO_PORT:-8444}/tcp, FakeTLS: ${MTPROTO_FAKETLS_DOMAIN:-gateway.icloud.com})"
        echo -e "      ${DIM}• Telegram MTProxy:${NC}     $mtp_status"

        local agh_status="${RED}Отключен${NC}"
        if is_true "${ENABLE_AGH:-0}"; then
            local m_desc="Основной домен"
            [ "$AGH_MODE" = "2" ] && m_desc="Поддомен $AGH_DOMAIN"
            agh_status="${GREEN}Включен${NC} (Режим: $m_desc, ClientID: $AGH_CLIENT_ID)"
        fi
        echo -e "  ${CYAN}[6]${NC} ${BOLD}AdGuard Home DoH:${NC}     $agh_status"

        local decoy_name="DataSphere Analytics"
        [ "$DECOY_MODE" = "2" ] && decoy_name="CosmosCloud NextGen"
        [ "$DECOY_MODE" = "3" ] && decoy_name="Стандартная заглушка Nginx"
        echo -e "  ${CYAN}[7]${NC} ${BOLD}Тема маскировки:${NC}      ${WHITE}$decoy_name${NC}"

        echo -e "  ${CYAN}[8]${NC} ${BOLD}SSL-домены (${#ALL_DOMAINS[@]}):${NC}   ${WHITE}${ALL_DOMAINS[*]}${NC}"

        local ssl_name="Certbot (HTTP-01)"
        [ "$SSL_ENGINE_CHOICE" = "2" ] && ssl_name="acme.sh + Cloudflare DNS-01"
        echo -e "  ${CYAN}[9]${NC} ${BOLD}Метод выпуска SSL:${NC}    ${WHITE}$ssl_name${NC}"

        local auto_3xui_str="${GREEN}Да${NC}"
        is_true "${AUTO_SETUP_3XUI:-y}" || auto_3xui_str="${RED}Нет${NC}"
        if is_true "${ENABLE_NODE_TOKEN:-n}"; then
            auto_3xui_str="${auto_3xui_str} ${DIM}(+ Node Token: ${WHITE}${NODE_TOKEN_NAME}${DIM})${NC}"
        fi
        echo -e "  ${CYAN}[10]${NC} ${BOLD}3X-UI автонастройка:${NC}  $auto_3xui_str"

        local warp_status="${RED}Отключен${NC}"
        is_true "${ENABLE_WARP:-n}" && warp_status="${GREEN}Включен${NC} (WireGuard MTU: 1280)"
        echo -e "  ${CYAN}[11]${NC} ${BOLD}Cloudflare WARP:${NC}      $warp_status"

        echo
        echo -e "${YELLOW}════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "  ${GREEN}[Enter]${NC} или ${GREEN}[y]${NC}  ${BOLD}Начать установку с выбранными параметрами${NC}"
        echo -e "  ${CYAN}[1 - 11]${NC}        ${BOLD}Изменить соответствующий раздел конфигурации${NC}"
        echo -e "  ${RED}[q]${NC}             ${BOLD}Отмена и выход${NC}"
        echo -e "${YELLOW}════════════════════════════════════════════════════════════════════════════════${NC}"
        echo

        while true; do
            local choice=""
            echo -ne "  ${WHITE}${ARROW} Ваш выбор [${GREEN}Enter = начать${WHITE}]: ${NC}"
            read -r choice </dev/tty || read -r choice || true
            choice=$(echo "${choice:-}" | tr -d '[:space:]')

            if [ -z "$choice" ] || [[ "${choice,,}" == "y" ]] || [[ "${choice,,}" == "yes" ]]; then
                save_session_state "$SAVED_CONFIG_FILE" >/dev/null 2>&1 || true
                if is_true "${ENABLE_AWG_V3:-0}" || is_true "${ENABLE_AWG_V2:-0}" || is_true "${ENABLE_AWG_STANDALONE:-0}"; then
                    start_amneziawg_preinstall_bg
                fi
                return 0
            fi

            if [[ "${choice,,}" == "q" || "${choice,,}" == "quit" || "${choice,,}" == "exit" ]]; then
                die "Установка отменена пользователем."
            fi

            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le 11 ]; then
                return $((100 + choice))
            fi

            warn "  Некорректный ввод. Нажмите Enter для старта, номер [1-11] для изменения или 'q' для выхода."
        done
    }

    # ==============================================================================
    # ЗАПУСК МАСТЕРА (WIZARD ENGINE)
    # ==============================================================================

    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        run_non_interactive_setup
    else
        if [ "$EXPERT_MODE" -eq 1 ]; then
            SHOW_TIPS="n"
            log "Экспертный режим (--expert): подробные подсказки отключены."
        else
            echo
            prompt_yes_no "Показывать подробные пояснения и подсказки к каждому шагу?" "${SHOW_TIPS:-y}" SHOW_TIPS
            if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
                ok "Включен подробный режим: для каждого протокола будут выводиться подсказки и пояснения."
            else
                ok "Включен экспертный режим: вопросы выводятся коротко и по делу."
            fi
        fi

        WIZARD_ALLOW_BACK=1
        if [ "${START_AT_REVIEW:-0}" -eq 1 ]; then
            CURRENT_STEP=12
            EDITING_FROM_REVIEW=0
        else
            CURRENT_STEP=1
            EDITING_FROM_REVIEW=0
        fi
        TOTAL_STEPS=12

        while [ "$CURRENT_STEP" -le "$TOTAL_STEPS" ]; do
            res=0
            case "$CURRENT_STEP" in
                1) q_step_domain || res=$? ;;
                2) q_step_steal || res=$? ;;
                3) q_step_classic || res=$? ;;
                4) q_step_ports || res=$? ;;
                5) q_step_protocols || res=$? ;;
                6) q_step_agh || res=$? ;;
                7) q_step_decoy || res=$? ;;
                8) q_step_ssl_domains || res=$? ;;
                9) q_step_ssl_engine || res=$? ;;
                10) q_step_3xui_auto || res=$? ;;
                11) q_step_warp || res=$? ;;
                12) q_step_review || res=$? ;;
            esac

            if [ "$res" -eq 10 ]; then
                # Запрос перехода назад
                if [ "$EDITING_FROM_REVIEW" -eq 1 ]; then
                    CURRENT_STEP=12
                    EDITING_FROM_REVIEW=0
                elif [ "$CURRENT_STEP" -gt 1 ]; then
                    CURRENT_STEP=$((CURRENT_STEP - 1))
                else
                    if [ "$EXPERT_MODE" -eq 0 ]; then
                        echo
                        old_back="$WIZARD_ALLOW_BACK"
                        WIZARD_ALLOW_BACK=0
                        prompt_yes_no "Показывать подробные пояснения и подсказки к каждому шагу?" "${SHOW_TIPS:-y}" SHOW_TIPS
                        WIZARD_ALLOW_BACK="$old_back"
                        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
                            ok "Включен подробный режим: для каждого протокола будут выводиться подсказки и пояснения."
                        else
                            ok "Включен экспертный режим: вопросы выводятся коротко и по делу."
                        fi
                    else
                        warn "Вы уже на первом шаге."
                    fi
                fi
            elif [ "$res" -ge 101 ] && [ "$res" -le 111 ]; then
                # Переход к конкретному шагу из экрана Review
                CURRENT_STEP=$((res - 100))
                EDITING_FROM_REVIEW=1
            elif [ "$res" -eq 0 ]; then
                if [ "$CURRENT_STEP" -eq 12 ]; then
                    break
                elif [ "$EDITING_FROM_REVIEW" -eq 1 ]; then
                    CURRENT_STEP=12
                    EDITING_FROM_REVIEW=0
                else
                    CURRENT_STEP=$((CURRENT_STEP + 1))
                fi
            else
                break
            fi
        done
        WIZARD_ALLOW_BACK=0


        rebuild_all_domains
        sync_reality_ports
    fi
fi
fi

if is_true "${ENABLE_WEB_STACK:-y}"; then
    # Определение системного каталога для хранения SSL
    if [ "$SSL_ENGINE_CHOICE" = "1" ]; then
        SSL_BASE_DIR="/etc/letsencrypt/live"
    else
        SSL_BASE_DIR="/etc/ssl/acme"
    fi

    # Проверка DNS-записей
    log "Проверка A-записей для всех собственных доменов..."
    WAN_IP=$(get_wan_ip)
    if [ -n "$WAN_IP" ]; then
        valid_domains=()
        for dom in "${ALL_DOMAINS[@]}"; do
            resolved_ip=$(dig +short "$dom" @1.1.1.1 2>/dev/null | tail -n1 || echo "")
            if [ -z "$resolved_ip" ]; then
                resolved_ip=$(getent ahosts "$dom" 2>/dev/null | awk '{print $1}' | head -n1 || echo "")
            fi

            local_dns_ok=0
            if [ -z "$resolved_ip" ]; then
                warn "Домен $dom не разрешается в IP-адрес. Проверьте DNS A-запись."
            elif [ "$resolved_ip" != "$WAN_IP" ]; then
                warn "Несовпадение IP: $dom указывает на $resolved_ip, IP сервера: $WAN_IP."
            else
                ok "DNS проверен: $dom -> $WAN_IP"
                valid_domains+=("$dom")
                local_dns_ok=1
            fi

            if [ "$local_dns_ok" -eq 0 ]; then
                if [ "$NON_INTERACTIVE" -eq 1 ]; then
                    if [ "$FORCE_DNS" -eq 1 ]; then
                        warn "Внимание: несовпадение DNS проигнорировано (флаг --force / FORCE_DNS=1)."
                        valid_domains+=("$dom")
                    elif [ "$dom" = "$PRIMARY_DOMAIN" ]; then
                        die "Критическая ошибка: Главный домен $dom не указывает на $WAN_IP. Укажите -f / --force или настройте A-запись в DNS."
                    else
                        warn "Внимание: Дополнительный домен '$dom' не указывает на IP сервера ($WAN_IP) и временно исключен из текущей установки."
                        new_steal=()
                        for sd in "${STEAL_DOMAINS[@]:-}"; do
                            [ "$sd" != "$dom" ] && new_steal+=("$sd")
                        done
                        STEAL_DOMAINS=("${new_steal[@]:-}")
                        unset "DOMAIN_TO_PORT[$dom]" 2>/dev/null || true
                    fi
                elif [ "$dom" = "$PRIMARY_DOMAIN" ]; then
                    read -rp "  [!] Основной домен $dom не совпадает с IP сервера ($WAN_IP). Продолжить выпуск SSL? [y/N]: " dns_ans </dev/tty || read -r dns_ans || true
                    if [[ "${dns_ans,,}" == "y" ]]; then
                        valid_domains+=("$dom")
                    else
                        die "Установка отменена пользователем."
                    fi
                else
                    echo -e "  ${YELLOW}${BOLD}Внимание:${NC} домен '${WHITE}$dom${NC}' не направлен на IP этого сервера (${WHITE}$WAN_IP${NC})."
                    echo -e "  ${DIM}Если продолжить, Let's Encrypt Certbot завершится с фатальной ошибкой (NXDOMAIN).${NC}"
                    echo -e "    ${CYAN}${BOLD}[1] Исключить '$dom' из установки и продолжить${NC} (Рекомендуется)"
                    echo -e "    ${YELLOW}[2] Всё равно попытаться выпустить SSL${NC} (если DNS только что обновлен)"
                    echo -e "    ${RED}[3] Прервать установку${NC}"
                    read -rp "  Ваш выбор [1/2/3] (по умолчанию: 1): " dns_choice </dev/tty || read -r dns_choice || dns_choice="1"
                    dns_choice=$(echo "${dns_choice:-1}" | tr -d '[:space:]')
                    case "$dns_choice" in
                        2)
                            warn "Попытка выпуска SSL для '$dom' будет выполнена."
                            valid_domains+=("$dom")
                            ;;
                        3)
                            die "Установка отменена пользователем для настройки DNS."
                            ;;
                        *)
                            warn "Домен '$dom' исключен из текущей установки."
                            new_steal=()
                            for sd in "${STEAL_DOMAINS[@]:-}"; do
                                [ "$sd" != "$dom" ] && new_steal+=("$sd")
                            done
                            STEAL_DOMAINS=("${new_steal[@]:-}")
                            unset "DOMAIN_TO_PORT[$dom]" 2>/dev/null || true
                            ;;
                    esac
                fi
            fi
        done
        ALL_DOMAINS=("${valid_domains[@]}")
    fi
fi

# Сохраняем состояние сессии в файл конфигурации для защиты от обрыва SSH или повторного вызова
save_session_state "$SAVED_CONFIG_FILE"

