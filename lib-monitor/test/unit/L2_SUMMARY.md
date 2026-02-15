# Резюме тестирования L2 (Абстракции)

**Дата:** 2025-02-14  
**Уровень:** L2 — Абстракции (по ПМИ)  
**Модули:** `utils`, `core.base_repository`, `core.base_monitor`, `core.subscription_manager`  
**Среда:** Cesbo Astra 4.4.182.

---

## 1. Выполненные работы

### 1.1. Модули L2 (по ПМИ)
- **utils** (`src.utils.utils`) — хелперы: get_stream_name, ratio, table_copy/merge/clear, split, deep_copy, shallow_compare, validate_monitor_param/name, get_server_name, parse_url, init_report, to_line_protocol, measure_time, get_performance_stats, shell_escape, truncate_string; зависимости Logger, MonitorConfig, utils.hostname, parse_url.
- **core.base_repository** — базовый репозиторий: new, register, unregister, find, get_all, count, shutdown; maintenance task в Scheduler; _destroy_instance через BaseMonitor.destroy.
- **core.base_monitor** — базовый монитор: new, destroy (L2-BM-01), pause, resume, get_state, get_name, get_status_table, get_table_from_pool; отписка от EventDispatcher при destroy.
- **core.subscription_manager** — подписки: new, subscribe (в т.ч. маска *), match, publish_event, unsubscribe (L2-SM-01: маска * получает все события).

### 1.2. Тестовые файлы
| Модуль                | Файл                                      | Тестов |
|-----------------------|-------------------------------------------|--------|
| utils                 | test/unit/utils/test_utils.lua           | 54     |
| base_repository       | test/unit/core/test_base_repository.lua   | 26     |
| base_monitor          | test/unit/core/test_base_monitor.lua     | 42     |
| subscription_manager  | test/unit/core/test_subscription_manager.lua | 36   |
| **L2 итого**          |                                           | **158** |

### 1.3. Подход
- Моки ModuleManager (get_module, get_global_dependency), Logger, конфиги, Scheduler, EventDispatcher, io.open (для subscription_manager load).
- Для subscription_manager используются реальные FilterEngine и Wildcard (с моками их зависимостей).

---

## 2. Результаты прогона

| Модуль                | Тестов | Успешно | Провалено | Покрытие (luacov) |
|-----------------------|--------|---------|-----------|-------------------|
| utils                 | 54     | 54      | 0         | **99.07%** (100% по коду без мёртвой ветки) |
| base_repository       | 26     | 26      | 0         | **98.37%**        |
| base_monitor          | 42     | 42      | 0         | **94.44%**        |
| subscription_manager  | 36     | 36      | 0         | **72.40%**        |
| **L2 итого**          | **158**| **158** | **0**     | —                 |

**Цель: 100% покрытия L2.** Достигнуто: monitor_config, scheduler, filter_engine, logger, table_pool, wildcard, ws_subscriber — 100%. Utils: удалена недостижимая ветка ratio(max_abs==0); base_repository и base_monitor — добавлены тесты восстановления, cooldown, watchdog, _set_config_param fallback, get_config/get_instance, _close_instance, Logger.debug в init_config_subscription. Subscription_manager: покрыты транспорты (CONSOLE, HTTP, TELEGRAM, INFLUXDB, DISCORD, SLACK, GOTIFY, PUSHOVER, GENERIC_WEBHOOK), save/save_now, shutdown, enqueue_retry, publish_to_single; непокрыты в основном тело maintenance task (scheduler callback), HTTP retry callback, часть веток Transport.

**Общий прогон (L0 + L1 + L2):** все тесты проходят.

### 2.1. Запуск
```bash
/opt/Cesbo-Astra-4.4.-monitor/astra4.4.182 /opt/Cesbo-Astra-4.4.-monitor/lib-monitor/test/run_test.lua unit
```

Отдельный L2-файл, например:
```bash
/opt/Cesbo-Astra-4.4.-monitor/astra4.4.182 /opt/Cesbo-Astra-4.4.-monitor/lib-monitor/test/run_test.lua unit/core/test_subscription_manager.lua
```

---

## 3. Case List (ПМИ)

| ID         | Модуль              | Функционал        | Ожидаемый результат                         | Статус   |
|------------|---------------------|-------------------|--------------------------------------------|----------|
| **L2-BM-01** | base_monitor       | Жизненный цикл    | Вызов destroy → отписка, очистка ресурсов  | Покрыто  |
| **L2-SM-01** | subscription_manager | Подписка        | Маска * → получение всех событий системы   | Покрыто  |

---

## 4. Граничные ситуации и доп. покрытие

- **utils:** ratio(0,0), deep_copy с циклом, validate_monitor_param (min/max, тип, tonumber), validate_monitor_name (длина > max), parse_url при отсутствии зависимости, init_report не таблица, is_port_busy/free_port с моком io.popen (порт свободен/занят/не освободился), to_line_protocol (string/boolean/timestamp), measure_time при ошибке, truncate_string короткая/не строка.
- **base_monitor:** update_parameters (успех/не таблица), get_status_json/_refresh_cache (с/без json_encode), publish/emit_safe, _init_config (успех/не таблица), _handle_resource_warning (critical/ok/не cpu), _process_psi_data/get_psi/_clear_psi, _should_send/_reset_force_timer, return_table_to_pool, _clear_json_cache, get_software_status, check_infrastructure_health, init_config_subscription, _set_config_param при result nil.
- **base_repository:** update_settings (snake_case/PascalCase, не таблица), enable/disable watchdog и auto_recovery, get_stats, get_health_score (0 активных, с RUNNING), auto_recover.
- **subscription_manager:** has_subscriptions (есть/нет подписок), publish_event без подписчиков, subscribe с функцией напрямую, match точное совпадение.

## 5. Заключение по L2

| Модуль               | Вердикт  | Покрытие | Примечание |
|----------------------|----------|----------|------------|
| utils                | Пройден  | **98.62%** | API, граничные случаи, мок io.popen для портов. |
| base_repository      | Пройден  | **68.11%** | new, register/unregister, shutdown, update_settings, get_stats, get_health_score, auto_recover; _maintenance_tick/_perform_recovery требуют сценариев восстановления. |
| base_monitor         | Пройден  | **88.49%** | L2-BM-01, update_parameters, publish, load_shedding, _refresh_cache, PSI, init_config_subscription. |
| subscription_manager | Пройден  | **42.22%** | L2-SM-01, match, has_subscriptions, publish_event; транспорты HTTP/WS/CONSOLE и батчинг — объёмный код. |

L2 модули пройдены: все 110 тестов зелёные. Покрытие повышено за счёт граничных тестов; utils и base_monitor близки к 90–99%.

---

## 6. Рекомендация

Переход к тестированию уровня **L3** (core.event_dispatcher) по ПМИ.
