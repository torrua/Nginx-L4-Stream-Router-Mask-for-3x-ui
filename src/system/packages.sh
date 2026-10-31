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
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" && "$ID" != "alpine" ]]; then
        die "Данный скрипт оптимизирован строго под дистрибутивы семейств Ubuntu, Debian и Alpine Linux."
    fi
else
    die "Не удалось определить параметры текущего дистрибутива ОС."
fi

# Обеспечение совместимости со средой Alpine Linux (bash, python3, iproute2, iptables)
if [ -f /etc/alpine-release ] || [ "${ID:-}" = "alpine" ]; then
    if ! command -v bash >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1 || ! command -v ip >/dev/null 2>&1 || ! command -v iptables >/dev/null 2>&1; then
        apk update && apk add --no-cache bash python3 iproute2 iptables
    fi
fi

# Унифицированные обертки для работы с пакетными менеджерами
pkg_update() {
    if command -v apk >/dev/null 2>&1; then
        apk update
    elif command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q
    fi
}

pkg_install() {
    [ $# -eq 0 ] && return 0
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache "$@"
    elif command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        local apt_flags=("-o" "Acquire::Retries=3" "-o" "Acquire::http::Timeout=15" "-o" "DPkg::Lock::Timeout=60")
        apt-get install -y --no-install-recommends "${apt_flags[@]}" -q "$@"
    fi
}

pkg_remove() {
    [ $# -eq 0 ] && return 0
    if command -v apk >/dev/null 2>&1; then
        apk del "$@"
    elif command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get purge -y "$@"
    fi
}

pkg_is_installed() {
    local pkg="$1"
    if command -v apk >/dev/null 2>&1; then
        apk info -e "$pkg" >/dev/null 2>&1
    elif command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"
    else
        return 1
    fi
}

map_pkg_to_alpine() {
    local pkg="$1"
    case "$pkg" in
        build-essential) echo "build-base" ;;
        python3-bcrypt) echo "py3-bcrypt" ;;
        python3-pip) echo "py3-pip" ;;
        python3-sqlite3) echo "py3-sqlite3" ;;
        python3-certbot-nginx|python3-certbot-dns-cloudflare) echo "certbot" ;;
        qrencode) echo "libqrencode-tools" ;;
        resolvconf) echo "openresolv" ;;
        cron) echo "dcron" ;;
        mtr-tiny) echo "mtr" ;;
        libnginx-mod-stream) echo "nginx-mod-stream" ;;
        iptables-persistent) echo "iptables-openrc" ;;
        libnetfilter-queue1|libnetfilter-queue-dev) echo "libnetfilter_queue" ;;
        iproute2-ss) echo "iproute2-ss" ;;
        *) echo "$pkg" ;;
    esac
}

# Функция установки базовых зависимостей без вывода простыни apt
install_prerequisites() {
    if [[ "${ID:-}" == "alpine" ]]; then
        local alpine_missing=()
        declare -A alpine_pkg_map=(
            [curl]="curl"
            [bash]="bash"
            [rc-service]="openrc"
            [openssl]="openssl"
            [awk]="gawk"
            [cron]="dcron"
            [crond]="dcron"
            [ufw]="ufw"
            [python3]="python3"
            [mtr]="mtr"
            [qrencode]="libqrencode-tools"
            [tar]="tar"
            [grep]="grep"
            [coreutils]="coreutils"
            [procps]="procps"
            [iptables]="iptables"
            [ss]="iproute2-ss"
        )
        for cmd in "${!alpine_pkg_map[@]}"; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                alpine_missing+=("${alpine_pkg_map[$cmd]}")
            fi
        done
        if command -v python3 >/dev/null 2>&1 && ! python3 -c "import bcrypt" >/dev/null 2>&1; then
            alpine_missing+=("py3-bcrypt")
        fi
        if command -v python3 >/dev/null 2>&1 && ! python3 -c "import sqlite3" >/dev/null 2>&1; then
            alpine_missing+=("py3-sqlite3")
        fi

        if [ ${#alpine_missing[@]} -gt 0 ]; then
            if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
                echo "  [DEBUG] Alpine: Требуется установка: ${alpine_missing[*]}"
            fi
            apk update || true
            apk add --no-cache "${alpine_missing[@]}" iptables-openrc shadow 2>/dev/null || apk add "${alpine_missing[@]}" || true
        else
            if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
                echo "  [DEBUG] Все базовые утилиты уже установлены — пропускаем apk add."
            fi
        fi

        # Запуск и включение службы cron (dcron) в OpenRC
        if command -v rc-update >/dev/null 2>&1; then
            rc-update add dcron default >/dev/null 2>&1 || rc-update add cron default >/dev/null 2>&1 || true
            rc-service dcron start >/dev/null 2>&1 || rc-service cron start >/dev/null 2>&1 || true
        fi
        return 0
    fi

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
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop motd-news.timer >/dev/null 2>&1 || true
        systemctl disable motd-news.timer >/dev/null 2>&1 || true
    fi
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
