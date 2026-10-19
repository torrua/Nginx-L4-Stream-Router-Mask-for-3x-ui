# =============================================================
#  ФОНОВАЯ ПРЕД-УСТАНОВКА (Параллельная подготовка пакетов)
# =============================================================
BG_PREINSTALL_PID=""
PREINSTALL_COMPLETED=0

start_background_preinstall() {
    if [ "$NON_INTERACTIVE" -eq 0 ] && [ "${DEBUG_MODE:-0}" -eq 0 ]; then
        local log_file="/tmp/setup_mask_preinstall.log"
        : > "$log_file"
        rm -f /tmp/setup_mask_bg_duration_*.time 2>/dev/null || true
        {
            export DEBIAN_FRONTEND=noninteractive
            # 1. Базовые утилиты
            local _t1_start
            _t1_start=$(date +%s)
            install_prerequisites
            local _t1_end
            _t1_end=$(date +%s)
            echo $(( _t1_end - _t1_start )) > /tmp/setup_mask_bg_duration_1.time

            # 2. Тюнинг ядра
            local _t2_start
            _t2_start=$(date +%s)
            apply_sysctl_and_limits
            local _t2_end
            _t2_end=$(date +%s)
            echo $(( _t2_end - _t2_start )) > /tmp/setup_mask_bg_duration_2.time

            # Компоненты веб-стека (Nginx Mainline + 3X-UI) устанавливаются ТОЛЬКО если включен веб-стек
            if is_true "${ENABLE_WEB_STACK:-y}"; then
                # 3. Nginx Mainline
                local _t3_start
                _t3_start=$(date +%s)
                setup_nginx_mainline
                local _t3_end
                _t3_end=$(date +%s)
                echo $(( _t3_end - _t3_start )) > /tmp/setup_mask_bg_duration_3.time

                # 4. Ядро 3X-UI (если ещё не установлено)
                if ! command -v x-ui >/dev/null 2>&1 && [ ! -f /etc/x-ui/x-ui.db ] && [ ! -f /usr/local/x-ui/bin/x-ui.db ]; then
                    local _tx_start
                    _tx_start=$(date +%s)
                    curl -Ls --connect-timeout 15 https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o /tmp/install_3xui.sh 2>/dev/null
                    printf "n\n" | bash /tmp/install_3xui.sh || true
                    local _tx_end
                    _tx_end=$(date +%s)
                    echo $(( _tx_end - _tx_start )) > /tmp/setup_mask_bg_duration_xui.time
                fi
            fi
        } >> "$log_file" 2>&1 &
        BG_PREINSTALL_PID=$!
        if is_true "${ENABLE_WEB_STACK:-y}"; then
            echo -e "  ${CYAN}⚡ [Фоновая подготовка]${NC} ${DIM}Установка Nginx, 3X-UI и сетевого стека запущена параллельно...${NC}\n"
        else
            echo -e "  ${CYAN}⚡ [Фоновая подготовка]${NC} ${DIM}Установка базовых утилит и сетевого стека запущена параллельно...${NC}\n"
        fi
    fi
}

sync_background_preinstall() {
    if [ -n "${BG_PREINSTALL_PID:-}" ]; then
        local log_file="/tmp/setup_mask_preinstall.log"
        local task_desc="Доустановка компонентов в фоне (Nginx, 3X-UI)..."
        local task_done="Фоновая подготовка пакетов (Nginx, 3X-UI, BBR)"
        if ! is_true "${ENABLE_WEB_STACK:-y}"; then
            task_desc="Доустановка базовых пакетов и сетевого стека в фоне..."
            task_done="Фоновая подготовка пакетов (BBR, утилиты)"
        fi
        if kill -0 "$BG_PREINSTALL_PID" 2>/dev/null; then
            local spin_chars=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
            local delay=0.08
            local i=0
            tput civis 2>/dev/null || echo -ne "\033[?25l"
            while kill -0 "$BG_PREINSTALL_PID" 2>/dev/null; do
                i=$(( (i + 1) % 10 ))
                printf "\r  ${CYAN}${spin_chars[$i]}${NC}  ${WHITE}%-54s${NC}" "$task_desc"
                sleep "$delay"
            done
            wait "$BG_PREINSTALL_PID"
            local exit_code=$?
            tput cnorm 2>/dev/null || echo -ne "\033[?25h"
            if [ $exit_code -eq 0 ]; then
                printf "\r  ${GREEN}${CHECK}${NC}  ${WHITE}%-54s${NC} ${GREEN}[ГОТОВО]${NC}\n" "$task_done"
                PREINSTALL_COMPLETED=1
            else
                printf "\r  ${RED}${CROSS}${NC}  ${WHITE}%-54s${NC} ${RED}[ОШИБКА]${NC}\n" "Фоновая подготовка пакетов"
                [ -f "$log_file" ] && tail -n 25 "$log_file" | sed 's/^/    /' || true
                die "Ошибка при фоновой установке пакетов. Подробности выше."
            fi
        else
            wait "$BG_PREINSTALL_PID"
            local exit_code=$?
            if [ $exit_code -eq 0 ]; then
                echo -e "  ${GREEN}${CHECK}${NC}  ${WHITE}${task_done} уже завершена${NC} ${GREEN}[ГОТОВО]${NC}"
                PREINSTALL_COMPLETED=1
            else
                echo -e "  ${RED}${CROSS}${NC}  ${WHITE}Ошибка при фоновой подготовке пакетов${NC}"
                [ -f "$log_file" ] && tail -n 25 "$log_file" | sed 's/^/    /' || true
                die "Ошибка при фоновой установке пакетов. Подробности выше."
            fi
        fi
        BG_PREINSTALL_PID=""
    fi
}

