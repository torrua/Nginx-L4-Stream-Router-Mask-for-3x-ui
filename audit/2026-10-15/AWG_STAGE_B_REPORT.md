# Этап B: техническая проверка AmneziaWG

Дата: 15 октября 2026 года. Основание: снимок исходного отчёта и локальный commit `2ff3d8cc3d034b4bf679fcd1c543769863fb4555`. Изменены только исследовательские материалы. Программы проекта не запускались; выводы о коде получены статическим чтением. Рабочий VPS и установленные на нём версии не исследовались.

## Основные результаты

1. В эволюции протокола пропущено важное различие: CPS I1–I5 появились в линии 1.5, а не впервые в 2.0. CPS расшифровывается как Custom Protocol Signature, а не Concealment Packet Sync.
2. При HPK проверяется `Sx < 12`: значение 12 допустимо. Возврат `EINVAL` при неверной настройке не является падением ядра. Цитата диагностического сообщения в исходном отчёте неточна.
3. `RandomTrailers` затрагивает и handshake, и padding внутри шифруемых transport-пакетов. Нельзя описывать его исключительно как хвосты handshake.
4. Представления bool различаются. В `.conf` для проверенных `amneziawg-tools` использовать `off`/`on` или `0`/`1`. Строка `RandomTrailers = false`, предложенная исходным отчётом, этими tools отвергается. Go UAPI, напротив, использует `strconv.ParseBool`; JSON панели использует bool. Это разные интерфейсы.
5. Пример I1 из отчёта имеет 44 байта: 2 случайных и 42 постоянных. Сравнение с `<r 128>` не сохраняет длину. Два случайных байта меняют Transaction ID, но оставляют большую постоянную часть пакета.
6. Для AmneziaVPN официальная граница AWG 3.1 — 5.0.1.5; запись «>=4.8.12 / 5.0+» слишком широка. Standalone Android 2.0.1 отвергает неизвестные поля 3.x; это конкретная несовместимость конфигурации с HPK, а не расплывчатая «ограниченная поддержка».
7. Матрица встроенного Keenetic требует исправления: официальный старый профиль KeeneticOS 4.2 относится к AWG 1.0 и не содержит S3/S4. Обещание полной AWG 2.0 для всей 4.x не выдерживает проверки. Нативная 3.1 документирована с 5.2 Alpha 11 для поддерживаемых моделей.
8. Исправлена предварительная заметка этапа A о MikroTik: полный README timbrs действительно описывает HPK и функции 3.1. Но это proxy поверх штатного WireGuard, который не воспроизводит ContentPaddingAddition и таймеры. «Полная поддержка» всех параметров остаётся неверной формулировкой.
9. В проекте обнаружены две разные системы управления: встроенная AWG-служба панели 3X-UI и отдельный адаптер Docker-контейнера Amnezia. Связь между ними автоматически не установлена. Правка одного генератора не меняет конфигурацию другого сервера.
10. Ошибка DNS в `manage_amneziawg.py` подтверждается. Одновременно обнаружены другие DNS-константы и четыре места `RandomTrailers=on`, поэтому перечень из двух строк исходного отчёта неполон. MSS clamping уже реализован на хосте и в Docker-адаптере; требуется оценить область действия, а не просто добавить ещё такое же правило.

Итоги по всем 68 исходным ID записаны в `AWG_STAGE_B_VERDICTS.tsv`. Часть ID этапа A оказалась составной; в таблице ниже и в пояснениях их компоненты оценены раздельно. Слово «частично» не означает, что все части исходной строки верны. Исправлено также неточное извлечение P28 на A: исходник называет набор S «стандартом проекта», а не официальным стандартом AWG; этот локальный набор действительно найден в template панели.

## Источники и область проверки

Версии зафиксированы тегами там, где это доступно. Ссылки на `main`/`master` — состояние прочитанной ветки на дату просмотра; они не доказывают поведение старого релиза или установленного пользователем сервера.

