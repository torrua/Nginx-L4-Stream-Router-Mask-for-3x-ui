# Wstunnel over Dokploy Traefik (WebSocket / HTTP/3)

**Wstunnel** позволяет упаковывать произвольный TCP/UDP-трафик (WireGuard, AmneziaWG, Shadowsocks, SSH) в защищенные WebSocket- или HTTP/3-сессии.

### Бесшовная интеграция с Dokploy
- Dokploy использует **Traefik** в качестве единого reverse-proxy на портах `80` и `443`.
- Контейнер `wstunnel-dokploy` подключается к общей сети Dokploy (`dokploy-network`).
- Traefik автоматически обнаруживает контейнер по меткам (Docker labels):
  - Выполняет TLS-терминацию с действующим сертификатом Let's Encrypt Dokploy.
  - Поддерживает протокол WebSocket Upgrade.
  - Проксирует соединения на внутренний порт контейнера `8080`.
- **Никаких конфликтов портов**: Dokploy продолжает обслуживать все ваши веб-сайты и базы данных на портах 80 и 443!

### Запуск через Docker Compose
```bash
docker compose -f ../docker-compose.dokploy.yml up -d wstunnel-dokploy
```

### Подключение клиента
```bash
wstunnel client -L udp://127.0.0.1:51820:127.0.0.1:51820 wss://wstunnel.yourdomain.online
```
Клиентский WireGuard / AmneziaWG подключается к `127.0.0.1:51820`, а весь UDP-трафик прозрачно идет через Traefik HTTPS WebSocket!
