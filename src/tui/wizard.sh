# =============================================================
#  ИНТЕРАКТИВНАЯ КОНФИГУРАЦИЯ И СЦЕНАРИИ МАРШРУТИЗАЦИИ
# =============================================================
EXPRESS_MODE=${EXPRESS_MODE:-0}
EXPERT_MODE=${EXPERT_MODE:-0}

# Проверка сохраненной контрольной точки (Resume Checkpoint)
SKIP_INTERVIEW=0
if [ "$NON_INTERACTIVE" -eq 0 ]; then
    print_mask_banner
    has_interrupted_run=0
    TARGET_RESUME_STEP=0
    FAILED_STEP_TITLE=""
    if [ -n "${CHECKPOINT_FAILED:-}" ] && [ "${FAILED_STEP_NUM:-0}" -gt 0 ]; then
        has_interrupted_run=1
        TARGET_RESUME_STEP="$FAILED_STEP_NUM"
        FAILED_STEP_TITLE="${INSTALLATION_TITLES[$CHECKPOINT_FAILED]:-${STEP_NAMES[$FAILED_STEP_NUM]:-Шаг $FAILED_STEP_NUM}}"
    elif [ "$LAST_COMPLETED_STEP" -gt 0 ] && [ "$LAST_COMPLETED_STEP" -lt "$TOTAL_STEPS" ]; then
        has_interrupted_run=1
        TARGET_RESUME_STEP=$(( LAST_COMPLETED_STEP + 1 ))
        FAILED_STEP_TITLE="${STEP_NAMES[$TARGET_RESUME_STEP]:-Шаг $TARGET_RESUME_STEP}"
    fi

    if [ "$has_interrupted_run" -eq 1 ]; then
        echo -e "  ${YELLOW}${BOLD}Обнаружена незавершенная установка!${NC}"
        if [ -n "${CHECKPOINT_FAILED:-}" ] && [ "${FAILED_STEP_NUM:-0}" -gt 0 ]; then
            echo -e "  ${RED}Предыдущая установка была прервана на шаге:${NC} ${WHITE}Шаг $TARGET_RESUME_STEP из $TOTAL_STEPS ($FAILED_STEP_TITLE)${NC}"
            if [ "$LAST_COMPLETED_STEP" -gt 0 ]; then
                echo -e "  ${DIM}Последний успешно завершенный шаг: ${WHITE}Шаг $LAST_COMPLETED_STEP из $TOTAL_STEPS (${STEP_NAMES[$LAST_COMPLETED_STEP]:-})${NC}"
            fi
        else
            echo -e "  ${DIM}Последний успешно завершенный шаг: ${WHITE}Шаг $LAST_COMPLETED_STEP из $TOTAL_STEPS (${STEP_NAMES[$LAST_COMPLETED_STEP]:-})${NC}"
        fi
        echo -e "    ${CYAN}${BOLD}[1] Повторить/продолжить с шага $TARGET_RESUME_STEP ($FAILED_STEP_TITLE)${NC} (Рекомендуется)"
        echo -e "    ${YELLOW}[2] Начать установку заново (с шага 1)${NC}\n"
        read -rp "  Ваш выбор [1/2] (по умолчанию: 1): " RESUME_CHOICE </dev/tty || read -r RESUME_CHOICE || RESUME_CHOICE="1"
        RESUME_CHOICE=$(echo "${RESUME_CHOICE:-1}" | tr -d '[:space:]')
        if [ "$RESUME_CHOICE" != "2" ]; then
            RESUME_STEP="$TARGET_RESUME_STEP"
            SKIP_INTERVIEW=1
            ok "Возобновление установки с шага $RESUME_STEP..."
        else
            LAST_COMPLETED_STEP=0
            RESUME_STEP=1
            CHECKPOINT_FAILED=""
            record_step_completed 0
            ok "Сброс контрольной точки. Установка будет начата с первого шага."
        fi
        echo ""
    fi
else
    # В неинтерактивном режиме с переданным конфигом пропускаем интервью и возобновляем
    SKIP_INTERVIEW=1
    if [ -n "${CHECKPOINT_FAILED:-}" ] && [ "${FAILED_STEP_NUM:-0}" -gt 0 ]; then
        RESUME_STEP="$FAILED_STEP_NUM"
        ok "Неинтерактивный режим: возобновление с шага $RESUME_STEP (${INSTALLATION_TITLES[$CHECKPOINT_FAILED]:-})..."
    elif [ "$LAST_COMPLETED_STEP" -gt 0 ] && [ "$LAST_COMPLETED_STEP" -lt "$TOTAL_STEPS" ]; then
        RESUME_STEP=$(( LAST_COMPLETED_STEP + 1 ))
        ok "Неинтерактивный режим: возобновление с шага $RESUME_STEP..."
    fi
fi

