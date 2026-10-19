# Release Notes: v8.0.1 — Hotfix: Устранение фатальной ошибки Bash 'local: can only be used in a function'

**Дата релиза:** Октябрь 2026  
**Ветка / Статус:** Релиз v8.0.1 (Patch / Hotfix)

---

## 🐛 Исправленные ошибки (Bugfixes)

### 1. Критическая ошибка времени выполнения Bash `local: can only be used in a function`
* **Проблема:**  
  В интерактивном мастере установки [`setup_mask.sh`](../setup_mask.sh) на строке 4930 скрипт аварийно прерывался при старте опроса параметров сессии со следующим выводом:
  ```text
  /tmp/setup_mask.sh: line 4930: local: can only be used in a function
    ✖ Скрипт аварийно прерван на строке 4930
  ```
* **Причина:**  
  В стандарте командного интерпретатора Bash ключевое слово `local` предназначено строго для объявления локальных переменных внутри тел функций. В блоке проверки сохраненной конфигурации предыдущей сессии (`if [ "$NON_INTERACTIVE" -eq 0 ]; then`) переменная `has_saved_config` ошибочно объявлялась через `local` в глобальной области видимости скрипта. Поскольку в скрипте включен строгий перехватчик ошибок (`trap ... ERR`), ненулевой код возврата встроенной команды `local` вызывал немедленный аварийный останов мастера.
* **Исправление:**
  1. **Интерактивный мастер ([`src/tui/wizard.sh`](../src/tui/wizard.sh#L103) / [`setup_mask.sh`](../setup_mask.sh)):** объявление `local has_saved_config=0` заменено на стандартное присваивание `has_saved_config=0`.
  2. **Экспресс-режим ([`src/tui/wizard.sh`](../src/tui/wizard.sh#L341)):** объявление `local udp_stack_summary=...` в блоке вывода параметров экспресс-установки заменено на `udp_stack_summary=...`.
  3. **Автономный AmneziaWG ([`src/entrypoints/setup_mask.main.sh`](../src/entrypoints/setup_mask.main.sh#L425)):** объявление `local awg_p=...` в шаге открытия портов фаервола UFW заменено на `awg_p=...`.

---

## 🏗 Архитектурная целостность (SSOT & Modular Build)

* Все исправления синхронизированы в модульных исходниках каталога `src/` (`src/tui/wizard.sh` и `src/entrypoints/setup_mask.main.sh`).
* Монолитные дистрибутивные файлы (`setup_mask.sh`, `install.sh`, `configure_3xui.sh`, `update_repair.sh`) пересобраны через [`scripts/build.py`](../scripts/build.py) с контролем дрифта и синтаксиса.
* Добавлен автоматический регрессионный тест `TestBashScopeRegressions` в тестовый комплект `tests/test_audit_regressions.py`, исключающий повторное появление ключевого слова `local` в глобальной области видимости скриптов.

---

## 🧪 Тестирование и валидация

* **Unit & Regression Tests:** 41 тест успешно пройден (`python -m pytest tests/` — 100% pass).
* **Синтаксическая валидация:** `python scripts/build.py --lint --check` подтверждает полную синхронность всех файлов и отсутствие ошибок парсинга AST / Bash (`0 errors`).

---

## 📋 Инструкция по обновлению

Обновление установщика на целевом сервере выполняется стандартной командой в одну строчку:

```bash
# Запуск актуальной версии мастера установки
curl -sSL "https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/install.sh?v=$(date +%s)" | sudo bash
```

Или при прямой загрузке `setup_mask.sh`:

```bash
curl -sSLO "https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/setup_mask.sh" && sudo bash setup_mask.sh
```
