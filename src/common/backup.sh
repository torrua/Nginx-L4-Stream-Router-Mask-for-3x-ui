# SQLite WAL-safe live database backup and verification
get_sqlite_backup_python() {
    if [ -n "${PYTHON_CMD:-}" ] && "$PYTHON_CMD" -c "import sqlite3" 2>/dev/null; then
        echo "$PYTHON_CMD"
        return 0
    fi
    if python3 -c "import sqlite3" 2>/dev/null; then
        echo "python3"
        return 0
    fi
    if python -c "import sqlite3" 2>/dev/null; then
        echo "python"
        return 0
    fi
    return 1
}

run_backup_engine() {
    local py_cmd
    py_cmd=$(get_sqlite_backup_python || return 1)
    local script_loc=""
    for cand in \
        "$(dirname "${BASH_SOURCE[0]}")/backup_engine.py" \
        "$(dirname "${BASH_SOURCE[0]}")/../common/backup_engine.py" \
        "$(dirname "${BASH_SOURCE[0]}")/src/common/backup_engine.py" \
        "${SCRIPT_DIR:-.}/src/common/backup_engine.py" \
        "${SCRIPT_DIR:-.}/backup_engine.py"; do
        if [ -f "$cand" ]; then
            script_loc="$cand"
            break
        fi
    done
    if [ -n "$script_loc" ]; then
        "$py_cmd" "$script_loc" "$@"
        return $?
    fi
    "$py_cmd" - "$@" << 'EOF_BACKUP_ENGINE'
# @include "common/backup_engine.py"
EOF_BACKUP_ENGINE
}

verify_sqlite_backup() {
    local bkp="$1"
    local py_cmd="${2:-}"
    if [ ! -s "$bkp" ]; then
        return 1
    fi
    if [ -n "$py_cmd" ] || get_sqlite_backup_python >/dev/null 2>&1; then
        run_backup_engine verify_db "$bkp" 2>/dev/null && return 0
    elif command -v sqlite3 >/dev/null 2>&1; then
        local check
        check=$(sqlite3 "$bkp" "PRAGMA integrity_check;" 2>/dev/null || true)
        [ "$check" = "ok" ] && return 0
    fi
    return 1
}

backup_sqlite_db() {
    local src="$1"
    local dst="$2"
    if [ ! -f "$src" ]; then
        return 1
    fi
    local py_cmd
    py_cmd=$(get_sqlite_backup_python || true)

    local backup_ok=0

    # 1. Primary: Python SQLite Online Backup API (atomic, WAL-safe)
    if [ -n "$py_cmd" ]; then
        if run_backup_engine backup_db "$src" "$dst" 2>/dev/null; then
            if verify_sqlite_backup "$dst" "$py_cmd"; then
                backup_ok=1
            fi
        fi
    fi

    # 2. Secondary: sqlite3 CLI .backup command (atomic, WAL-safe)
    if [ "$backup_ok" -eq 0 ] && command -v sqlite3 >/dev/null 2>&1; then
        if sqlite3 "$src" ".backup '$dst'" 2>/dev/null; then
            if verify_sqlite_backup "$dst" "$py_cmd"; then
                backup_ok=1
            fi
        fi
    fi

    if [ "$backup_ok" -eq 1 ]; then
        chmod 600 "$dst" 2>/dev/null || true
        return 0
    fi

    # Never silently downgrade to raw cp of a live WAL database; fail safe and clean up
    rm -f "$dst" 2>/dev/null || true
    return 1
}