| ID | Первоисточник | Для чего использован |
|---|---|---|
| B01 | [AmneziaWG Docs](https://docs.amnezia.org/documentation/amnezia-wg/) | Названия механизмов, рекомендация H=1/2/3/4 с HPK, общий порядок CPS/Junk, актуальное описание функций. |
| B02 | [Go README v3.1.20260814](https://github.com/amnezia-vpn/amneziawg-go/blob/v3.1.20260814/README.md) | Параметры, рекомендации и смысл односторонней настройки. |
| B03 | [Go uapi.go v3.1.20260814](https://github.com/amnezia-vpn/amneziawg-go/blob/v3.1.20260814/device/uapi.go) и [v3.1.20260828](https://github.com/amnezia-vpn/amneziawg-go/blob/v3.1.20260828/device/uapi.go) | Парсеры, типы, ошибки конфигурации, уровень Device/Peer. |
| B04 | [Go noise-types.go v3.1.20260814](https://github.com/amnezia-vpn/amneziawg-go/blob/v3.1.20260814/device/noise-types.go) | Диапазоны uint32, проверка пересечения. |
| B05 | [Go send.go v3.1.20260814](https://github.com/amnezia-vpn/amneziawg-go/blob/v3.1.20260814/device/send.go) и [v3.1.20260828](https://github.com/amnezia-vpn/amneziawg-go/blob/v3.1.20260828/device/send.go) | Порядок отправки, handshake trailers, transport padding. |
| B06 | [Go receive.go v3.1.20260828](https://github.com/amnezia-vpn/amneziawg-go/blob/v3.1.20260828/device/receive.go) | Распознавание типа/длины, обработка HPK и cookie. |
| B07 | [Go timers.go v3.1.20260828](https://github.com/amnezia-vpn/amneziawg-go/blob/v3.1.20260828/device/timers.go) | Реальное действие таймеров и лимита повторных попыток. |
| B08 | [Kernel netlink.c v3.1.20260812](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/blob/v3.1.20260812/src/netlink.c) | Валидация S/HPK, H, возврат EINVAL. |
| B09 | [Kernel type.h](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/blob/v3.1.20260812/src/type.h), [device.h](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/blob/v3.1.20260812/src/device.h), [messages.h](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/blob/v3.1.20260812/src/messages.h) | Типы полей и представление сообщений. |
| B10 | [Tools config.c v3.1.20260812](https://github.com/amnezia-vpn/amneziawg-tools/blob/v3.1.20260812/src/config.c), [type.c](https://github.com/amnezia-vpn/amneziawg-tools/blob/v3.1.20260812/src/type.c) | Синтаксис `.conf`, bool, ключи и границы числовых парсеров. |
| B11 | [Официальная issue kernel #87](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/87), [Go device.go v3.0.0](https://github.com/amnezia-vpn/amneziawg-go/blob/v3.0.0/device/device.go), [v0.2.19 obf.go](https://github.com/amnezia-vpn/amneziawg-go/blob/v0.2.19/device/obf.go) | CPS относится к AWG 1.5; наличие новых полей в 3.0. |
| B12 | [Android Interface.java 2.0.1](https://github.com/amnezia-vpn/amneziawg-android/blob/2.0.1/tunnel/src/main/java/org/amnezia/awg/config/Interface.java), [v3.1.20260814](https://github.com/amnezia-vpn/amneziawg-android/blob/v3.1.20260814/tunnel/src/main/java/org/amnezia/awg/config/Interface.java), [backend go.mod](https://github.com/amnezia-vpn/amneziawg-android/blob/v3.1.20260814/tunnel/tools/libwg-go/go.mod) | Принимаемые поля, преобразование UAPI, зависимость на Go v3.1.20260814. |
| B13 | [Amnezia FAQ](https://docs.amnezia.org/faq/), [релиз AmneziaVPN 5.0.1.5](https://github.com/amnezia-vpn/amnezia-client/releases/tag/5.0.1.5) | Официальная нижняя граница поддержки 3.1. |
| B14 | [Старый Keenetic AWG 1.0](https://docs.amnezia.org/ru/documentation/instructions/old-keenetic-os-awg/), [актуальная инструкция 3.1](https://docs.amnezia.org/documentation/instructions/keenetic-os-awg/) | Конкретные схемы конфигурации и версии KeeneticOS. |
| B15 | [AWG Manager CHANGELOG в v2.17.4](https://github.com/hoaxisr/awg-manager/blob/v2.17.4/CHANGELOG.md) | Запись от 27 августа: NativeWG через awg_proxy 1.4.0, HPK и trailers. |
| B16 | [2Grey OpenWrt README](https://github.com/2Grey/awg-openwrt/blob/master/README.en.md), [kmod Makefile](https://github.com/2Grey/awg-openwrt/blob/master/kmod-amneziawg/Makefile) | Согласованный набор kmod/tools/LuCI и поддержанные поля 3.1. |
| B17 | [timbrs MikroTik README](https://github.com/timbrs/amneziawg-mikrotik-c/blob/main/README_en.md) | Полные разделы 3.0/3.1 и перечисленные ограничения proxy. |
| B18 | [WARP generator](https://github.com/ImMALWARE/bash-warp-generator/blob/main/warp_generator.sh) | Фактические поля генерируемого профиля, включая I1. |
| B19 | [3X-UI go.mod](https://github.com/MHSanaei/3x-ui/blob/main/go.mod), [netstack.go](https://github.com/MHSanaei/3x-ui/blob/main/internal/amneziawgnet/netstack.go), [device.go](https://github.com/MHSanaei/3x-ui/blob/main/internal/amneziawgnet/device.go), [forwarder.go](https://github.com/MHSanaei/3x-ui/blob/main/internal/amneziawgnet/forwarder.go) | Отдельный встроенный AWG Device/gVisor и преобразование в UAPI. |
| B20 | [3X-UI params.go](https://github.com/MHSanaei/3x-ui/blob/main/internal/amneziawg/params.go), [XTLS distro imports](https://github.com/XTLS/Xray-core/blob/main/main/distro/all/all.go) | Правила панели и отличие от стандартного набора Xray handlers. |
| B21 | [RFC 8200 §5](https://www.rfc-editor.org/rfc/rfc8200.html#section-5), [WireGuard protocol](https://www.wireguard.com/protocol/) | Слои и размеры; отделение базового WG от внешней AWG обфускации. |
| B22 | [Kernel v1.0.20260725](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/tree/v1.0.20260725), [v3.0.20260731-04](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/tree/v3.0.20260731-04), [v3.1.20260812](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/releases/tag/v3.1.20260812) | Упомянутые теги существуют; номер пакета/тега нельзя автоматически считать номером профиля протокола. |

## Паспорт параметров: проверенные уточнения

Значения типов ниже — границы парсеров, а не обещание безопасной работы любого значения в этих границах. В реальной конфигурации действуют ограничения размера буфера, MTU и клиента.

| Параметр | Проверенный смысл и представление | Исправление исходного отчёта |
|---|---|---|
| H1–H4 | uint32 или диапазон; Device-wide. Sender выбирает значение, receiver ищет его на смещении Sx. Пересечения проверяют Go и ядро. | Совпадение настроек — надёжный способ согласования. Рекомендация 1/2/3/4 при HPK подтверждена B01. |
| S1–S4 | Длины случайных префиксов перед соответствующим сообщением; парсер tools/Go принимает uint16. Receiver использует свои смещения. | 15–150 и 16/20/24/16 не универсальные допустимые границы или стандарт. S4 оплачивается каждым data-пакетом. |
| S1+56 != S2 | Из 148+S1=92+S2 следует равенство длин, если S2=S1+56. | Условие есть в старых рекомендациях и в validator панели B20. В прочитанном Go merge и kernel netlink 3.1 такой проверки нет. Не объявлять его универсальной проверкой UAPI. |
| Jc/Jmin/Jmax | Локальные Device-wide настройки отправителя; согласование не нужно. В Go UAPI — uint32, в tools/ядре — uint16. Ноль допустим для Jc. | «Клиентский» означает обычное место настройки, а не запрет работы на сервере. Диапазон 1–128 — не общий предел текущего Go UAPI. Рекомендация README — 4–12, а 2/20/50 — локальный пресет. |
| I1–I5 | CPS-шаблоны. В send path Initiation: заданные I-пакеты по порядку → JunkPackets → handshake. | Механизм был в 1.5. Нельзя обещать, что произвольная hex-строка является корректной имитацией протокола. Не требуется совпадение сторон. |
| HeaderProtectionKey | Конфиг tools: Base64 ключа 32 байта; Go UAPI: hex. Device-wide, общий для пиров интерфейса. | В приведённых версиях минимум Sx равен 12. Нулевой ключ отключает механизм. Криптографические последствия и совместимость разных реализаций переданы C. |
| RandomTrailers | bool Device-wide. Receiver допускает удлинённые handshake только при своём включённом флаге. На transport padding добавляется до AEAD. | Протокольное описание «только handshake» неполно. Для обычного двустороннего профиля флаги согласовывать. Решение «всем off» отдельно на C. |
| DisableCookies | Локальный Device-wide bool, не требует одинакового значения у пиров. | В коде нет ограничения только серверной ролью. В receive.go флаг отключает ветвь under-load с MAC2/cookie/ratelimiter, что нужно учитывать на C. |
| ContentPaddingAddition | Выбор дополнительного внутреннего transport-padding. Go UAPI — uint32 range; tools и kernel хранят границы uint16. | Таблица отчёта неполна: поле пропущено. Путь ограничений изменён между прочитанными версиями send.go; нельзя дать одно объяснение без фиксации версии. |
| RekeyAfterTime | Локальная настройка порога возраста ключа, используемая при обработке трафика. | Это не гарантия отдельного периодического handshake каждые N секунд вне зависимости от трафика. |
| KeepaliveTimeout | Служебный реактивный keepalive после получения данных; новое значение берётся при постановке таймера. | Не отождествлять с Peer.PersistentKeepalive, который отдельно поддерживает периодическую активность. |
| MaxHandshakeAttempts | Выбранный лимит повторов; после его исчерпания очищается очередь ожидающих пакетов, ставится очистка ключевого материала. | Peer не удаляется из конфигурации автоматически; формулировка «до сброса пира» неточна. |
| RekeyTimeout / RejectAfterTime | Локальные настройки повторов и жизни ключей. Tools/kernel: uint16 ranges; Go: uint32 ranges. | Оба отсутствуют в «исчерпывающей» таблице. Значения требуют согласованного выбора с RekeyAfterTime. |
| PersistentKeepalive | Peer-level range в прочитанном Go 3.x; отдельный механизм. | Отчёт смешивает его назначение с KeepaliveTimeout. |
| MTU | Настройка интерфейса/клиентского приложения или userspace netstack; не согласуемое поле handshake. | Равенство MTU у сторон не требуется протоколом. Выбор 1280 и путь MSS оценить на C. |

### Проверка bool и сообщений об ошибках

В B10 `parse_bool` принимает `on`, `off` либо числовую строку. Словесные `true`/`false` не проходят этот parser. В B03 `random_trailers` и `disable_cookies` передаются в `strconv.ParseBool`, который не принимает `on`/`off`. Android B12 преобразует строки в UAPI 1/0. Поэтому предложение заменить `.conf` на `false` исправляется на `off`, а JSON поля должны оставаться логическими значениями.

В B08 `wg_set_device` при недостаточном Sx возвращает `-EINVAL` и выходит из функции. Диагностический шаблон — `S1 must be more then %d to use headerProtection` и аналогичные для остальных S. Несмотря на слово `more`, условие в коде `< HEADER_PROTECTION_NONCE_SIZE`, поэтому 12 принимается. В Go B03 сходная проверка возвращает ошибку merge. Вывод исходного отчёта о гарантированном kernel crash этим не подтверждается.

### Разбор DNS I1

Независимый подсчёт длины исходной hex-строки: 84 hex-символа = 42 байта. С `<r 2>` итог — 44 байта. Это UDP payload, без IP/UDP заголовков.

| Поле | Значение |
|---|---|
| Transaction ID | 2 случайных байта |
| Flags | 0x8580 |
| QDCOUNT / ANCOUNT / NSCOUNT / ARCOUNT | 1 / 1 / 0 / 0 |
| Question | icloud.com, A, IN |
| Answer name | Compression pointer 0xc00c |
| Answer TTL | 0x105a = 4186 секунд |
| Answer RDATA | 77.88.55.55 |

Структура соответствует DNS-подобному response. Это не проверка достоверности ответа для icloud.com, его ожидаемости на выбранном UDP-порту или принятия DPI. Контроль с `<r 128>` отличается и содержимым, и длиной; причинный вывод по такому сравнению нуждается в повторной оценке на C.

## Исправленная матрица совместимости для проверенных случаев

Здесь «принимает параметры» не означает проведённый нами тест соединения на устройстве.

| Реализация | Что подтверждено | Ограничение / вердикт исходной строки |
|---|---|---|
| AmneziaVPN | FAQ и release notes: AWG 3.1 начиная с 5.0.1.5. | Нижняя граница 4.8.12 / произвольная 5.0 неверна. Импорт конкретных URI нужно проверять по формату. B13. |
| Standalone Android v3.1.20260814 | Parser знает HPK, timers, CPA, оба 3.1 bool; backend требует Go v3.1.20260814. | Поддержка полей подтверждена кодом. Успешное соединение с любой серверной реализацией не проверялось. B12. |
| Standalone Android 2.0.1 | Parser знает S3/S4, H и I1–I5; неизвестное поле вызывает BadConfigException. | HPK/timers/RandomTrailers нет в switch. Профиль с этими полями не импортируется через этот parser. B12. |
| KeeneticOS 4.2 native | Официальная инструкция использует AWG 1.0 asc без S3/S4/I/HPK. | «Полная 2.0 в KeeneticOS 4.x» опровергнута как обобщение для всей ветки. Более поздние сборки оценивать отдельно. B14. |
| KeeneticOS 5.2 Alpha 11+ | Официальная инструкция заявляет native 3.1 для перечисленных моделей. | Не путать стабильный 5.2 с конкретной alpha и не обещать обновление всем устройствам. B14. |
| AWG Manager v2.17.4 | Changelog подтверждает NativeWG через awg_proxy 1.4.0 с HPK и trailers; kernel mode существовал ранее. | Требуется реально загруженная новая версия модуля, в changelog указана перезагрузка. Бейдж сам по себе не доказательство. B15. |
| OpenWrt / 2Grey | kmod v3.1.20260906 + tools v3.1.20260812 + LuCI v3.1.1; перечислены новые поля и ranges. | Одного kmod недостаточно для UI/import/export. Нужен комплект под точный target и ядро. B16. |
| MikroTik / timbrs | Proxy понимает HPK и handshake trailers, подавление outbound cookies. | Таймеры и ContentPaddingAddition не исполняются им; шифрование данных остаётся в штатном WG. Имя Containers_3.1 как версия не установлено. B17. |
| WARP с AWG-клиентом | Генератор B18 выдаёт стандартные H=1/2/3/4 и S1/S2=0, но также Jc/Jmin/Jmax и большой CPS I1. | «Работает только Jc» опровергается уже содержимым приведённого источника. Реальная доступность зависит от сети и нами не измерялась. |

## Карта локального проекта и следствия для рекомендаций §7

| Место | Фактический путь данных | Следствие |
|---|---|---|
| `scripts/build.py`, ENTRYPOINTS и bundle_file | Разворачивает `# @include` из `src/` в root shell scripts. | При будущей правке изменять исходные модули, затем сборку. Две текстовые копии одной логики не являются двумя независимыми реализациями. |
| `src/entrypoints/configure_3xui.main.sh:1324` | Берёт/создаёт unified HPK и bool из AWG_RANDOM_TRAILERS. | Это настройка встроенного профиля панели, не Docker-контейнера адаптера. |
| `src/entrypoints/configure_3xui.main.sh:1416` | Создаёт server profile 8443: S=16/20/24/16, MTU1280, HPK, RandomTrailers из env, DisableCookies=true, таймеры; H пустые. | DNS и JC/JMIN/JMAX уже заданы, но I1 и CPA в этом template нет. Runtime-обработку пустых H проверять для версии панели. |
| `src/entrypoints/configure_3xui.main.sh:1445` | Создаёт профиль 8444 с фиксированными H и S3=24,S4=16, без HPK. | Это не универсальный профиль старого AWG 1.0. Одни скалярные H не делают его совместимым с любым Keenetic 4.x. |
| `src/xray/inbounds.py:191` | Сохраняет существующие ключи, S/H/J и часть других параметров, затем условно меняет их. | Существующий профиль может отличаться от defaults. I-поля и timing-поля отсутствуют в этом списке сохранения. |
| `src/xray/inbounds.py:198` | Отключает существующий truthy RandomTrailers, только если не включены AWG_FORCE_RANDOM_TRAILERS и AWG_RANDOM_TRAILERS. | Сброс не безусловный; создания отсутствующего inbound он не касается, потому что функция раньше возвращает. |
| `src/xray/inbounds.py:203` | При MTU>1280 снижает до 1280; при S<12 с HPK меняет S на локальные defaults; снижает Jc/Jmax. | Это уже действующие политики изменения существующих настроек. Их обоснование и совместимость клиентов оценить на C. |
| `manage_amneziawg.py:88` | Читает Docker `awg0.conf` и ограниченный набор полей; env имеет приоритет. | Не читает RandomTrailers, DisableCookies, timers, CPA и DNS. Нельзя ожидать точной копии серверного профиля. |
| `manage_amneziawg.py:113` | HPK берёт из HEADER_PROTECTION_KEY или config; если отсутствует — генерирует случайный. | Имя env отличается от AWG_HEADER_PROTECTION_KEY панели. Сгенерированный fallback не устанавливается здесь на сервер. |
| `manage_amneziawg.py:178`, `add_client:434` | Отдельно строит `.conf`, внутренний config для URI, last_config и awg metadata. | Четыре фиксированных `on` относятся к одному адаптеру с разными представлениями. Функция URI не использует переданный conf_text как единственный источник истины. |
| `manage_amneziawg.py:185`, `:292`, `:489` | DNS: буквальные `$PRIMARY_DNS`, далее metadata dns1/dns2 и `.conf` используют 76.76.10.0/1.1.1.1. | Исправление одной строки не согласует все формы выдачи. AWG_PRIMARY_DNS/AWG_SECONDARY_DNS модуль не читает. |
| `manage_amneziawg.py:456` | Изменяет серверный peer/AllowedIPs через `awg set` и дописывает Peer в config. | Изменение peer не устанавливает Device-wide HPK/S/RandomTrailers. Ручная замена client on→off должна соответствовать серверу. |
| `src/system/sysctl.sh:123` | Уже добавляет глобальный host FORWARD TCPMSS после проверки `iptables -C`; ошибки подавляются. | Дублирующее добавление не требуется. Проверить работоспособность и эффект для нужного backend на C. |
| `src/system/sysctl.sh:128` | Добавляет persistence только когда UFW file существует и в нём нет `*mangle`. | Наличие любой mangle table может помешать сохранению правила; это конкретное ограничение текущей реализации. |
| `manage_amneziawg.py:131` | Добавляет два clamp-правила внутри контейнера для `-i awg0` / `-o awg0`, выставляет MTU. | Это отдельное netns. Shell-команды подавляют ошибки и не доказывают успешное применение. |

В актуальном исходнике 3X-UI B19 AWG реализован отдельным in-process Go Device поверх gVisor, а не стандартным AWG inbound handler ядра Xray. Go dependency — v3.1.20260828. Локальный проект скачивает сторонний installer без фиксации релиза и пишет настройки прямо в SQLite, поэтому нельзя по этому репозиторию определить фактическую версию/схему установленной панели. Docker-адаптер требует уже существующий контейнер; просмотренный установочный путь не даёт основания считать его связанным с embedded AWG панели.

Правило Linux FORWARD и пакет внутри userspace netstack относятся к разным слоям. Применимость MSS clamping к каждому backend требует разбора его маршрута трафика на C. Наличие Dokploy само по себе не задаёт ни network_mode контейнера, ни режим AWG kernel/userspace.

## Пакет вопросов для сильной модели на этапе C

1. **RandomTrailers**: исследовать именно v3.1.20260814 и v3.1.20260828, kernel v3.1.20260812 и версию kmod из OpenWrt. Сопоставить широкие H, разные S и HPK; отдельно проверить fixed H с разными S. Не переносить эффект широкого диапазона на scalar H без доказательства. Сверить PR/issue и статус фиксов. Уточнить, какой throughput-эксперимент описан в bivlked, до/после каких исправлений и что он доказывает.
2. **HPK**: детально проверить образование nonce, область XOR и совместимость kernel↔Go↔proxy. Учесть issue #216/#222. Код валидации доказывает ≥12, но не отсутствие других дефектов. Набор 16/20/24/16 оценивать как локальный выбор, а не установленный стандарт; с trailers официальная документация рекомендует равные S.
3. **MTU/MSS**: рассчитать outer overhead с S4, AEAD, IPv4/IPv6 и внутренним padding для конкретных версий. Разобрать Docker/TUN и встроенный gVisor отдельно; оценить, где реально проходит FORWARD и поможет ли clamp при неизвестном PMTU. Не переносить вывод о TCP на UDP/QUIC.
4. **ТСПУ и DNS**: провести оценку свидетельств по четырём общим тезисам §1; не считать недоступность/троттлинг доказательством именно entropy detector. Пересмотреть сравнение 128-байтного random packet и 44-байтного DNS-shaped packet. Нужен равный контроль по размеру и воспроизводимые замеры.
5. **Рекомендации проекта**: оценить синхронизацию реальных server/client параметров и цену изменения существующего Device. Простой массовый on→off и смена S могут нарушить клиентов, если не выполнены на обеих сторонах. Проверить DisableCookies/DoS tradeoff, временные диапазоны и сохранение I/timing-полей при reconcile. Пример панели RekeyAfterTime=120–180 и RejectAfterTime=180–210 соприкасается на 180; validator актуальной 3X-UI требует maxRekey<minReject — проверить применимость к версии панели и прямой записи в DB.
6. **Качество доказательств**: уже существующие тексты проекта и сторонние повторения одного замера не являются независимыми подтверждениями. Сохранять статусы «не подтверждено» и «требует эксперимента», если данных не хватает.

## Граница этапа

Этап B закончен: для технических утверждений установлены значения и ограничения либо конкретный пробел; сложные причинные объяснения переданы C. Следующая модель: **GPT-6 Astra, высокий уровень рассуждений (High)**. Начать C только после переключения и команды пользователя.
