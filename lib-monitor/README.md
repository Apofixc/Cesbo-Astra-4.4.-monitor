# lib-monitor

`lib-monitor` — это высокопроизводительная библиотека Lua для Astra (Cesbo), предназначенная для глубокого мониторинга DVB-тюнеров, потоков каналов и системных ресурсов. Библиотека предоставляет программный интерфейс для автоматизации внутри Astra и полноценный HTTP REST API для интеграции с внешними панелями управления и системами мониторинга (Zabbix, Grafana и др.).

## Основные возможности:

*   **Мониторинг DVB-тюнеров**: Инициализация, запуск, динамическая перенастройка (TP), получение детальных метрик (Signal, SNR, BER, UNC) и расчет интегрального показателя качества (Quality). Автоматическое управление счетчиком каналов Astra для совместного использования адаптеров.
*   **Мониторинг каналов**: Поддержка мониторов типа `input` (вход), `output` (выход канала) и `ip` (прямой мониторинг UDP/RTP). Отслеживание битрейта, CC/PES ошибок и статуса шифрования.
*   **Системный мониторинг**: Сбор метрик процесса Astra (CPU, RAM, потоки, дескрипторы) и ОС (I/O диска, сетевая активность по интерфейсам, Load Average, температура CPU).
*   **HTTP REST API**: Более 30 эндпоинтов для управления всеми аспектами системы в реальном времени с единообразным форматом JSON-ответов.
*   **Push-уведомления (Webhooks)**: Автоматическая рассылка JSON-статусов на удаленные серверы при изменении состояния объектов.
*   **Интеллектуальная фильтрация**: 4 метода сравнения состояния для минимизации сетевого трафика и записи только значимых изменений.
*   **Гибкая архитектура**: Модульная структура на базе `ModuleManager` с автоматическим разрешением зависимостей и валидацией параметров.

## Структура проекта:

```
lib-monitor/
├── init_monitor.lua        # Точка входа. Инициализирует модули и экспортирует функции в _G.
├── README.md               # Данная документация.
├── subscribers.json        # Постоянное хранилище активных HTTP-подписок.
├── http/                   # Слой HTTP-сервера.
│   ├── http_server.lua     # Ядро сервера (маршрутизация).
│   ├── http_helpers.lua    # Утилиты (Auth, JSON-ответы, валидация заголовков).
│   └── routes/             # Обработчики API (channel, dvb, monitor, subscriber, system).
├── src/                    # Исходный код бизнес-логики.
│   ├── module_manager.lua  # Управление жизненным циклом модулей.
│   ├── adapters/           # Работа с DVB (adapter.lua, dvb_tuner.lua).
│   ├── channel/            # Мониторинг потоков (channel.lua, channel_monitor.lua).
│   ├── storage/            # Репозитории активных объектов (channel_storage, dvb_storage).
│   ├── system/             # Сбор метрик (resource_monitor.lua).
│   ├── config/             # Конфигурация и схемы валидации (monitor_config.lua).
│   └── utils/              # Логгер, HTTP-клиент для Push, общие утилиты.
└── test/                   # Набор интеграционных и стресс-тестов.
```

## Установка и запуск:

1.  Разместите папку `lib-monitor` в директории скриптов Astra.
2.  Инициализируйте библиотеку в вашем скрипте:
    ```lua
    require("lib-monitor.init_monitor")
    ```
3.  Запустите HTTP API сервер:
    ```lua
    local ModuleManager = require("lib-monitor.src.module_manager")
    local server = ModuleManager.get_module("http_server")
    server.start("0.0.0.0", 8080)
    ```
4.  Настройте ключ доступа через переменную окружения `ASTRA_API_KEY` (по умолчанию "test").

## Использование (Global API):

Библиотека экспортирует основные функции в глобальную область видимости Astra:

### Каналы и Стримы
*   `make_stream(conf)`: Создает канал Astra и привязывает к нему монитор.
*   `kill_stream(name)`: Останавливает канал и корректно завершает работу монитора.
*   `make_monitor(config, channel_data)`: Создает монитор для уже существующего объекта канала.
*   `kill_monitor(name)`: Удаляет монитор, не трогая сам канал.
*   `pause_monitor(name)` / `resume_monitor(name)`: Временная остановка анализа без удаления объекта.

