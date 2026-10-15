# Проверка реализации изменений v7.3.4 → v7.5.0

Дата: 15 октября 2026 года, Europe/Moscow.  
Диапазон: `955ac281314e988423c4bccb72fe9be3dc079852..92d39e7`.  
Рабочее дерево до проверки: чистое. Исходные файлы реализации при review не изменялись.

## Вердикт

**Изменения пока не готовы к рекомендации для рабочих VPS.** Проверка сборки проходит, несколько исходных дефектов исправлены, но обнаружены **9 существенных замечаний: 5 P1 и 4 P2**. Восемь сценариев подтверждены на изолированных fixtures; конфликт сохраненных HTTPS-vhost с Nginx Stream установлен по коду и требует отдельного Linux integration test.

Это review реализации diff, а не повторное объявление всех 30 пунктов первоначального аудита. В частности, неизмененные проблемы self-signed TLS fallback, rollback manifest, runtime capability tests и полной supply-chain фиксации не перечислены здесь как новые находки. Закрытие всех этапов в remediation checklist не подтверждает автоматического закрытия всех исходных находок.

## Что проверено и что работает

- `python tests/test_builder.py`: **5/5 PASS**.
- `python scripts/build.py --check --lint`: четыре корневых скрипта совпадают с собранными `src/`; lint прошел.
- `bash -n`: корневые Bash-скрипты и все `src/**/*.sh` проходят.
- AST Python-блоков configurator и repair проходит отдельную проверку.
- Исторический `audit_checks.py` завершается на текущей версии; его результаты не являются строгим regression gate — см. R08.
- На synthetic SQLite fixture подтверждено сохранение `enable=0` для инбаунда/клиента и существующего xHTTP `decryption`.
- В diff действительно убраны destructive DELETE клиентов, добавлены guards по наличию колонок, dry-run WARP registration branch, корректное размещение AGH DNS ACL и exact DoH location.
- Нормальный путь SQLite Backup API, выделение общего inbound helper и build drift check — полезные изменения. Замечания относятся к оставшимся failure paths и семантике отдельных исправлений.

## R01 — P1: сохраненные HTTPS-сайты конфликтуют с новым Stream listener

Место: [src/nginx/config.sh:184](<C:/Users/User/Dropbox/Python/PRIZI/gemini-discussions/how-to-setup-awg-on-dokploy/src/nginx/config.sh:184>), Stream listener — строка 243; preflight — `src/common/preflight.sh:149–157`.

Новый код сохраняет и включает `sites-enabled/*` в блок `http`, но продолжает выделять публичный `443` отдельному `stream` listener. Если сохраненный пользовательский vhost содержит обычный `listen 443 ssl`, один и тот же публичный socket нужен HTTP и Stream. Они не превращаются автоматически в backends друг друга. Preflight считает любой nginx на этом порту своим сервисом и разрешает реконфигурацию.

**Условие:** сервер с существующим HTTPS-сайтом на Nginx. **Последствие:** bind/restart failure или нарушение ожидаемой маршрутизации, вместо заявленного безопасного сосуществования. Аналогичная проблема возможна для сохраненных `conf.d` HTTPS-vhost. Удаление файлов заменено их сохранением, но перенос listener/SNI path не реализован.

**Исправить:** либо отказ до мутаций при чужом публичном HTTPS listener, либо явно переводить существующие vhost на отдельный loopback/Unix backend с SNI-картой, сохраняя TLS/PROXY contract. Проверять staged configuration до замены рабочего `nginx.conf`.

**Приемка:** Linux VM с существующим сайтом на 80/443; после apply сайт и VPN работают, restart/reload успешны, чужой vhost не переписан. В текущей среде реальный Nginx restart не запускался; это статически подтвержденный конфликт конфигурационной модели.

## R02 — P1: защита AWG от path traversal применена только к add

Место: [manage_amneziawg.py:554](<C:/Users/User/Dropbox/Python/PRIZI/gemini-discussions/how-to-setup-awg-on-dokploy/manage_amneziawg.py:554>).

`add_client` теперь валидирует имя, а `remove_client` продолжает строить `AWG_DIR / f"{client_name}{ext}"` без проверки containment. Воспроизведение `remove_client('../victim')` с AWG_DIR, указывающим на временный `exports`, удалило соседний `victim.conf` и вернуло `ok=true`.

