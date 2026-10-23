#!/usr/bin/env bash
# ==============================================================================
#  DEBUG LOG EXPORT & RETRIEVAL ENGINE
# ==============================================================================
#  Provides easy multi-channel retrieval of installation and diagnostic logs:
#    1. One-click SCP copy commands (formatted for Windows / macOS / Linux)
#    2. Temporary one-time Web link (via Nginx webroot with automatic expiration)
#    3. Sanitized upload to ephemeral pastebin (0x0.st / bashupload.com)
#    4. Interactive tail preview in console
# ==============================================================================

_LOG_EXPORT_OFFERED=0

sanitize_debug_log() {
    local src_file="$1"
    local dst_file="$2"
    [ -f "$src_file" ] || return 1

    local tmp_dst
    tmp_dst=$(mktemp "${TMPDIR:-/tmp}/sanitized.XXXXXX") || return 1

    # Маскирование чувствительных данных: паролей, токенов, UUID, JWT, приватных ключей и JSON-полей
    if sed -E \
        -e 's/\x1b\[[0-9;]*m//g' \
        -e '/-----BEGIN ([A-Z ]+)?PRIVATE KEY-----/,/-----END ([A-Z ]+)?PRIVATE KEY-----/c\***PRIVATE_KEY_BLOCK_MASKED***' \
        -e 's/(PASSWORD|PASS|SECRET|TOKEN|KEY|UUID|PRIVATE_KEY)[[:space:]]*=[[:space:]]*[^ ]+/\1=***MASKED***/gI' \
        -e 's/(ADMIN_PASSWORD|AGH_PASS|NODE_TOKEN)[[:space:]]*=.*/\1=***MASKED***/gI' \
        -e 's/"(password|secret|token|privateKey|private_key)"[[:space:]]*:[[:space:]]*"[^"]+"/"\1":"***MASKED***"/gI' \
        -e 's/(Пароль[^:]*|Password[^:]*)[[:space:]]*:[[:space:]]*[^ ]+/\1: ***MASKED***/gI' \
        -e 's/(PrivateKey|PresharedKey)[[:space:]]*=[[:space:]]*[A-Za-z0-9+/=]{40,}/\1 = ***MASKED***/gI' \
        -e 's/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/***UUID***/gI' \
        -e 's/(ey[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{10,})/***JWT***/g' \
        "$src_file" > "$tmp_dst" 2>/dev/null; then
        mv -f "$tmp_dst" "$dst_file"
        return 0
    else
        rm -f "$tmp_dst" "$dst_file"
        return 1
    fi
}

get_log_export_target() {
    local cand
    for cand in "${SERVER_SETUP_LOG:-}" \
                "/var/log/server-setup.log" \
                "${TMPDIR:-/tmp}/server-setup.log"; do
        if [ -n "$cand" ] && [ -f "$cand" ]; then
            echo "$cand"
            return 0
        fi
    done
    echo ""
}

create_web_download_link() {
    local log_path="$1"
    local webroot="${WEBROOT:-/var/www/html}"

    # Доступно только при наличии установленного веб-сервера (Nginx) и доступного веб-корня
    if [ ! -d "$webroot" ] || [ ! -w "$webroot" ]; then
        return 1
    fi

    # Генерация случайного токена с высокой энтропией
    local token
    token=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 24 || true)
    if [ -z "$token" ] || [ "${#token}" -lt 16 ]; then
        token=$(openssl rand -hex 16 2>/dev/null || true)
    fi
    [ -n "$token" ] && [ "${#token}" -ge 16 ] || return 1

    local dest_file="$webroot/debug-${token}.log"

    # Обязательное маскирование чувствительных данных перед размещением в веб-каталоге
    sanitize_debug_log "$log_path" "$dest_file" || return 1
    chmod 644 "$dest_file" 2>/dev/null || true

    # Фоновое удаление через 15 минут
    (sleep 900 && rm -f "$dest_file") >/dev/null 2>&1 &

    local host="${PRIMARY_DOMAIN:-}"
    if [ -z "$host" ] && command -v get_wan_ip >/dev/null 2>&1; then
        host=$(get_wan_ip 2>/dev/null || echo "")
    fi
    [ -n "$host" ] || host="${WAN_IP:-$(hostname -I 2>/dev/null | awk '{print $1}' || echo '')}"
    [ -n "$host" ] || { rm -f "$dest_file"; return 1; }

    local scheme="http"
    if [ -n "${PRIMARY_DOMAIN:-}" ] && { [ -d "/etc/letsencrypt/live/${PRIMARY_DOMAIN}" ] || [ -d "/etc/ssl/acme/${PRIMARY_DOMAIN}" ]; }; then
        scheme="https"
    fi
    echo "${scheme}://${host}/debug-${token}.log"
    return 0
}

