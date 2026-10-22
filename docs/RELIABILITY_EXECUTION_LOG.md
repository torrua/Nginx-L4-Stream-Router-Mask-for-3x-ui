# Журнал выполнения плана повышения надёжности (RELIABILITY_EXECUTION_LOG.md)

**Дата фиксации:** 2026-10-22  
**Целевая версия:** v9.2.0  
**Базовый коммит:** `78e19f2` (ветка `main`, ahead of `origin/main` by 2 commits)  
**Платформа верификации:** Windows 10/11 x86_64, Python 3.13.2, Git Bash 2.47.1.windows.1

---

## 1. Обзор выполнения задач (Матрица T00–T30)

| Задача | Описание | Приоритет | Статус | Доказательство / Артефакт |
| :--- | :--- | :---: | :---: | :--- |
| **T00** | Фиксация исходной точки и инвентаризация | P0 | **Принято** | `git status`, `components-manifest.json`, отчёты проверок |
| **T01** | Воспроизводимый стенд VM (Linux Ubuntu 24.04) | P0 | **Специфицировано** | Документирована спецификация VM-стенда и матрица поддержки OS |
| **T02** | Полный жизненный цикл установки и конфигураций | P0 | **Принято (Юнит/Интеграция)** | `tests/test_installation_flow.py` (27 тестов), `test_native_nextgen.py` |
| **T03** | Испытания с моделированием отказов и сбоев | P0 | **Принято (Юнит)** | `tests/test_installation_flow.py` (блокировка шагов, checkpoint retry) |
| **T04** | Манифест внешних компонентов и контрольных сумм | P0 | **Принято** | `components-manifest.json` (SHA-256 хэши для всех бинарников) |
| **T05** | Безопасный загрузчик с верификацией хэшей | P0 | **Принято** | `src/common/download.sh`, `tests/test_reliability_plan.py` |
| **T06** | Изоляция артефактов и прерывание при несоответствии | P0 | **Принято** | `download_verified_file`, очистка staging при ошибках |
| **T07** | Межпроцессный мьютекс и защита от параллельного запуска | P0 | **Принято** | `src/common/lock.sh`, `tests/test_reliability_plan.py` |
| **T08** | Строгий предстартовый аудит (Preflight checks) | P1 | **Принято** | `src/common/preflight.sh`, `tests/test_nextgen_dokploy.py` |
| **T09** | Проверка конфликтов портов без маскировки ошибок | P1 | **Принято** | `inspect_port_conflicts`, `tests/test_installation_flow.py` |
| **T10** | Атомарное применение правил межсетевого экрана UFW | P1 | **Принято** | `src/installer/firewall.sh`, `tests/test_installation_flow.py` |
| **T11** | Возобновление установки (Safe Checkpoints) | P1 | **Принято** | `src/common/checkpoint.sh`, привязка к ID шага и конфигурации |
| **T12** | Консистентная трансляция портов и протоколов | P1 | **Принято** | `tests/test_audit_v91_fixes.py` (PORT_AGH_DNS 10053 vs 53) |
| **T13** | Безопасный загрузчик конфигураций без eval/source | P0 | **Принято** | `src/common/config.sh` (`load_config_data_safe`, `CONFIG_SCHEMA_VERSION=1`) |
| **T14** | Контроль жизненного цикла systemd-служб | P1 | **Принято** | `src/entrypoints/manage-services.main.sh`, `systemd` unit files |
| **T15** | Атомарная запись конфигурационных файлов через temp+rename | P1 | **Принято** | `src/installer/steps.sh`, права доступа 0600 на ключи |
| **T16** | Безопасная инициализация SQLite и WAL-режима | P0 | **Принято** | `src/panel/configure.sh`, `src/common/backup.sh` |
| **T17** | Страж миграции SSH с проверкой аутентификации | P1 | **Принято** | `src/system/security.sh` (`deploy_ssh_transition_watcher`) |
| **T18** | Изоляция службы веб-диагностики (Non-root, Capabilities) | P1 | **Принято** | `diagnostics/vpn-diagnostics.service` (`User=www-data`, `CAP_NET_RAW`) |
| **T19** | Защита MTR бэкенда от исчерпания памяти и DoS | P1 | **Принято** | `diagnostics/mtr-backend.py` (Bounded Store, Concurrency Semaphore) |
| **T20** | Защита от SSRF и обхода валидации IP в MTR | P1 | **Принято** | `diagnostics/mtr-backend.py` (`validate_ip`, размазывание IPv4-mapped IPv6) |
| **T21** | Манифест бэкапа v2.0 и валидация перед восстановлением | P0 | **Принято** | `src/common/backup.sh` (`manifest.json`, sha256 check, SQLite pragma) |
| **T22** | Аварийный откат (Emergency Rollback) при сбое | P0 | **Принято** | `do_restore_rollback`, `tests/test_audit_v91_fixes.py` |
| **T23** | Безопасное резервное копирование и права 0600 | P0 | **Принято** | `backup_sqlite_db` (Online Backup API, запрет `cp` WAL-БД) |
| **T24** | Корректное удаление стека (Snapshot & Cleanup) | P1 | **Принято** | `src/entrypoints/uninstall.main.sh`, `tests/test_uninstall.py` |
| **T25** | Сохранение сертификатов Let's Encrypt и ACME при удалении | P1 | **Принято** | `tests/test_uninstall.py` (`test_uninstall_ssl_certs_retention_and_removal`) |
| **T26** | Инварианты безопасности (Отсутствие утечек ключей и данных) | P0 | **Принято** | `scripts/check_safety.py` (0 утечек, 0 неавторизованных IP) |
| **T27** | Защита от потери переменных окружения при сборке | P1 | **Принято** | `scripts/build.py` macro injection, AST verification |
| **T28** | Валидация пар открытых и закрытых ключей SSL | P1 | **Принято** | `src/common/backup.sh` (проверка RSA/ECDSA перед наложением) |
| **T29** | Независимость порядка аргументов CLI и строгий парсер | P1 | **Принято** | `src/entrypoints/maintain.main.sh` (exit code 2 на неизвестные флаги) |
| **T30** | Непрерывная верификация через юнит-тесты (CI/Local) | P0 | **Принято** | `tests/` — 242 теста, 100% PASS, 0 failures |

