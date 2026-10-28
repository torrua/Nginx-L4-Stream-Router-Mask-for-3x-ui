#!/usr/bin/env bash
# ==============================================================================
#  YABS BENCHMARK RUNNER & INTERACTIVE PROMPT
# ==============================================================================
#  Интеграция Yet Another Bench Script (fio, iperf3, Geekbench 6/7)
#  с поддержкой экспресс-режимов, Geekbench 7, таймаута и неинтерактивного обхода.
# ==============================================================================

run_yabs_benchmark() {
    local flags="${1:-}"
    local log_file="${2:-/root/yabs.log}"

    # Защита директории для лога
    local log_dir
    log_dir=$(dirname "$log_file")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir" 2>/dev/null || log_file="/tmp/yabs.log"
    fi

    log "Запуск тестирования производительности сервера (YABS)..."
    echo -e "  ${DIM}Команда:${NC} ${CYAN}curl -sL yabs.sh | bash ${flags:+-s -- $flags}${NC}"
    echo -e "  ${DIM}Файл отчета:${NC} ${GREEN}${log_file}${NC}\n"

    if ! command -v curl >/dev/null 2>&1; then
        warn "Утилита curl не найдена. Установите curl для запуска YABS."
        return 1
    fi

    # Основной и зеркальный адреса YABS
    local yabs_url="https://raw.githubusercontent.com/masonr/yet-another-bench-script/master/yabs.sh"
    if ! curl -sI --max-time 3 "https://raw.githubusercontent.com" >/dev/null 2>&1; then
        yabs_url="https://yabs.sh"
    fi

    # Временно отключаем pipefail и set -e, чтобы прерывание или сбой бенчмарка
    # не ломали общий статус завершения скрипта развертывания
    local prev_pipefail=0
    if [[ $- == *o* ]] && shopt -po pipefail >/dev/null 2>&1; then
        prev_pipefail=1
        set +o pipefail
    fi
    local prev_errexit=0
    if [[ $- == *e* ]]; then
        prev_errexit=1
        set +e
    fi

    if [ -n "${TEST_YABS_RUNNER:-}" ]; then
        # Хук для модульных тестов
        "$TEST_YABS_RUNNER" "$flags" 2>&1 | tee "$log_file"
    elif [ -n "$flags" ]; then
        # shellcheck disable=SC2086
        curl -sL "$yabs_url" | bash -s -- $flags 2>&1 | tee "$log_file"
    else
        curl -sL "$yabs_url" | bash 2>&1 | tee "$log_file"
    fi
    local exit_code=${PIPESTATUS[0]:-$?}

    if [ "$prev_pipefail" -eq 1 ]; then
        set -o pipefail
    fi
    if [ "$prev_errexit" -eq 1 ]; then
        set -e
    fi

    if [ -f "$log_file" ]; then
        chmod 600 "$log_file" 2>/dev/null || true
        echo ""
        ok "Отчет бенчмарка успешно сохранен в: ${GREEN}${log_file}${NC}"
    fi

    return "$exit_code"
}

offer_yabs_benchmark() {
    # Защита от повторного вызова
    if [ "${_YABS_BENCHMARK_OFFERED:-0}" -eq 1 ]; then
        return 0
    fi
    _YABS_BENCHMARK_OFFERED=1

    # Полное отключение через SKIP_YABS
    if is_true "${SKIP_YABS:-0}"; then
        return 0
    fi

    # Автоматический запуск, если явно включен через флаг/переменную RUN_YABS / YABS
    if is_true "${RUN_YABS:-0}" || is_true "${YABS:-0}"; then
        local auto_flags="${YABS_ARGS:--g}"
        run_yabs_benchmark "$auto_flags"
        return $?
    fi

    # Если включен неинтерактивный режим — пропускаем без запроса
    if is_true "${NON_INTERACTIVE:-0}"; then
        return 0
    fi

    # Проверка объема оперативной памяти для подсказки к Geekbench 7
    local mem_total_kb=0 mem_total_mb=0 ram_warning=""
    if [ -f /proc/meminfo ]; then
        mem_total_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
        mem_total_mb=$(( mem_total_kb / 1024 ))
    fi
    if [ "$mem_total_mb" -gt 0 ] && [ "$mem_total_mb" -lt 2000 ]; then
        ram_warning=" ${YELLOW}(Внимание: на сервере ${mem_total_mb}MB RAM, рекомендуется >= 2GB)${NC}"
    fi

    local timeout_sec="${YABS_TIMEOUT:-20}"

    echo ""
    echo -e "  ${CYAN}${BOLD}────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${CYAN}${BOLD}🚀 Проверка производительности сервера (YABS Benchmark)${NC}"
    echo -e "  ${CYAN}${BOLD}────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${WHITE}Желаете протестировать диск (fio), сеть (iperf3) и процессор (Geekbench)?${NC}"
    echo -e "  ${DIM}Отчет будет выведен в терминал и сохранен в /root/yabs.log.${NC}"
    echo ""
    echo -e "  ${CYAN}[1]${NC} Пропустить и завершить ${DIM}(по умолчанию через ${timeout_sec} сек)${NC}"
    echo -e "  ${CYAN}[2]${NC} Экспресс-тест ${GREEN}(Диск fio + Сеть iperf3, без CPU, ~2 мин)${NC}"
    echo -e "  ${CYAN}[3]${NC} Стандартный бенчмарк ${GREEN}(Диск + Сеть + Geekbench 6, ~8-10 мин)${NC}"
    echo -e "  ${CYAN}[4]${NC} Продвинутый бенчмарк ${GREEN}(Диск + Сеть + Geekbench 7, ~10-15 мин)${NC}${ram_warning}"
    echo -e "  ${CYAN}[5]${NC} Только скорость сети ${GREEN}(iperf3 по всему миру, ~1 мин)${NC}"
    echo ""

    local choice="1"
    read -r -t "$timeout_sec" -p "  Ваш выбор [1-5] (по умолчанию: 1): " choice </dev/tty 2>/dev/null || \
    read -r -t "$timeout_sec" choice 2>/dev/null || choice="1"
    choice=$(echo "${choice:-1}" | tr -d '[:space:]')

    case "$choice" in
        2)
            run_yabs_benchmark "${YABS_ARGS:--g}"
            ;;
        3)
            run_yabs_benchmark "${YABS_ARGS:-}"
            ;;
        4)
            run_yabs_benchmark "${YABS_ARGS:--7}"
            ;;
        5)
            run_yabs_benchmark "${YABS_ARGS:--f -g}"
            ;;
        *)
            ok "Тестирование производительности пропущено."
            echo -e "  ${DIM}Вы всегда можете запустить YABS вручную позже:${NC}"
            echo -e "  ${CYAN}curl -sL yabs.sh | bash${NC}  ${DIM}(или с флагом -g для пропуска Geekbench)${NC}\n"
            ;;
    esac

    return 0
}