do_restore_rollback() {
    local rollback_dir="$1"
    warn "Инициирован аварийный откат к состоянию до восстановления..."
    local rollback_failed=0

    # Остановка служб перед манипуляциями с файлами во избежание гонок и повреждения БД
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop nginx 2>/dev/null || true
        if ! systemctl stop x-ui 2>/dev/null; then
            if systemctl is-active --quiet x-ui 2>/dev/null; then
                die "Критическая ошибка: невозможно остановить службу x-ui перед аварийным откатом (процесс активен). Во избежание повреждения базы данных операция отката прервана, резервные копии сохранены в $rollback_dir."
            fi
        fi
        # Обязательное подтверждение, что x-ui остановлен перед удалением журналов и заменой БД
        if systemctl is-active --quiet x-ui 2>/dev/null; then
            die "Критическая ошибка: служба x-ui продолжает работать после команды остановки. Замена базы данных и удаление журналов отменены во избежание повреждения данных. Исходные резервные копии сохранены в $rollback_dir."
        fi
    fi

    # Очистка устаревших WAL/SHM журналов перед накатом старой БД
    rm -f /etc/x-ui/x-ui.db-wal /etc/x-ui/x-ui.db-shm \
          /usr/local/x-ui/bin/x-ui.db-wal /usr/local/x-ui/bin/x-ui.db-shm 2>/dev/null || true

    if [ -f "$rollback_dir/x-ui.db" ]; then
        if [ -d /etc/x-ui ] || [ -f /etc/x-ui/x-ui.db ]; then
            mkdir -p /etc/x-ui 2>/dev/null || true
            cp -a "$rollback_dir/x-ui.db" /etc/x-ui/x-ui.db || rollback_failed=1
            chmod 600 /etc/x-ui/x-ui.db 2>/dev/null || true
        fi
        if [ -d /usr/local/x-ui/bin ] || [ -f /usr/local/x-ui/bin/x-ui.db ]; then
            mkdir -p /usr/local/x-ui/bin 2>/dev/null || true
            cp -a "$rollback_dir/x-ui.db" /usr/local/x-ui/bin/x-ui.db || rollback_failed=1
            chmod 600 /usr/local/x-ui/bin/x-ui.db 2>/dev/null || true
        fi
    fi

    if [ -d "$rollback_dir/nginx" ]; then
        cp -a "$rollback_dir/nginx/"* /etc/nginx/ 2>/dev/null || rollback_failed=1
    fi
    if [ -d "$rollback_dir/amneziawg" ]; then
        mkdir -p /etc/amnezia/amneziawg 2>/dev/null || true
        cp -a "$rollback_dir/amneziawg/"* /etc/amnezia/amneziawg/ 2>/dev/null || rollback_failed=1
    fi
    if [ -d "$rollback_dir/mita" ]; then
        mkdir -p /etc/mita 2>/dev/null || true
        cp -a "$rollback_dir/mita/"* /etc/mita/ 2>/dev/null || rollback_failed=1
        chown -R mita:mita /etc/mita 2>/dev/null || true
    fi
    if [ -f "$rollback_dir/mita_server_config.json" ]; then
        cp -a "$rollback_dir/mita_server_config.json" /etc/mita_server_config.json 2>/dev/null || rollback_failed=1
        chown mita:mita /etc/mita_server_config.json 2>/dev/null || true
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        if [ -f /etc/x-ui/x-ui.db ] || [ -f /usr/local/x-ui/bin/x-ui.db ]; then
            systemctl restart x-ui || rollback_failed=1
            systemctl is-active --quiet x-ui || rollback_failed=1
        fi
        if command -v nginx >/dev/null 2>&1 && [ -f /etc/nginx/nginx.conf ]; then
            nginx -t >/dev/null 2>&1 && systemctl restart nginx || rollback_failed=1
            systemctl is-active --quiet nginx || rollback_failed=1
        fi
    fi

    if [ "$rollback_failed" -ne 0 ]; then
        die "Восстановление прервано с ошибкой. ВНИМАНИЕ: при аварийном откате к $rollback_dir также возникли сбои (ошибки копирования или перезапуска служб)! Проверьте состояние служб и каталог $rollback_dir."
    else
        die "Восстановление прервано с ошибкой. Исходное состояние сервера успешно восстановлено из $rollback_dir."
    fi
}

