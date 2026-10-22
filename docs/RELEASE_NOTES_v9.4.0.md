# Релиз v9.4.0 — Пул SNI, клиентская авторотация в 3X-UI и настраиваемый uTLS Fingerprint

**Дата релиза:** 22 октября 2026  
**Версия:** v9.4.0

В версии v9.4.0 реализована полноценная поддержка задания пула маскировочных доменов (SNI) для протокола VLESS Classic REALITY, нативная клиентская авторотация через подписки 3X-UI с флагом `shuffle_host`, а также возможность гибкой настройки браузерного профиля TLS (uTLS Fingerprint: Chrome, Firefox, Safari, iOS, Android, Edge, Randomized).

---

## 1. Пул SNI для VLESS Classic REALITY (`CLASSIC_SNI`)

* **Поддержка множественных адресов в конфигурации:**
  Переменная `CLASSIC_SNI` теперь принимает как одиночный домен, так и список адресов через пробел или запятую (например, `CLASSIC_SNI="dl.google.com www.google.com"` или поддомены Microsoft, делящие общий TLS-сертификат: `www.microsoft.com wwwqa.microsoft.com staticview.microsoft.com`).
* **Нормализация и дедупликация:**
  Входная строка очищается от пробельных символов, переводится в нижний регистр, валидируется по FQDN-формату и дедуплицируется как на уровне Bash (`src/system/env.sh`, `src/tui/wizard.sh`), так и на уровне Python-реконсиляции (`src/panel/reconcile.py`).
* **Сквозная маршрутизация Nginx Stream L4:**
  Nginx Stream Router (`src/nginx/config.sh`) автоматически формирует правила в `00-stream.conf` для каждого домена из пула, направляя входящий TLS ClientHello трафик на локальный порт инбаунда REALITY (`46443`).
* **Многоузловой externalProxy:**
  Для каждого домена из пула генерируется индивидуальная запись в массиве `externalProxy` со своими ремарками `VLESS Classic (<sni>)`, гарантируя корректное формирование ссылок подключения и экспорта конфигураций.

---

## 2. Нативная клиентская авторотация через подписки 3X-UI (`shuffle_host`)

* **Интеграция с таблицей `hosts` базы данных 3X-UI:**
  В базе данных `/etc/x-ui/x-ui.db` при согласовании удаляются устаревшие хосты инбаунда и создаются отдельные записи под каждый SNI из пула с выставлением флага `shuffle_host = 1`.
* **Поддержка схем именования колонок:**
  Логика согласования корректно работает как со стандартной схемой `snake_case` (`inbound_id`, `sort_order`, `shuffle_host`), так и с версиями 3X-UI, использующими `camelCase` (`inboundId`, `sortOrder`, `shuffleHost`).
* **Бесперебойная работа клиентов без перезапуска сервера:**
  При запросе подписки панель 3X-UI автоматически рандомизирует порядок профилей. Клиентские приложения (Hiddify, Clash / Mihomo, Sing-box, v2rayN) получают все узлы и самостоятельно выполняют балансировку трафика (`load-balance` / round-robin) или автоматический fallback (`url-test`), если один из SNI блокируется ТСПУ.

---

## 3. Настраиваемый uTLS Fingerprint (`REALITY_FINGERPRINT`)

* **Параметр маскировки браузера:**
  Добавлена переменная окружения `REALITY_FINGERPRINT` (по умолчанию `firefox`).
* **Поддерживаемые профили uTLS:**
  `chrome`, `firefox`, `safari`, `ios`, `android`, `edge`, `360`, `qq`, `random`, `randomized`.
* **Интеграция в интерактивный TUI-визард (`prompt_select`):**
  Внедрен новый универсальный TUI-компонент одиночного выбора `prompt_select`: интерактивная навигация стрелками `↑` / `↓` (`j` / `k`), подтверждение выбора по `Enter` или `Пробелу`, мгновенный выбор цифровыми клавишами `1`..`7`, а также автоматический фоллбек на нумерованный ввод при отсутствии интерактивного TTY или по нажатию `?`. В [src/tui/wizard.sh](file:///c:/Users/User/Dropbox/Python/PRIZI/gemini-discussions/how-to-setup-awg-on-dokploy/src/tui/wizard.sh) в экспертном режиме выбора портов выбор профиля Fingerprint переведен на `prompt_select`.
* **Автоматическое применение и реконсиляция:**
  Fingerprint прокидывается в `realitySettings.settings.fingerprint`, во все узлы `externalProxy` инбаундов REALITY и xHTTP, а также в колонку `fingerprint` таблицы `hosts`. Модуль `smart_reconcile_inbound` автоматически обнаруживает изменение fingerprint в конфигурации и обновляет существующую базу данных без ручных правок.

---

## 4. Обновление Smart Reconcile и защита от регрессий

* **Обнаружение обновления пула в `src/xray/inbounds.py`:**
  В `smart_reconcile_inbound` добавлена проверка изменения `serverNames` и `fingerprint`. Теперь при вызове `maintain.sh` или `configure-panel.sh` обновленный пул доменов из `.env` не затирается старыми одиночными значениями из БД, а аккуратно применяется к инбаунду и его узлам `externalProxy`.
* **Автоматические тесты:**
  - `test_classic_sni_pool_parsing_and_deduplication_in_bash` — проверка разбиения строки, нормализации регистра и дедупликации в Bash.
  - `test_reconcile_hosts_table_multiple_snis_and_shuffle_host` — проверка удаления старых хостов, вставки пула и выставления `shuffle_host=1` для обеих SQLite-схем.
  - `test_reality_fingerprint_parameter_and_reconciliation` — валидация передачи и реконсиляции профилей uTLS.
  - 100% прохождение сьюта из 280 тестов `pytest`.
