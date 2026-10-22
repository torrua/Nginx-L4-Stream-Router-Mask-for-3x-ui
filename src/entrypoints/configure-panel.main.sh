#!/usr/bin/env bash
# ==============================================================================
#  CONFIGURE 3X-UI INBOUNDS & SETTINGS (__VERSION__ Universal Companion & Smart Reconcile)
# ==============================================================================
#  Скрипт автоматического конфигурирования и самовосстановления базы 3X-UI.
#  Безопасен для повторного запуска:
#    1. Сохранение существующих клиентов (UUID, пароли Hy2, ключи AWG, лимиты);
#    2. Сохранение действующих серверных ключей REALITY и AmneziaWG;
#    3. Самоисправление скрытых ошибок (reality settings.publicKey, мертвый SNI swdist);
#    4. Автоматическая настройка externalProxy :443 для корректных ссылок подписок;
#    5. Защита существующей кастомной подписки (не затирает кастомный домен/путь);
#    6. Режим безопасного аудита (--dry-run) и авто-бэкап базы перед записью.
# ==============================================================================

set -euo pipefail

# @include "common/colors.sh"
# @include "common/logger.sh"
# @include "common/config.sh"
# @include "common/lock.sh"
# @include "panel/node-token.sh"
# @include "common/backup.sh"
# @include "common/spinner.sh"
# @include "panel/configure.sh"

configure_3xui_panel "$@"
