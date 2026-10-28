#!/usr/bin/env bash
# ==============================================================================
# clean_server.sh — Универсальная автоматическая оптимизация и очистка VPS
# ==============================================================================
# Подходит для: Ubuntu (20.04 / 22.04 / 24.04 / 26.04) и Debian (11 / 12 / 13)
#
# Назначение:
#   Превращает «раздутый» облачный образ ОС в чистый, защищенный и оптимизированный
#   headless-сервер для прокси/VPN стеков (AmneziaWG, Dokploy, Xray, Sing-box).
#
# Что делает скрипт в один шаг (полностью неинтерактивно):
#   1. Разблокирует прямой вход root по SSH (снимает cloud-init ограничения),
#      сохраняя исходные SSH-ключи пользователя без хардкода.
#   2. Отключает повторные блокировки cloud-init при перезагрузках.
#   3. Останавливает и маскирует неиспользуемые системные службы (ModemManager,
#      multipathd, udisks2, rsyslog, fwupd, open-vm-tools).
#   4. Удаляет snapd, лишние облачные SDK (AWS botocore, twisted, landscape),
#      диагностические пакеты и неиспользуемые linux-headers.
#   5. Устанавливает политику DPKG no-doc и очищает документацию/мануалы (/usr/share).
#   6. Отключает кэширование пакетов APT (02nocache) и освобождает место.
#   7. Ограничивает разрастание системных логов Journald и задает ротацию логов Docker.
#   8. Адаптивно настраивает zRAM (сжатый swap в RAM) и профиль ядра (sysctl)
#      в зависимости от объема оперативной памяти сервера (<=2GB или >2GB).
#   9. Устанавливает чистый информативный MOTD-баннер (RAM / zRAM / Диск).
#
# Переменные окружения (опционально):
#   SSH_PUBLIC_KEY        — Дополнительный публичный SSH-ключ для добавления в authorized_keys
#   ADDITIONAL_SSH_PORT   — Дополнительный порт для SSH (например: ADDITIONAL_SSH_PORT=1981)
# ==============================================================================

set -euo pipefail

# 1. Проверка прав суперпользователя
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "[-] Ошибка: скрипт должен запускаться с правами root (sudo bash $0)" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "=========================================================="
echo " [1/9] Настройка SSH-доступа и разблокировка root"
echo "=========================================================="

mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# Если cloud-init заблокировал root оберткой command="echo Please login as...",
# аккуратно снимаем ограничение, сохраняя сам публичный ключ:
if grep -qE 'command=".*Please login as' /root/.ssh/authorized_keys 2>/dev/null; then
    sed -i -E 's/^.*(ssh-[a-z0-9]+|ecdsa-[a-z0-9-]+)/\1/' /root/.ssh/authorized_keys
    echo "  -> Снята cloud-init блокировка прямого входа root в authorized_keys."
fi

# Если файл authorized_keys у root пуст, но запуск идет через sudo-пользователя (customer, ubuntu, debian),
# копируем ключ этого пользователя для root:
if [ ! -s /root/.ssh/authorized_keys ] && [ -n "${SUDO_USER:-}" ] && [ -f "/home/${SUDO_USER}/.ssh/authorized_keys" ]; then
    cp "/home/${SUDO_USER}/.ssh/authorized_keys" /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    echo "  -> SSH-ключи скопированы из профиля /home/${SUDO_USER} в /root."
fi

# Опциональное добавление пользовательского ключа через переменную окружения
if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
    echo "${SSH_PUBLIC_KEY}" >> /root/.ssh/authorized_keys
    sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    echo "  -> Добавлен SSH-ключ из переменной SSH_PUBLIC_KEY."
fi

# Отключаем сброс доступа root в cloud-init при последующих перезагрузках
if [ -d /etc/cloud ]; then
    mkdir -p /etc/cloud/cloud.cfg.d
    echo 'disable_root: false' > /etc/cloud/cloud.cfg.d/99-disable-root.cfg
    if [ -f /etc/cloud/cloud.cfg ]; then
        sed -i 's/disable_root: true/disable_root: false/' /etc/cloud/cloud.cfg 2>/dev/null || true
    fi
    touch /etc/cloud/cloud-init.disabled 2>/dev/null || true
fi

# Конфигурация портов SSH
mkdir -p /etc/ssh/sshd_config.d
SSH_PORTS_CONF="/etc/ssh/sshd_config.d/99-vps-ports.conf"

{
    echo "Port 22"
    if [ -n "${ADDITIONAL_SSH_PORT:-}" ] && [ "${ADDITIONAL_SSH_PORT}" != "22" ]; then
        echo "Port ${ADDITIONAL_SSH_PORT}"
    fi
    echo "PermitRootLogin prohibit-password"
    echo "PasswordAuthentication no"
    echo "PubkeyAuthentication yes"
} > "$SSH_PORTS_CONF"

