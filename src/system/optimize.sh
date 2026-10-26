#!/usr/bin/env bash
# ==============================================================================
# src/system/optimize.sh — Модуль оптимизации ресурсов VPS и очистки балласта
# ==============================================================================
# Подходит для: Ubuntu (20.04 - 26.04) и Debian (11 - 13)
#
# Предоставляет функции:
#   - unlock_cloud_init_root: снятие cloud-init блокировок с сохранением ключей
#   - optimize_vps_storage: DPKG no-doc, APT no-cache, удаление snapd/cloud-балласта
#   - optimize_vps_memory: адаптивная настройка zRAM (сжатый swap) и sysctl
#   - optimize_vps_logs: лимиты journald (50M) и ротация логов Docker (10M)
#   - setup_clean_motd: установка информативного MOTD-баннера RAM/zRAM/Диск
#   - run_full_vps_optimization: пакетный вызов всех процедур оптимизации
# ==============================================================================

unlock_cloud_init_root() {
    echo "Проверка и разблокировка прямого SSH-доступа для root..."
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys

    # Снятие блокирующего префикса cloud-init (command="echo Please login as...")
    if grep -qE 'command=".*Please login as' /root/.ssh/authorized_keys 2>/dev/null; then
        sed -i -E 's/^(no-[^ ]+ +)*command="[^"]*" +//g' /root/.ssh/authorized_keys
        echo "  ✔ Снята cloud-init блокировка прямого входа root в authorized_keys."
    fi

    # Копирование ключей из профиля sudo-пользователя, если root пуст
    if [ ! -s /root/.ssh/authorized_keys ] && [ -n "${SUDO_USER:-}" ] && [ -f "/home/${SUDO_USER}/.ssh/authorized_keys" ]; then
        cp "/home/${SUDO_USER}/.ssh/authorized_keys" /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        echo "  ✔ SSH-ключи перенесены из профиля /home/${SUDO_USER} в /root."
    fi

    # Опциональное добавление ключа из переменной окружения
    if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
        echo "${SSH_PUBLIC_KEY}" >> /root/.ssh/authorized_keys
        sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
        echo "  ✔ Добавлен SSH-ключ из переменной SSH_PUBLIC_KEY."
    fi

    # Отключение повторной блокировки в cloud-init
    if [ -d /etc/cloud ]; then
        mkdir -p /etc/cloud/cloud.cfg.d
        echo 'disable_root: false' > /etc/cloud/cloud.cfg.d/99-disable-root.cfg
        if [ -f /etc/cloud/cloud.cfg ]; then
            sed -i 's/disable_root: true/disable_root: false/' /etc/cloud/cloud.cfg 2>/dev/null || true
        fi
        touch /etc/cloud/cloud-init.disabled 2>/dev/null || true
    fi
}