if [ "$SKIP_INTERVIEW" -eq 1 ]; then
    # Восстановление массивов из сохраненных скалярных параметров конфигурации
    if [ "${EXPRESS_MODE:-0}" -eq 1 ] && is_true "${ENABLE_WEB_STACK:-y}"; then apply_express_defaults; else reconstruct_arrays_from_vars; fi
    REALITY_FALLBACK_PORT="9443"
    if [ "${SSL_ENGINE_CHOICE:-1}" = "1" ]; then
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
            echo -ne "  ${WHITE}${ARROW} Перейти к проверке плана? [${GREEN}Enter = далее${WHITE}, q = отмена]: ${NC}"
            read -r choice </dev/tty || read -r choice || true
            choice=$(echo "${choice:-}" | tr -d '[:space:]')
            if [ -z "$choice" ] || [[ "${choice,,}" == "y" ]] || [[ "${choice,,}" == "yes" ]]; then
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
                    PORTS_SETUP_MODE=1
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
    reconstruct_arrays_from_vars
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

    apply_express_defaults

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
        if is_true "${ENABLE_NAIVE:-0}" && [ -n "${NAIVE_DOMAIN:-}" ]; then
            if [[ ! " ${ALL_DOMAINS[*]} " == *" ${NAIVE_DOMAIN} "* ]]; then
                ALL_DOMAINS+=("$NAIVE_DOMAIN")
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
        ensure_panel_path || return 1
        validate_path_segment "$RAW_PATH" "URI панели"

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

        if [[ "${ENABLE_MASQUE,,}" == "y" || "${ENABLE_MASQUE:-}" == "1" ]]; then
            ENABLE_MASQUE=1
            MASQUE_PORT="${MASQUE_PORT:-8449}"
        else
            ENABLE_MASQUE=0
        fi

        if [[ "${ENABLE_SHADOWTLS,,}" == "y" || "${ENABLE_SHADOWTLS:-}" == "1" ]]; then
            ENABLE_SHADOWTLS=1
            SHADOWTLS_PORT="${SHADOWTLS_PORT:-8543}"
            SHADOWTLS_SNI="${SHADOWTLS_SNI:-gateway.icloud.com}"
            ENABLE_SS2022=1
        else
            ENABLE_SHADOWTLS=0
        fi

        if [[ "${ENABLE_WSTUNNEL,,}" == "y" || "${ENABLE_WSTUNNEL:-}" == "1" ]]; then
            ENABLE_WSTUNNEL=1
            WSTUNNEL_PORT="${WSTUNNEL_PORT:-8080}"
            ensure_wstunnel_prefix || return 1
        else
            ENABLE_WSTUNNEL=0
        fi

        if [[ "${ENABLE_ZAPRET,,}" == "y" || "${ENABLE_ZAPRET:-}" == "1" ]]; then
            ENABLE_ZAPRET=1
            ZAPRET_QNUM="${ZAPRET_QNUM:-200}"
        else
            ENABLE_ZAPRET=0
        fi

        if [[ "${ENABLE_NAIVE,,}" == "y" || "${ENABLE_NAIVE:-}" == "1" ]]; then
            ENABLE_NAIVE=1
            NAIVE_PORT="${NAIVE_PORT:-8446}"
            NAIVE_USER="${NAIVE_USER:-user}"
        else
            ENABLE_NAIVE=0
        fi

        if [[ "${ENABLE_DNSTT,,}" == "y" || "${ENABLE_DNSTT:-}" == "1" ]]; then
            ENABLE_DNSTT=1
            DNSTT_PORT="${DNSTT_PORT:-53053}"
            ENABLE_SS2022=1
        else
            ENABLE_DNSTT=0
        fi

        if [[ "${ENABLE_MIERU,,}" == "y" || "${ENABLE_MIERU:-}" == "1" ]]; then
            ENABLE_MIERU=1
            MIERU_PORT_MODE="${MIERU_PORT_MODE:-single}"
            case "${MIERU_PORT_MODE,,}" in
                range|pool)
                    MIERU_PORT="${MIERU_PORT:-8450-8455}"
                    ;;
                *)
                    MIERU_PORT="${MIERU_PORT:-8450}"
                    ;;
            esac
            [ -n "${MIERU_USER:-}" ] || MIERU_USER="user-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "mieru${RANDOM}")"
            [ -n "${MIERU_PASS:-}" ] || MIERU_PASS="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 16 || echo "mieru${RANDOM}")"
        else
            ENABLE_MIERU=0
        fi


        # AdGuard Home
        if [[ "${ENABLE_AGH,,}" == "y" || "${ENABLE_AGH:-}" == "1" ]]; then
            ENABLE_AGH=1
            AGH_MODE="${AGH_MODE:-1}"
            [ "$AGH_MODE" = "2" ] && AGH_DOMAIN="${AGH_DOMAIN:-dns.$PRIMARY_DOMAIN}" || AGH_DOMAIN=""
            AGH_USER="${AGH_USER:-admin}"
            AGH_PASS="${AGH_PASS:-AgHome_$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 8 || echo 'Pass1234')}"
            ensure_agh_client_id || return 1
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

        ENABLE_HOST_SECURITY="${ENABLE_HOST_SECURITY:-n}"
        local _act_p
        _act_p=$(detect_active_ssh_port)
        [ -n "$_act_p" ] || _act_p=22
        SSH_ACTIVE_PORT="${SSH_ACTIVE_PORT:-$_act_p}"
        SSH_PORT="${SSH_PORT:-$SSH_ACTIVE_PORT}"
        ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-n}"

        rebuild_all_domains
        sync_reality_ports
    }

    # ==============================================================================
    # ШАГИ ИНТЕРАКТИВНОГО МАСТЕРА НАСТРОЙКИ (WIZARD STATE MACHINE)
    # ==============================================================================

    q_step_domain() {
        echo
        echo -e "${YELLOW}━━━ Шаг 1/11: Конфигурация главного сайта (домена) ━━━${NC}"
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

    configure_steal_settings() {
        local old_steal_dom="${STEAL_DOMAINS[0]:-${STEAL_DOMAINS_STR:-cdn.$PRIMARY_DOMAIN}}"
        local old_steal_port="${STEAL_PORTS_LIST[0]:-${STEAL_PORT:-45443}}"
        STEAL_PORTS_LIST=()
        STEAL_DOMAINS=()

        if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
            local port_input=""
            prompt_default "  Локальный порт Xray для REALITY (свой сайт)" "$old_steal_port" port_input || return $?
            STEAL_PORT="$port_input"
            if [[ ! "$STEAL_PORT" =~ ^[0-9]+$ ]] || [ "$STEAL_PORT" -le 0 ] || [ "$STEAL_PORT" -gt 65535 ]; then
                warn "  Некорректный номер порта. Установлен порт по умолчанию: 45443."
                STEAL_PORT="45443"
            fi
            STEAL_PORTS_LIST+=("$STEAL_PORT")
        else
            STEAL_PORT="${STEAL_PORT:-45443}"
            STEAL_PORTS_LIST+=("$STEAL_PORT")
        fi

        local s_dom_in=""
        prompt_default "  Домен/поддомен для маскировки REALITY (свой сайт)" "$old_steal_dom" s_dom_in || return $?
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

        if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
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
        fi
        return 0
    }

    q_step_steal() {
        prompt_yes_no "Включить VLESS REALITY (маскировка под свой сайт)?" "${ENABLE_STEAL:-y}" ENABLE_STEAL || return $?
        if is_true "${ENABLE_STEAL:-y}"; then
            STEAL_ENABLED=1
            configure_steal_settings || return $?
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

    configure_classic_settings() {
        CLASSIC_PORTS_LIST=()
        EXT_SNI_LIST=()

        if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
            local port_input=""
            prompt_default "  Локальный порт Xray для REALITY (внешние сервисы)" "${CLASSIC_PORT:-46443}" port_input || return $?
            CLASSIC_PORT="$port_input"
            if [[ ! "$CLASSIC_PORT" =~ ^[0-9]+$ ]] || [ "$CLASSIC_PORT" -le 0 ] || [ "$CLASSIC_PORT" -gt 65535 ]; then
                warn "  Некорректный номер порта. Установлен порт по умолчанию: 46443."
                CLASSIC_PORT="46443"
            fi
            CLASSIC_PORTS_LIST+=("$CLASSIC_PORT")
        else
            CLASSIC_PORT="${CLASSIC_PORT:-46443}"
            CLASSIC_PORTS_LIST+=("$CLASSIC_PORT")
        fi

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
        return 0
    }

    q_step_classic() {
        prompt_yes_no "Включить VLESS REALITY (маскировка под популярные сервисы)?" "${ENABLE_CLASSIC:-y}" ENABLE_CLASSIC || return $?
        if [[ "${ENABLE_CLASSIC,,}" == "y" || "${ENABLE_CLASSIC:-}" == "1" ]]; then
            CLASSIC_ENABLED=1
            configure_classic_settings || return $?
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

    q_step_protocols() {
        echo
        echo -e "${YELLOW}━━━ Шаг 2/11: Выбор протоколов и транспортов (VPN / Прокси) ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Выберите протоколы подключения, которые будут развернуты на сервере."
            echo -e "     • ${GREEN}VLESS REALITY (свой сайт)${NC}: маскировка под собственный поддомен (напр. cdn.$PRIMARY_DOMAIN)."
            echo -e "     • ${GREEN}VLESS REALITY (внешний)${NC}: маскировка под популярные сервисы (Apple, Microsoft, dl.google.com)."
            echo -e "     • ${GREEN}Hysteria 2${NC}: сверхбыстрый QUIC/UDP протокол с BBR Brutal для стриминга и мобильного интернета."
            echo -e "     • ${GREEN}AmneziaWG v3.1${NC}: защита от блокировок ТСПУ/DPI с обфускацией пакетов (внутри 3X-UI)."
            echo -e "     • ${GREEN}AmneziaWG v2.0${NC}: совместимость со старыми роутерами (Keenetic, OpenWrt)."
            echo -e "     • ${GREEN}TUIC v5${NC}: 0-RTT рукопожатие на чистом QUIC для мгновенного отклика."
            echo -e "     • ${GREEN}Shadowsocks 2022${NC}: устойчивый к зондированию шифрованный протокол."
            echo -e "     • ${GREEN}Telegram MTProxy${NC}: прямой доступ для клиентов Telegram без дополнительных VPN-приложений."
            echo -e "     • ${GREEN}Автономный AmneziaWG${NC}: независимый сервис ядра Linux (awg-quick@awg0, утилита awg-mgr)."
            echo -e "     • ${GREEN}MASQUE (RFC 9484)${NC}: стандартизированный IETF CONNECT-UDP/IP прокси поверх HTTP/3 QUIC."
            echo -e "     • ${GREEN}ShadowTLS v4${NC}: идеальная маскировка под Apple gateway.icloud.com через Nginx Stream L4."
            echo -e "     • ${GREEN}Wstunnel (Nginx L7)${NC}: WebSocket туннелирование через порт 443 HTTPS с валидным SSL."
            echo -e "     • ${GREEN}Server-Side Zapret${NC}: десинхронизация DPI ТСПУ прямо на VPS через nfqws connbytes 1:6."
            echo -e "     • ${GREEN}NaïveProxy${NC}: маскировка под Chrome HTTP/2/3 HTTPS (Chromium network stack via Caddy)."
            echo -e "     • ${GREEN}DNSTT (DoH Tunnel)${NC}: аварийный DNS-туннель через DoH (dnstt-server) для обхода жестких белых списков."
            echo -e "     • ${GREEN}Mieru Proxy${NC}: протокол без TLS, устойчивый к активному зондированию."
            echo
        fi

        # Инбаунды панели 3X-UI: основные включены по умолчанию, v2.0 для старых роутеров отключен
        ENABLE_STEAL="${ENABLE_STEAL:-y}"
        ENABLE_CLASSIC="${ENABLE_CLASSIC:-y}"
        ENABLE_HY2="${ENABLE_HY2:-y}"
        ENABLE_AWG_V3="${ENABLE_AWG_V3:-y}"
        ENABLE_AWG_V2="${ENABLE_AWG_V2:-n}"
        ENABLE_TUIC="${ENABLE_TUIC:-y}"
        ENABLE_SS2022="${ENABLE_SS2022:-y}"
        ENABLE_MTPROTO="${ENABLE_MTPROTO:-y}"

        # Дополнительные автономные протоколы по умолчанию отключены (пользователь отмечает при необходимости)
        ENABLE_AWG_STANDALONE="${ENABLE_AWG_STANDALONE:-n}"
        ENABLE_MASQUE="${ENABLE_MASQUE:-n}"
        ENABLE_SHADOWTLS="${ENABLE_SHADOWTLS:-n}"
        ENABLE_WSTUNNEL="${ENABLE_WSTUNNEL:-n}"
        ENABLE_ZAPRET="${ENABLE_ZAPRET:-n}"
        ENABLE_NAIVE="${ENABLE_NAIVE:-n}"
        ENABLE_DNSTT="${ENABLE_DNSTT:-n}"
        ENABLE_MIERU="${ENABLE_MIERU:-n}"

        local proto_keys=(
            "ENABLE_STEAL"
            "ENABLE_CLASSIC"
            "ENABLE_HY2"
            "ENABLE_AWG_V3"
            "ENABLE_AWG_V2"
            "ENABLE_TUIC"
            "ENABLE_SS2022"
            "ENABLE_MTPROTO"
            "ENABLE_AWG_STANDALONE"
            "ENABLE_MASQUE"
            "ENABLE_SHADOWTLS"
            "ENABLE_WSTUNNEL"
            "ENABLE_ZAPRET"
            "ENABLE_NAIVE"
            "ENABLE_DNSTT"
            "ENABLE_MIERU"
        )
        local proto_labels=(
            "VLESS REALITY (маскировка под свой сайт, :${STEAL_PORT:-45443})"
            "VLESS REALITY (маскировка под популярные сервисы, :${CLASSIC_PORT:-46443})"
            "Hysteria 2 (UDP/QUIC Brutal CC, :${HY2_PORT:-443})"
            "AmneziaWG v3.1 (инбаунд 3X-UI, :${AWG_V3_PORT:-8443}/udp)"
            "AmneziaWG v2.0 (инбаунд 3X-UI для роутеров, :${AWG_V2_PORT:-8444}/udp)"
            "TUIC v5 (инбаунд 3X-UI QUIC 0-RTT, :${TUIC_PORT:-8448}/udp)"
            "Shadowsocks 2022 (инбаунд 3X-UI TCP/UDP, :${SS2022_PORT:-8388})"
            "Telegram MTProxy (инбаунд 3X-UI FakeTLS, :${MTPROTO_PORT:-8444}/tcp)"
            "Автономный сервер AmneziaWG (awg-quick@awg0 на хосте, :${AWG_STANDALONE_PORT:-8445}/udp)"
            "MASQUE (RFC 9484 / RFC 9298 via Sing-box, :${MASQUE_PORT:-8449}/udp)"
            "ShadowTLS v4 + SS-2022 (Nginx Stream :443 SNI ${SHADOWTLS_SNI:-gateway.icloud.com})"
            "Wstunnel over Nginx L7 (HTTPS WebSocket :443 -> :${WSTUNNEL_PORT:-8080})"
            "Server-Side Zapret (DPI Desync nfqws connbytes 1:6 NFQUEUE 200)"
            "NaïveProxy (Chromium HTTPS Stack via Caddy, Nginx Stream :443 -> :${NAIVE_PORT:-8446})"
            "DNSTT DoH Tunnel (DNS Tunneling via dnstt-server, :${DNSTT_PORT:-53053}/udp -> SS-2022)"
            "Mieru Proxy (XChaCha20-Poly1305, без TLS, защита от активного зондирования, :${MIERU_PORT:-8450})"
        )

        prompt_multiselect "Выберите протоколы для установки" proto_keys proto_labels || return $?

        # Настройки VLESS REALITY (свой сайт)
        if is_true "$ENABLE_STEAL"; then
            STEAL_ENABLED=1
            configure_steal_settings || return $?
        else
            STEAL_ENABLED=0
            STEAL_PORTS_LIST=()
            STEAL_DOMAINS=()
        fi

        # Настройки VLESS REALITY (внешние сервисы)
        if is_true "$ENABLE_CLASSIC"; then
            CLASSIC_ENABLED=1
            configure_classic_settings || return $?
        else
            CLASSIC_ENABLED=0
            CLASSIC_PORTS_LIST=()
            EXT_SNI_LIST=()
            ALL_EXT_SNIS=()
        fi

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

        if is_true "$ENABLE_MASQUE"; then
            [ -n "${MASQUE_PORT:-}" ] || MASQUE_PORT="8449"
            [ -n "${MASQUE_USER:-}" ] || MASQUE_USER="client"
            [ -n "${MASQUE_PASSWORD:-}" ] || MASQUE_PASSWORD="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 16 || echo "masque${RANDOM}")"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  UDP-порт для MASQUE (HTTP/3)" "$MASQUE_PORT" MASQUE_PORT || return $?
                prompt_default "  Имя пользователя для MASQUE" "$MASQUE_USER" MASQUE_USER || return $?
            fi
        else
            MASQUE_PORT=""
        fi

        if is_true "$ENABLE_SHADOWTLS"; then
            [ -n "${SHADOWTLS_PORT:-}" ] || SHADOWTLS_PORT="8543"
            [ -n "${SHADOWTLS_SNI:-}" ] || SHADOWTLS_SNI="gateway.icloud.com"
            [ -n "${SHADOWTLS_PASSWORD:-}" ] || SHADOWTLS_PASSWORD="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 16 || echo "stls${RANDOM}")"
            ENABLE_SS2022=1
            [ -n "${SS2022_PORT:-}" ] || SS2022_PORT="8388"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  Локальный порт для ShadowTLS" "$SHADOWTLS_PORT" SHADOWTLS_PORT || return $?
                prompt_default "  FakeTLS SNI для ShadowTLS" "$SHADOWTLS_SNI" SHADOWTLS_SNI || return $?
            fi
        else
            SHADOWTLS_PORT=""
            SHADOWTLS_SNI=""
        fi

        if is_true "$ENABLE_WSTUNNEL"; then
            [ -n "${WSTUNNEL_PORT:-}" ] || WSTUNNEL_PORT="8080"
            ensure_wstunnel_prefix || return 1
            [ -n "${WSTUNNEL_SECRET:-}" ] || WSTUNNEL_SECRET="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 16 || echo "wst${RANDOM}")"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  Локальный порт для Wstunnel daemon" "$WSTUNNEL_PORT" WSTUNNEL_PORT || return $?
                prompt_default "  HTTP-путь location для Wstunnel" "$WSTUNNEL_PREFIX" WSTUNNEL_PREFIX || return $?
            fi
        else
            WSTUNNEL_PORT=""
            WSTUNNEL_PREFIX=""
        fi

        if is_true "$ENABLE_ZAPRET"; then
            [ -n "${ZAPRET_QNUM:-}" ] || ZAPRET_QNUM="200"
            [ -n "${ZAPRET_DESYNC:-}" ] || ZAPRET_DESYNC="split2"
            [ -n "${ZAPRET_FOOLING:-}" ] || ZAPRET_FOOLING="md5sig,badseq"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  Очередь NFQUEUE для Zapret" "$ZAPRET_QNUM" ZAPRET_QNUM || return $?
                prompt_default "  Режим desync для nfqws" "$ZAPRET_DESYNC" ZAPRET_DESYNC || return $?
                prompt_default "  Режим fooling для nfqws" "$ZAPRET_FOOLING" ZAPRET_FOOLING || return $?
            fi
        else
            ZAPRET_QNUM=""
        fi

        if is_true "$ENABLE_NAIVE"; then
            [ -n "${NAIVE_PORT:-}" ] || NAIVE_PORT="8446"
            [ -n "${NAIVE_USER:-}" ] || NAIVE_USER="user"
            [ -n "${NAIVE_DOMAIN:-}" ] || NAIVE_DOMAIN="naive.${PRIMARY_DOMAIN:-}"
            [ -n "${NAIVE_PASS:-}" ] || NAIVE_PASS="$(generate_urlsafe_token 16)"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  Локальный порт для NaïveProxy (Caddy)" "$NAIVE_PORT" NAIVE_PORT || return $?
                prompt_default "  SNI-домен для NaïveProxy" "$NAIVE_DOMAIN" NAIVE_DOMAIN || return $?
                prompt_default "  Пользователь для NaïveProxy" "$NAIVE_USER" NAIVE_USER || return $?
            fi
        else
            NAIVE_PORT=""
            NAIVE_DOMAIN=""
            NAIVE_USER=""
            NAIVE_PASS=""
        fi

        if is_true "$ENABLE_DNSTT"; then
            [ -n "${DNSTT_PORT:-}" ] || DNSTT_PORT="53053"
            [ -n "${DNSTT_DOMAIN:-}" ] || DNSTT_DOMAIN="t.${PRIMARY_DOMAIN:-}"
            ENABLE_SS2022=1
            [ -n "${SS2022_PORT:-}" ] || SS2022_PORT="8388"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  UDP-порт для DNSTT-сервера" "$DNSTT_PORT" DNSTT_PORT || return $?
                prompt_default "  NS/DNS-домен зоны для DNSTT" "$DNSTT_DOMAIN" DNSTT_DOMAIN || return $?
            fi
        else
            DNSTT_PORT=""
            DNSTT_DOMAIN=""
        fi

        if is_true "$ENABLE_MIERU"; then
            MIERU_PORT_MODE="${MIERU_PORT_MODE:-single}"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                echo -e "\n  ${BOLD}Режим портов для Mieru Proxy:${NC}"
                echo -e "    1) Одиночный порт [8450] (рекомендуется)"
                echo -e "    2) Пул портов [8450-8455] (рандомизация соединений)"
                local _m_mode_choice="1"
                [ "$MIERU_PORT_MODE" = "range" ] && _m_mode_choice="2"
                prompt_default "  Выберите режим портов Mieru (1 или 2)" "$_m_mode_choice" _m_mode_choice || return $?
                if [ "$_m_mode_choice" = "2" ]; then
                    MIERU_PORT_MODE="range"
                    prompt_default "  Диапазон портов для Mieru (TCP и UDP)" "${MIERU_PORT:-8450-8455}" MIERU_PORT || return $?
                else
                    MIERU_PORT_MODE="single"
                    prompt_default "  Порт для Mieru (TCP и UDP)" "${MIERU_PORT:-8450}" MIERU_PORT || return $?
                fi
                prompt_default "  Имя пользователя Mieru" "${MIERU_USER:-user-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "m$(date +%s | cut -c7-10)")}" MIERU_USER || return $?
                prompt_default "  Пароль Mieru" "${MIERU_PASS:-$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 16 || echo "pass$(date +%s)")}" MIERU_PASS || return $?
            else
                case "${MIERU_PORT_MODE,,}" in
                    range|pool)
                        MIERU_PORT="${MIERU_PORT:-8450-8455}"
                        ;;
                    *)
                        MIERU_PORT_MODE="single"
                        MIERU_PORT="${MIERU_PORT:-8450}"
                        ;;
                esac
                [ -n "${MIERU_USER:-}" ] || MIERU_USER="user-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "mieru${RANDOM}")"
                [ -n "${MIERU_PASS:-}" ] || MIERU_PASS="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 16 || echo "mieru${RANDOM}")"
            fi
        else
            MIERU_PORT=""
            MIERU_USER=""
            MIERU_PASS=""
        fi

        rebuild_all_domains
        sync_reality_ports
        return 0
    }

    q_step_ports() {
        echo
        echo -e "${YELLOW}━━━ Шаг 3/11: Настройка путей и внутренних портов (3X-UI и VLESS xHTTP) ━━━${NC}"
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

            ensure_panel_path || return 1
            local r_path="$RAW_PATH"
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

            ensure_panel_path || return 1
            validate_path_segment "$RAW_PATH" "URI панели"

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

    q_step_awg_v3() {
        prompt_yes_no "Установить и настроить AmneziaWG v3.1 (инбаунд 3X-UI)?" "${ENABLE_AWG_V3:-y}" ENABLE_AWG_V3 || return $?
        if is_true "${ENABLE_AWG_V3:-y}"; then
            ENABLE_AWG_V3=1

            prompt_default "  Внешний UDP-порт для AmneziaWG v3.1 (3X-UI)" "${AWG_V3_PORT:-8443}" AWG_V3_PORT || return $?
        else
            ENABLE_AWG_V3=0
            AWG_V3_PORT=""
        fi
        return 0
    }

    q_step_awg_v2() {
        prompt_yes_no "Установить и настроить AmneziaWG v2.0 (для роутеров Keenetic / OpenWrt, инбаунд 3X-UI)?" "${ENABLE_AWG_V2:-n}" ENABLE_AWG_V2 || return $?
        if is_true "${ENABLE_AWG_V2:-y}"; then
            ENABLE_AWG_V2=1

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
        echo -e "${YELLOW}━━━ Шаг 4/11: Настройка приватного AdGuard Home DoH + Split-DNS ━━━${NC}"
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
            ensure_agh_client_id || return 1
            local def_agh_cid="$AGH_CLIENT_ID"
            prompt_default "  Секретный ClientID токен для роутера" "$def_agh_cid" AGH_CLIENT_ID || return $?
            prompt_yes_no "  Использовать AdGuard Home как DNS для VPN-клиентов (Xray)?" "${AGH_XRAY_DNS:-n}" AGH_XRAY_DNS || return $?
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
        echo -e "${YELLOW}━━━ Шаг 5/11: Выбор темы для сайта-маскировки (Decoy Site) ━━━${NC}"
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
        echo -e "${YELLOW}━━━ Шаг 6/11: Реестр SSL-сертификатов и дополнительные домены ━━━${NC}"
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
        echo -e "${YELLOW}━━━ Шаг 7/11: Выбор метода выпуска SSL-сертификатов ━━━${NC}"
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
        echo -e "${YELLOW}━━━ Шаг 8/11: Автоматическая настройка базы данных панели 3X-UI ━━━${NC}"
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

            prompt_yes_no "Создать API-токен для подключения сервера как узла (3X-UI Node)?" "${ENABLE_NODE_TOKEN:-y}" ENABLE_NODE_TOKEN || return $?
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
        echo -e "${YELLOW}━━━ Шаг 9/11: Исходящий туннель Cloudflare WARP ━━━${NC}"
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

    q_step_security() {
        echo
        echo -e "${YELLOW}━━━ Шаг 10/11: Безопасность сервера (SSH и Fail2ban) ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Базовая защита операционной системы хоста."
            echo -e "     ${GREEN}Преимущество:${NC} Перенос порта SSH со стандартного 22 скрывает сервер"
            echo -e "     от автоматических сканеров портов, а Fail2ban автоматически блокирует IP-адреса"
            echo -e "     злоумышленников после нескольких неудачных попыток подбора паролей."
            echo
        fi

        local def_active_port
        def_active_port=$(detect_active_ssh_port)
        [ -n "$def_active_port" ] || def_active_port=22
        SSH_ACTIVE_PORT="${SSH_ACTIVE_PORT:-$def_active_port}"

        local current_configured_port="${SSH_PORT:-$SSH_ACTIVE_PORT}"

        prompt_yes_no "Настроить безопасность сервера (SSH-ключи, порт и защиту Fail2ban)?" "${ENABLE_HOST_SECURITY:-n}" ENABLE_HOST_SECURITY || return $?
        if is_true "$ENABLE_HOST_SECURITY"; then
            ENABLE_HOST_SECURITY="y"

            # Вопрос 1: Порт SSH
            echo
            local keep_ssh="y"
            if [ "$current_configured_port" -ne "$SSH_ACTIVE_PORT" ]; then
                keep_ssh="n"
            fi
            prompt_yes_no "  Оставить текущий порт SSH (${SSH_ACTIVE_PORT})?" "$keep_ssh" KEEP_SSH || return $?
            if is_true "$KEEP_SSH"; then
                SSH_PORT="$SSH_ACTIVE_PORT"
                ok "Используется текущий порт SSH: ${WHITE}$SSH_PORT${NC}"
            else
                while true; do
                    local custom_p="${current_configured_port}"
                    [ "$custom_p" -eq "$SSH_ACTIVE_PORT" ] && custom_p=2222
                    prompt_default "  Введите новый порт SSH (1024-65535)" "$custom_p" custom_p || return $?
                    if [[ "$custom_p" =~ ^[0-9]+$ ]] && [ "$custom_p" -ge 1024 ] && [ "$custom_p" -le 65535 ]; then
                        # Проверка на конфликт с известными портами сервисов
                        local conflict=0
                        for reserved in 80 443 "${PANEL_PORT:-10443}" "${SUB_PORT:-55443}" "${XHTTP_STREAM_PORT:-50443}" "${HY2_PORT:-443}" "${AWG_V3_PORT:-8443}" "${AWG_V2_PORT:-8444}" "${AWG_STANDALONE_PORT:-8445}" "${SS2022_PORT:-8388}" "${TUIC_PORT:-8448}" "${MASQUE_PORT:-8449}"; do
                            if [ "$custom_p" -eq "$reserved" ]; then
                                warn "  Порт $custom_p уже используется для одного из VPN/прокси сервисов. Выберите другой."
                                conflict=1
                                break
                            fi
                        done
                        if [ "$conflict" -eq 0 ]; then
                            SSH_PORT="$custom_p"
                            ok "Новый порт SSH: ${WHITE}$SSH_PORT${NC} (активный порт $SSH_ACTIVE_PORT также останется разрешен в UFW для защиты от потери связи)"
                            break
                        fi
                    else
                        warn "  Порт должен быть числом от 1024 до 65535."
                    fi
                done
            fi

            # Вопрос 2: Настройка SSH-ключей
            echo
            local prompt_keys="n"
            if has_authorized_keys "root"; then
                echo -e "  ${GREEN}✔ В системе уже настроены авторизованные SSH-ключи (~/.ssh/authorized_keys).${NC}"
                prompt_yes_no "  Добавить дополнительный публичный ключ SSH?" "n" prompt_keys || return $?
            else
                echo -e "  ${YELLOW}ℹ️  В системе не найдено авторизованных SSH-ключей в ~/.ssh/authorized_keys.${NC}"
                prompt_keys="y"
            fi

            if is_true "$prompt_keys"; then
                echo -e "  ${CYAN}Настройка SSH-ключей для root:${NC}"
                echo -e "    ${WHITE}[1]${NC} Вставить существующий Public Key клиента (напр. ssh-ed25519 ...) ${GREEN}[Рекомендуется]${NC}"
                echo -e "    ${WHITE}[2]${NC} Сгенерировать новую пару ключей Ed25519 прямо на сервере"
                echo -e "    ${WHITE}[3]${NC} Пропустить настройку ключей"
                local k_choice="1"
                echo -ne "  ${WHITE}${ARROW} Ваш выбор (1-3) [1]: ${NC}"
                read -r k_choice </dev/tty 2>/dev/null || read -r k_choice 2>/dev/null || k_choice="1"
                k_choice="${k_choice:-1}"
                case "$k_choice" in
                    1)
                        echo -e "  ${CYAN}Вставьте ваш публичный ключ (начинается с ssh-ed25519, ssh-rsa или ecdsa):${NC}"
                        local pub_in=""
                        read -r pub_in </dev/tty 2>/dev/null || read -r pub_in 2>/dev/null || true
                        pub_in=$(echo "$pub_in" | tr -d '\r\n')
                        if [ -n "$pub_in" ]; then
                            add_authorized_key "$pub_in" "root"
                            SSH_PUBLIC_KEY="$pub_in"
                        else
                            warn "Публичный ключ не введен, пропуск."
                        fi
                        ;;
                    2)
                        generate_ed25519_keypair "root"
                        ;;
                    *)
                        log "Настройка SSH-ключей пропущена."
                        ;;
                esac
            fi

            # Вопрос 3: Отключение входа по паролю (Строго с защитой от потери доступа)
            echo
            if has_authorized_keys "root"; then
                prompt_yes_no "  Отключить вход по паролю (PasswordAuthentication no)? Вход будет ТОЛЬКО по SSH-ключам" "${DISABLE_PASSWORD_AUTH:-n}" DISABLE_PASSWORD_AUTH || return $?
                if is_true "$DISABLE_PASSWORD_AUTH"; then
                    DISABLE_PASSWORD_AUTH="y"
                    ok "Вход по паролю будет отключен. Убедитесь, что у вас сохранен приватный ключ!"
                else
                    DISABLE_PASSWORD_AUTH="n"
                    log "Вход по паролю оставлен включенным."
                fi
            else
                DISABLE_PASSWORD_AUTH="n"
                echo -e "  ${YELLOW}⚠️  Отключение пароля недоступно: в authorized_keys не обнаружено ключей.${NC}"
            fi

            # Вопрос 4: Fail2ban
            echo
            prompt_yes_no "  Установить и включить Fail2ban (защита от брутфорса)?" "${ENABLE_FAIL2BAN:-y}" ENABLE_FAIL2BAN || return $?
            if is_true "$ENABLE_FAIL2BAN"; then
                ENABLE_FAIL2BAN="y"
                ok "Служба Fail2ban будет установлена и настроена с backend=systemd."
            else
                ENABLE_FAIL2BAN="n"
                log "Установка Fail2ban пропущена."
            fi
        else
            ENABLE_HOST_SECURITY="n"
            SSH_PORT="$SSH_ACTIVE_PORT"
            DISABLE_PASSWORD_AUTH="n"
            ENABLE_FAIL2BAN="n"
            log "Настройки SSH и Fail2ban оставлены без изменений."
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

        echo -e "  ${CYAN}[2]${NC} ${BOLD}Протоколы VPN/Прокси:${NC}"
        local steal_status="${RED}Отключен${NC}"
        if is_true "${STEAL_ENABLED:-0}"; then
            steal_status="${GREEN}Включен${NC} (${WHITE}${STEAL_DOMAINS[*]}${NC} -> 127.0.0.1:${STEAL_PORTS_LIST[*]})"
        fi
        echo -e "      ${DIM}• REALITY (свой сайт):${NC}    $steal_status"

        local classic_status="${RED}Отключен${NC}"
        if is_true "${CLASSIC_ENABLED:-0}"; then
            classic_status="${GREEN}Включен${NC} (SNI: ${WHITE}${EXT_SNI_LIST[*]}${NC} -> 127.0.0.1:${CLASSIC_PORTS_LIST[*]})"
        fi
        echo -e "      ${DIM}• REALITY (внешний):${NC}      $classic_status"

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

        local masque_status="${RED}Отключен${NC}"
        is_true "${ENABLE_MASQUE:-0}" && masque_status="${GREEN}Включен${NC} (:${MASQUE_PORT:-8449}/udp, RFC 9484)"
        echo -e "      ${DIM}• MASQUE (RFC 9484):${NC}    $masque_status"

        local stls_status="${RED}Отключен${NC}"
        is_true "${ENABLE_SHADOWTLS:-0}" && stls_status="${GREEN}Включен${NC} (Nginx :443 SNI ${SHADOWTLS_SNI:-gateway.icloud.com} ➜ :${SHADOWTLS_PORT:-8543})"
        echo -e "      ${DIM}• ShadowTLS v4:${NC}         $stls_status"

        local wst_status="${RED}Отключен${NC}"
        is_true "${ENABLE_WSTUNNEL:-0}" && wst_status="${GREEN}Включен${NC} (Nginx :443 HTTPS ${WSTUNNEL_PREFIX:-/wstunnel/} ➜ :${WSTUNNEL_PORT:-8080})"
        echo -e "      ${DIM}• Wstunnel over Nginx:${NC}  $wst_status"

        local zapret_status="${RED}Отключен${NC}"
        is_true "${ENABLE_ZAPRET:-0}" && zapret_status="${GREEN}Включен${NC} (NFQUEUE ${ZAPRET_QNUM:-200}, ${ZAPRET_DESYNC:-split2})"
        echo -e "      ${DIM}• Server-Side Zapret:${NC}   $zapret_status"

        local naive_status="${RED}Отключен${NC}"
        is_true "${ENABLE_NAIVE:-0}" && naive_status="${GREEN}Включен${NC} (Nginx :443 SNI ${NAIVE_DOMAIN:-naive.$PRIMARY_DOMAIN} ➜ :${NAIVE_PORT:-8446})"
        echo -e "      ${DIM}• NaïveProxy:${NC}          $naive_status"

        local dnstt_status="${RED}Отключен${NC}"
        is_true "${ENABLE_DNSTT:-0}" && dnstt_status="${GREEN}Включен${NC} (UDP :${DNSTT_PORT:-53053} ➜ SS-2022, Zone: ${DNSTT_DOMAIN:-t.$PRIMARY_DOMAIN})"
        echo -e "      ${DIM}• DNSTT DoH Tunnel:${NC}     $dnstt_status"

        local mieru_status="${RED}Отключен${NC}"
        is_true "${ENABLE_MIERU:-0}" && mieru_status="${GREEN}Включен${NC} (:${MIERU_PORT:-8450}/tcp,udp, XChaCha20-Poly1305)"
        echo -e "      ${DIM}• Mieru Proxy:${NC}          $mieru_status"

        echo -e "  ${CYAN}[3]${NC} ${BOLD}Внутренние порты:${NC}     Панель :${WHITE}$PANEL_PORT${NC} (${DIM}$PANEL_PATH${NC}), Подписки :${WHITE}$SUB_PORT${NC} (${DIM}$SUB_PATH, Clash: $SUB_CLASH_PATH${NC}), xHTTP :${WHITE}$XHTTP_STREAM_PORT${NC}"
        echo -e "      ${DIM}Доступ в 3X-UI:${NC}       Логин: ${WHITE}$ADMIN_USERNAME${NC}, Пароль: ${YELLOW}$ADMIN_PASSWORD${NC}"

        local agh_status="${RED}Отключен${NC}"
        if is_true "${ENABLE_AGH:-0}"; then
            local m_desc="Основной домен"
            [ "$AGH_MODE" = "2" ] && m_desc="Поддомен $AGH_DOMAIN"
            agh_status="${GREEN}Включен${NC} (Режим: $m_desc, ClientID: $AGH_CLIENT_ID)"
        fi
        echo -e "  ${CYAN}[4]${NC} ${BOLD}AdGuard Home DoH:${NC}     $agh_status"

        local decoy_name="DataSphere Analytics"
        [ "$DECOY_MODE" = "2" ] && decoy_name="CosmosCloud NextGen"
        [ "$DECOY_MODE" = "3" ] && decoy_name="Стандартная заглушка Nginx"
        echo -e "  ${CYAN}[5]${NC} ${BOLD}Тема маскировки:${NC}      ${WHITE}$decoy_name${NC}"

        echo -e "  ${CYAN}[6]${NC} ${BOLD}SSL-домены (${#ALL_DOMAINS[@]}):${NC}   ${WHITE}${ALL_DOMAINS[*]}${NC}"

        local ssl_name="Certbot (HTTP-01)"
        [ "$SSL_ENGINE_CHOICE" = "2" ] && ssl_name="acme.sh + Cloudflare DNS-01"
        echo -e "  ${CYAN}[7]${NC} ${BOLD}Метод выпуска SSL:${NC}    ${WHITE}$ssl_name${NC}"

        local auto_3xui_str="${GREEN}Да${NC}"
        is_true "${AUTO_SETUP_3XUI:-y}" || auto_3xui_str="${RED}Нет${NC}"
        if is_true "${ENABLE_NODE_TOKEN:-n}"; then
            auto_3xui_str="${auto_3xui_str} ${DIM}(+ Node Token: ${WHITE}${NODE_TOKEN_NAME}${DIM})${NC}"
        fi
        echo -e "  ${CYAN}[8]${NC} ${BOLD}3X-UI автонастройка:${NC}  $auto_3xui_str"

        local warp_status="${RED}Отключен${NC}"
        is_true "${ENABLE_WARP:-n}" && warp_status="${GREEN}Включен${NC} (WireGuard MTU: 1280)"
        echo -e "  ${CYAN}[9]${NC} ${BOLD}Cloudflare WARP:${NC}      $warp_status"

        local sec_status="${DIM}Без изменений (порт ${SSH_PORT:-$SSH_ACTIVE_PORT}, Fail2ban выкл)${NC}"
        if is_true "${ENABLE_HOST_SECURITY:-n}"; then
            local f2b_str="${RED}выкл${NC}"
            is_true "${ENABLE_FAIL2BAN:-n}" && f2b_str="${GREEN}вкл${NC}"
            local pwd_str="${GREEN}пароль разрешен${NC}"
            is_true "${DISABLE_PASSWORD_AUTH:-n}" && pwd_str="${YELLOW}только по ключам${NC}"
            local key_str=""
            [ -n "${SSH_PUBLIC_KEY:-}" ] && key_str=", ключ добавлен"
            if [ "${SSH_PORT:-$SSH_ACTIVE_PORT}" -ne "${SSH_ACTIVE_PORT:-22}" ]; then
                sec_status="${GREEN}Настроена${NC} (SSH порт: ${WHITE}${SSH_PORT}${NC} [было ${SSH_ACTIVE_PORT}], Fail2ban: ${f2b_str}, Доступ: ${pwd_str}${key_str})"
            else
                sec_status="${GREEN}Настроена${NC} (SSH порт: ${WHITE}${SSH_PORT}${NC}, Fail2ban: ${f2b_str}, Доступ: ${pwd_str}${key_str})"
            fi
        fi
        echo -e "  ${CYAN}[10]${NC} ${BOLD}Безопасность сервера:${NC}   $sec_status"

        echo
        echo -e "${YELLOW}════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "  ${GREEN}[Enter]${NC} или ${GREEN}[y]${NC}  ${BOLD}Проверить параметры и перейти к плану установки${NC}"
        echo -e "  ${CYAN}[1 - 10]${NC}        ${BOLD}Изменить соответствующий раздел конфигурации${NC}"
        echo -e "  ${RED}[q]${NC}             ${BOLD}Отмена и выход${NC}"
        echo -e "${YELLOW}════════════════════════════════════════════════════════════════════════════════${NC}"
        echo

        while true; do
            local choice=""
            echo -ne "  ${WHITE}${ARROW} Ваш выбор [${GREEN}Enter = далее${WHITE}]: "
            read -r choice </dev/tty || read -r choice || true
            choice=$(echo "${choice:-}" | tr -d '[:space:]')

            if [ -z "$choice" ] || [[ "${choice,,}" == "y" ]] || [[ "${choice,,}" == "yes" ]]; then
                return 0
            fi

            if [[ "${choice,,}" == "q" || "${choice,,}" == "quit" || "${choice,,}" == "exit" ]]; then
                die "Установка отменена пользователем."
            fi

            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le 10 ]; then
                return $((100 + choice))
            fi

            warn "  Некорректный ввод. Нажмите Enter для старта, номер [1-10] для изменения или 'q' для выхода."
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
            CURRENT_STEP=11
            EDITING_FROM_REVIEW=0
        else
            CURRENT_STEP=1
            EDITING_FROM_REVIEW=0
        fi
        TOTAL_STEPS=11

        while [ "$CURRENT_STEP" -le "$TOTAL_STEPS" ]; do
            res=0
            case "$CURRENT_STEP" in
                1) q_step_domain || res=$? ;;
                2) q_step_protocols || res=$? ;;
                3) q_step_ports || res=$? ;;
                4) q_step_agh || res=$? ;;
                5) q_step_decoy || res=$? ;;
                6) q_step_ssl_domains || res=$? ;;
                7) q_step_ssl_engine || res=$? ;;
                8) q_step_3xui_auto || res=$? ;;
                9) q_step_warp || res=$? ;;
                10) q_step_security || res=$? ;;
                11) q_step_review || res=$? ;;
            esac

            if [ "$res" -eq 10 ]; then
                # Запрос перехода назад
                if [ "$EDITING_FROM_REVIEW" -eq 1 ]; then
                    CURRENT_STEP=11
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
            elif [ "$res" -ge 101 ] && [ "$res" -le 110 ]; then
                # Переход к конкретному шагу из экрана Review
                CURRENT_STEP=$((res - 100))
                EDITING_FROM_REVIEW=1
            elif [ "$res" -eq 0 ]; then
                if [ "$CURRENT_STEP" -eq 11 ]; then
                    break
                elif [ "$EDITING_FROM_REVIEW" -eq 1 ]; then
                    CURRENT_STEP=11
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

