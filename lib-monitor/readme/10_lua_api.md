# Программный интерфейс (Lua API)

Библиотека предоставляет набор функций для управления мониторингом непосредственно из ваших Lua-скриптов в Astra.

## 1. Управление сервером

*   `server_start(addr, port)`: Запускает HTTP-сервер мониторинга. Включает автоматическую логику повторных попыток при занятом порте.
*   `server_stop()`: Останавливает сервер и гарантированно освобождает сетевой порт.

## 2. DVB-мониторинг

*   `dvb_tuner_monitor(conf)`: Инициализация и запуск мониторинга DVB-тюнера.
*   `update_dvb_monitor_parameters(name_adapter, params)`: Обновление параметров (интервалы, пороги) существующего монитора.
*   `pause_dvb_monitor(name_adapter)` / `resume_dvb_monitor(name_adapter)`: Управление активностью сбора метрик.
*   `switch_transponder(name_adapter, new_params, reserve_input)`: Сценарий переключения транспондера с сохранением выходов каналов.
*   `stop_dependent_channels(name_adapter)`: Остановка всех каналов, использующих указанный адаптер.

## 3. Мониторинг каналов

*   `make_monitor(config, channel_data)`: Создание и регистрация нового монитора для существующего канала.
*   `make_stream(conf)`: Создание и запуск потока Astra с автоматическим созданием монитора.
*   `update_monitor_parameters(name, params)`: Динамическое обновление настроек монитора.
*   `kill_monitor(name)`: Остановка и удаление только монитора.
*   `kill_stream(name)`: Полная остановка потока и связанного с ним монитора.
*   `pause_monitor(name)` / `resume_monitor(name)`: Приостановка/возобновление анализа потока.

## 4. Управление подписками

*   `EventDispatcher:subscribe(event_type, sub_data)`: Программное добавление подписки.
    *   `sub_data.callback`: Функция, которая будет вызвана при событии.
    *   `sub_data.filters`: Таблица условий фильтрации.
    *   `sub_data.throttle_ms`: Ограничение частоты вызовов.
*   `EventDispatcher.subscription_manager:unsubscribe(sub_id)`: Удаление подписки по её ID.

## 5. Продвинутое использование (ООП)

Вы можете взаимодействовать с объектами мониторов напрямую через репозитории:
```lua
local ModuleManager = require("core.module_manager")
local DvbRepository = ModuleManager.get_module("dvb_repository")

local tuner = DvbRepository.find("dvb0")
if tuner then
    -- Получение данных без аллокаций (из пула)
    local status = tuner:get_status_table()
    
    -- Принудительное обновление PSI таблиц на 10 секунд
    tuner:psi_update()
end
```

## 6. Логирование и диагностика

*   `Logger.info(component, format, ...)`: Информационное сообщение.
*   `Logger.warning(component, format, ...)`: Предупреждение (алиас для системного лога Astra).
*   `Logger.error(component, format, ...)`: Ошибка с сохранением в контекст.
*   `Logger.clear_component_buffer(component)`: Очистка диагностического буфера логов для компонента.
