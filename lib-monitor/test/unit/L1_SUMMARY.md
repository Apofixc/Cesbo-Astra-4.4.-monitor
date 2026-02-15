# Резюме тестирования L1 (Базовые сервисы)

**Дата:** 2025-02-14  
**Уровень:** L1 — Базовые сервисы  
**Модули:** `logger`, `core.scheduler`, `utils.filter_engine`, `utils.ws_subscriber`  
**Среда:** Cesbo Astra 4.4.182, без внешних C-библиотек.

---

## 1. Выполненные работы

### 1.1. Модули L1 (по ПМИ)
- **utils.logger** — логирование, уровни, буфер, контексты ошибок, batch, JSON-формат.
- **core.scheduler** — планировщик задач (Min-Heap), таймер Astra, add/remove/pause/resume, config subscription.
- **utils.filter_engine** — компиляция аксессоров, match по conditions/script, JIT, duration, кэш.
- **utils.ws_subscriber** — WebSocket-клиенты, broadcast_raw, on_message (ping/batch), init/shutdown.

### 1.2. Тестовые файлы
| Модуль           | Файл                          | Тестов |
|------------------|-------------------------------|--------|
| logger           | test/unit/utils/test_logger.lua | 31   |
| scheduler        | test/unit/core/test_scheduler.lua | 26   |
| filter_engine    | test/unit/utils/test_filter_engine.lua | 36 |
| ws_subscriber    | test/unit/utils/test_ws_subscriber.lua | 19 |

### 1.3. Подход
- Без использования `_G` для тестовых данных: локальные переменные и ссылки на моки (`ref_ModuleManager`, `ref_logger_config_cb`, `ref_timer_callback` и т.д.).
- Моки: `ModuleManager` (get_module, get_global_dependency), Logger, TablePool, EventDispatcher, Scheduler, timer.
- Восстановление подменённых функций после тестов (get_global_dependency и т.д.), чтобы порядок прогона не ломал другие тесты.

---

## 2. Результаты прогона

| Модуль           | Тестов | Успешно | Провалено | Покрытие (luacov) |
|------------------|--------|---------|-----------|-------------------|
| logger           | 31     | 31      | 0         | **100%**          |
| scheduler        | 26     | 26      | 0         | **100%**          |
| filter_engine    | 36     | 36      | 0         | **100%**          |
| ws_subscriber    | 19     | 19      | 0         | **100%**          |
| **L1 итого**     | **112**| **112** | **0**     | —                 |

**Общий прогон (L0 + L1):** 22+26+36+31+35+24+19 = **193 теста**, все проходят.  
**Сводное покрытие по src:** monitor_config 100%, scheduler 100%, logger 100%, table_pool 100%, wildcard 100%, ws_subscriber 100%, filter_engine 100%. **Общее 100%.**

### 2.1. Запуск
```bash
/opt/Cesbo-Astra-4.4.-monitor/astra4.4.182 /opt/Cesbo-Astra-4.4.-monitor/lib-monitor/test/run_test.lua unit
```

Отдельный файл L1, например:
```bash
/opt/Cesbo-Astra-4.4.-monitor/astra4.4.182 /opt/Cesbo-Astra-4.4.-monitor/lib-monitor/test/run_test.lua unit/utils/test_logger.lua
```

---

## 3. Покрытие и границы

- **logger:** уровни (INFO/DEBUG/WARN/NONE), конфиг по событию, буфер (buffer_log, get_buffer, clear, overflow, eviction), flush, with_error, JSON-формат и ошибка json.encode, fallback в print при отсутствии/ошибке log, проверка state через get_module_upvalues (_get_current_level при nil cached_log_level).
- **scheduler:** get_instance (singleton), add_task (валидные/невалидные, перезапись по id), remove_task, set_task_interval (в т.ч. remaining > interval → _heap_up), pause/resume, shutdown, init_config_subscription (пересоздание таймера при смене SchedulerInterval), отсутствие timer (Logger.error), ошибка в callback и долгая задача (warning), _heap_up swap при добавлении после tick, _heap_down с правым потомком.
- **filter_engine:** compile_accessor (nil/пусто, 1/2/3+ сегмента, кэш, overflow), clear_state, match (пустые фильтры, key-value, conditions and/or, операторы eq/ne/gt/ge/lt/le/contains/matches/in), интерпретатор OPERATORS и condition.accessor, вложенные группы и condition.conditions, script (успех, ошибка, script_cache overflow), JIT (поле с точкой, upvalue для table, ошибка load), простая фильтрация без JIT (fallback-цикл), duration.
- **ws_subscriber:** init (nil/валидный server), clear, shutdown, on_message (nil request, первый запрос, ping, command batch), авто init при отсутствии сервера, broadcast_raw (без сервера/данных/клиентов, с клиентом, 5 ошибок send → отключение), get_clients_count, init_config_subscription (в т.ч. set_task_interval при смене WsBatchInterval после init), _flush_buffers при 5 ошибках send (удаление клиента, server.close).

---

## 4. Исправления и оптимизации в коде (production)

- **filter_engine:** кэш скриптов — для каждого закэшированного скрипта хранится `env` в `state.script_env`; перед каждым вызовом устанавливается `env.data = data`, чтобы повторные вызовы видели актуальные данные. Оптимизация: проверка ключа «не с _» заменена с `key:find("^_")` на `key:sub(1, 1) ~= "_"` (в простом fallback и в JIT-ветке для простых фильтров).
- **ws_subscriber:** счётчик клиентов O(1) — введён `state.client_count`; увеличивается при регистрации клиента, уменьшается при удалении (on_message nil, 5 ошибок в broadcast_raw / _flush_buffers), сбрасывается в clear(); `get_clients_count()` возвращает `state.client_count`.

---

## 5. Заключение по L1

| Модуль         | Вердикт   | Покрытие | Примечание                                  |
|----------------|-----------|----------|---------------------------------------------|
| logger         | Пройден   | 100%     | Все сценарии, fallback в print, _G.ModuleManager в тестах |
| scheduler      | Пройден   | 100%     | Куча, таймер, _heap_up swap, set_task_interval remaining, пересоздание таймера |
| filter_engine  | Пройден   | 100%     | JIT/script/conditions, duration, overflow, интерпретатор, простая фильтрация fallback, script кэш env.data |
| ws_subscriber  | Пройден   | 100%     | broadcast, batch, _flush_buffers error≥5, set_task_interval по config, get_clients_count O(1) |

L1 модули пройдены: все тесты зелёные, зависимости изолированы моками. **100% luacov** достигнуто по всем L1: logger, scheduler, filter_engine, ws_subscriber.
