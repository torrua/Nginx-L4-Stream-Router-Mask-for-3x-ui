# ----------------------- Системные предусловия -----------------------
# Проверка прав root только при реальной установке (пропускается для --help, --gen-config, --check, --doctor)
check_root() {
    for arg in "$@"; do
        case "$arg" in
            -v|--version|-h|--help|--gen-config|--check|--doctor)
                return 0
                ;;
        esac
    done
    if [ "$EUID" -ne 0 ]; then
        die "Пожалуйста, запустите установщик с правами суперпользователя root (через sudo)."
    fi
}
check_root "$@"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        die "Данный скрипт оптимизирован строго под дистрибутивы семейств Ubuntu и Debian."
    fi
else
    die "Не удалось определить параметры текущего дистрибутива ОС."
fi

# Функция установки базовых зависимостей без вывода простыни apt
install_prerequisites() {
    local missing_pkgs=()
    declare -A pkg_map=(
        [curl]="curl"
        [bash]="bash"
        [systemctl]="systemd"
        [openssl]="openssl"
        [awk]="gawk"
        [gpg]="gnupg"
        [cron]="cron"
        [ufw]="ufw"
        [python3]="python3"
        [mtr]="mtr-tiny"
        [qrencode]="qrencode"
    )
    for cmd in "${!pkg_map[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_pkgs+=("${pkg_map[$cmd]}")
        fi
    done

    if command -v apt-get >/dev/null 2>&1; then
        if command -v python3 >/dev/null 2>&1 && ! python3 -c "import bcrypt" >/dev/null 2>&1; then
            missing_pkgs+=("python3-bcrypt")
        fi
    fi

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
            echo "  [DEBUG] Требуется установка: ${missing_pkgs[*]}"
        fi
        export DEBIAN_FRONTEND=noninteractive
        local apt_flags=("-o" "Acquire::Retries=3" "-o" "Acquire::http::Timeout=15" "-o" "DPkg::Lock::Timeout=60")
        if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
            apt-get update "${apt_flags[@]}" 2>/dev/null || apt-get update || true
            apt-get install -y --no-install-recommends "${apt_flags[@]}" "${missing_pkgs[@]}"
        else
            apt-get update -q "${apt_flags[@]}" 2>/dev/null || apt-get update -q || true
            apt-get install -y --no-install-recommends "${apt_flags[@]}" "${missing_pkgs[@]}" -q
        fi
    else
        if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
            echo "  [DEBUG] Все базовые утилиты уже установлены — пропускаем apt-get."
        fi
    fi

    # Отключение навязчивой рекламы Canonical, ESM Apps и спама motd в Ubuntu
    if command -v pro >/dev/null 2>&1; then
        pro config set apt_news=false >/dev/null 2>&1 || true
    fi
    if [ -f /etc/default/motd-news ]; then
        sed -i 's/ENABLED=1/ENABLED=0/' /etc/default/motd-news 2>/dev/null || true
    fi
    systemctl stop motd-news.timer >/dev/null 2>&1 || true
    systemctl disable motd-news.timer >/dev/null 2>&1 || true
    chmod -x /etc/update-motd.d/10-help-text \
             /etc/update-motd.d/50-motd-news \
             /etc/update-motd.d/88-esm-announce \
             /etc/update-motd.d/91-contract-ua-esm-status >/dev/null 2>&1 || true
    if [ -f /etc/apt/apt.conf.d/20apt-esm-hook.conf ]; then
        rm -f /etc/apt/apt.conf.d/20apt-esm-hook.conf
        touch /etc/apt/apt.conf.d/20apt-esm-hook.conf
    fi
    rm -f /var/lib/update-notifier/updates-available 2>/dev/null || true
}