### DVB-адаптеры
*   `dvb_tuner_monitor(conf)`: Запускает мониторинг физического адаптера.
*   `pause_dvb_monitor(name)` / `resume_dvb_monitor(name)`: Управление активностью опроса тюнера.

## Методы сравнения (Optimization):

Параметр `method_comparison` определяет, когда библиотека должна отправить уведомление (Push) или обновить кэш:

1.  **Always (1)**: Отправка данных при каждом получении данных от ядра Astra.
2.  **Strict (2)**: Отправка при любом изменении статуса (On-Air), битрейта или появлении хотя бы одной ошибки CC/PES.
3.  **Ratio (3)**: (Рекомендуемый) Отправка при изменении статуса или если отклонение битрейта превысило порог `rate` (по умолчанию 3.5%).
4.  **On-Air (4)**: Отправка только при критическом изменении (появился или пропал сигнал).

## HTTP API Endpoints:

Все успешные ответы имеют статус `HTTP 200 OK` и содержат поля `"status": "ok"` (или `"healthy"` для health-check) и `"timestamp": <unix_time>`. Ошибки возвращают соответствующий код (400, 401, 404, 500) и поле `"message"`.

### 1. Каналы (`/api/channels`)

*   **GET `/api/channels`**
    *   **Описание**: Список всех активных каналов.
    *   **Ответ**:
```json
        {
          "status": "ok",
          "timestamp": 1704312345,
          "channels": [
            { "id": "Discovery", "name": "Discovery Channel", "output": ["udp://239.255.1.1:1234"] }
          ]
        }
```

*   **GET `/api/channels/stats`**
    *   **Описание**: Агрегированная статистика по всем каналам.
    *   **Ответ**:
```json
        {
          "status": "ok",
          "timestamp": 1704312345,
          "total": 10,
          "online": 8,
          "offline": 2,
          "with_errors": 1
        }
```

*   **GET `/api/channels/{id}`**
    *   **Описание**: Полная конфигурация конкретного канала.
    *   **Ответ**:
```json
        {
          "status": "ok",
          "timestamp": 1704312345,
          "channel": {
            "id": "Discovery",
            "name": "Discovery Channel",
            "input": ["http://..."],
            "output": ["udp://..."],
            "map": "..."
          }
        }
```

*   **GET `/api/channels/{id}/inputs`**
    *   **Описание**: Список входов канала и индекс текущего активного входа.
    *   **Ответ**:
```json
        {
          "status": "ok",
          "timestamp": 1704312345,
          "inputs": ["http://input1", "http://input2"],
          "active_input": 1
        }
```

*   **GET `/api/channels/{id}/psi`**
    *   **Описание**: Таблицы PSI/SI (PMT, SDT) для канала.
    *   **Ответ**:
```json
        {
          "status": "ok",
          "timestamp": 1704312345,
          "psi": {
            "pmt": { "pid": 256, "streams": [...] },
            "sdt": { "pid": 17, "services": [...] }
          }
        }
```

*   **POST `/api/channels/create`** (также доступен как **POST `/api/streams`**)
    *   **Описание**: Создание нового канала (принимает стандартный конфиг Astra).
    *   **Ответ**: `{"status": "ok", "timestamp": 1704312345, "message": "Channel created"}`.

*   **POST `/api/channels/{id}/kill`** (также доступен как **POST `/api/streams/{id}/kill`** или **POST `/api/monitors/{id}/kill`**)
    *   **Описание**: Остановка канала. Параметр `?reboot=true` выполнит перезапуск.
    *   **Ответ**: `{"status": "ok", "timestamp": 1704312345, "message": "Channel killed"}`.

### 2. DVB-адаптеры (`/api/dvb`)

*   **GET `/api/dvb/adapters`** (также доступен как **GET `/api/env/adapters`**)
    *   **Описание**: Список активных DVB-мониторов.
    *   **Ответ**:
```json
        {
          "status": "ok",
          "timestamp": 1704312345,
          "adapters": [
            { "id": "dvb0", "name": "dvb0", "type": "S2" }
          ]
        }
```

*   **GET `/api/dvb/adapters/{id}/data`**
    *   **Описание**: Метрики тюнера.
    *   **Ответ**:
```json
        {
          "status": "ok",
          "timestamp": 1704312345,
          "adapter_data": {
            "id": "dvb0",
            "status": 1,
            "signal": 75.5,
            "snr": 24.8,
            "ber": 0,
            "unc": 0,
            "lock": true
          }
        }
```

