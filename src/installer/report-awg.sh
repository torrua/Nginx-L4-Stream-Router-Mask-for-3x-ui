    echo
    echo -e "${GREEN}=====================================================================${NC}"
    echo -e "  ${GREEN}${BOLD}🎉 УСТАНОВКА АВТОНОМНОГО СЕРВЕРА AMNEZIAWG УСПЕШНО ЗАВЕРШЕНА!${NC}"
    echo -e "${GREEN}=====================================================================${NC}"
    echo
    echo -e "${YELLOW}СЕРВЕРНЫЙ КОНТРОЛЛЕР AMNEZIAWG (awg-mgr):${NC}"
    echo -e "  - ${YELLOW}Служба ядра Linux:${NC}         ${GREEN}awg-quick@awg0${NC} (активна)"
    echo -e "  - ${YELLOW}Внешний UDP-порт:${NC}          ${WHITE}${AWG_STANDALONE_PORT:-8445}/udp${NC}"
    echo -e "  - ${YELLOW}Хост подключения (Endpoint):${NC} ${CYAN}${AWG_SERVER_HOST:-${WAN_IP:-127.0.0.1}}:${AWG_STANDALONE_PORT:-8445}${NC}"
    echo -e "  - ${YELLOW}Первичный конфиг админа:${NC}     ${CYAN}/root/awg/client-1.conf${NC}"
    if [ -f "/root/awg/client-1.vpnuri" ]; then
        echo -e "  - ${YELLOW}Ссылка Amnezia (vpn://):${NC}     ${GREEN}$(head -n 1 /root/awg/client-1.vpnuri 2>/dev/null | tr -d '[:space:]')${NC}"
    fi
    echo -e "  - ${YELLOW}Утилита управления:${NC}          ${GREEN}awg-mgr${NC} (или ${GREEN}awg-cli${NC})"
    echo
    echo -e "  ${YELLOW}Команды управления клиентами:${NC}"
    echo -e "    * Создать нового клиента:   ${CYAN}awg-mgr add <имя> [--preset=stealth|fast|base] [--expires=30d]${NC}"
    echo -e "    * Получить ссылку vpn://:   ${CYAN}awg-mgr uri <имя>${NC}"
    echo -e "    * Список всех клиентов:     ${CYAN}awg-mgr list${NC}"
    echo -e "    * Показать QR-код клиента:  ${CYAN}awg-mgr qr <имя>${NC}"
    echo -e "    * Отозвать / удалить:       ${CYAN}awg-mgr remove <имя>${NC}"
    echo -e "    * Резервная копия:          ${CYAN}awg-mgr backup${NC} / ${CYAN}awg-mgr restore <файл>${NC}"
    echo -e "    * Автоочистка истекших:     ${CYAN}awg-mgr purge-expired${NC} (активна в cron)"
    echo

    if [ -f "/root/awg/client-1.conf" ] && command -v /root/awg/manage-clients.sh >/dev/null 2>&1; then
        local qr_out=""
        qr_out=$(/root/awg/manage-clients.sh qr client-1 2>/dev/null || true)
        if [ -n "$qr_out" ] && [[ "$qr_out" != "{"* ]]; then
            echo -e "  ${WHITE}${BOLD}QR-код для подключения первого клиента (client-1):${NC}"
            echo "$qr_out"
            echo
        fi
    fi