# Перезапуск службы SSH с поддержкой systemd socket (Ubuntu 24+) и стандартного сервиса
if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl daemon-reload
    systemctl restart ssh.socket || true
fi
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

echo "=========================================================="
echo " [2/9] Отключение неиспользуемых фоновых демонов"
echo "=========================================================="
USELESS_SERVICES=(
    ModemManager
    multipathd
    udisks2
    rsyslog
    fwupd
    fwupd-refresh.timer
    open-vm-tools
    networkd-dispatcher
    unattended-upgrades
    ssh-transition-watcher
    sysstat
    sysstat-collect.timer
    sysstat-rotate.timer
    sysstat-summary.timer
    getty@tty1
)

for svc in "${USELESS_SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl stop "$svc" 2>/dev/null || true
    fi
    systemctl disable "$svc" 2>/dev/null || true
    systemctl mask "$svc" 2>/dev/null || true
done
rm -f /etc/systemd/system/ssh-transition-watcher.service /usr/local/bin/ssh-transition-watcher.sh 2>/dev/null || true
rm -rf /var/log/sysstat/* 2>/dev/null || true

echo "=========================================================="
echo " [3/9] Удаление snapd и облачного балласта"
echo "=========================================================="
if dpkg -l | grep -qE '^ii\s+snapd\s'; then
    apt-get purge -y snapd 2>/dev/null || true
    rm -rf /root/snap /var/snap /var/lib/snapd /usr/lib/snapd /home/*/snap /var/cache/snapd /snap 2>/dev/null || true
fi

# Заменяем раздутую GTK/X11-версию mtr на легковесный headless mtr-tiny
if dpkg -l | grep -qE '^ii\s+mtr\s' && ! dpkg -l | grep -qE '^ii\s+mtr-tiny\s'; then
    apt-get install -y --no-install-recommends mtr-tiny 2>/dev/null || true
    apt-get purge -y mtr 2>/dev/null || true
fi

PACKAGES_TO_PURGE=(
    landscape-common
    python3-boto3
    python3-botocore
    python3-s3transfer
    python3-twisted
    sosreport
    sos
    bpftrace
    ubuntu-kernel-accessories
    fwupd
    linux-perf
    g++
    adwaita-icon-theme
    glycin-loaders
    python-babel-localedata
    python3-babel
)

INSTALLED_PURGE=()
for pkg in "${PACKAGES_TO_PURGE[@]}"; do
    if dpkg -l | grep -qE "^ii\s+${pkg}\b" 2>/dev/null; then
        INSTALLED_PURGE+=("$pkg")
    fi
done