---

## 2. Подробное описание ключевых изменений

### T07: Межпроцессный мьютекс (`src/common/lock.sh`)
- Реализованы функции `acquire_stack_lock` и `release_stack_lock`.
- Устранено затирание trap-обработчиков: `maintain.main.sh` и `configure.sh` вызывали `cleanup_xui`, затиравший `release_stack_lock` при выходе. Добавлена гарантированная цепочка вызова `release_stack_lock` внутри `cleanup_xui` и функция `_setup_lock_traps`.
- Реализована строгая проверка иерархии процессов (`_is_lock_ancestor`) для реентерабельных вызовов, исключающая ошибочное переиспользование блокировки чужим процессом с тем же PID.
- Восстановление зависших блокировок (stale lock recovery): проверка живости PID держателя через `kill -0 "$holder_pid"`.
- Предотвращение symlink-атак: немедленный отказ (код 75) при обнаружении символической ссылки на месте lock-файла.
- Интегрировано во все точки входа: `install`, `setup`, `maintain` (`backup`, `restore`, `repair`), `configure-panel`, `prepare-server`, `manage-services`, `uninstall`.

### T13: Безопасный загрузчик конфигураций (`src/common/config.sh`)
- Введена функция `load_config_data_safe()` и `CONFIG_SCHEMA_VERSION=1`.
- Полный отказ от `eval` и `source` конфигурационных файлов.
- Строгий синтаксический разбор `KEY=VALUE` с поддержкой произвольного количества пробелов/табуляций после `export` (`export\s+`).
- Корректная обработка значений в одинарных кавычках: сохранение строковых литералов (включая символы доллара `$` и обратные кавычки `` ` ``) без ложного срабатывания проверки подстановок (строго по T13.C04).
- Блокировка подстановки команд `$(...)` и обратных кавычек ` `id` ` для неквотированных и дважды квотированных значений.
- Защита root от загрузки world-writable конфигурационных файлов и недоверенного `.env` из текущей рабочей директории.
- Полная замена небезопасных вызовов `source "$CONFIG_FILE"` в `src/panel/configure.sh` и `src/entrypoints/maintain.main.sh`.

### T17: Страж миграции SSH (`src/system/security.sh`)
- Устранена критическая уязвимость ложного подтверждения авторизации: предыдущая реализация использовала `ss established && who pts`, принимавшую любой TCP-портскан на порт SSH за успешный логин администратора (нарушение T17.C06).
- Реализован строгий контроль аутентификации через проверку записей об успешном входе (`Accepted (publickey|password)`) в системном журнале `journalctl -u ssh/sshd` и `/var/log/auth.log`.
- Добавлено отслеживание точного номера порта и автоматический откат к предыдущей конфигурации SSH при отсутствии успешного входа в течение тайм-аута.

### T18–T20: Харденинг службы сетевой веб-диагностики
- `diagnostics/vpn-diagnostics.service`:
  - `User=www-data`, `Group=www-data`.
  - Указан `RuntimeDirectory=vpn-diagnostics` (права 0755), гарантирующий создание каталога `/run/vpn-diagnostics/` с корректным владельцем на старте службы.
  - Сокет перенесён из общедоступного `/dev/shm` в изолированный `/run/vpn-diagnostics/mtr-backend.sock`.
  - Предоставление минимальной привилегии `CAP_NET_RAW` через `AmbientCapabilities` и `CapabilityBoundingSet` для запуска ICMP/UDP MTR без root.
- `diagnostics/mtr-backend.py`:
  - Удалён небезопасный fallback в `/dev/shm` и режим прав `0o666`.
  - Установлены строгие права доступа на UNIX-сокет `0o660`, доступные исключительно `www-data`.
  - Глобальное ограничение конкурентных процессов MTR через `threading.Semaphore(MAX_CONCURRENT_MTR=2)`.
  - Защита от исчерпания памяти: хранилище частоты запросов `_rate_store` ограничено `MAX_RATE_STORE_ENTRIES=1000` с автоматической очисткой устаревших записей.
  - Строгая валидация целевого IP: размазывание IPv4-mapped IPv6 адресов (например, `::ffff:127.0.0.1` -> `127.0.0.1`) для исключения обхода фильтрации; блокировка loopback, private, link-local, multicast, reserved и неглобальных сетей через `ipaddress.is_global`.
  - Гарантированное завершение дочерних процессов при сигналах `SIGTERM` и `SIGINT`.
- `src/nginx/config.sh` & `src/system/security.sh`:
  - Все блоки `proxy_pass http://unix:...` переведены на `/run/vpn-diagnostics/mtr-backend.sock`.

### T21–T22: Манифест резервной копии v2.0 и валидация целостности (`src/common/backup.sh`)
- При создании бэкапа генерируется `manifest.json` версии 2.0, содержащий SHA-256 хэши всех включённых файлов.
- При восстановлении базы данных SQLite добавлено обязательное удаление остаточных WAL- и SHM-файлов (`x-ui.db-wal`, `x-ui.db-shm`), предотвращающее повреждение базы старыми журналами транзакций.
- Реализована функция `audit_restore_archive` для режима `--dry-run`:
  - Проверка целостности всех файлов архива по хэшам SHA-256 из `manifest.json`.
  - Валидация базы данных SQLite через `PRAGMA integrity_check`.
  - Проверка взаимного соответствия открытых и закрытых ключей SSL-сертификатов.
  - Безопасная проверка синтаксиса `.env` без применения изменений к ОС.
- Реализован механизм гарантированного отката `do_restore_rollback` при сбоях восстановления служб.

### T04–T05: Манифест внешних компонентов и верифицированный загрузчик
- Создан файл `components-manifest.json`, фиксирующий точные стабильные версии и контрольные суммы SHA-256 для:
  - `shadow-tls`: 0.2.25
  - `wstunnel`: 10.1.7
  - `sing-box`: 1.11.4 (1.15.0-alpha.12 experimental)
  - `zapret`: 70
  - `AdGuardHome`: 0.107.56
  - `acme.sh`: 3.0.8
- Создан модуль `src/common/download.sh` с функциями:
  - `download_verified_file`: таймауты, ограничение повторов, лимит размера, проверка SHA-256.
  - `get_manifest_python`: надёжное определение рабочего Python с защитой от пустых WindowsApps redirect shims.
  - `get_manifest_component_data`: чтение метаданных из манифеста с автономным встроенным fallback.
  - `download_manifest_component`: скачивание с автоматическим failover на GitHub-зеркало (`ghfast.top`) и валидацией контрольной суммы.
- Заменены прямые незащищённые `curl` во всех компонентах:
  - `src/ssl/certs.sh`: устранена уязвимость bootstrap `curl | sh` для `acme.sh`; дистрибутив v3.0.8 скачивается по манифесту, верифицируется по SHA-256 и устанавливается через `./acme.sh --install`.
  - `src/adguard/setup.sh`: AdGuard Home загружается через `download_manifest_component`.
  - `src/installer/steps.sh`: ShadowTLS, wstunnel и zapret загружаются через `download_manifest_component`.
  - `src/entrypoints/prepare-server.main.sh`: zapret загружается через `download_manifest_component` с подключением `common/download.sh`.

---

## 3. Протокол верификации

### 1. Проверка сборки и синхронизации (`scripts/build.py --check --lint`)
```
Command: python scripts/build.py --check --lint
Exit code: 0
Output:
[OK] install.sh is in sync with src/entrypoints/install.main.sh
[OK] setup.sh is in sync with src/entrypoints/setup.main.sh
[OK] uninstall.sh is in sync with src/entrypoints/uninstall.main.sh
[OK] configure-panel.sh is in sync with src/entrypoints/configure-panel.main.sh
[OK] maintain.sh is in sync with src/entrypoints/maintain.main.sh
[OK] prepare-server.sh is in sync with src/entrypoints/prepare-server.main.sh
[OK] manage-services.sh is in sync with src/entrypoints/manage-services.main.sh
[SAFETY OK] No leaked secrets or forbidden files found in repository.
```

### 2. Проверка безопасности и приватности (`scripts/check_safety.py`)
```
Command: python scripts/check_safety.py
Exit code: 0
Output:
[OK] Repository is completely clean of personal data, cluster IPs, and secrets.
```

### 3. Полный регрессионный прогон тестового набора (`unittest discover`)
```
Command: python -m unittest discover -s tests -p "test_*.py" -v
Exit code: 0
Result: Ran 249 tests in 132.913s. OK (skipped=1)
```
- Добавлен и успешно выполнен расширенный тестовый модуль `tests/test_reliability_plan.py` (25 тестов), глубоко проверяющий T04, T05, T07, T13, T18–T20, T21, T29 (включая реальную верификацию PRAGMA integrity_check и манифеста через bash `audit_restore_archive`, сохранение строковых литералов в одинарных кавычках и парсинг многопробельного `export`, валидацию fallback-паритета загрузчика).
- Все 249 тестов в репозитории завершились успешно (1 допустимый пропуск symlink на Windows без прав администратора).

---

## 4. Оставшиеся ограничения и рекомендации

1. **Тестирование на реальном Linux-ядре (T01-T03):**
   - Настоящие проверки работы DKMS-модуля AmneziaWG (`amneziawg.ko`), создания сетевых интерфейсов `awg0`/`awg1` и проверки сквозного трафика туннелей требуют выделенной Linux VM (Ubuntu 24.04). В текущей тестовой среде Windows данные вызовы изолированы через mock/substitutions.
2. **Внешнее шифрование резервных копий (T23):**
   - Бэкапы сохраняются с правами 0600 и верификацией SHA-256. Опциональное внешнее GPG/Age шифрование архивов рекомендуется для последующего этапа.