upload_to_pastebin() {
    local sanitized_file="$1"
    local res=""

    if command -v curl >/dev/null 2>&1; then
        # 1. 0x0.st
        res=$(curl -sS --connect-timeout 5 --max-time 15 -F "file=@${sanitized_file}" https://0x0.st 2>/dev/null || true)
        if [[ "$res" =~ ^https?:// ]]; then
            echo "$res" | tr -d ' \r\n'
            return 0
        fi

        # 2. bashupload.com
        res=$(curl -sS --connect-timeout 5 --max-time 15 --upload-file "${sanitized_file}" https://bashupload.com 2>/dev/null | grep -E '^https?://' | head -n1 || true)
        if [[ "$res" =~ ^https?:// ]]; then
            echo "$res" | tr -d ' \r\n'
            return 0
        fi
    fi
    return 1
}

offer_debug_log_export() {
    # Защита от повторного вызова
    if [ "${_LOG_EXPORT_OFFERED:-0}" -eq 1 ]; then
        return 0
    fi
    _LOG_EXPORT_OFFERED=1

    local log_path
    log_path=$(get_log_export_target)
    if [ -z "$log_path" ] || [ ! -f "$log_path" ]; then
        return 0
    fi

    # Автоматическое создание удобной копии в /root/
    local home_copy="/root/server-setup.log"
    if [ -d /root ] && [ -w /root ]; then
        cp -f "$log_path" "$home_copy" 2>/dev/null || true
        chmod 600 "$home_copy" 2>/dev/null || true
    fi

    local ssh_port="${SSH_PORT:-${SSH_ACTIVE_PORT:-22}}"
    local wan_ip="${WAN_IP:-}"
    if [ -z "$wan_ip" ] && command -v get_wan_ip >/dev/null 2>&1; then
        wan_ip=$(get_wan_ip 2>/dev/null || echo "")
    fi
    [ -n "$wan_ip" ] || wan_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'IP-СЕРВЕРА')"

    echo ""
    echo -e "  ${CYAN}${BOLD}📋 Журнал выполнения отладки (Debug Log):${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
    echo -e "  Файл на сервере:   ${WHITE}${log_path}${NC}"
    if [ -f "$home_copy" ]; then
        echo -e "  Копия в /root:     ${WHITE}${home_copy}${NC}"
    fi
    echo ""
    echo -e "  ${WHITE}Команда для скачивания на локальный ПК (PowerShell / Bash):${NC}"
    echo -e "  ${GREEN}${BOLD}scp -P ${ssh_port} root@${wan_ip}:${log_path} .${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"

    # Если неинтерактивный режим или нет TTY — выводим только плашку
    if [ "${NON_INTERACTIVE:-0}" -eq 1 ] || [ ! -t 1 ]; then
        return 0
    fi

    local exp_keys=("scp" "web" "upload" "tail" "exit")
    local exp_labels=(
        "Показать команды SCP / SFTP для всех ОС"
        "Создать временную веб-ссылку для скачивания"
        "Загрузить на защищенный обменник (маскировка паролей)"
        "Показать последние 50 строк прямо в консоли"
        "Завершить без дополнительных действий"
    )

    local chosen=""
    while true; do
        if command -v prompt_select >/dev/null 2>&1; then
            prompt_select "  Экспорт журнала отладки" chosen "exit" exp_keys exp_labels || break
        else
            echo -e "  ${CYAN}[1]${NC} Показать команды SCP"
            echo -e "  ${CYAN}[2]${NC} Создать веб-ссылку"
            echo -e "  ${CYAN}[3]${NC} Загрузить на защищенный обменник"
            echo -e "  ${CYAN}[4]${NC} Показать последние 50 строк"
            echo -e "  ${CYAN}[5]${NC} Завершить"
            read -rp "  Выберите действие [1-5]: " num_choice </dev/tty || break
            case "$num_choice" in
                1) chosen="scp" ;;
                2) chosen="web" ;;
                3) chosen="upload" ;;
                4) chosen="tail" ;;
                *) chosen="exit" ;;
            esac
        fi

        case "$chosen" in
            scp)
                echo ""
                echo -e "  ${YELLOW}${BOLD}Команды для скачивания лога на ваш компьютер:${NC}"
                echo -e "  • ${WHITE}Windows (PowerShell / cmd):${NC}"
                echo -e "    ${GREEN}scp -P ${ssh_port} root@${wan_ip}:${log_path} .${NC}"
                echo -e "  • ${WHITE}macOS / Linux Terminal:${NC}"
                echo -e "    ${GREEN}scp -P ${ssh_port} root@${wan_ip}:${log_path} ~/Downloads/${NC}"
                echo -e "  • ${WHITE}SFTP Клиент (FileZilla / WinSCP):${NC}"
                echo -e "    Хост: ${GREEN}${wan_ip}${NC}, Порт: ${GREEN}${ssh_port}${NC}, Пользователь: ${GREEN}root${NC}, Путь: ${GREEN}${log_path}${NC}"
                echo ""
                read -rp "  Нажмите Enter для возврата к меню экспорта... " _dummy </dev/tty || true
                ;;
            web)
                echo ""
                echo -e "  ${CYAN}${ARROW:-➜} Создание временной ссылки для скачивания...${NC}"
                local web_url
                web_url=$(create_web_download_link "$log_path" || true)
                if [ -n "$web_url" ]; then
                    echo -e "  ${GREEN}${CHECK:-✔} Ссылка готова (действует 15 минут):${NC}"
                    echo -e "    ${WHITE}${BOLD}${web_url}${NC}"
                    echo -e "  ${DIM}(Все пароли, ключи и токены были автоматически замаскированы)${NC}"
                else
                    warn "Не удалось создать веб-ссылку (веб-сервер Nginx недоступен). Воспользуйтесь SCP."
                fi
                echo ""
                read -rp "  Нажмите Enter для возврата к меню экспорта... " _dummy </dev/tty || true
                ;;
            upload)
                echo ""
                echo -e "  ${CYAN}${ARROW:-➜} Очистка лога от паролей и токенов...${NC}"
                local tmp_clean
                tmp_clean=$(mktemp "${TMPDIR:-/tmp}/sanitized-log.XXXXXX") || continue
                if ! sanitize_debug_log "$log_path" "$tmp_clean"; then
                    rm -f -- "$tmp_clean"
                    warn "Ошибка безопасной санитизации журнала. Выгрузка отменена во избежание утечки секретов."
                    read -rp "  Нажмите Enter для возврата к меню экспорта... " _dummy </dev/tty || true
                    continue
                fi
                echo -e "  ${CYAN}${ARROW:-➜} Загрузка на защищенный обменник...${NC}"
                local up_url
                up_url=$(upload_to_pastebin "$tmp_clean" || true)
                rm -f -- "$tmp_clean"
                if [ -n "$up_url" ]; then
                    echo -e "  ${GREEN}${CHECK:-✔} Журнал безопасно загружен:${NC}"
                    echo -e "    ${WHITE}${BOLD}${up_url}${NC}"
                    echo -e "  ${DIM}(Все пароли, ключи и токены были автоматически замаскированы)${NC}"
                else
                    warn "Не удалось загрузить лог на внешний сервис. Воспользуйтесь SCP."
                fi
                echo ""
                read -rp "  Нажмите Enter для возврата к меню экспорта... " _dummy </dev/tty || true
                ;;
            tail)
                echo ""
                echo -e "  ${YELLOW}${BOLD}Последние 50 строк журнала (${log_path}):${NC}"
                echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
                tail -n 50 "$log_path" | sed 's/^/  /' || true
                echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}\n"
                read -rp "  Нажмите Enter для возврата к меню экспорта... " _dummy </dev/tty || true
                ;;
            exit|*)
                break
                ;;
        esac
    done
}
