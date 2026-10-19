# MASQUE Inbound (RFC 9484 / RFC 9298 via Sing-box 1.14+)

Протокол **MASQUE** (Multiplexed Application Substrate over QUIC Encryption) обеспечивает высокоскоростное проксирование UDP и IP-датаграмм поверх стандартизированного протокола HTTP/3 (QUIC Datagrams).

### Стандарты IETF
- **RFC 9298**: Proxying UDP in HTTP (`CONNECT-UDP`)
- **RFC 9484**: Proxying IP in HTTP (`CONNECT-IP`)

### Преимущества
1. **0-RTT и HTTP/3**: Минимальные задержки при установлении соединений.
2. **Сверхвысокая устойчивость**: Трафик неотличим от стандартных защищенных сессий HTTP/3 (UDP 443/8445).
3. **Нативная поддержка Apple**: Начиная с iOS 17 и macOS 14, Apple поддерживает MASQUE нативно через системный фреймворк `Network.framework`.
4. **Бесконфликтность с Dokploy**: Работает на порту `8445/udp`, не конфликтуя с Traefik на портах 80/443.

### Быстрый запуск
```bash
docker compose -f ../docker-compose.nextgen.yml up -d sing-box-masque
```
