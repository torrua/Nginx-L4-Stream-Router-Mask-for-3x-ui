# Модульная архитектура и сборщик монолитных скриптов (Вариант А)

> **Goal:** Разбить монолитные скрипты (`setup_mask.sh` ~6200 строк, `configure_3xui.sh` ~2300 строк, `update_repair.sh` ~1300 строк, `install.sh` ~820 строк) на переиспользуемые модули в каталоге `src/` с автоматической компиляцией в корень репозитория через сборщик `scripts/build.py` и верификацией в GitHub Actions.

**Architecture:** 
- Исходный код разделяется на предметные модули (`src/common/`, `src/system/`, `src/nginx/`, `src/ssl/`, `src/adguard/`, `src/xray/`, `src/tui/`, `src/entrypoints/`).
- Сборщик `scripts/build.py` разрешает директивы `# @include "<relative_path>"` и генерирует единые самодостаточные дистрибутивные скрипты в корень проекта, сохраняя 100% совместимость с `curl -sSL ... | sudo bash`.
- Устраняется дублирование логики между `configure_3xui.sh` и `update_repair.sh` через единый модульный пул ядра Xray/SQLite.
- В GitHub Actions (`.github/workflows/ci.yml`) внедряется шаг проверки дрифта `python scripts/build.py --check` (`git diff --exit-code`), предотвращающий рассинхронизацию исходников и собранных файлов.

**Tech Stack:** Python 3 (сборщик, AST-анализ, SQLite тесты), Bash (целевые скрипты), GitHub Actions.

---

### План поэтапной реализации

#### Этап 1: Создание движка сборки (`scripts/build.py`)
- **Файлы:**
  - Создать: `scripts/build.py`
  - Создать: `tests/test_builder.py`
- **Задачи:**
  1. Реализовать парсер директив `# @include "<module>"` с защитой от циклических зависимостей.
  2. Реализовать режим `--check` (сравнение сгенерированного вывода с файлами в репозитории, выход с кодом 1 при наличии дрифта).
  3. Реализовать проверку синтаксиса `bash -n` и Python AST после сборки.
  4. Протестировать работу сборщика на минимальном тестовом модуле.

#### Этап 2: Модуляризация ядра Xray и базы 3X-UI (`configure_3xui.sh` и `update_repair.sh`)
- **Файлы:**
  - Создать: `src/xray/db.py` (WAL-режим, безопасный sqlite3 backup API).
  - Создать: `src/xray/keys.py` (Curve25519, WireGuard, vlessenc генерация ключей).
  - Создать: `src/xray/routing.py` (чистка bad_geosites, независимые RU-правила, приоритет YouTube над WARP).
  - Создать: `src/xray/inbounds.py` (движок `smart_reconcile_inbound` с сохранением `enable` и xHTTP ключей).
  - Создать: `src/xray/clients.py` (синхронизация единого клиента по всем таблицам).
  - Создать: `src/entrypoints/configure_3xui.main.sh`
  - Создать: `src/entrypoints/update_repair.main.sh`
- **Задачи:**
  1. Вынести повторяющуюся Python-логику в чистые модули в `src/xray/`.
  2. Собрать через `python scripts/build.py`.
  3. Прогнать `python audit/2026-10-14/audit_checks.py` и подтвердить сохранение идентичного поведения.
  4. Зафиксировать коммитом `refactor(xray): modularize configure_3xui and update_repair into src/xray/`.

#### Этап 3: Модуляризация основного инсталлятора `setup_mask.sh`
- **Файлы:**
  - Создать: `src/common/utils.sh` (логирование, цвета, спиннеры, `is_true`).
  - Создать: `src/common/preflight.sh` (Universal Preflight Conflict Inspector, арбитраж портов 3000, 53, 80/443).
  - Создать: `src/tui/wizard.sh` (шаги мастера, Tips/Expert, Back navigation `b`).
  - Создать: `src/tui/review.sh` (Review screen).
  - Создать: `src/tui/checkpoint.sh` (Checkpoint & Resume engine).
  - Создать: `src/system/sysctl.sh` (BBR, тюнинг ядра, IPv6 off).
  - Создать: `src/system/ufw.sh` (недеструктивный фаервол).
  - Создать: `src/system/packages.sh` (установка системных пакетов).
  - Создать: `src/nginx/stream.sh` (L4 Stream SNI маршрутизация).
  - Создать: `src/nginx/http.sh` (L7 HTTP Core, сокеты в `/dev/shm/`, fallback 9443).
  - Создать: `src/nginx/http2.sh` (`determine_nginx_http2_mode`).
  - Создать: `src/nginx/decoys.sh` (веб-маскировка, 3D DataSphere, CosmosCloud).
  - Создать: `src/ssl/certbot.sh` (HTTP-01 Certbot).
  - Создать: `src/ssl/acme.sh` (DNS-01 acme.sh Cloudflare, chmod).
  - Создать: `src/adguard/setup.sh` (AdGuard Home DoH, split-DNS).
  - Создать: `src/entrypoints/setup_mask.main.sh`
- **Задачи:**
  1. Разложить функции `setup_mask.sh` по изолированным смысловым модулям (каждый модуль < 400 строк).
  2. Скомпилировать монолитный `setup_mask.sh` через сборщик.
  3. Проверить синтаксис `bash -n setup_mask.sh` и CLI-тесты (`--help`, `--version`, `--gen-config`).
  4. Зафиксировать коммитом `refactor(setup_mask): decompose monolithic setup_mask.sh into src/ modules`.

#### Этап 4: Модуляризация мастера `install.sh`
- **Файлы:**
  - Создать: `src/entrypoints/install.main.sh`
- **Задачи:**
  1. Подключить общие модули `src/common/utils.sh` и собрать единый `install.sh`.
  2. Проверить `--help` и `--version`.
  3. Зафиксировать коммитом `refactor(installer): modularize install.sh`.

#### Этап 5: Автоматизация контроля в GitHub Actions CI
- **Файлы:**
  - Изменить: `.github/workflows/ci.yml`
- **Задачи:**
  1. Добавить шаг `Build and check for drift` перед запуском тестов:
     `python scripts/build.py --check`
  2. Проверить отработку сборщика и регрессионного тестового набора.
  3. Зафиксировать коммитом `ci: enforce build drift detection in GitHub Actions workflow`.
