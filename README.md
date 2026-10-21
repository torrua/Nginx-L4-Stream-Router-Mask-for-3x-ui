<div align="center">

# Личный VPN на своём сервере
### 3X-UI и Nginx с маскировкой под сайт

Надёжный персональный VPN на VPS, устойчивый к блокировкам операторов связи.  
Работает на смартфонах (iOS, Android), компьютерах (Windows, macOS) и роутерах.

[Инструкция для новичков](docs/BEGINNER_GUIDE.md) • [Техническая архитектура](docs/ARCHITECTURE.md) • [Бэклог задач (РФ)](docs/BACKLOG.md) • [Быстрый старт](#-быстрый-старт-установка-в-1-команду)

[![CI](https://github.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/actions/workflows/ci.yml/badge.svg)](https://github.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/actions/workflows/ci.yml)
[![Версия](https://img.shields.io/badge/версия-v9.0.0-blue)](https://github.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui)
[![ОС](https://img.shields.io/badge/ОС-Ubuntu%20%7C%20Debian-informational)](docs/BEGINNER_GUIDE.md#1-сервер-vps)
[![Лицензия](https://img.shields.io/badge/лицензия-MIT-success)](LICENSE)

</div>

---

## ⚡ Быстрый старт (Установка в 1 команду)

Подключитесь к VPS по SSH под пользователем `root` и запустите единый установщик:

```bash
curl -sSL "https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/install.sh?v=$(date +%s)" | sudo bash
```

> **Нужно продолжить после сбоя или перезагрузки?**  
> Выполните `bash install.sh -r` — мастер автоматически продолжит установку с сохранёнными параметрами с последнего незавершённого шага.

---

## 🗺️ Схема движения трафика (Traffic Flow)

```mermaid
flowchart TD
    subgraph Clients["📱 Клиенты (iOS, Android, Windows, macOS, Linux, Keenetic / OpenWrt)"]
        BrowserUser["🌐 Обычный браузер / Поисковый бот / Сканер Censys"]
        VpnReality["🛡️ VPN: VLESS REALITY (Happ / v2rayNG / v2rayN)"]
        VpnWeb["🔒 VPN: VLESS xHTTP / Wstunnel (Строгие корпоративные сети)"]
        AmneziaClient["⚡ AmneziaWG v3.1 / v2.0 (Мобильные операторы 4G/5G / Keenetic)"]
        NextGenClient["🚀 Next-Gen: Hysteria 2 / TUIC v5 / MASQUE / Shadowsocks 2022 / MTProxy"]
    end

    subgraph Port443["🚪 Единый входной порт: TCP 443 (Nginx Stream L4 Router)"]
        StreamRouter{"Nginx L4 Stream SNI Router\n(Определение домена без расшифровки TLS)"}
    end

    subgraph DedicatedPorts["📡 Выделенные порты протоколов"]
        PortHy2["UDP 443: Hysteria 2 (QUIC Brutal CC)"]
        PortAWG["UDP 8443 (v3.1) / UDP 8444 (v2.0): 3X-UI AmneziaWG"]
        PortAWGStand["UDP 8445: Автономный сервер AmneziaWG (awg-mgr)"]
        PortTUIC["UDP 8448: TUIC v5 (QUIC 0-RTT BBR)"]
        PortMASQUE["UDP 8449: MASQUE (Sing-box HTTP/3 Datagrams)"]
        PortSS["TCP/UDP 8388: Shadowsocks 2022"]
        PortMTP["TCP 8444: Telegram MTProxy (FakeTLS)"]
        PortNaive["TCP 8446: NaïveProxy (Caddy)"]
        PortDNSTT["UDP 53053: DNSTT DoH Tunnel"]
    end

    subgraph Inbounds["⚙️ Внутренние службы и ядро Xray"]
        NginxL7["Nginx L7 Web-Server\n(unix:/dev/shm/nginx-http.sock)"]
        MirrorSite["🎭 Сайт-маскировка (Decoy Mirror)\n/var/www/html"]
        Panel3XUI["🎛️ Защищенная панель 3X-UI\nПорт 10443 (Секретный путь)"]
        SubService["📋 Сервер подписок\nПорт 55443 (JSON / Base64 / Clash)"]
        XrayRealitySteal["🛡️ Xray: VLESS Steal-Oneself\n(Поддомен cdn.* :45443)"]
        XrayRealityClassic["🕶️ Xray: VLESS Classic External\n(Внешние SNI :46443)"]
        XrayXHTTP["🚀 Xray: VLESS xHTTP Stream\n(:50443 через Nginx H2C/gRPC)"]
        AmneziaCore["⚡ AmneziaWG Kernel DKMS (awg0)"]
        SingBox["📦 Sing-box (MASQUE RFC 9484)"]
        ShadowTLS["🍏 ShadowTLS v4 -> SS-2022 :8388 / Apple Decoy"]
        WstunnelServ["🌐 Wstunnel Server :8080"]
        AdGuard["🛡️ AdGuard Home DNS (:3000 / DoH)"]
    end

    subgraph Outbound["🌍 Умная маршрутизация исходящего трафика (Smart Outbound Routing)"]
        DirectOut["⚡ DIRECT (Прямой выход с IP вашего VPS)\nYouTube, Российские сервисы (.ru, Госуслуги, Банки)"]
        WarpOut["🛡️ Cloudflare WARP Outbound (WireGuard MTU 1280)\nGoogle, OpenAI ChatGPT, Claude, Gemini, Cloudflare Turnstile"]
    end

    %% Маршрутизация соединений
    BrowserUser -->|"HTTPS GET / Сканирование IP"| StreamRouter
    VpnReality -->|"SNI: cdn.domain.com"| StreamRouter
    VpnReality -->|"SNI: gateway.icloud.com"| StreamRouter
    VpnWeb -->|"SNI: domain.com (xHTTP/Wstunnel)"| StreamRouter

    StreamRouter -->|"SNI: основной домен"| NginxL7
    StreamRouter -->|"SNI: cdn.* (Свой сайт)"| XrayRealitySteal
    StreamRouter -->|"SNI: внешний сайт"| XrayRealityClassic
    StreamRouter -->|"SNI: Apple gateway.icloud.com"| ShadowTLS

    NginxL7 -->|"Обычный посетитель / Бот"| MirrorSite
    NginxL7 -->|"/secret-panel-path/"| Panel3XUI
    NginxL7 -->|"/secret-sub-path/"| SubService
    NginxL7 -->|"/secret-xhttp-path/"| XrayXHTTP
    NginxL7 -->|"/wstunnel-prefix/"| WstunnelServ

    AmneziaClient --> PortAWG & PortAWGStand
    NextGenClient --> PortHy2 & PortTUIC & PortMASQUE & PortSS & PortMTP & PortNaive & PortDNSTT

    PortAWG --> AmneziaCore
    PortAWGStand --> AmneziaCore
    PortMASQUE --> SingBox
    WstunnelServ --> AmneziaCore
    PortDNSTT --> PortSS

    %% Исходящий трафик
    XrayRealitySteal & XrayRealityClassic & XrayXHTTP & SingBox & PortSS & PortHy2 & PortTUIC -->|"Умная маршрутизация Xray"| DirectOut
    XrayRealitySteal & XrayRealityClassic & XrayXHTTP & SingBox & PortSS & PortHy2 & PortTUIC -->|"AI & Обход капч"| WarpOut
```

---

## 📌 Архитектура устойчивости к цензуре и глубокому анализу трафика (DPI)

Обычные протоколы (WireGuard, OpenVPN) легко вычисляются и блокируются провайдерами по характерным признакам трафика.

В этом проекте защита устроена иначе:

1. **Сервер выглядит как обычный сайт.** Снаружи это сайт компании с настоящим SSL-сертификатом.
2. **Один порт 443 для всего.** И сайт, и VPN работают на стандартном HTTPS-порту `443`. Провайдер видит только обычные зашифрованные веб-сессии.
3. **Nginx распределяет запросы:**
   * Открыли сайт в браузере или пришёл бот-сканер → Nginx показывает веб-сайт.
   * Подключилось приложение с вашим VPN-ключом → Nginx сразу передаёт трафик ядру Xray, и у вас работает интернет.
   * Открыли секретный адрес панели управления → загружается веб-интерфейс 3X-UI.
4. **Защита для мобильных сетей (AmneziaWG 3.1):**
   * Поддержка AmneziaWG 3.1 с обфускацией заголовков (`HeaderProtectionKey`, `RandomTrailers`, DNS CPS-эмуляция `I1`).
   * Встроенные сценарии выдачи в `awg-cli` (`--preset=stealth`, `--preset=fast`, `--preset=base`). Подробнее: [Руководство по клиентам AmneziaWG](docs/AWG_CLIENT_CONFIGURATION_GUIDE.md).
   * Автономный режим (`awg-mgr`): возможность развернуть AmneziaWG как системную службу ядра Linux без Nginx и веб-сервера. Для подключения клиентов достаточно обычной A-записи домена или IP (SSL-сертификаты не требуются).
5. **Входящие подключения нового поколения (Next-Gen Inbounds):**
   * **TUIC v5** (порт `8448/udp`) на базе QUIC 0-RTT с бесшовной миграцией сессий (Connection Migration) при смене сотовых вышек и сетей Wi-Fi.
   * **Shadowsocks 2022** (порт `8388` TCP/UDP, метод `2022-blake3-aes-128-gcm`) с защитой от атак повторного воспроизведения пакетов.
   * **Telegram MTProxy с маскировкой FakeTLS** (порт `8444/tcp`) для прямого подключения в Telegram без сторонних VPN-приложений.
   * **MASQUE (RFC 9484 / RFC 9298 via Sing-box 1.14+)** (порт `8449/udp`): датаграммное проксирование HTTP/3 с нативной поддержкой в iOS 17+ и macOS 14+.
   * **ShadowTLS v4 + Shadowsocks-2022** (`udp_over_tcp: true`, порт `8543/tcp`): подлинный TLS Apple (`gateway.icloud.com`) с защитой от активных зондов ТСПУ.
   * **NaïveProxy + Caddy** (порт `8446/tcp`): сетевой стек Chromium и выпуск SSL через Cloudflare DNS-01 ACME.
   * **Server-Side Zapret** (`nfqws` с `connbytes 1:6`): серверная десинхронизация DPI ТСПУ без снижения скорости.
   * **Wstunnel поверх Dokploy Traefik**: туннелирование WireGuard/AmneziaWG через порт `443` Dokploy без конфликтов с Traefik.
6. **Умный исходящий трафик (Cloudflare WARP Smart Routing):**
   * Запросы к Google, AI-сервисам (ChatGPT, Claude, Gemini) и сайтам с капчей Cloudflare идут через чистый IP Cloudflare WARP (MTU 1280).
   * Видео YouTube и российские сервисы (банки, Госуслуги) идут напрямую с VPS для максимальной скорости и отсутствия блокировок.
7. **Автоматическая проверка занятости портов (Preflight Inspector):**
   * Автоматически проверяет порты (53, 80/443, 3000 и внутренние порты стека) перед установкой.
   * Если порт 3000 уже занят другими сервисами или контейнерами, скрипт автоматически подберёт свободный порт для AdGuard Home из диапазона 3001–3053.
   * Поддерживает режим бесконфликтного сосуществования с Dokploy (`DOKPLOY_COEXISTENCE=y`).
8. **Безопасная настройка UFW, Nginx и защита Anti-Loop:**
   * UFW настраивается без сброса существующих правил (`ufw reset`), полностью сохраняя существующие правила и SSH-доступ администратора.
   * Nginx точечно размещает конфигурации без удаления сторонних сайтов в `sites-enabled/`.
   * Разделение Proxy Protocol: для маскировки под свой сайт (`Steal-Oneself`) запрос перенаправляется на Anti-Loop порт `9443` с `xver: 1`, а для маскировки под внешние сервисы (`Classic External`) Proxy Protocol отключен (`xver: 0`), предотвращая сброс соединения целевым сервером.

---

## 📚 Документация

| Руководство | Описание |
| :--- | :--- |
| 🚀 **[Инструкция для новичков](docs/BEGINNER_GUIDE.md)** | Пошаговый запуск с нуля: аренда VPS и домена, укрепление ОС (`prepare-server.sh`), настройка Nginx (`setup.sh`) и подключение устройств. |
| ⚙️ **[Техническое описание архитектуры](docs/ARCHITECTURE.md)** | Полная инженерная документация: схема Nginx L4 Stream, ручная настройка инбаундов 3X-UI, правила UFW от сканирования, Anti-Loop порт 9443, тюнинг буферов HTTP/2 xHTTP, диагностика (Health Check) и бэкапы. |
| 🛡️ **[Протоколы следующего поколения & Dokploy](docs/NEXTGEN_PROTOCOLS_DOKPLOY.md)** | Развертывание MASQUE, ShadowTLS v4, NaïveProxy, Zapret и Wstunnel через Docker Compose с нулевым конфликтом с Dokploy Traefik на портах 80/443. |
| 🎛️ **[Автонастройка 3X-UI (`configure-panel.sh`)](#-ручная-пошаговая-установка-для-экспертов)** | Скрипт, который сам создаёт подключения в панели, генерирует клиентские ссылки `:443` через `externalProxy`, настраивает Cloudflare WARP, задает часовой пояс, ежемесячный сброс трафика, защиту от SMTP-спама (порт 25) и блокировку SSRF к локальным службам VPS. |
| ✍️ **[Редакционная политика](docs/EDITORIAL_POLICY.md)** | Стандарт коммуникации проекта: Tone of Voice, словарь понятных терминов для новичков, запрет пафоса и псевдомаркетинга. |
| 📝 **[История версий и Release Notes](docs/RELEASE_NOTES_v9.0.0.md)** | Подробные отчеты о релизах: [v9.0.0](docs/RELEASE_NOTES_v9.0.0.md) (Unified Engine, Snapshot Rollback & Offline Autonomy), [v8.2.2](docs/RELEASE_NOTES_v8.2.2.md) (Случайные пути и сохранение действующих настроек), [v8.2.1](docs/RELEASE_NOTES_v8.2.1.md) (Stability & UX Polish), [v8.2.0](docs/RELEASE_NOTES_v8.2.0.md) (Next-Gen & Extreme Stealth Suite), [v8.1.0](docs/RELEASE_NOTES_v8.1.0.md), [v8.0.2](docs/RELEASE_NOTES_v8.0.2.md), [v8.0.1](docs/RELEASE_NOTES_v8.0.1.md), [v8.0.0](docs/RELEASE_NOTES_v8.0.0.md). |

---

## 🚀 Быстрый старт (Установка в 1 команду)

### Скрипты и конфигурация

| Файл | Назначение |
| :--- | :--- |
| [`install.sh`](install.sh) | Основной установщик: запуск Express или пошаговой настройки. |
| [`setup.sh`](setup.sh) | Пошаговая настройка сервера, диагностика и продолжение установки. |
| [`uninstall.sh`](uninstall.sh) | Полное удаление стека и возврат сервера к исходному состоянию из снимка. |
| [`configure-panel.sh`](configure-panel.sh) | Настройка подключений и параметров панели. |
| [`maintain.sh`](maintain.sh) | Проверка, восстановление настроек и откат к резервной копии. |
| [`prepare-server.sh`](prepare-server.sh) | Первичная подготовка ОС, SSH и файрвола. |
| [`manage-services.sh`](manage-services.sh) | Управление дополнительными сервисами через Docker Compose. |
| [`src/awg/manage-clients.sh`](src/awg/manage-clients.sh) | Управление клиентами; реализация — `manage_clients.py` рядом с лаунчером. |
| [`server-setup.env.example`](server-setup.env.example) | Шаблон основного конфига `server-setup.env`. |

Начиная с мажорного релиза v9.0.0, проект использует исключительно каноническую линейку утилит (kebab-case). Ранее сохранённые файлы конфигурации `setup_mask.env` на сервере распознаются автоматически при обновлении; переносить параметры вручную не требуется.

### Подготовка: VPS и домен (DNS-записи)
1. Арендуйте виртуальный сервер (VPS) с **Ubuntu 22.04 / 24.04** или **Debian 11 / 12**.
2. В панели управления DNS создайте **две A-записи** на IP-адрес вашего VPS:
   * `@` (или ваш основной поддомен, например `vpn.domain.com`) → для веб-маскировки, панели и VLESS xHTTP.
   * `cdn` (или поддомен `cdn.domain.com` / `*.domain.com`) → **обязательно** для VLESS REALITY Steal-Oneself (маскировка под свой поддомен).
   *(Если используете Cloudflare: обязательно режим **DNS Only / Серое облако**).*

Подробно: [порядок установки, ошибки и возобновление](docs/INSTALLATION_FLOW.md).

### Бесшовный интерактивный запуск (`install.sh`)
Подключитесь к серверу по SSH под пользователем `root` и запустите единый мастер:

```bash
curl -sSL "https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/install.sh?v=$(date +%s)" | sudo bash
```

> **Что произойдет автоматически:**
> 1. **Интуитивный CLI-интерфейс:** выберите **Express Режим** (всего 2 вопроса: домен и email) или **Expert Режим** (с выбором префикса сервера, логина/пароля панели и детальной настройкой портов).
> 2. **Проверка плана:** параметры и порты проверяются до изменений системы; установка начинается после подтверждения состава и порядка этапов.
> 3. **Укрепление ОС и изоляция:** включается **TCP BBR**, настраивается фаервол UFW, отключается IPv6 (чтобы трафик не уходил мимо VPN).
> 4. **Развертывание стека и автосинхронизация:** выпускаются SSL-сертификаты Let's Encrypt, разворачивается сайт-маскировка, создаются протоколы с префиксом подключений `<Префикс> (<Метод>)` (например: `Server (VLESS Steal-Oneself)`), а клиенты автоматически синхронизируются с вкладкой «Клиенты» в 3X-UI.
> 5. **Итоговый дашборд:** на экран выводятся персональная ссылка на защищенную панель, логин и пароль администратора, статус изоляции портов (данные надёжно сохраняются в `/root/vpn_credentials.txt` и `server-setup.env` с правами 600).

<details>
<summary><b>🔧 Ручная пошаговая установка (для экспертов)</b></summary>

Если вам требуется ручной контроль над каждым шагом и точечный ввод нестандартных параметров:

1. **Защита ОС и установка 3X-UI:**
   ```bash
   curl -sSLO https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/prepare-server.sh && sudo bash prepare-server.sh
   ```
2. **Настройка Nginx, SSL и SNI-маскировки:**
   ```bash
   curl -sSLO https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/setup.sh && sudo bash setup.sh
   ```
3. **Автосоздание входящих подключений (Inbounds):**
   ```bash
   curl -sSL https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/configure-panel.sh | sudo bash
   ```
</details>

---

## 💡 Какой протокол когда использовать

| Протокол | Для чего подходит | Как работает |
| :--- | :--- | :--- |
| **AmneziaWG (v3.1 / v2.0)** | Смартфоны на мобильном интернете (4G/5G) и роутеры Keenetic/OpenWrt | Добавляет случайный шум в заголовки пакетов (Junk) и подбирает размер кадра (MTU 1280), защищая от замедлений и блокировок в сетях сотовых операторов. |
| **VLESS Reality** | Домашний Wi-Fi, компьютеры и ноутбуки | Высокая скорость без дополнительной криптографической нагрузки на процессор, маскировка сессии под стандартное открытие защищенного сайта (TLS 1.3). |
| **VLESS xHTTP** | Сети со строгой фильтрацией (офисы, публичный Wi-Fi) | Работает поверх протокола HTTP/2 с дополнительным шифрованием (`vlessenc`). Трафик передаётся внутри обычных веб-запросов и маскируется под загрузку страниц. |
| **Hysteria 2** | Нестабильные линии с потерями пакетов | Работает по UDP (QUIC/HTTP/3) с протоколом контроля перегрузок BBR для ускорения передачи данных. |
| **TUIC v5** | Мобильные устройства при частой смене сетей (Wi-Fi ↔ сотовая связь) | Высокоскоростной транспорт на базе QUIC с 0-RTT установлением сессий и бесшовной миграцией соединений (Connection Migration) без разрыва связности. |
| **Shadowsocks 2022** | Компьютеры, игры и приложения с чувствительностью к задержкам | Современный стандарт с аутентифицированным шифрованием Blake3-AES-128-GCM и защитой от атак повторного воспроизведения сессий (порт 8388 TCP/UDP). |
| **Telegram MTProxy (FakeTLS)** | Мессенджер Telegram на смартфонах и компьютерах | Подключается прямо внутри Telegram в 1 клик без сторонних VPN-клиентов. Маскирует служебный трафик MTProto под защищенное TLS-соединение с сайтом (порт 8444/tcp). |
| **AdGuard Home DoH** | Защита от рекламы, трекеров и обход блокировок DNS | Шифрованный DNS (DoH) с раздельными маршрутами: запросы к российским сайтам (.ru, банки, Госуслуги) идут через быстрые локальные DNS, а зарубежные — через зашифрованные апстримы. |

---

## 📱 Приложения для устройств

| Устройство | Рекомендуемые программы | Как настроить |
| :--- | :--- | :--- |
| **iPhone / iPad** | **Happ Proxy** (VLESS, TUIC v5, SS-2022, Hysteria 2), **FoXray**, **Streisand**, **Telegram** | Открыть приложение → отсканировать QR-код из панели 3X-UI (или нажать ссылку `tg://proxy` для Telegram) |
| **Android** | **v2rayNG**, **Happ Proxy**, **NekoBox**, **Telegram** | Скопировать ссылку `vless://` / `tuic://` / `ss://` → импортировать из буфера или по QR |
| **Windows** | **v2rayN**, **Happ**, **Flclash**, **Telegram Desktop** | Скопировать ссылку → нажать `Ctrl + V` → включить системный прокси |
| **macOS** | **FoXray**, **V2RayXS**, **Karing**, **Telegram** | Добавить подключение по ссылке или QR-коду |
| **Роутеры Keenetic** | Встроенный клиент WireGuard / AmneziaWG, Shadowsocks | Скачать `.conf` файл AmneziaWG в панели и загрузить в меню роутера |

---

## 🛠️ Автоматизация, отказоустойчивость и CLI для сисадминов

Скрипт `setup.sh` оснащён встроенной системой надёжности и автоматизации:

### 🩺 Экспресс-диагностика (`--check` / `--doctor`)
Быстрая проверка состояния сервера за 2 секунды:
* Статус и целостность Nginx, 3X-UI, Xray, AdGuard Home
* Доступность портов (TCP 443, 80, 9443, входящих подключений; UDP 443, 8443)
* Срок действия SSL-сертификатов
* Аудит маскировки Censys (проверка скрытности при сканировании по IP: сброс TLS Handshake)

### 🛡️ Автоматический повтор при сбоях (Smart Retry)
Все ключевые операции (установка пакетов, BBR, выпуск SSL, запуск Nginx, ядро 3X-UI) защищены перехватом ошибок в реальном времени:
* При сбое операция не прерывает скрипт аварийно: выводится полный лог ошибки и интерактивное меню:
  * **`[1] Повторить попытку (Retry)`** *(по умолчанию)* — исправьте причину (например, DNS A-запись или открытый порт) и продолжите без перезапуска.
  * **`[2] Прервать установку (Abort)`** — безопасный выход с сохранением состояния.

### 📍 Система контрольных точек и возобновления
* Скрипт сохраняет имена завершённых этапов и подписи параметров в файле `<конфиг>.state`; перед пропуском проверяется фактический результат. При повторном запуске после сбоя или обрыва связи предлагается выбор:
  * `[1] Продолжить установку с шага N` (Enter — опросник пропускается, настройки берутся из сохранённого `.env`)
  * `[2] Начать заново (с шага 1)`
* При штатном завершении отметка незавершённой установки сбрасывается; итоговая проверка сервисов выполняется при каждом запуске.

### ⏱️ Хронометраж этапов и экспресс-проверка служб
В финале скрипта запускается автоматическая экспресс-проверка всех служб и выводится детальный хронометраж каждого из этапов установки.

### Ключи командной строки:
```bash
# Интерактивный запуск с мастером настройки (b — назад, экран проверки)
sudo ./setup.sh

# Экспресс-диагностика всех сервисов, портов и SSL за 2 секунды
sudo ./setup.sh --check

# Выбор компонентов установки (только веб-стек или только AmneziaWG)
sudo ./setup.sh --web-stack
sudo ./setup.sh --awg-standalone
sudo ./setup.sh --awg-host vpn.domain.com

# Экспертный режим (компактный мастер без подробных подсказок к протоколам)
sudo ./setup.sh --expert

# Возобновление прерванной установки с последнего шага
sudo ./setup.sh --resume

# Принудительный старт с указанного шага (1-12) в неинтерактивном режиме
sudo ./setup.sh --step 4 -y

# Режим отладки (вывод всех команд в консоль без спиннеров)
sudo ./setup.sh --debug

# Полное удаление и возврат сервера к исходному состоянию (по снимку)
sudo ./uninstall.sh
# или через флаг установщика:
sudo ./setup.sh --uninstall

# Развёртывание через файл конфигурации (.env) / CI / Ansible
sudo ./setup.sh -c server-setup.env -y --force
```

---

## 🛠️ Разработка и модульная архитектура (`src/`)

Начиная с версии v7.5.0, все скрипты проекта декомпозированы на независимые модули в каталоге `src/` (подсистемы `common/`, `tui/`, `system/`, `nginx/`, `ssl/`, `adguard/`, `xray/`, `installer/`, `entrypoints/`).

Для сохранения удобства установки в 1 команду (`curl -sSL ... | sudo bash`) дистрибутивные файлы в корне собираются автоматически через `scripts/build.py`:

```bash
# Сборка всех дистрибутивных скриптов из исходников src/
python scripts/build.py

# Проверка синхронизации (контроль дрифта) и синтаксиса bash/python
python scripts/build.py --check --lint

# Единое обновление версии проекта во всех скриптах и документации (SSOT)
python scripts/build.py --bump 8.0.0

# Запуск тестов сборщика
python tests/test_builder.py
```

В GitHub Actions CI настроен строгий контроль дрифта: попытка изменить только собранные файлы в корне или только модули в `src/` без сборки автоматически блокируется.

---

## 📄 Лицензия
Проект распространяется под свободной лицензией **MIT**.