**Условие:** вызывающий оператор/бот может передать имя удаления; неавторизованный удаленный доступ к боту этим review не установлен. **Последствие:** root-контроллер удаляет файлы вне каталога экспорта. Опасны также absolute paths и использование публичного ключа с `/` в качестве имени файла.

**Исправить:** единая валидация идентификатора для mutating commands; отделить поиск по public key от имени экспортного файла. Перед каждым unlink проверять разрешенный resolved path и symlink policy.

**Приемка:** traversal/absolute/symlink escape для remove отклоняются без единой файловой мутации. Подтверждение: `awg_remove_path_traversal` в `review_checks.json`.

## R03 — P1: blocked AWG peer остается в конфигурации перезапуска

Место: [manage_amneziawg.py:585](<C:/Users/User/Dropbox/Python/PRIZI/gemini-discussions/how-to-setup-awg-on-dokploy/manage_amneziawg.py:585>).

Новая реализация добавляет `userData.blocked=true` в `clientsTable`, но удаляет peer только через runtime `awg set`. Его `[Peer]` остается в `awg0.conf`. Ни restart/repair в контроллере, ни exporter не применяют persisted blocked-флаг обратно к интерфейсу. При восстановлении интерфейса из этого файла peer снова разрешен.

Fixture подтвердил одновременно: `status=suspended`, флаг `blocked=true`, существующий persistent `[Peer]`. Исторический тест проверяет факт сохранения таблицы, поэтому считает этот частичный fix успешным.

