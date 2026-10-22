#!/usr/bin/env bash
#
# ==============================================================================
# Production AutoSetup: Nginx Stream L4 Router & 3X-UI Companion __VERSION__ Universal
# Nginx L4 Stream + 3X-UI + Unix Sockets + Native proxy_http_version 2 + 3 Decoys
# ==============================================================================
# Архитектура:
#   1) Nginx Mainline Branch v.1.31.4+ (Официальный репозиторий nginx.org)
#   2) VLESS REALITY (маскировка под свой сайт) с защитой от зацикливания (Anti-Loop Fallback 9443)
#   3) VLESS REALITY (маскировка под популярные внешние сервисы)
#   4) VLESS xHTTP (Stream-One) + VLESSENC + Native H2 Streaming (без XMUX-блокировок)
#      (СТРОГО по TCP/HTTP/2 без QUIC — полнодуплексное HTTP/2-проксирование Nginx)
#   5) Опциональный скоростной UDP VPN: Hysteria 2 (по умолчанию 443/UDP)
#   6) Опциональный двухверсионный стек AmneziaWG / WireGuard:
#      - AmneziaWG v3.1 (WG3, по умолчанию 8443/UDP, Transport Protection)
#      - AmneziaWG v2.0 (по умолчанию 8444/UDP, для роутеров Keenetic / OpenWrt)
#   7) Гибридный SSL-движок с разделением каталогов:
#      - Certbot (HTTP-01): /etc/letsencrypt/live/
#      - acme.sh + Cloudflare (DNS-01): /etc/ssl/acme/ (изоляция от /root/ и 755/644)
#      - 3 автономных локальных режима маскировки (Decoy Front):
#      - 1: DataSphere Analytics (SPA с 3D-сферой и телеметрией)
#      - 2: Облако CosmosCloud
#      - 3: Стандартная заглушка Nginx (Welcome to nginx)
#   9) Комплексная защита от ботов, сканеров уязвимостей, AI-парсеров (444/404)
#  10) Полный тюнинг ядра Linux (TCP BBR, fq, somaxconn, lowat, IPC /dev/shm, UDP buffers)
#  ==============================================================================

set -euo pipefail

SCRIPT_VERSION="__VERSION__"


# @include "common/checkpoint.sh"
# @include "common/lock.sh"
# @include "common/download.sh"

# @include "tui/base.sh"

# @include "tui/banner.sh"

# @include "system/packages.sh"

# @include "system/env.sh"

# @include "system/snapshot.sh"
# @include "system/uninstall.sh"

# @include "tui/prompts.sh"

# @include "common/preflight.sh"

# @include "system/sysctl.sh"

# @include "system/security.sh"

# @include "nginx/install.sh"

# @include "ssl/certs.sh"

# @include "awg/setup.sh"
# @include "installer/steps.sh"
# @include "installer/express.sh"
# @include "installer/plan.sh"
# @include "installer/engine.sh"

SSH_ACTIVE_PORT="${SSH_ACTIVE_PORT:-$(detect_active_ssh_port)}"
if [ -z "${CONFIG_EXPLICIT_KEYS[SSH_PORT]:-}" ]; then SSH_PORT="$SSH_ACTIVE_PORT"; fi
build_installation_plan
restore_installation_checkpoint
# @include "tui/wizard.sh"

finalize_installation_config
run_installation
