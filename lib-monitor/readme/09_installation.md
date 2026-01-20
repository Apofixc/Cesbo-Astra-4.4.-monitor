# Установка и быстрый старт

Библиотека `lib-monitor` легко интегрируется в существующие проекты на базе Astra.

## 1. Установка

1.  **Копирование файлов**: Разместите содержимое библиотеки в директории вашего проекта, например `/opt/astra/lib-monitor/`.
2.  **Настройка путей**: Для корректной работы `require` рекомендуется добавить путь к библиотеке в переменную окружения `LUA_PATH`.

Добавьте в `~/.bashrc`:
```bash
export LUA_PATH="./?.lua;/opt/astra/lib-monitor/?.lua;;"
```

## 2. Подключение в скрипте

```lua
-- Инициализация библиотеки
local init = require("init_monitor")
if not init then
    log.error("Не удалось загрузить lib-monitor")
    astra.exit()
end

-- Запуск HTTP API сервера
server_start("0.0.0.0", 8080)
```

## 3. Безопасность

По умолчанию API требует ключ аутентификации.
*   **Переменная окружения**: `ASTRA_API_KEY`.
*   **Значение по умолчанию**: `test` (не рекомендуется для продакшн).
*   **Заголовок запроса**: `X-Api-Key: ваш_ключ`.

## 4. Первый запуск мониторинга

### Мониторинг DVB-адаптера
```lua
dvb_tuner_monitor({
    adapter = 0,
    type = "S2",
    tp = "11044:V:43200",
    name_adapter = "my_tuner"
})
```

### Мониторинг канала
```lua
make_stream({
    name = "Discovery",
    input = { "http://example.com/stream.ts" },
    output = { "udp://239.255.1.1:1234" },
    monitor = {
        type = "output",
        cc_threshold = 10
    }
})
```

## 5. Проверка работы

После запуска вы можете проверить состояние системы через `curl`:
```bash
curl -H "X-Api-Key: test" http://localhost:8080/api/system/health
```

Или подключиться к WebSocket для получения событий в реальном времени:
```bash
wscat -c ws://localhost:8080/api/ws -H "X-Api-Key: test"
# В консоли wscat:
# {"command": "subscribe", "event_type": "*"}
