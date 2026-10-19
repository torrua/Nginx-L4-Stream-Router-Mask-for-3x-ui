# NaïveProxy with Caddy (forwardproxy@naive + Cloudflare DNS-01 ACME)

**NaïveProxy** использует сетевой стек Chromium для маскировки туннельного трафика под легитимный серфинг Google Chrome.

### Архитектурные особенности
1. **Неразличимость от Chrome**: Хэндшейки TLS, поведение TCP, заголовки HTTP/2 и HTTP/3 генерируются кодом браузера Chromium.
2. **Защита Probe Resistance**: Сканеры портов без базовой аутентификации получают обычный статический сайт или 404, не обнаруживая наличие прокси.
3. **Cloudflare DNS-01 ACME**: Выпуск доверенных SSL-сертификатов Let's Encrypt выполняется через Cloudflare DNS API (TXT-записи), **без необходимости слушать порты 80 и 443**.
4. **Совместимость с Dokploy**: Порт `8446` не конфликтует с Traefik на 80/443.

### Запуск
```bash
docker compose -f ../docker-compose.nextgen.yml up -d naiveproxy-caddy
```