*   **GET `/api/dvb/adapters/{id}/psi`**
    *   **Описание**: Сбор таблиц PSI напрямую с частоты адаптера.
    *   **Ответ**: `{"status": "ok", "timestamp": 1704312345, "psi": {...}}`.

*   **POST `/api/dvb/adapters/{id}/tune`**
    *   **Описание**: Перенастройка адаптера на новую частоту (параметр `tp`).
    *   **Ответ**: `{"status": "ok", "timestamp": 1704312345, "message": "Adapter tuning started"}`.

*   **POST `/api/dvb/adapters/{id}/update`** (также доступен как **POST `/api/dvb/adapters/{id}/restart`** или **POST `/api/dvb/adapters/{id}/kill`**)
    *   **Описание**: Обновление параметров мониторинга адаптера (rate, time_check).
    *   **Ответ**: `{"status": "ok", "timestamp": 1704312345, "message": "Adapter monitor updated"}`.

*   **POST `/api/dvb/adapters/scan`**
    *   **Описание**: Запуск процесса сканирования.
    *   **Ответ**: `{"status": "ok", "timestamp": 1704312345, "message": "Scan started"}`.

### 3. Общие Мониторы (`/api/monitors`)

*   **GET `/api/monitors`**
    *   **Описание**: Список всех активных мониторов (Channel + DVB).
    *   **Ответ**:
```json
        {
          "status": "ok",
          "timestamp": 1704312345,
          "monitors": [
            { "id": "Discovery", "name": "Discovery", "type": "output" }
          ]
        }
```

*   **GET `/api/monitors/status`**
    *   **Описание**: Сводка по всей системе мониторинга.
    *   **Ответ**:
```json
        {
          "status": "ok",
          "timestamp": 1704312345,
          "total": 20,
          "ok": 18,
          "error": 2,
          "total_cc_errors": 150
        }
```

*   **GET `/api/monitors/{id}/data`**
    *   **Описание**: Текущие метрики конкретного монитора.
    *   **Ответ**:
```json
        {
          "status": "ok",
          "timestamp": 1704312345,
          "monitor_data": {
            "id": "Discovery",
            "status": "OK",
            "bitrate": 12500,
            "cc_errors": 0,
            "pes_errors": 0,
            "scrambled": false,
            "ready": true
          }
        }
```

*   **POST `/api/monitors/{id}/update`**
    *   **Описание**: Динамическое изменение `rate`, `time_check`, `method_comparison`, `analyze`.
    *   **Ответ**: `{"status": "ok", "timestamp": 1704312345, "message": "Monitor updated"}`.

### 4. Подписки (Push/Webhooks) (`/api/subscribers`)

*   **GET `/api/subscribers`**
    *   **Описание**: Список всех активных Webhooks.
    *   **Ответ**:
```json
        {
          "status": "ok",
          "timestamp": 1704312345,
          "subscribers": {
            "channels": [ { "host": "192.168.1.10", "port": 80, "path": "/webhook" } ],
            "dvb": [],
            "error": []
          }
        }
```

*   **POST `/api/subscribers/subscribe`**
    *   **Описание**: Регистрация нового получателя.
    *   **Параметры (JSON/Query)**: `host`, `port`, `path`, `event_type` (`channels`, `dvb`, `error`).
    *   **Ответ**: `{"status": "ok", "timestamp": 1704312345, "message": "Subscribed successfully"}`.

*   **POST `/api/subscribers/unsubscribe`**
    *   **Описание**: Удаление подписки.
    *   **Ответ**: `{"status": "ok", "timestamp": 1704312345, "message": "Unsubscribed successfully"}`.

### 5. Система (`/api/system`)

*   **GET `/api/env/astra`**
    *   **Описание**: Информация о версии Astra и аптайме процесса.
    *   **Ответ**:
```json
        {
          "status": "ok",
          "timestamp": 1704312345,
          "astra": {
            "version": "4.4.182",
            "uptime": 3600
          }
        }
```

*   **GET `/api/system/resources`**
    *   **Описание**: Детальные метрики системы.
    *   **Ответ**:
