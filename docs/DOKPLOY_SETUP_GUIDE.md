# 🚀 Руководство по настройке VPN и AmneziaWG на сервере с Dokploy

[← Назад к главному README](../README.md) | [⚙️ Архитектура системы](ARCHITECTURE.md) | [🚀 Протоколы следующего поколения & Dokploy](NEXTGEN_PROTOCOLS_DOKPLOY.md)

---

> **Полное практическое руководство:**  
> Как развернуть персональный VPN-сервер (**AmneziaWG**, **3X-UI**, **Wstunnel**, **VLESS xHTTP**, **MASQUE**) на одном VPS с платформой **Dokploy**, сохранив удобство развертывания веб-приложений и баз данных без конфликтов портов 80 и 443.

---

## 📋 Содержание

1. [Введение: как Dokploy сосуществует с VPN](#1-введение-как-dokploy-сосуществует-с-vpn)
2. [Выбор варианта установки (Сравнение)](#2-выбор-варианта-установки)
3. [Шаг 0: Настройка DNS-записей домена](#3-шаг-0-настройка-dns-записей-домена)
4. [Вариант А: Гибридный режим (Рекомендуемый для максимальной скорости)](#4-вариант-а-гибридный-режим-рекомендуемый)
5. [Вариант Б: All-in-One Compose (100% через веб-панель Dokploy)](#5-вариант-б-all-in-one-compose-100-через-веб-панель-dokploy)
6. [Настройка клиентских устройств](#6-настройка-клиентских-устройств)
7. [Диагностика и решение проблем (FAQ)](#7-диагностика-и-решение-проблем-faq)

---

## 1. Введение: как Dokploy сосуществует с VPN

**Dokploy** — это современная PaaS-панель (аналог Coolify/Heroku) для управления контейнерами Docker. В качестве обратного прокси Dokploy использует **Traefik**, который монопольно занимает порты **`80/TCP`** и **`443/TCP`**.

Наш стек решает проблему конкуренции за порты следующим образом:
* **Traefik (Dokploy)** остаётся единственным хозяином портов 80 и 443 для всех сайтов, API и баз данных.
* **AmneziaWG (AWG)** работает по собственному протоколу на **UDP-порту 8443** (или 51820). Traefik вообще не использует эти UDP-порты, поэтому AWG работает на полной скорости ядра Linux.
* **Панель 3X-UI и сервер подписок** работают локально на портах `10443` и `55443`, а Traefik проксирует к ним безопасные домены (`panel.yourdomain.online`, `sub.yourdomain.online`) с автоматическими SSL-сертификатами Let's Encrypt.
* **Wstunnel** позволяет пропускать трафик AmneziaWG и WireGuard через стандартный HTTPS-порт `443` через WebSocket, если оператор связи глушит UDP.

```mermaid
flowchart TD
    subgraph Internet["Входящий трафик из интернета"]
        TrafficWeb["🔒 HTTPS (Порт 443/TCP)"]
        TrafficAWG["⚡ AmneziaWG (Порт 8443/UDP)"]
        TrafficNextGen["🚀 MASQUE / Hy2 (UDP 8449 / 8443)"]
    end

    subgraph DokployHost["Сервер с Dokploy"]
        Traefik["Dokploy Traefik (:80/:443 TCP)\nАвто-SSL Let's Encrypt"]
        KernelAWG["Ядро Linux DKMS: AmneziaWG (:8443 UDP)"]
        DirectServices["MASQUE :8449 / ShadowTLS :8543"]

        subgraph ProxiedByTraefik["Сервисы за Traefik"]
            Panel["🎛️ 3X-UI Панель (:10443)"]
            Sub["📋 Сервер подписок (:55443)"]
            Wst["🌐 Wstunnel (:8080)"]
            DokApps["🐳 Ваши сайты и приложения в Dokploy"]
        end
    end

    TrafficWeb --> Traefik
    TrafficAWG --> KernelAWG
    TrafficNextGen --> DirectServices

    Traefik -->|Host: panel.domain| Panel
    Traefik -->|Host: sub.domain| Sub
    Traefik -->|Host: wstunnel.domain| Wst
    Traefik -->|Другие домены| DokApps

    Wst -.->|Резервный туннель через 443| KernelAWG
```

---

## 2. Выбор варианта установки

| Критерий | Вариант А: Гибридный (Хост + Traefik) | Вариант Б: All-in-One (100% Dokploy UI) |
| :--- | :--- | :--- |
| **Кому подходит** | Тем, кому нужна максимальная скорость и пинг | Тем, кто хочет развернуть всё из браузера без SSH |
| **Установка** | 1 команда в терминале SSH | Вставка YAML в разделе Compose панели Dokploy |
| **Драйвер AmneziaWG** | Ядерный модуль ядра Linux (**DKMS**) | Контейнерный драйвер (`/dev/net/tun`) |
| **Скорость AmneziaWG** | **Wire Speed** (до 1–2.5 Гбит/с, 0% CPU overhead) | До 300–600 Мбит/с (небольшой оверхед userspace) |
| **BBR и conntrack** | Настраиваются в ядре хоста автоматически | Настраиваются вручную на хосте (при желании) |
| **Обновление** | Через `./maintain.sh` | В 1 клик через веб-интерфейс Dokploy |

---

## 3. Шаг 0: Настройка DNS-записей домена

Перед началом настройки создайте у вашего DNS-провайдера (Cloudflare, Reg.ru, Beget и т.д.) A-записи, указывающие на IP-адрес вашего VPS.

### Реестр поддоменов по функциональным группам:

#### 1. Основные сервисы Dokploy и управления
| Поддомен | Пример записи | Порт / Маршрут | Назначение |
| :--- | :--- | :---: | :--- |
| **`@`** *(корень)* | `yourdomain.online` ➜ `IP_ВАШЕГО_VPS` | `80/443` | Основной сайт-маскировка или ваши веб-приложения в Dokploy. |
| **`www`** | `www.yourdomain.online` ➜ `IP_ВАШЕГО_VPS` | `80/443` | Алиас основного сайта для корректного выпуска SSL. |
| **`panel`** | `panel.yourdomain.online` ➜ `IP_ВАШЕГО_VPS` | `10443` ➜ Traefik | Веб-интерфейс панели управления 3X-UI с валидным Let's Encrypt SSL. |
| **`sub`** | `sub.yourdomain.online` ➜ `IP_ВАШЕГО_VPS` | `55443` ➜ Traefik | Сервер подписок (ссылки для v2rayN, Happ, Clash, Sing-box). |

#### 2. Туннели и прокси через Traefik (порт 443)
| Поддомен | Пример записи | Порт / Маршрут | Назначение |
| :--- | :--- | :---: | :--- |
| **`vless`** | `vless.yourdomain.online` ➜ `IP_ВАШЕГО_VPS` | `50443` ➜ Traefik | VLESS xHTTP / gRPC поток через Dokploy Traefik без конфликта портов. |

#### 3. REALITY Маскировка (Steal-Oneself / Fallback)
| Поддомен | Пример записи | Порт / Маршрут | Назначение |
| :--- | :--- | :---: | :--- |
| **`cdn`** | `cdn.yourdomain.online` ➜ `IP_ВАШЕГО_VPS` | `45443` | Основной SNI-камуфляж для режима REALITY Steal-Oneself. |
| **`static`** | `static.yourdomain.online` ➜ `IP_ВАШЕГО_VPS` | `47443` | Резервный SNI-камуфляж для статических ресурсов REALITY. |

#### 4. Специализированные протоколы следующего поколения (Next-Gen Protocols)
| Поддомен | Пример записи | Порт / Транспорт | Назначение |
| :--- | :--- | :---: | :--- |
| **`wstunnel`** | `wstunnel.yourdomain.online` ➜ `IP_ВАШЕГО_VPS` | `443` (WS) ➜ `8080` | **Wstunnel:** туннелирование AmneziaWG / WireGuard UDP внутри WebSocket over TLS 443 для обхода жестких блокировок UDP мобильными операторами. |
| **`naive`** | `naive.yourdomain.online` ➜ `IP_ВАШЕГО_VPS` | `8446` (TCP/UDP) | **NaïveProxy (Caddy):** маскировка сетевого стека под Google Chrome с защитой `probe_resistance`. |
| **`dns`** | `dns.yourdomain.online` ➜ `IP_ВАШЕГО_VPS` | `3000/10053` | **AdGuard Home DoH:** шифрованный DNS-over-HTTPS (при выборе Режима 2 в мастере). |
| **`t`** | `t.yourdomain.online` ➜ `IP_ВАШЕГО_VPS` | `53053` (DoH/UDP) | **DNSTT Tunnel:** инкапсуляция трафика внутри DNS-запросов (пробивает глубокие белые списки). |

> [!TIP]
> **Как настроить все поддомены за 30 секунд:**  
> Создайте всего **две записи** у вашего DNS-провайдера:
> 1. `@` ➜ `IP_ВАШЕГО_VPS` (для корня)
> 2. `*` ➜ `IP_ВАШЕГО_VPS` (Wildcard-запись — автоматически покроет `panel`, `sub`, `wstunnel`, `vless`, `cdn`, `static`, `naive`, `dns`, `t` и любые будущие сайты в Dokploy!).
>
> В Cloudflare обязательно выключите оранжевое облако (режим **DNS Only**) для записей, чтобы Traefik мог напрямую подтвердить владение доменом и выпустить SSL-сертификаты Let's Encrypt через HTTP-01 challenge.

---

## 4. Вариант А: Гибридный режим (Рекомендуемый)

Этот метод гарантирует максимальную производительность AmneziaWG и алгоритма BBR.

### Шаг 1. Запуск установки на хосте

Подключитесь к VPS по SSH под пользователем `root` и запустите установку:

```bash
curl -sSL "https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/setup.sh?v=$(date +%s)" | sudo bash -s -- --dokploy
```

* Установщик автоматически обнаружит Dokploy, применит системные оптимизации ядра (BBR, conntrack), установит DKMS-модуль ядра AmneziaWG и панель 3X-UI на изолированный порт `10443`.
* Порты `80` и `443` **не будут затронуты** — они останутся за Dokploy Traefik.

### Шаг 2. Подключение панели к Dokploy Traefik

После завершения работы установщика сгенерируйте динамическую конфигурацию для Traefik:

```bash
cd /root/vpn-setup 2>/dev/null || cd /root
./manage-services.sh dokploy-traefik > /etc/dokploy/traefik/dynamic/vpn.yml
```

> [!NOTE]
> Traefik в Dokploy отслеживает папку `/etc/dokploy/traefik/dynamic/` и применяет конфигурацию **мгновенно без перезагрузки**.
> Теперь по адресам `https://panel.yourdomain.online` и `https://sub.yourdomain.online` откроются панель 3X-UI и сервер подписок с валидным SSL!

### Шаг 3. (Опционально) Запуск Wstunnel и вспомогательных протоколов

Чтобы развернуть Wstunnel, MASQUE и ShadowTLS в Dokploy:

1. Откройте веб-панель **Dokploy** (`https://IP-СЕРВЕРА:3000`).
2. Перейдите в **Compose** ➜ **Create Compose** (назовите проект, например, `vpn-nextgen`).
3. Скопируйте содержимое файла [`compose/docker-compose.dokploy.yml`](../compose/docker-compose.dokploy.yml) или выполните на сервере `./manage-services.sh dokploy-export` и вставьте результат.
4. В разделе **Environment Variables** укажите:
   ```env
   PRIMARY_DOMAIN=yourdomain.online
   WSTUNNEL_DOMAIN=wstunnel.yourdomain.online
   ```
5. Нажмите **Deploy**.

---

## 5. Вариант Б: All-in-One Compose (100% через веб-панель Dokploy)

Этот метод не требует работы в консоли SSH — всё настраивается через браузер.

### Шаг 1. Создание Compose проекта в Dokploy

1. Откройте панель **Dokploy** (`https://IP-СЕРВЕРА:3000`).
2. В левом меню выберите ваш проект или нажмите **Create Project**.
3. Нажмите **Create Service** ➜ выберите **Compose**.
4. Введите имя сервиса, например: `vpn-all-in-one`.

### Шаг 2. Конфигурация Docker Compose

В редактор Compose вставьте содержимое файла [`compose/docker-compose.dokploy-all-in-one.yml`](../compose/docker-compose.dokploy-all-in-one.yml):

```yaml
services:
  x-ui:
    image: ghcr.io/mhsanaei/3x-ui:latest
    container_name: 3x-ui-dokploy
    restart: unless-stopped
    volumes:
      - xui_data:/etc/x-ui
      - /lib/modules:/lib/modules:ro
    ports:
      - "${AWG_PORT:-8443}:${AWG_PORT:-8443}/udp"
      - "${TUIC_PORT:-8448}:${TUIC_PORT:-8448}/udp"
      - "${SS2022_PORT:-8388}:${SS2022_PORT:-8388}/tcp"
      - "${SS2022_PORT:-8388}:${SS2022_PORT:-8388}/udp"
      - "${MTPROTO_PORT:-8444}:${MTPROTO_PORT:-8444}/tcp"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    devices:
      - /dev/net/tun:/dev/net/tun
    sysctls:
      - net.ipv4.ip_forward=1
    environment:
      - XRAY_VMESS_AEAD_FORCED=false
    networks:
      - dokploy-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.xui-panel.rule=Host(`${PANEL_DOMAIN}`)"
      - "traefik.http.routers.xui-panel.entrypoints=websecure"
      - "traefik.http.routers.xui-panel.tls=true"
      - "traefik.http.routers.xui-panel.tls.certresolver=letsencrypt"
      - "traefik.http.services.xui-panel.loadbalancer.server.port=2053"
      - "traefik.http.routers.xui-sub.rule=Host(`${SUB_DOMAIN}`)"
      - "traefik.http.routers.xui-sub.entrypoints=websecure"
      - "traefik.http.routers.xui-sub.tls=true"
      - "traefik.http.routers.xui-sub.tls.certresolver=letsencrypt"
      - "traefik.http.services.xui-sub.loadbalancer.server.port=2096"

  wstunnel-dokploy:
    image: ghcr.io/erebe/wstunnel:latest
    container_name: wstunnel-dokploy
    restart: unless-stopped
    entrypoint: ["/usr/bin/dumb-init", "--", "/home/app/wstunnel"]
    command:
      - "server"
      - "--restrict-to=3x-ui-dokploy:8443,3x-ui-dokploy:51820,3x-ui-dokploy:8388,host.docker.internal:51820"
      - "ws://0.0.0.0:8080"
    networks:
      - dokploy-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.wstunnel.rule=Host(`${WSTUNNEL_DOMAIN}`)"
      - "traefik.http.routers.wstunnel.entrypoints=websecure"
      - "traefik.http.routers.wstunnel.tls=true"
      - "traefik.http.routers.wstunnel.tls.certresolver=letsencrypt"
      - "traefik.http.services.wstunnel.loadbalancer.server.port=8080"

volumes:
  xui_data:

networks:
  dokploy-network:
    external: true
```

### Шаг 3. Переменные окружения (Environment)

Перейдите во вкладку **Environment** сервиса и добавьте переменные:

```env
PANEL_DOMAIN=panel.yourdomain.online
SUB_DOMAIN=sub.yourdomain.online
WSTUNNEL_DOMAIN=wstunnel.yourdomain.online
AWG_PORT=8443
TUIC_PORT=8448
SS2022_PORT=8388
MTPROTO_PORT=8444
```

### Шаг 4. Развертывание

Нажмите кнопку **Deploy**. Dokploy подтянет образы, запустит контейнеры и автоматически настроит Traefik.  
Через 1–2 минуты откройте браузер: `https://panel.yourdomain.online`.

> **Данные для первого входа в 3X-UI по умолчанию:**  
> Логин: `admin`  
> Пароль: `admin`  
> *(Сразу после первого входа перейдите в «Настройки панели» и смените логин и пароль!)*

---

## 6. Автоматическая настройка маршрутизации и подключение клиентов

> [!IMPORTANT]
> **Вам НЕ нужно создавать инбаунды и прописывать правила маршрутизации вручную!**  
> При установке скрипт `configure-panel.sh` и движок `reconcile.py` делают это **на 100% автоматически**:
> 1. Создают инбаунд **AmneziaWG 3.1** (`8443/udp`) со всеми параметрами обфускации (`Jc=2`, `S1=16..S4=16`), защитой `HeaderProtectionKey` и `MTU 1280`.
> 2. Создают инбаунды **AmneziaWG 2.0**, **VLESS xHTTP**, **Hysteria 2**, **TUIC v5** и **Shadowsocks-2022**.
> 3. Настраивают **Умную маршрутизацию (Smart Outbound Routing)** в ядре Xray:
>    * Российские сервисы (`.ru`, Госуслуги, банки, VK, Яндекс) ➜ **DIRECT** (выход с IP сервера, без блокировок и капч).
>    * Видеосерверы YouTube ➜ **DIRECT** (максимальная скорость без буферизации).
>    * Заблокированные AI-сервисы (ChatGPT, Claude, Gemini) ➜ **Cloudflare WARP** (автоматический обход геоблока).
>    * Защита от спама (блокировка 25 порта) и защита от SSRF-атак на локальные службы хоста.
> 4. Создают единый клиентский профиль `Client` с персональной ссылкой подписки и QR-кодами.

### 1. Подключение AmneziaWG (Напрямую через UDP)
* В терминале сервера сразу после установки отображается готовый **ASCII QR-код** первого клиента.
* Также QR-код и файлы `.conf` / `vpn://` можно вывести в любой момент командой:
  ```bash
  awg-mgr qr client-1
  ```
* Отсканируйте QR-код в приложении **AmneziaWG** на смартфоне или импортируйте файл в клиент для Windows/macOS/Keenetic. Подключение произойдет на полной скорости ядра Linux.

### 2. Подключение AmneziaWG через Wstunnel (Обход блокировок UDP через порт 443)
Если сотовый оператор глушит UDP-трафик:
1. Запустите wstunnel на клиенте или роутере (Keenetic, OpenWrt, Windows, macOS):
   ```bash
   wstunnel client -L udp://127.0.0.1:51820:host.docker.internal:8443 wss://wstunnel.yourdomain.online
   ```
2. В файле конфигурации AmneziaWG укажите:
   ```ini
   [Peer]
   Endpoint = 127.0.0.1:51820
   ```
3. Весь трафик пойдет через стандартный порт `443` Dokploy Traefik под видом легитимного веб-трафика!

### 3. Подключение через сервер подписок
1. Откройте панель 3X-UI (`https://panel.yourdomain.online`) и скопируйте персональную ссылку подписки.
2. Ссылка имеет вид: `https://sub.yourdomain.online/sub-xxxx/xxxx`.
3. Вставьте ссылку в любое приложение: **v2rayN** (Windows), **Happ Proxy** (iOS/Android), **v2rayNG** (Android), **FoXray** (macOS/iOS) или **Clash/Mihomo**.
4. Все доступные протоколы (VLESS xHTTP, Hysteria 2, TUIC, Shadowsocks, MASQUE) загрузятся и будут автоматически обновляться.

---

## 7. Диагностика и решение проблем (FAQ)

### ❓ Что делать при ошибке 404 / 502 Bad Gateway в Traefik?
1. Убедитесь, что DNS A-записи доменов указывают прямо на IP вашего сервера (без Cloudflare Proxy).
2. Проверьте логи Traefik:
   ```bash
   docker logs dokploy-traefik --tail 50
   ```
3. Для Варианта А (Гибридного): убедитесь, что в файле `/etc/dokploy/traefik/dynamic/vpn.yml` в поле `servers.url` указан адрес `http://host.docker.internal:10443`.
4. Для Варианта Б (All-in-One): убедитесь, что контейнер `3x-ui-dokploy` находится в сети `dokploy-network`.

### ❓ Конфликтует ли порт 3000 (Dokploy vs AdGuard Home)?
* Панель Dokploy по умолчанию работает на порту `3000`.
* Наш установщик автоматически проверяет занятость порта `3000`. Если порт занят Dokploy, веб-интерфейс AdGuard Home автоматически переносится на свободный порт из диапазона `3001..3053`, исключая любые сбои.

### ❓ Нужно ли открывать порты в файрволе облачного провайдера?
Да, в панели управления вашего облачного провайдера (Hetzner Firewall, Selectel, Beget, VK Cloud) должны быть открыты:
* **`80/TCP`** и **`443/TCP`** — для Dokploy Traefik и выпуска SSL.
* **`8443/UDP`** (или ваш порт) — для AmneziaWG.
* **`8448/UDP`** — для TUIC v5 (если используется).
* **`8449/UDP`** — для MASQUE (если используется).
* **`8388/TCP,UDP`** — для Shadowsocks 2022 (если используется).