optimize_vps_storage() {
    echo "Оптимизация дискового пространства и удаление фонового балласта..."
    export DEBIAN_FRONTEND=noninteractive

    # 1. Отключение неиспользуемых фоновых служб
    local useless_services=(
        ModemManager
        multipathd
        udisks2
        rsyslog
        fwupd
        open-vm-tools
    )
    for svc in "${useless_services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc" 2>/dev/null || true
        fi
        systemctl disable "$svc" 2>/dev/null || true
        systemctl mask "$svc" 2>/dev/null || true
    done

    # 2. Удаление snapd
    if dpkg -l | grep -qE '^ii\s+snapd\s' 2>/dev/null; then
        echo "  - Удаление snapd..."
        apt-get purge -y snapd ubuntu-advantage-tools 2>/dev/null || true
        rm -rf /root/snap /var/snap /var/lib/snapd /usr/lib/snapd /home/*/snap 2>/dev/null || true
    fi

    # 3. Удаление облачных SDK и неиспользуемых библиотек
    local packages_to_purge=(
        landscape-common
        python3-boto3
        python3-botocore
        python3-s3transfer
        python3-twisted
        sosreport
        sos
        bpftrace
        ubuntu-kernel-accessories
    )
    for pkg in "${packages_to_purge[@]}"; do
        if dpkg -l | grep -qE "^ii\s+${pkg}\b" 2>/dev/null; then
            echo "  - Удаление $pkg..."
            apt-get purge -y "$pkg" 2>/dev/null || true
        fi
    done

    # 4. Удаление неиспользуемых заголовочных файлов ядра
    if dpkg -l | grep -qE 'linux-headers' 2>/dev/null; then
        echo "  - Очистка неиспользуемых linux-headers..."
        dpkg --list | grep -E 'linux-headers' | awk '{print $2}' | xargs -r apt-get purge -y 2>/dev/null || true
    fi

    # 5. Политика DPKG no-doc
    mkdir -p /etc/dpkg/dpkg.cfg.d
    cat << 'EOF' > /etc/dpkg/dpkg.cfg.d/01_nodoc
path-exclude /usr/share/doc/*
path-exclude /usr/share/man/*
path-exclude /usr/share/groff/*
path-exclude /usr/share/info/*
path-exclude /usr/share/lintian/*
path-exclude /usr/share/linda/*
EOF
    rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/groff/* /usr/share/info/* 2>/dev/null || true

    # 6. Политика APT no-cache и очистка архивов
    mkdir -p /etc/apt/apt.conf.d
    cat << 'EOF' > /etc/apt/apt.conf.d/02nocache
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
Acquire::GzipIndexes "true";
Acquire::CompressionTypes::Order:: "gz";
EOF

    apt-get autoremove --purge -y 2>/dev/null || true
    apt-get clean 2>/dev/null || true
    rm -rf /var/cache/apt/archives/*.deb /var/cache/apt/*.bin 2>/dev/null || true
    echo "  ✔ Дисковая очистка и политики экономии памяти успешно применены."
}

optimize_vps_logs() {
    echo "Настройка лимитов системных логов (Journald и Docker)..."
    
    # 1. Лимиты systemd-journald (максимум 50 МБ)
    mkdir -p /etc/systemd/journald.conf.d
    cat << 'EOF' > /etc/systemd/journald.conf.d/00-limits.conf
[Journal]
SystemMaxUse=50M
SystemMaxFileSize=10M
MaxRetentionSec=1month
EOF
    systemctl restart systemd-journald 2>/dev/null || true
    journalctl --vacuum-size=50M 2>/dev/null || true

    # 2. Ротация логов Docker (максимум 10 МБ на контейнер)
    mkdir -p /etc/docker
    local docker_daemon_json="/etc/docker/daemon.json"
    if [ ! -f "$docker_daemon_json" ]; then
        cat << 'EOF' > "$docker_daemon_json"
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
        systemctl restart docker 2>/dev/null || true
    fi
    echo "  ✔ Лимиты логов успешно настроены (защита диска от переполнения активна)."
}

optimize_vps_memory() {
    local total_ram_mb
    total_ram_mb=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "1024")
    echo "Настройка адаптивного zRAM для ${total_ram_mb}M RAM..."

    # Установка systemd-zram-generator
    if ! dpkg -l | grep -qE '^ii\s+systemd-zram-generator\s' 2>/dev/null; then
        apt-get update -qq 2>/dev/null || true
        apt-get install -y --no-install-recommends systemd-zram-generator 2>/dev/null || true
    fi

    mkdir -p /etc/systemd
    mkdir -p /etc/sysctl.d

    if [ "$total_ram_mb" -le 2048 ]; then
        echo "  -> Профиль малого объема RAM (<= 2GB): zRAM 50% + агрессивный возврат кэша."
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
        echo "  -> Профиль стандартного объема RAM (> 2GB): zRAM 2GB + сохранение дискового кэша."
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
    systemctl daemon-reload 2>/dev/null || true
    systemctl start /dev/zram0 2>/dev/null || systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true
    echo "  ✔ zRAM и параметры ядра успешно настроены."
}

setup_clean_motd() {
    echo "Настройка чистого системного MOTD-баннера..."
    local motd_spam=(
        10-help-text
        50-motd-news
        90-updates-available
        91-contract-ua-esm-status
        91-release-upgrade
        95-hwe-eol
    )

    for script in "${motd_spam[@]}"; do
        if [ -f "/etc/update-motd.d/$script" ]; then
            chmod -x "/etc/update-motd.d/$script" 2>/dev/null || true
        fi
    done

    if [ -L "/etc/update-motd.d/50-landscape-sysinfo" ] || [ -f "/etc/update-motd.d/50-landscape-sysinfo" ]; then
        rm -f "/etc/update-motd.d/50-landscape-sysinfo" 2>/dev/null || true
    fi

    cat << 'EOF' > /etc/update-motd.d/50-sysinfo
#!/bin/bash
mem_total=$(free -m | awk '/^Mem:/ {print $2}')
mem_used=$(free -m | awk '/^Mem:/ {print $3}')
mem_pct=$(awk "BEGIN {printf \"%.1f\", ($mem_used/($mem_total ? $mem_total : 1))*100}")

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
    chmod +x /etc/update-motd.d/50-sysinfo 2>/dev/null || true
    echo "  ✔ MOTD-баннер обновлен."
}

run_full_vps_optimization() {
    echo "==========================================================="
    echo "Запуск комплексной оптимизации VPS (Диск, Память, Службы)..."
    echo "==========================================================="
    unlock_cloud_init_root
    optimize_vps_storage
    optimize_vps_logs
    optimize_vps_memory
    setup_clean_motd
    echo "==========================================================="
    echo "✔ Оптимизация VPS успешно завершена!"
    echo "==========================================================="
    if [ -x /etc/update-motd.d/50-sysinfo ]; then
        /etc/update-motd.d/50-sysinfo || true
    fi
}