```json
        {
          "status": "ok",
          "timestamp": 1704312345,
          "resources": {
            "cpu": { "total": 12.5, "user": 8.0, "sys": 4.5, "temp_c": 45.0, "threads": 15 },
            "memory": { "rss_kb": 262809, "vms_kb": 512000, "lua_kb": 1500 },
            "io": { "read_bps": 1024, "write_bps": 512 },
            "network": { "eth0": { "rx_bps": 1250000, "tx_bps": 750000 } },
            "system": { "load_avg": [0.5, 0.8, 1.2], "fd_count": 120 }
          }
        }
```

*   **GET `/api/system/health`**
    *   **Описание**: Проверка работоспособности сервера.
    *   **Ответ**:
```json
        {
          "status": "healthy",
          "timestamp": 1704312345,
          "astra_version": "4.4.182",
          "server_time": "2024-01-15 14:30:00"
        }
```

*   **GET `/api/system/monitor-stats`**
    *   **Описание**: Статистика работы `ResourceMonitor`.
    *   **Ответ**:
```json
        {
          "status": "ok",
          "timestamp": 1704312345,
          "stats": {
            "collections": 1500,
            "cache_hits": 1350
          }
        }
```

*   **POST `/api/system/reload`**
    *   **Описание**: Мягкая перезагрузка Astra.
    *   **Ответ**: `{"status": "ok", "timestamp": 1704312345, "message": "Astra reload scheduled..."}`.

*   **POST `/api/system/exit`**
    *   **Описание**: Завершение процесса Astra.
    *   **Ответ**: `{"status": "ok", "timestamp": 1704312345, "message": "Astra exit scheduled..."}`.

*   **POST `/api/system/clear-cache`**
    *   **Описание**: Очистка кэша системных метрик.
    *   **Ответ**: `{"status": "ok", "timestamp": 1704312345, "message": "Cache cleared"}`.

## Конфигурация (`monitor_config.lua`):

*   `ChannelMonitorLimit`: Лимит активных мониторов (по умолчанию 200).
*   `LogLevel`: Уровень логирования (`DEBUG`, `INFO`, `WARN`, `ERROR`).
*   `HttpTimeout`: Таймаут для Push-уведомлений (10 сек).
*   `ValidationSchema`: Строгие правила валидации для всех входящих параметров API.

---
**Примечание**: Для полноценной работы библиотека требует наличия следующих глобальных функций и переменных:
*   **Astra (глобальные функции и переменные, напрямую используемые `lib-monitor`)**:
    *   `astra.version`: Переменная, содержащая версию Astra.
    *   `astra.reload()`: Функция для перезагрузки Astra.
    *   `astra.exit()`: Функция для завершения работы.
    *   `utils.hostname()`: Функция для получения имени хоста.
    *   `log.info()`, `log.error()`, `log.debug()`: Функции для вывода сообщений в лог.
    *   `http_request()`: Функция для выполнения HTTP-запросов.
    *   `find_channel()`: Функция для поиска канала по имени.
    *   `make_channel()`: Функция для создания нового канала.
    *   `kill_channel()`: Функция для остановки и удаления канала.
    *   `parse_url()`: Функция для парсинга URL-адресов.
    *   `init_input()`: Функция для инициализации входного модуля.
    *   `http_server()`: Функция для запуска HTTP-сервера.
    *   `string.split()`: Функция для разделения строки на подстроки.
    *   `dvb_tune()`: Функция для настройки DVB-тюнера.
    *   `analyze()`: Функция для анализа потока.
    *   `kill_input()`: Функция для остановки входного потока.
    *   `timer()`: Функция для создания таймеров.
    *   `dvb_input_instance_list`: Глобальный список инстансов DVB.
*   **Стандартные Lua функции и переменные (напрямую используемые `lib-monitor`)**:
    *   `type()`, `tostring()`, `tonumber()`, `pcall()`, `setmetatable()`, `collectgarbage()`.
    *   `string.format()`, `string.match()`, `string.lower()`, `string.gsub()`, `string.gmatch()`.
    *   `math.max()`, `math.abs()`.
    *   `ipairs()`, `pairs()`.
    *   `table.insert()`, `table.remove()`, `table.concat()`.
    *   `os.time()`, `os.date()`, `os.getenv()`.
    *   `io.popen()`, `io.open()`.
*   **Внешние библиотеки Lua**:
    *   `socket.core`: Для сетевых операций.
    *   `json.decode()`, `json.encode()`: Для работы с JSON.