Для штатного AWG lifecycle это существенная граница: официальный startup script поднимает интерфейс через `awg-quick up /opt/amnezia/awg/awg0.conf`, не читая blocked-флаг таблицы. Для нестандартного контейнера нужно отдельно проверить его startup contract. [Amnezia AWG start.sh](https://raw.githubusercontent.com/amnezia-vpn/amnezia-client/dev/client/server_scripts/awg/start.sh).

**Исправить:** хранить единый desired state, формировать runtime config без suspended peers либо хранить заблокированные peer records отдельно от активного `awg0.conf`; обеспечить явный путь unblock. Одной записи флага недостаточно.

**Приемка:** add → block → restart/recreate контейнера → попытка handshake по старому ключу неуспешна; unblock снова разрешает его. Подтверждение fixture: `awg_block_restart_configuration`. Сам Docker/VPN handshake в review не запускался.

## R04 — P1: fallback WAL-safe backup вновь использует небезопасный cp

Место: [src/common/backup.sh:44](<C:/Users/User/Dropbox/Python/PRIZI/gemini-discussions/how-to-setup-awg-on-dokploy/src/common/backup.sh:44>); callers — `src/entrypoints/configure_3xui.main.sh:396`, `src/entrypoints/update_repair.main.sh:219`.

После ошибки Python Backup API и sqlite3 `.backup` helper возвращается к `cp` живого main DB file и сообщает успех. При полностью неудачном backup callers только предупреждают, затем продолжают изменения и печатают сообщение о созданной копии.

В воспроизведении отключены обе безопасные возможности backup; исходная WAL-база содержит committed row. Helper вернул **0**, копия содержит **0 строк вместо 1**. Таким образом, основной defect A10 не устранен на failure path.

**Исправить:** отсутствие корректного snapshot — обязательная ошибка, запрещающая write/apply. Для fallback допустимы только гарантированно остановленные writers с согласованным checkpoint/snapshot; не заменять безопасную операцию обычным copy без изменения контракта. Добавить integrity/read-back validation.

**Приемка:** Backup API unavailable/error/permission failure не приводят к записи в production DB; WAL fixture восстанавливается полностью. Подтверждение: `backup_fallback_loses_wal`.

## R05 — P1: новый AWG fallback скрывает failure persistent write

Место: [manage_amneziawg.py:58](<C:/Users/User/Dropbox/Python/PRIZI/gemini-discussions/how-to-setup-awg-on-dokploy/manage_amneziawg.py:58>), аналогично `append_container_file:69–77`.

Для устранения двойного append сначала вызывается container `tee`, а затем host fallback. Однако вызов больше не использует `check=True`. Если Docker write не выполнен, а host parent отсутствует или запись не удалась, функция молча возвращает `None`. Add/block/remove продолжают работу и могут вернуть success после изменения runtime peer, хотя `awg0.conf`/`clientsTable` не обновлены.

Воспроизведение: Docker возвращает failure, host-каталог отсутствует; `write_container_file` не выдает ошибку. Это регрессия обработки ошибок по сравнению с обязательным исключением прежней container-write ветки.

**Исправить:** единственный authoritative writer, явный результат/исключение при failure обеих веток, rollback уже сделанной runtime-операции. Не трактовать отсутствие mount как успешно завершенную persistent write.

**Приемка:** Docker stopped/read-only FS/full disk не дают `ok=true`; после ошибки runtime и persistent configuration согласованы. Подтверждение: `awg_persistent_write_failure_swallowed`.

## R06 — P2: --debug запускает функции без их shell-контекста

Место: [src/tui/base.sh:39](<C:/Users/User/Dropbox/Python/PRIZI/gemini-discussions/how-to-setup-awg-on-dokploy/src/tui/base.sh:39>).

Экспортируется только вызываемая функция, затем создается новый `bash -euo pipefail`. Неэкспортированные глобальные переменные и helper-функции не наследуются. Реальные задачи используют `WEBROOT`, `_ACME`, `LE_EMAIL`, `PRIMARY_DOMAIN`, `warn`, `supports_x86_64_v3` и другие зависимости.

Тестовая task, читающая обычный `PRIMARY_DOMAIN`, завершается `PRIMARY_DOMAIN: unbound variable`; wrapper возвращает ошибку вместо успешного выполнения. Даже при export переменных остаются helpers и Bash arrays, которые таким способом не передаются.

**Исправить:** выполнять функцию в subshell, сохраняющем текущий контекст, с продуманной явной проверкой ошибок, либо передавать задаче весь контекст через стабильный интерфейс. Исправление одного errexit edge case не должно менять окружение исполнения.

**Приемка:** одинаковая задача в normal/debug имеет одинаковый доступ к config/helpers и одинаковый результат; внутренний failure при этом корректно возвращается. Подтверждение: `debug_spinner_loses_context`.

## R07 — P2: нормализация RU routing теряет пользовательские ограничения

Место: [src/entrypoints/configure_3xui.main.sh:1092](<C:/Users/User/Dropbox/Python/PRIZI/gemini-discussions/how-to-setup-awg-on-dokploy/src/entrypoints/configure_3xui.main.sh:1092>), до строки 1103; аналогичный алгоритм в repair.

При обнаружении direct-правила с RU domain/IP старый объект удаляется, а новые собираются только из `type`, `outboundTag`, `domain`/`ip`. Ограничения `user`, `inboundTag`, `network`, `port` теряются. Дополнительные IP-сети заменяются единственным `geoip:ru`; несколько совпавших правил перезаписывают промежуточные переменные.

Fixture с `user=['alice']`, `domain=['domain:ru']`, `ip=['geoip:ru','203.0.113.0/24']` после apply не содержит ни ограничения пользователя, ни дополнительной сети. Разделение AND в OR полезно для installer-owned policy, но произвольные правила оператора нельзя так расширять.

**Исправить:** нормализовать только собственные маркированные правила; пользовательские сохранять. При явной миграции клонировать остальные qualifiers и сохранять все IP entries.

**Приемка:** custom routing fixtures сохраняют все ограничения/сети и порядок; меняются только installer-managed exceptions. Подтверждение: `routing_custom_constraints_lost`.

## R08 — P2: добавленный CI audit job не падает на FAIL

Место: [audit_checks.py:276](<C:/Users/User/Dropbox/Python/PRIZI/gemini-discussions/how-to-setup-awg-on-dokploy/audit/2026-10-14/audit_checks.py:276>); новый workflow запускает этот файл как regression suite.

Исторический harness собирает наблюдения и печатает `FAIL`/`DEFECT_REPRODUCED`, но не возвращает nonzero по ним и не делает assertions ожидаемого исправленного поведения. Он создавался для аудита конкретной версии; включение его в CI без изменения контракта не делает его regression gate.

Инъекция обычного failure `install.sh --version` дала запись `FAIL`, но `main()` завершился нормально: CI-команда получит exit 0. Есть и ложные проверки: тест block смотрит обновление таблицы, не исключение peer из persistent config; doctor берет старую фиксированную строку 1670.

**Исправить:** перенести исправленные поведения в assert-based tests, проверять отрицательные и failure сценарии, возвращать ненулевой status при нарушении контракта. Исторический сборщик доказательств оставить отдельным инструментом.

**Приемка:** намеренная поломка версии, backup, client status, block persistence или parser делает job красным. Подтверждение: `ci_gate_ignores_failed_cli_check`.

## R09 — P2: preflight принимает собственный AdGuard за чужой конфликт

Место: [src/common/preflight.sh:115](<C:/Users/User/Dropbox/Python/PRIZI/gemini-discussions/how-to-setup-awg-on-dokploy/src/common/preflight.sh:115>).

Любой listener на `PORT_AGH_WEB` приводит к переносу. Значение `get_port_listener_info` используется только в сообщении; собственный `AdGuardHome` не отличен от чужой службы. На повторном apply уже работающий AGH поэтому переезжает с 3000 на 3001.

Особенно опасен resume: inspector выполняется независимо от checkpoint, а Nginx stage 6 может быть пропущен. AGH stage 8 получает новый порт, existing proxy остается на старом. Кроме того, session config сохраняется до inspector, поэтому выбранный новый порт не гарантированно попадает в `.env`. При занятом всем диапазоне цикл выбирает 3054 без проверки.

Fixture с listener `AdGuardHome` на 3000 подтвердил выбор 3001. Отдельно тот же preflight вернул 0 при конфликте docker-proxy на 443: он информирует, но не является блокирующим арбитром.

**Исправить:** идентифицировать managed service, сохранять его порт при rerun; для реальной смены порта инвалидировать зависимые checkpoints и атомарно сохранить config. При исчерпании диапазона и нерешенном обязательном конфликте прекращать apply до мутаций.

**Приемка:** second apply и resume сохраняют endpoint; реальный foreign listener вызывает предсказуемый перенос или отказ, Nginx/AGH/env синхронны. Подтверждение: `preflight_own_agh_and_foreign_https`.

## Рекомендуемый порядок доработки

1. Закрыть R01–R05: данные, блокировки, файловые операции и failure backup.
2. Превратить regression job в реальный gate (R08), включая reproductions R01–R09.
3. Исправить debug context, ownership routing и идемпотентность port resolution (R06, R07, R09).
4. Проверить на disposable Linux VM existing HTTPS site, rerun/resume, WAL restore, Docker restart и реальные VPN/TLS/DoH подключения.
5. Сверить remediation checklist с первоначальными критериями аудита. Например, проверка схемы таблиц не заменяет deployment manifest/transactional rollback, а `-version` нового core не доказывает readiness рабочей конфигурации.

## Доказательства и ограничения

[review_checks.py](<C:/Users/User/Dropbox/Python/PRIZI/gemini-discussions/how-to-setup-awg-on-dokploy/audit/2026-10-15/review_checks.py>) исполняет выделенные функции/блоки из текущих исходников, использует только временные SQLite DB/файлы и mocks внешних действий. Результаты — [review_checks.json](<C:/Users/User/Dropbox/Python/PRIZI/gemini-discussions/how-to-setup-awg-on-dokploy/audit/2026-10-15/review_checks.json>). Исторический `checks.json` не перезаписывался; production scripts, настройки ОС/VPS и рабочие ключи не изменялись.

```powershell
python audit\2026-10-15\review_checks.py
```

Сценарии описывают текущие defects и фиксируют доказательства, а не являются готовым passing acceptance suite. Возврат 0 review harness означает завершение сбора наблюдений. Для product CI необходимо преобразовать их в assertions требуемого поведения. Полная Linux integration, реальные Docker restart/handshake и Nginx bind не запускались из-за ограниченного доступа к Linux runtime в данной среде.

### 🌐 Community Wisdom: [Setting up a firewall with UFW](https://dev.to/serverkueche/setting-up-a-firewall-with-ufw-4lk5)

> **Source**: [serverkueche](https://dev.to/serverkueche)  
> **Tags**: `linux`, `security`, `networking`
>
> Практический контекст для разделения host/container networking и проверки действующего доступа при изменении firewall. Эта статья не является доказательством находок review: они подтверждены текущим кодом и fixtures. Комментариев источник через API не вернул; широкое согласие сообщества по одной публикации не выводится.
>
> 🔗 [Read Full Discussion](https://dev.to/serverkueche/setting-up-a-firewall-with-ufw-4lk5)
