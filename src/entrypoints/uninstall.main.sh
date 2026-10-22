#!/usr/bin/env bash
# ==============================================================================
#  UNINSTALL ENTRYPOINT (__VERSION__)
# ==============================================================================
#  Standalone tool to revert server to initial state using initial snapshot.
# ==============================================================================

set -euo pipefail

# @include "common/colors.sh"
# @include "common/logger.sh"
# @include "common/lock.sh"
# @include "system/snapshot.sh"
# @include "system/uninstall.sh"

show_uninstall_help() {
    cat << 'EOF'
Использование: ./uninstall.sh [ОПЦИИ]

Утилита полного удаления VPN/прокси стека и отката сервера к исходному состоянию.
Использует снимок исходного состояния (/var/backups/server_setup/).

Опции:
  -y, --yes, -f, --force      Пропустить интерактивное подтверждение
  --purge                     Полное удаление установленных пакетов (Nginx, AWG DKMS)
  --remove-certs              Удалить выданные SSL-сертификаты (/etc/letsencrypt, /etc/ssl/acme)
  --keep-certs                Сохранить SSL-сертификаты (по умолчанию: да)
  -v, --version               Показать версию и выйти
  -h, --help                  Показать эту справку и выйти

Примеры:
  ./uninstall.sh
  ./uninstall.sh -y
  ./uninstall.sh -y --purge --remove-certs
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes|-f|--force)
            UNINSTALL_FORCE=1
            shift
            ;;
        --purge)
            UNINSTALL_PURGE_PKGS=1
            shift
            ;;
        --remove-certs|--purge-certs)
            UNINSTALL_KEEP_CERTS=0
            UNINSTALL_CERTS_EXPLICIT=1
            shift
            ;;
        --keep-certs)
            UNINSTALL_KEEP_CERTS=1
            UNINSTALL_CERTS_EXPLICIT=1
            shift
            ;;
        -v|--version)
            echo "uninstall.sh (Nginx L4 Stream Router Mask for 3X-UI) __VERSION__"
            exit 0
            ;;
        -h|--help)
            show_uninstall_help
            exit 0
            ;;
        *)
            warn "Неизвестный параметр: $1"
            show_uninstall_help
            exit 1
            ;;
    esac
done

acquire_stack_lock "${VPN_STACK_LOCK_TIMEOUT:-10}" "uninstall" || exit $?
run_uninstall