do_backup() {
    local target_dir="/var/backups/vpn-stack"
    mkdir -p "$target_dir" 2>/dev/null || true
    chmod 700 "$target_dir" 2>/dev/null || true

    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    local archive="${target_dir}/vpn-backup-${ts}.tar.gz"
    local staging
    staging=$(mktemp -d /tmp/vpn-backup-staging.XXXXXX) || die "Не удалось создать временный каталог для бэкапа."

    log "Создание транзакционного снимка системы..."

    # 1. Загрузка конфигурации окружения
    local cfg=""
    if [ -n "${CONFIG_FILE:-}" ] && [ -f "$CONFIG_FILE" ]; then
        cfg="$CONFIG_FILE"
    else
        cfg=$(find_config_file "${SCRIPT_DIR:-.}" 2>/dev/null || true)
    fi
    if [ -n "$cfg" ] && [ -f "$cfg" ]; then
        if command -v load_config_data_safe >/dev/null 2>&1; then
            load_config_data_safe "$cfg" 2>/dev/null || true
        fi
        mkdir -p "$staging/env"
        cp -a "$cfg" "$staging/env/server-setup.env" 2>/dev/null || true
    fi
    if [ -f /root/vpn_credentials.txt ]; then
        mkdir -p "$staging/env"
        cp -a /root/vpn_credentials.txt "$staging/env/" 2>/dev/null || true
    fi

    # 2. Атомарный дамп базы 3X-UI через SQLite Online Backup API
    local db_file="${DB_PATH:-/etc/x-ui/x-ui.db}"
    if [ ! -f "$db_file" ]; then
        for alt_db in /usr/local/x-ui/bin/x-ui.db /etc/x-ui/x-ui.db; do
            if [ -f "$alt_db" ]; then
                db_file="$alt_db"
                break
            fi
        done
    fi

    if [ -f "$db_file" ]; then
        mkdir -p "$staging/db"
        if ! backup_sqlite_db "$db_file" "$staging/db/x-ui.db"; then
            rm -rf "$staging"
            die "Ошибка: Не удалось выполнить атомарный дамп базы данных $db_file."
        fi
        ok "База данных 3X-UI сохранена и проверена (WAL-safe)"
    fi

    # 3. Конфигурации Nginx
    if [ -d /etc/nginx ]; then
        mkdir -p "$staging/nginx"
        [ -f /etc/nginx/nginx.conf ] && cp -a /etc/nginx/nginx.conf "$staging/nginx/" 2>/dev/null || true
        [ -d /etc/nginx/conf.d ] && cp -a /etc/nginx/conf.d "$staging/nginx/" 2>/dev/null || true
        [ -d /etc/nginx/stream.d ] && cp -a /etc/nginx/stream.d "$staging/nginx/" 2>/dev/null || true
        ok "Конфигурации Nginx сохранены"
    fi

    # 4. AmneziaWG / WireGuard ключи и конфиги
    if [ -d /etc/amnezia/amneziawg ]; then
        mkdir -p "$staging/amnezia"
        cp -a /etc/amnezia/amneziawg "$staging/amnezia/" 2>/dev/null || true
        ok "Конфигурации Dual AmneziaWG сохранены"
    fi

    # 5. Службы NextGen (Sing-box, ShadowTLS, Caddy, Wstunnel, DNSTT, Mieru/mita)
    mkdir -p "$staging/nextgen"
    for ng_dir in /etc/sing-box /etc/shadowtls /etc/dnstt /etc/caddy /etc/wstunnel /etc/mita; do
        if [ -d "$ng_dir" ]; then
            cp -a "$ng_dir" "$staging/nextgen/" 2>/dev/null || true
        fi
    done
    if [ -f /etc/mita_server_config.json ]; then
        cp -a /etc/mita_server_config.json "$staging/nextgen/" 2>/dev/null || true
    fi
    ok "Конфигурации Next-Gen сервисов сохранены (включая Mieru)"

    # 6. Диагностический портал
    if [ -d /var/www/diagnostics ] || [ -d /usr/local/lib/vpn-diagnostics ]; then
        mkdir -p "$staging/diagnostics"
        [ -d /var/www/diagnostics ] && cp -a /var/www/diagnostics "$staging/diagnostics/" 2>/dev/null || true
        [ -d /usr/local/lib/vpn-diagnostics ] && cp -a /usr/local/lib/vpn-diagnostics "$staging/diagnostics/" 2>/dev/null || true
        [ -f /etc/systemd/system/vpn-diagnostics.service ] && cp -a /etc/systemd/system/vpn-diagnostics.service "$staging/diagnostics/" 2>/dev/null || true
        ok "Ресурсы веб-диагностики сохранены"
    fi

    # 7. AdGuard Home
    if [ -f /opt/AdGuardHome/AdGuardHome.yaml ]; then
        mkdir -p "$staging/adguard"
        cp -a /opt/AdGuardHome/AdGuardHome.yaml "$staging/adguard/" 2>/dev/null || true
        ok "Конфигурация AdGuard Home сохранена"
    fi

    # 8. Селективный экспорт SSL-сертификатов (Certbot lineages + acme.sh)
    mkdir -p "$staging/ssl"
    if [ -d /etc/letsencrypt/live ]; then
        local domains=()
        [ -n "${PRIMARY_DOMAIN:-}" ] && domains+=("$PRIMARY_DOMAIN")
        [ -n "${AGH_DOMAIN:-}" ] && domains+=("$AGH_DOMAIN")

        mkdir -p "$staging/ssl/letsencrypt/live"
        mkdir -p "$staging/ssl/letsencrypt/archive"
        mkdir -p "$staging/ssl/letsencrypt/renewal"

        for d in "${domains[@]}"; do
            [ -z "$d" ] && continue
            if [ -d "/etc/letsencrypt/live/$d" ]; then
                mkdir -p "$staging/ssl/letsencrypt/live/$d"
                cp -L "/etc/letsencrypt/live/$d/"* "$staging/ssl/letsencrypt/live/$d/" 2>/dev/null || true
            fi
            if [ -d "/etc/letsencrypt/archive/$d" ]; then
                mkdir -p "$staging/ssl/letsencrypt/archive/$d"
                cp -a "/etc/letsencrypt/archive/$d/"* "$staging/ssl/letsencrypt/archive/$d/" 2>/dev/null || true
            fi
            if [ -f "/etc/letsencrypt/renewal/$d.conf" ]; then
                cp -a "/etc/letsencrypt/renewal/$d.conf" "$staging/ssl/letsencrypt/renewal/" 2>/dev/null || true
            fi
        done
        [ -d /etc/letsencrypt/renewal-hooks ] && cp -a /etc/letsencrypt/renewal-hooks "$staging/ssl/letsencrypt/" 2>/dev/null || true
        ok "SSL-сертификаты Let's Encrypt сохранены"
    fi

    if [ -d /etc/ssl/acme ]; then
        mkdir -p "$staging/ssl/acme"
        cp -a /etc/ssl/acme/* "$staging/ssl/acme/" 2>/dev/null || true
        ok "SSL-сертификаты acme.sh сохранены"
    fi

    # 8.5 Создание manifest.json со списком файлов и SHA256 (T21.C01)
    run_backup_engine create_manifest "$staging" 2>/dev/null || true

    # 9. Упаковка архива
    if ! run_backup_engine create_archive "$archive" "$staging"; then
        rm -rf "$staging"
        die "Ошибка создания tar-архива $archive."
    fi

    rm -rf "$staging"
    chmod 600 "$archive"

    local sz
    sz=$(du -h "$archive" 2>/dev/null | cut -f1 || echo "OK")
    echo
    ok "Резервная копия успешно создана: ${BOLD}$archive${NC} ($sz)"
    echo -e "      ${BOLD}Путь к архиву:${NC}  ${CYAN}$archive${NC}"
    echo -e "      ${BOLD}Права доступа:${NC}  0600 (root only)"
    echo -e "      ${BOLD}Команда отката:${NC} ./maintain.sh restore $archive"
    echo
}

do_restore() {
    local archive="${1:-}"
    [[ -n "$archive" ]] || die "Укажите путь к архиву: ./maintain.sh restore <архив.tar.gz>"
    [[ -f "$archive" ]] || die "Файл архива не найден: $archive"

    local target_backup_dir="/var/backups/vpn-stack"
    local rollback_dir="${target_backup_dir}/.rollback-latest"
    mkdir -p "$target_backup_dir" 2>/dev/null || true

    log "Подготовка к восстановлению из $archive..."

    # Создание снапшота текущего состояния для гарантированного отката
    rm -rf "$rollback_dir" 2>/dev/null || true
    mkdir -p "$rollback_dir"
    chmod 700 "$rollback_dir"

    local current_db="/etc/x-ui/x-ui.db"
    if [ ! -f "$current_db" ]; then
        for alt_db in /usr/local/x-ui/bin/x-ui.db /etc/x-ui/x-ui.db; do
            if [ -f "$alt_db" ]; then
                current_db="$alt_db"
                break
            fi
        done
    fi
    if [ -f "$current_db" ]; then
        if ! backup_sqlite_db "$current_db" "$rollback_dir/x-ui.db"; then
            rm -rf "$rollback_dir"
            die "Ошибка: не удалось создать безопасный снапшот SQLite базы $current_db перед восстановлением."
        fi
    fi
    [ -d /etc/nginx ] && cp -a /etc/nginx "$rollback_dir/" 2>/dev/null || true
    [ -d /etc/amnezia/amneziawg ] && cp -a /etc/amnezia/amneziawg "$rollback_dir/" 2>/dev/null || true
    [ -d /etc/mita ] && cp -a /etc/mita "$rollback_dir/" 2>/dev/null || true
    [ -f /etc/mita_server_config.json ] && cp -a /etc/mita_server_config.json "$rollback_dir/" 2>/dev/null || true

    local staging
    staging=$(mktemp -d /tmp/vpn-restore-staging.XXXXXX) || die "Не удалось создать временный каталог для распаковки."

    # Распаковываем во временный каталог через безопасный фильтр Python
    if ! run_backup_engine extract_archive "$archive" "$staging"; then
        rm -rf "$staging"
        die "Ошибка безопасной распаковки архива $archive."
    fi

    # 0. Проверка целостности файлов бэкапа по manifest.json (T21.C01, T21.C02)
    if [ -f "$staging/manifest.json" ]; then
        if ! run_backup_engine verify_manifest "$staging"; then
            rm -rf "$staging"
            die "Ошибка: Нарушена целостность файлов бэкапа по манифесту (T21.C02)!"
        fi
        ok "Целостность файлов бэкапа и манифест версии 2.0 подтверждены"
    fi

    # 0.5 Проверка целостности SQLite перед наложением (T21.C03)
    if [ -f "$staging/db/x-ui.db" ]; then
        if ! verify_sqlite_backup "$staging/db/x-ui.db" "$py_cmd"; then
            rm -rf "$staging"
            die "Ошибка: База данных в бэкапе x-ui.db повреждена (PRAGMA integrity_check failed)!"
        fi
        ok "Целостность базы данных x-ui.db в бэкапе проверена (PRAGMA integrity_check OK)"
    fi

    # Валидация соответствия сертификатов и ключей, если они присутствуют в архиве (RSA / ECDSA / Ed25519)
    if [ -d "$staging/ssl/letsencrypt/live" ]; then
        for cert_dir in "$staging/ssl/letsencrypt/live/"*; do
            if [ -d "$cert_dir" ] && [ -f "$cert_dir/fullchain.pem" ] && [ -f "$cert_dir/privkey.pem" ]; then
                local cert_pub key_pub
                cert_pub=$(openssl x509 -noout -pubkey -in "$cert_dir/fullchain.pem" 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256 2>/dev/null || true)
                key_pub=$(openssl pkey -pubout -in "$cert_dir/privkey.pem" 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256 2>/dev/null || true)
                if [ -n "$cert_pub" ] && [ -n "$key_pub" ] && [ "$cert_pub" != "$key_pub" ]; then
                    rm -rf "$staging"
                    die "Криптографическая ошибка: сертификат и ключ в $cert_dir не соответствуют друг другу!"
                fi
            fi
        done
        ok "Криптографическая валидация SSL-сертификатов пройдена (RSA/ECDSA OK)"
    fi

    # Приостанавливаем сервисы перед заменой файлов с верификацией остановки x-ui (T03.C04, T22.C03)
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop nginx 2>/dev/null || true
        systemctl stop vpn-diagnostics 2>/dev/null || true
        if ! systemctl stop x-ui 2>/dev/null; then
            if systemctl is-active --quiet x-ui 2>/dev/null; then
                rm -rf "$staging"
                die "Критическая ошибка: невозможно остановить службу x-ui перед восстановлением (процесс активен). Замена базы отменена."
            fi
        fi
        if systemctl is-active --quiet x-ui 2>/dev/null; then
            rm -rf "$staging"
            die "Критическая ошибка: служба x-ui продолжает работать после команды остановки. Замена базы отменена."
        fi
    fi

    # 1. Восстановление базы данных
    if [ -f "$staging/db/x-ui.db" ]; then
        # Очистка устаревших журналов WAL/SHM перед накатом базы данных (T03.C04, T21.C03)
        rm -f /etc/x-ui/x-ui.db-wal /etc/x-ui/x-ui.db-shm \
              /usr/local/x-ui/bin/x-ui.db-wal /usr/local/x-ui/bin/x-ui.db-shm 2>/dev/null || true
        mkdir -p /etc/x-ui
        cp -a "$staging/db/x-ui.db" /etc/x-ui/x-ui.db
        chmod 600 /etc/x-ui/x-ui.db
        if [ -d /usr/local/x-ui/bin ]; then
            cp -a "$staging/db/x-ui.db" /usr/local/x-ui/bin/x-ui.db 2>/dev/null || true
            chmod 600 /usr/local/x-ui/bin/x-ui.db 2>/dev/null || true
        fi
        ok "База данных 3X-UI восстановлена"
    fi

    # 2. Восстановление Nginx
    if [ -d "$staging/nginx" ]; then
        mkdir -p /etc/nginx/conf.d /etc/nginx/stream.d
        [ -f "$staging/nginx/nginx.conf" ] && cp -a "$staging/nginx/nginx.conf" /etc/nginx/nginx.conf
        [ -d "$staging/nginx/conf.d" ] && cp -a "$staging/nginx/conf.d/"* /etc/nginx/conf.d/ 2>/dev/null || true
        [ -d "$staging/nginx/stream.d" ] && cp -a "$staging/nginx/stream.d/"* /etc/nginx/stream.d/ 2>/dev/null || true
        ok "Конфигурация Nginx восстановлена"
    fi

    # 3. Восстановление AmneziaWG
    if [ -d "$staging/amnezia/amneziawg" ]; then
        mkdir -p /etc/amnezia/amneziawg
        cp -a "$staging/amnezia/amneziawg/"* /etc/amnezia/amneziawg/ 2>/dev/null || true
        chmod 700 /etc/amnezia/amneziawg
        chmod 600 /etc/amnezia/amneziawg/*.conf 2>/dev/null || true
        ok "Конфигурация AmneziaWG восстановлена"
    fi

    # 4. Восстановление AdGuard Home
    if [ -f "$staging/adguard/AdGuardHome.yaml" ]; then
        mkdir -p /opt/AdGuardHome
        cp -a "$staging/adguard/AdGuardHome.yaml" /opt/AdGuardHome/AdGuardHome.yaml
        ok "Конфигурация AdGuard Home восстановлена"
    fi

    # 5. Восстановление Next-Gen сервисов (включая Mieru/mita)
    if [ -d "$staging/nextgen" ]; then
        for ng_dir in sing-box shadowtls dnstt caddy wstunnel mita; do
            if [ -d "$staging/nextgen/$ng_dir" ]; then
                mkdir -p "/etc/$ng_dir"
                cp -a "$staging/nextgen/$ng_dir/"* "/etc/$ng_dir/" 2>/dev/null || true
            fi
        done
        if [ -f "$staging/nextgen/mita_server_config.json" ]; then
            cp -a "$staging/nextgen/mita_server_config.json" /etc/mita_server_config.json 2>/dev/null || true
        fi
        if id -u mita >/dev/null 2>&1; then
            chown -R mita:mita /etc/mita /etc/mita_server_config.json 2>/dev/null || true
            chmod 750 /etc/mita 2>/dev/null || true
            chmod 600 /etc/mita/config.json /etc/mita_server_config.json 2>/dev/null || true
        fi
        ok "Конфигурации Next-Gen сервисов восстановлены"
    fi

    # 6. Восстановление веб-диагностики
    if [ -d "$staging/diagnostics" ]; then
        if [ -d "$staging/diagnostics/diagnostics" ]; then
            mkdir -p /var/www/diagnostics
            cp -a "$staging/diagnostics/diagnostics/"* /var/www/diagnostics/ 2>/dev/null || true
        fi
        if [ -d "$staging/diagnostics/vpn-diagnostics" ]; then
            mkdir -p /usr/local/lib/vpn-diagnostics
            cp -a "$staging/diagnostics/vpn-diagnostics/"* /usr/local/lib/vpn-diagnostics/ 2>/dev/null || true
        fi
        if [ -f "$staging/diagnostics/vpn-diagnostics.service" ]; then
            cp -a "$staging/diagnostics/vpn-diagnostics.service" /etc/systemd/system/ 2>/dev/null || true
        fi
        ok "Ресурсы веб-диагностики восстановлены"
    fi

    # 7. Селективное восстановление SSL
    if [ -d "$staging/ssl/letsencrypt" ]; then
        mkdir -p /etc/letsencrypt
        [ -d "$staging/ssl/letsencrypt/live" ] && cp -a "$staging/ssl/letsencrypt/live" /etc/letsencrypt/ 2>/dev/null || true
        [ -d "$staging/ssl/letsencrypt/archive" ] && cp -a "$staging/ssl/letsencrypt/archive" /etc/letsencrypt/ 2>/dev/null || true
        [ -d "$staging/ssl/letsencrypt/renewal" ] && cp -a "$staging/ssl/letsencrypt/renewal" /etc/letsencrypt/ 2>/dev/null || true
        [ -d "$staging/ssl/letsencrypt/renewal-hooks" ] && cp -a "$staging/ssl/letsencrypt/renewal-hooks" /etc/letsencrypt/ 2>/dev/null || true
        ok "Селективные сертификаты Certbot восстановлены"
    fi
    if [ -d "$staging/ssl/acme" ]; then
        mkdir -p /etc/ssl/acme
        cp -a "$staging/ssl/acme/"* /etc/ssl/acme/ 2>/dev/null || true
        ok "Сертификаты acme.sh восстановлены"
    fi

    # 8. Восстановление переменных окружения
    if [ -f "$staging/env/server-setup.env" ]; then
        local target_env="${CONFIG_FILE:-/root/server-setup.env}"
        cp -a "$staging/env/server-setup.env" "$target_env" 2>/dev/null || true
    fi
    if [ -f "$staging/env/vpn_credentials.txt" ]; then
        cp -a "$staging/env/vpn_credentials.txt" /root/vpn_credentials.txt 2>/dev/null || true
    fi

    rm -rf "$staging"

    # 9. Проверка синтаксиса Nginx
    if command -v nginx >/dev/null 2>&1 && [ -f /etc/nginx/nginx.conf ]; then
        if ! nginx -t >/dev/null 2>&1; then
            warn "Ошибка: Восстановленная конфигурация Nginx не прошла синтаксическую проверку (nginx -t)!"
            do_restore_rollback "$rollback_dir"
        fi
    fi

    # 10. Перезапуск и строгая проверка активности критических служб
    systemctl daemon-reload 2>/dev/null || true

    if systemctl is-enabled x-ui >/dev/null 2>&1 || [ -f /etc/systemd/system/x-ui.service ]; then
        if ! systemctl restart x-ui; then
            warn "Ошибка: Не удалось перезапустить службу x-ui после восстановления!"
            do_restore_rollback "$rollback_dir"
        fi
        sleep 1
        if ! systemctl is-active --quiet x-ui; then
            warn "Ошибка: Служба x-ui не перешла в активное состояние после восстановления!"
            do_restore_rollback "$rollback_dir"
        fi
    fi

    if systemctl is-enabled nginx >/dev/null 2>&1 || [ -f /lib/systemd/system/nginx.service ] || [ -f /etc/systemd/system/nginx.service ]; then
        if ! systemctl restart nginx; then
            warn "Ошибка: Не удалось перезапустить службу nginx после восстановления!"
            do_restore_rollback "$rollback_dir"
        fi
        sleep 1
        if ! systemctl is-active --quiet nginx; then
            warn "Ошибка: Служба nginx не перешла в активное состояние после восстановления!"
            do_restore_rollback "$rollback_dir"
        fi
    fi

    # Вспомогательные службы перезапускаются best effort
    if [ -f /etc/systemd/system/vpn-diagnostics.service ]; then
        systemctl restart vpn-diagnostics 2>/dev/null || true
    fi
    if [ -f /etc/systemd/system/mita.service ]; then
        systemctl restart mita 2>/dev/null || true
    fi
    if [ -f /etc/amnezia/amneziawg/awg0.conf ]; then
        systemctl restart awg-quick@awg0 2>/dev/null || true
    fi
    if [ -f /etc/amnezia/amneziawg/awg1.conf ]; then
        systemctl restart awg-quick@awg1 2>/dev/null || true
    fi

    echo
    ok "Система успешно восстановлена из бэкапа $archive!"
    echo -e "      ${BOLD}Проверка Nginx:${NC}   ${GREEN}nginx -t OK${NC}"
    echo -e "      ${BOLD}Службы:${NC}           ${GREEN}x-ui, nginx активны${NC}"
    echo -e "      ${BOLD}Снимок отката:${NC}    ${CYAN}$rollback_dir${NC}"
    echo
    return 0
}

do_extract() {
    local archive="${1:-}"
    local target="${2:-}"
    [[ -n "$archive" ]] || die "Укажите путь к архиву: ./maintain.sh extract <архив.tar.gz> <каталог_для_распаковки>"
    [[ -n "$target" ]] || die "Укажите целевой каталог: ./maintain.sh extract <архив.tar.gz> <каталог_для_распаковки>"
    [[ -f "$archive" ]] || die "Файл архива не найден: $archive"

    mkdir -p "$target" 2>/dev/null || true
    log "Аварийное безопасное извлечение архива в $target..."

    if ! run_backup_engine extract_archive "$archive" "$target"; then
        die "Ошибка извлечения архива $archive."
    fi
    ok "Архив $archive успешно и безопасно извлечён в $target"
    return 0
}

audit_restore_archive() {
    local archive="${1:-}"
    [[ -n "$archive" ]] || die "Укажите путь к архиву: ./maintain.sh --dry-run restore <архив.tar.gz>"
    [[ -f "$archive" ]] || die "Файл архива не найден: $archive"

    local staging
    staging=$(mktemp -d /tmp/vpn-audit-staging.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/vpn-audit-staging.XXXXXX") || die "Не удалось создать временный каталог для аудита."

    if ! run_backup_engine extract_archive "$archive" "$staging"; then
        rm -rf "$staging"
        die "Ошибка распаковки архива $archive при аудите."
    fi

    # 1. Проверка манифеста (T21.C01, T21.C02)
    if [ -f "$staging/manifest.json" ]; then
        if ! run_backup_engine verify_manifest "$staging"; then
            rm -rf "$staging"
            die "Ошибка аудита: Нарушена целостность файлов по манифесту архива (T21.C02)!"
        fi
        ok "[DRY-RUN] Манифест v2.0 и контрольные суммы SHA-256 проверены и совпадают"
    else
        warn "[DRY-RUN] Манифест manifest.json отсутствует (архив устаревшего формата v1.0)"
    fi

    # 2. Проверка SQLite базы (T21.C03)
    if [ -f "$staging/db/x-ui.db" ]; then
        if ! verify_sqlite_backup "$staging/db/x-ui.db" "$py_cmd"; then
            rm -rf "$staging"
            die "Ошибка аудита: База данных x-ui.db в архиве повреждена (PRAGMA integrity_check failed)!"
        fi
        ok "[DRY-RUN] База данных x-ui.db проверена (PRAGMA integrity_check OK)"
    fi

    # 3. Проверка SSL-ключей
    if [ -d "$staging/ssl/letsencrypt/live" ]; then
        for cert_dir in "$staging/ssl/letsencrypt/live/"*; do
            if [ -d "$cert_dir" ] && [ -f "$cert_dir/fullchain.pem" ] && [ -f "$cert_dir/privkey.pem" ]; then
                local cert_pub key_pub
                cert_pub=$(openssl x509 -noout -pubkey -in "$cert_dir/fullchain.pem" 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256 2>/dev/null || true)
                key_pub=$(openssl pkey -pubout -in "$cert_dir/privkey.pem" 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256 2>/dev/null || true)
                if [ -n "$cert_pub" ] && [ -n "$key_pub" ] && [ "$cert_pub" != "$key_pub" ]; then
                    rm -rf "$staging"
                    die "Ошибка аудита: сертификат и ключ в $cert_dir не соответствуют друг другу!"
                fi
            fi
        done
        ok "[DRY-RUN] Криптографические пары сертификат/ключ проверены"
    fi

    # 4. Проверка конфигурации .env
    if [ -f "$staging/env/server-setup.env" ]; then
        if command -v load_config_data_safe >/dev/null 2>&1; then
            if ! ( load_config_data_safe "$staging/env/server-setup.env" >/dev/null 2>&1 ); then
                rm -rf "$staging"
                die "Ошибка аудита: файл конфигурации server-setup.env содержит синтаксические ошибки!"
            fi
            ok "[DRY-RUN] Конфигурация server-setup.env проверена"
        fi
    fi

    rm -rf "$staging"
    ok "[DRY-RUN] Архив $archive проверен: целостность и формат валидны для восстановления"
    return 0
}