if [ ${#INSTALLED_PURGE[@]} -gt 0 ]; then
    apt-get purge -y "${INSTALLED_PURGE[@]}" 2>/dev/null || true
fi

echo "=========================================================="
echo " [4/9] Удаление неиспользуемых заголовочных файлов ядра (headers)"
echo "=========================================================="
dpkg --list | grep -E 'linux-headers' | awk '{print $2}' | xargs -r apt-get purge -y 2>/dev/null || true

echo "=========================================================="
echo " [5/9] Запрет документации (DPKG no-doc) и очистка мануалов"
echo "=========================================================="
mkdir -p /etc/dpkg/dpkg.cfg.d
cat << 'EOF' > /etc/dpkg/dpkg.cfg.d/01_nodoc
path-exclude /usr/share/doc/*
path-exclude /usr/share/man/*
path-exclude /usr/share/groff/*
path-exclude /usr/share/info/*
path-exclude /usr/share/lintian/*
path-exclude /usr/share/linda/*
EOF

rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/groff/* /usr/share/info/*
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'en*' ! -name 'ru*' ! -name 'locale.alias' -exec rm -rf {} + 2>/dev/null || true

echo "=========================================================="
echo " [6/9] Запрет кэша APT и автоочистка пакетов"
echo "=========================================================="
mkdir -p /etc/apt/apt.conf.d
cat << 'EOF' > /etc/apt/apt.conf.d/02nocache
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
Acquire::GzipIndexes "true";
Acquire::CompressionTypes::Order:: "gz";
EOF

apt-get autoremove --purge -y
apt-get clean
rm -rf /var/cache/apt/archives/*.deb /var/cache/apt/*.bin /var/lib/apt/lists/* /var/cache/swcatalog/* /var/lib/ubuntu-advantage/apt-esm/* 2>/dev/null || true
rm -f /usr/local/x-ui/bin/geoip_IR.dat /usr/local/x-ui/bin/geosite_IR.dat 2>/dev/null || true

echo "=========================================================="
echo " [7/9] Ограничение системных логов Journald и ротация логов Docker"
echo "=========================================================="
mkdir -p /etc/systemd/journald.conf.d
cat << 'EOF' > /etc/systemd/journald.conf.d/00-limits.conf
[Journal]
SystemMaxUse=50M
SystemMaxFileSize=10M
MaxRetentionSec=1month
EOF
systemctl restart systemd-journald 2>/dev/null || true
journalctl --vacuum-size=50M 2>/dev/null || true

mkdir -p /etc/docker
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
if [ ! -f "$DOCKER_DAEMON_JSON" ]; then
    cat << 'EOF' > "$DOCKER_DAEMON_JSON"
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "2"
  }
}
EOF
fi
if systemctl is-active --quiet docker 2>/dev/null; then
    systemctl restart docker || true
fi

echo "=========================================================="
echo " [8/9] Адаптивная автонастройка zRAM и профиля ядра (sysctl)"
echo "=========================================================="
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')

# Установка генератора zRAM при отсутствии
if ! dpkg -l | grep -qE '^ii\s+systemd-zram-generator\s'; then
    apt-get update -qq
    apt-get install -y --no-install-recommends systemd-zram-generator
fi

mkdir -p /etc/systemd
mkdir -p /etc/sysctl.d

if [ "$TOTAL_RAM_MB" -le 2048 ]; then
    echo "  -> Профиль малого объема RAM (${TOTAL_RAM_MB}M <= 2GB): zRAM 50% + активная утилизация кэша."
    cat << 'EOF' > /etc/systemd/zram-generator.conf
[zram0]
zram-size = min(ram / 2, 1024)
compression-algorithm = zstd
swap-priority = 100
EOF

    cat << 'EOF' > /etc/sysctl.d/99-vps-memory.conf
vm.swappiness = 100
vm.vfs_cache_pressure = 150
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
EOF
else
    echo "  -> Профиль стандартного/большого объема RAM (${TOTAL_RAM_MB}M > 2GB): zRAM 2GB + сохранение кэша."
    cat << 'EOF' > /etc/systemd/zram-generator.conf
[zram0]
zram-size = 2048
compression-algorithm = zstd
swap-priority = 100
EOF

    cat << 'EOF' > /etc/sysctl.d/99-vps-memory.conf
vm.swappiness = 10
vm.vfs_cache_pressure = 100
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
EOF
fi

sysctl --system > /dev/null 2>&1 || true
systemctl daemon-reload
systemctl start /dev/zram0 2>/dev/null || systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true

echo "=========================================================="
echo " [9/9] Установка чистого системного MOTD-баннера"
echo "=========================================================="
MOTD_SPAM=(
    10-help-text
    50-motd-news
    90-updates-available
    91-contract-ua-esm-status
    91-release-upgrade
    95-hwe-eol
)

for script in "${MOTD_SPAM[@]}"; do
    if [ -f "/etc/update-motd.d/$script" ]; then
        chmod -x "/etc/update-motd.d/$script" 2>/dev/null || true
    fi
done

if [ -L "/etc/update-motd.d/50-landscape-sysinfo" ] || [ -f "/etc/update-motd.d/50-landscape-sysinfo" ]; then
    rm -f "/etc/update-motd.d/50-landscape-sysinfo"
fi

cat << 'EOF' > /etc/update-motd.d/50-sysinfo
#!/bin/bash
mem_total=$(free -m | awk '/^Mem:/ {print $2}')
mem_used=$(free -m | awk '/^Mem:/ {print $3}')
mem_pct=$(awk "BEGIN {printf \"%.1f\", ($mem_used/$mem_total)*100}")

zram_total=$(free -m | awk '/^Swap:/ {print $2}')
zram_used=$(free -m | awk '/^Swap:/ {print $3}')

disk_total=$(df -h / | awk 'NR==2 {print $2}')
disk_used=$(df -h / | awk 'NR==2 {print $3}')
disk_pct=$(df -h / | awk 'NR==2 {print $5}')

echo -e "\033[1;36m========================================================\033[0m"
echo -e "\033[1;32m  RAM:\033[0m  ${mem_used}M / ${mem_total}M (${mem_pct}%)"
echo -e "\033[1;32m  zRAM:\033[0m ${zram_used}M / ${zram_total}M (compressed swap)"
echo -e "\033[1;32m  Disk:\033[0m ${disk_used} / ${disk_total} (${disk_pct})"
echo -e "\033[1;36m========================================================\033[0m"
EOF
chmod +x /etc/update-motd.d/50-sysinfo

echo ""
echo "=========================================================="
echo " ✔ ОПТИМИЗАЦИЯ И НАСТРОЙКА УСПЕШНО ЗАВЕРШЕНЫ!"
echo "=========================================================="
/etc/update-motd.d/50-sysinfo
echo ""
swapon --show || true
