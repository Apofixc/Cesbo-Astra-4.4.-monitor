# lib-monitor

`lib-monitor` — это библиотека Lua, предназначенная для мониторинга DVB-тюнеров и потоков каналов в рамках системы Astra. Она предоставляет набор функций для управления и отслеживания состояния различных компонентов мониторинга.

## Основные возможности:

*   **Мониторинг DVB-тюнеров**: Инициализация, запуск, обновление параметров и получение статуса DVB-тюнеров.
*   **Мониторинг каналов**: Создание, обновление, поиск и удаление мониторов для потоков каналов.
*   **Управление адресами мониторинга**: Установка и удаление адресов для отправки данных мониторинга клиентам.
*   **Отправка данных мониторинга**: Функция для отправки собранных данных на настроенные адреса.
*   **Валидация параметров**: Встроенные функции для валидации имен и параметров мониторов.
*   **Получение имени сервера**: Возможность получить имя хоста, на котором запущен монитор.
*   **Гибкая конфигурация**: Поддержка различных типов мониторов (входной, выходной, IP) и настраиваемых параметров, таких как погрешность битрейта, интервалы проверки и методы сравнения.
*   **Интеграция с Astra**: Использует глобальные функции Astra для управления каналами и потоками.
*   **Логирование**: Интегрированное логирование для отслеживания операций и ошибок.
*   **HTTP API**: Полноценный REST API для управления мониторами, каналами и получения статистики.

## Структура проекта:

```
lib-monitor/
├── init_monitor.lua
├── README.md
├── adapters/
│   ├── adapter.lua
│   ├── dvb_tuner.lua
│   └── resource_adapter.lua
├── channel/
│   ├── channel_monitor.lua
│   └── channel.lua
├── config/
│   ├── monitor_config.lua
│   └── monitor_settings.lua
├── dispatcher/
│   ├── channel_monitor_manager.lua
│   └── dvb_monitor_manager.lua
├── http/
│   ├── http_helpers.lua
│   ├── http_server.lua
│   └── routes/
│       ├── channel_routes.lua
│       ├── dvb_routes.lua
│       └── system_routes.lua
└── utils/
    ├── logger.lua
    └── utils.lua
```

*   `init_monitor.lua`: Точка входа для инициализации и загрузки всех необходимых компонентов библиотеки.
*   `adapters/`: Содержит модули, отвечающие за взаимодействие с различными аппаратными и программными адаптерами.
    *   `adapter.lua`: Предоставляет интерфейс для управления DVB-тюнерами.
    *   `dvb_tuner.lua`: Класс для мониторинга DVB-тюнеров.
    *   `resource_adapter.lua`: Менеджер для мониторинга системных ресурсов.
*   `channel/`: Включает модули для управления жизненным циклом каналов и их мониторингом.
    *   `channel.lua`: Основные операции с каналами.
    *   `channel_monitor.lua`: Логика мониторинга каналов.
*   `config/`: Хранит файлы конфигурации, определяющие параметры работы мониторов.
    *   `monitor_config.lua`: Конфигурация мониторов.
    *   `monitor_settings.lua`: Настройки мониторов.
*   `dispatcher/`: Содержит менеджеры, которые координируют работу различных типов мониторов.
    *   `channel_monitor_manager.lua`: Менеджер для мониторов каналов.
    *   `dvb_monitor_manager.lua`: Менеджер для DVB-мониторов.
*   `http/`: Модули для создания и управления HTTP-сервером.
    *   `http_helpers.lua`: Вспомогательные функции для HTTP.
    *   `http_server.lua`: Реализация HTTP-сервера.
    *   `routes/`: Определения маршрутов HTTP API.
        *   `channel_routes.lua`: Маршруты для управления каналами.
        *   `dvb_routes.lua`: Маршруты для управления DVB-тюнерами.
        *   `system_routes.lua`: Маршруты для системной информации.
*   `utils/`: Вспомогательные утилиты.
    *   `logger.lua`: Модуль логирования.
    *   `utils.lua`: Общие вспомогательные функции.

## Документация Astra:

Для получения подробной информации о функциях Astra, используемых в этой библиотеке, обратитесь к официальной документации: [https://cdn.cesbo.com/astra/4.4.182-free](https://cdn.cesbo.com/astra/4.4.182-free)

## Установка:

Для использования `lib-monitor` необходимо скопировать содержимое репозитория в директорию `lib-monitor` вашего проекта Astra. Убедитесь, что все зависимости Lua установлены и доступны.

## Использование:

Библиотека предназначена для использования в проектах, требующих детального мониторинга DVB-тюнеров и потоков каналов. Ниже приведены основные функции, доступные для использования конечными пользователями:

### Функции для инициализации и управления сервером:

*   `server_start(addr, port)`: Запускает HTTP-сервер мониторинга.

### Функции для DVB-мониторинга:

*   `dvb_tuner_monitor(conf)`: Инициализация и запуск мониторинга DVB-тюнера. Параметр `conf` должен содержать конфигурацию тюнера.
*   `update_dvb_monitor_parameters(name_adapter, params)`: Обновление параметров существующего монитора DVB-тюнера по его имени.

### Функции для мониторинга каналов:

*   `make_monitor(config, channel_data)`: Создание и регистрация нового монитора канала. `config` определяет тип и параметры монитора, `channel_data` - данные о канале.
*   `make_stream(conf)`: Создание и запуск потока с мониторингом. `conf` содержит параметры потока.
*   `update_monitor_parameters(name, params)`: Обновление параметров существующего монитора канала по его имени.
*   `kill_monitor(monitor_obj)`: Остановка и удаление монитора.
*   `kill_stream(channel_data)`: Остановка потока и связанного с ним монитора.

### Функции для управления данными мониторинга (клиентские):

*   `set_client_monitoring(host, port, path, feed)`: Устанавливает или переопределяет адрес мониторинга для клиентов.
*   `remove_client_monitoring(host, port, path, feed)`: Удаляет конкретный адрес мониторинга для клиента.

### Инициализация HTTP-сервера:

Для запуска HTTP-сервера мониторинга используйте функцию:

*   `server_start(addr, port)`: Запускает HTTP-сервер по указанному IP-адресу (`addr`) и порту (`port`).

Все остальные операции по управлению мониторингом DVB-тюнеров, каналов и системными ресурсами осуществляются через HTTP API-эндпоинты, описанные в следующем разделе.

## API Endpoints:

Все API-запросы требуют аутентификации с помощью заголовка `X-Api-Key`. Значение ключа устанавливается через переменную окружения `ASTRA_API_KEY` (по умолчанию "test").

### Channel Routes (`/api/channels`)

*   **POST `/api/channels/streams/kill`**
    *   **Описание**: Останавливает или перезагружает поток.
    *   **Параметры (JSON или Query String)**:
        *   `channel` (string, **обязательно**): Имя потока.
        *   `reboot` (boolean, опционально): `true` для перезагрузки потока после остановки.
        *   `delay` (number, опционально): Задержка в секундах перед перезагрузкой (по умолчанию 30).
    *   **Ответ**: `HTTP 200 OK` или `400 Bad Request` / `401 Unauthorized` / `404 Not Found`.

*   **POST `/api/channels/kill`**
    *   **Описание**: Останавливает или перезагружает канал.
    *   **Параметры (JSON или Query String)**:
        *   `channel` (string, **обязательно**): Имя канала.
        *   `reboot` (boolean, опционально): `true` для перезагрузки канала после остановки.
        *   `delay` (number, опционально): Задержка в секундах перед перезагрузкой (по умолчанию 30).
    *   **Ответ**: `HTTP 200 OK` или `400 Bad Request` / `401 Unauthorized` / `404 Not Found`.

*   **POST `/api/channels/monitors/kill`**
    *   **Описание**: Останавливает или перезагружает монитор канала.
    *   **Параметры (JSON или Query String)**:
        *   `channel` (string, **обязательно**): Имя монитора канала.
        *   `reboot` (boolean, опционально): `true` для перезагрузки монитора канала после остановки.
        *   `delay` (number, опционально): Задержка в секундах перед перезагрузкой (по умолчанию 30).
    *   **Ответ**: `HTTP 200 OK` или `400 Bad Request` / `401 Unauthorized` / `404 Not Found`.

*   **POST `/api/channels/monitors/update`**
    *   **Описание**: Обновляет параметры монитора канала.
    *   **Параметры (JSON или Query String)**:
        *   `channel` (string, **обязательно**): Имя канала.
        *   `analyze` (boolean, опционально): Включить/отключить расширенную информацию об ошибках потока.
        *   `time_check` (number, опционально): Новый интервал проверки данных (от 0 до 300).
        *   `rate` (number, опционально): Новое значение погрешности сравнения битрейта (от 0.001 до 0.3).
        *   `method_comparison` (number, опционально): Новый метод сравнения состояния потока (от 1 до 4).
    *   **Ответ**: `HTTP 200 OK` или `400 Bad Request` / `401 Unauthorized`.

*   **GET `/api/channels`**
    *   **Описание**: Получает список всех каналов.
    *   **Ответ**: JSON-массив имен каналов. `HTTP 200 OK` или `401 Unauthorized` / `500 Internal Server Error`.

```json
        [
          "Channel_1",
          "Channel_2",
          "Channel_3",
          "Discovery",
          "National_Geographic"
        ]
```

*   **GET `/api/channels/monitors`**
    *   **Описание**: Получает список активных мониторов каналов.
    *   **Ответ**: JSON-массив имен мониторов каналов. `HTTP 200 OK` или `401 Unauthorized` / `500 Internal Server Error`.

```json
        [
          "Channel_1_Monitor",
          "Channel_2_Monitor",
          "Discovery_Monitor"
        ]
```

*   **GET `/api/channels/monitors/data`**
    *   **Описание**: Получает данные монитора канала.
    *   **Параметры (Query String)**:
        *   `channel` (string, **обязательно**): Имя канала.
    *   **Ответ**: JSON-объект со статусом монитора. `HTTP 200 OK` или `400 Bad Request` / `401 Unauthorized` / `404 Not Found`.

```json
        {
          "type": "Channel",
          "server": "astra-server-01",
          "channel": "Discovery",
          "output": "udp://239.255.0.1:1234",
          "stream": "31.130.202.110/httpts/tv3by/avchigh.ts",
          "format": "udp",
          "addr": "192.168.1.100@239.255.0.1:1234",
          "ready": true,
          "scrambled": false,
          "bitrate": 12500,
          "cc_errors": 0,
          "pes_errors": 0
        }
```

*   **GET `/api/channels/psi`**
    *   **Описание**: Получает данные PSI канала.
    *   **Параметры (Query String)**:
        *   `channel` (string, **обязательно**): Имя канала.
    *   **Ответ**: JSON-объект с данными PSI. `HTTP 200 OK` или `400 Bad Request` / `401 Unauthorized` / `404 Not Found` / `500 Internal Server Error`.

```json
        {
          "pmt": {
            "pid": 256,
            "table_id": 2,
            "section_length": 45,
            "program_number": 1001,
            "version_number": 5,
            "current_next_indicator": 1,
            "section_number": 0,
            "last_section_number": 0,
            "pcr_pid": 256,
            "program_info_length": 0,
            "streams": [
              {
                "stream_type": 27,
                "elementary_pid": 256,
                "es_info_length": 0
              },
              {
                "stream_type": 3,
                "elementary_pid": 257,
                "es_info_length": 0
              }
            ]
          },
          "sdt": {
            "pid": 17,
            "table_id": 66,
            "section_length": 78,
            "transport_stream_id": 1001,
            "version_number": 3,
            "current_next_indicator": 1,
            "section_number": 0,
            "last_section_number": 0,
            "original_network_id": 1,
            "services": [
              {
                "service_id": 1001,
                "eit_schedule_flag": 1,
                "eit_present_following_flag": 1,
                "running_status": 4,
                "free_ca_mode": 0,
                "descriptors_loop_length": 32
              }
            ]
          }
        }
```

### DVB Routes (`/api/dvb`)

*   **GET `/api/dvb/adapters`**
    *   **Описание**: Получает список DVB-адаптеров.
    *   **Ответ**: JSON-массив имен адаптеров. `HTTP 200 OK` или `401 Unauthorized` / `500 Internal Server Error`.

```json
        [
          "dvb0",
          "dvb1",
          "dvb2_T",
          "dvb3_S",
          "dvb4_C"
        ]
```

*   **GET `/api/dvb/adapters/data`**
    *   **Описание**: Получает данные DVB-адаптера.
    *   **Параметры (Query String)**:
        *   `name_adapter` (string, **обязательно**): Имя адаптера.
    *   **Ответ**: JSON-объект со статусом DVB-адаптера. `HTTP 200 OK` или `400 Bad Request` / `401 Unauthorized` / `404 Not Found`.

```json
        {
          "type": "dvb",
          "server": "astra-server-01",
          "format": "T",
          "modulation": "QAM256",
          "source": "474000000",
          "name_adapter": "dvb0",
          "status": 1,
          "signal": 75.5,
          "snr": 24.8,
          "ber": 2.1e-7,
          "unc": 0
        }
```

*   **POST `/api/dvb/adapters/monitors/update`**
    *   **Описание**: Обновляет параметры DVB-монитора.
    *   **Параметры (JSON или Query String)**:
        *   `name_adapter` (string, **обязательно**): Имя адаптера.
        *   `time_check` (number, опционально): Новый интервал проверки в секундах (неотрицательное число).
        *   `rate` (number, опционально): Новое значение допустимой погрешности (от 0.001 до 1).
    *   **Ответ**: `HTTP 200 OK` или `400 Bad Request` / `401 Unauthorized`.

### System Routes (`/api/system`)

*   **POST `/api/system/reload`**
    *   **Описание**: Перезагружает Astra.
    *   **Параметры (JSON или Query String)**:
        *   `delay` (number, опционально): Задержка в секундах перед перезагрузкой (по умолчанию 30).
    *   **Ответ**: `HTTP 200 OK` или `401 Unauthorized`.

*   **POST `/api/system/exit`**
    *   **Описание**: Останавливает Astra.
    *   **Параметры (JSON или Query String)**:
        *   `delay` (number, опционально): Задержка в секундах перед остановкой (по умолчанию 30).
    *   **Ответ**: `HTTP 200 OK` или `401 Unauthorized`.

*   **GET `/api/system/health`**
    *   **Описание**: Проверяет состояние сервера.
    *   **Ответ**: JSON-объект с информацией о сервере, версии Astra и данных о ресурсах процесса. `HTTP 200 OK` или `401 Unauthorized` / `500 Internal Server Error`.

```json
        {
          "addr": "0.0.0.0",
          "port": 8080,
          "version": "Astra 1.0.0",
          "timestamp": "2024-01-15 14:30:00",
          "process": {
            "pid": 12345,
            "cpu_usage_percent": 12.5,
            "memory_usage_mb": 256.7,
            "memory_usage_kb": 262809
          }
        }
```

*   **GET `/api/system/resources`**
    *   **Описание**: Получает данные о системных ресурсах (CPU, RAM, Disk I/O, Network I/O).
    *   **Ответ**: JSON-объект с данными о системных ресурсах. `HTTP 200 OK` или `401 Unauthorized` / `500 Internal Server Error`.

```json
        {
          "timestamp": "2024-01-15 14:30:00",
          "system": {
            "cpu": {
              "usage_percent": 24.7,
              "cores": 8
            },
            "memory": {
              "total_mb": 16384,
              "used_mb": 8192,
              "free_mb": 8192,
              "usage_percent": 50.0
            },
            "disk": {
              "usage_percent": 65.3,
              "total_gb": 1024.0,
              "used_gb": 668.7,
              "free_gb": 355.3
            },
            "network": {
              "interfaces": [
                {
                  "name": "eth0",
                  "rx_bytes_per_sec": 1250000,
                  "tx_bytes_per_sec": 750000,
                  "rx_bytes_total": 107374182400,
                  "tx_bytes_total": 53687091200
                },
                {
                  "name": "eth1",
                  "rx_bytes_per_sec": 500000,
                  "tx_bytes_per_sec": 250000,
                  "rx_bytes_total": 21474836480,
                  "tx_bytes_total": 10737418240
                }
              ],
              "total_rx_bytes_per_sec": 1750000,
              "total_tx_bytes_per_sec": 1000000
            }
          }
        }
```

*   **GET `/api/system/monitor-stats`**
    *   **Описание**: Получает статистику работы ResourceMonitor.
    *   **Ответ**: JSON-объект со статистикой работы монитора ресурсов. `HTTP 200 OK` или `401 Unauthorized` / `501 Not Implemented` / `500 Internal Server Error`.

```json
        {
          "name": "system_monitor",
          "pid": 12345,
          "collections": 1500,
          "last_reset": "2024-01-15 12:00:00",
          "cache_hits": 1350,
          "cache_interval": 2
        }
```

*   **POST `/api/system/clear-cache`**
    *   **Описание**: Очищает кэш ResourceMonitor.
    *   **Ответ**: `HTTP 200 OK` или `401 Unauthorized` / `501 Not Implemented` / `500 Internal Server Error`.

*   **POST `/api/system/set-cache-interval`**
    *   **Описание**: Устанавливает интервал кэширования ResourceMonitor.
    *   **Параметры (JSON или Query String)**:
        *   `interval` (number, **обязательно**): Новый интервал кэширования в секундах (неотрицательное число).
    *   **Ответ**: `HTTP 200 OK` или `400 Bad Request` / `401 Unauthorized` / `501 Not Implemented` / `500 Internal Server Error`.

## Пример использования:

```lua
local dvb_config = {
    -- Стандартные параметры
    ------------------------
    ------------------------
    ------------------------
    -- Новые параметры
    name_adapter = "dvb0", -- Имя адаптера (обязательно).
    time_check = 10, -- Интервал проверки в секундах (по умолчанию 10).
    rate = 0.015, -- Допустимая погрешность для сравнения параметров (по умолчанию 0.015).
    method_comparison = 3 -- Метод сравнения параметров (1, 2 или 3, по умолчанию 3).
}
local dvb_monitor = require("lib-monitor.dispatcher.dvb_monitor_manager").dvb_tuner_monitor(dvb_config)

-- Пример создания стрима
local channel_data = {
    name = "Channel1",
    input = "udp://239.1.1.1:1234",
    output = "udp://239.1.1.2:1234"
    monitor = {
        name  = "Monitor1", -- Имя монитора (по умолчанию совпадает с именем потока).
        monitor_type = "output", -- Тип монитора ("input", "output", "ip", по умолчанию "output").
        rate = 0.03,  -- Погрешность сравнения битрейта.
        time_check = 0,-- Время до сравнения данных.
        analyze = false, -- Включить/отключить расширенную информацию об ошибках.
        method_comparison = 3, -- Метод сравнения состояния потока.
    }
}
local channel_stream = require("lib-monitor.dispatcher.channel_monitor_manager").make_stream(channel_data)

-- Пример создания монитора
local channel_data = {
    name = "Channel1",
    input = "udp://239.1.1.1:1234",
    output = "udp://239.1.1.2:1234"
}
local channel_data = make_channel({.........})
local monitor = {
    name  = "Monitor1", -- Имя монитора (по умолчанию совпадает с именем потока).
    monitor_type = "output", -- Тип монитора ("input", "output", "ip", по умолчанию "output").
    rate = 0.03,  -- Погрешность сравнения битрейта.
    time_check = 0,-- Время до сравнения данных.
    analyze = false, -- Включить/отключить расширенную информацию об ошибках.
    method_comparison = 3, -- Метод сравнения состояния потока.
}
local channel_monitor = require("lib-monitor.dispatcher.channel_monitor_manager").make_monitor(monitor_config, channel_data)
```

---
**Примечание**: Для полноценной работы библиотека требует наличия следующих глобальных функций и переменных:
*   **Astra (глобальные функции и переменные, напрямую используемые `lib-monitor`)**:
    *   `astra.version`: Переменная, содержащая версию Astra.
    *   `utils.hostname()`: Функция для получения имени хоста.
    *   `log.info()`, `log.error()`, `log.debug()`: Функции для вывода информационных, ошибочных и отладочных сообщений в лог.
    *   `http_request()`: Функция для выполнения HTTP-запросов.
    *   `find_channel()`: Функция для поиска канала по имени.
    *   `make_channel()`: Функция для создания нового канала.
    *   `kill_channel()`: Функция для остановки и удаления канала.
    *   `parse_url()`: Функция для парсинга URL-адресов.
    *   `init_input()`: Функция для инициализации входного модуля.
    *   `http_server()`: Функция для запуска HTTP-сервера.
    *   `string.split()`: Функция для разделения строки на подстроки (из `utils.utils`).
    *   `dvb_tune()`: Функция для настройки DVB-тюнера.
    *   `analyze()`: Функция для анализа потока.
    *   `kill_input()`: Функция для остановки входного потока.
    *   `timer()`: Функция для создания таймеров.
    *   `os.exit()`: Функция для завершения работы скрипта.
    *   `astra.reload()`: Функция для перезагрузки Astra.
*   **Стандартные Lua функции и переменные (напрямую используемые `lib-monitor`)**:
    *   `type()`: Функция для получения типа переменной.
    *   `tostring()`: Функция для преобразования значения в строку.
    *   `string.format()`: Функция для форматирования строк.
    *   `math.max()`, `math.abs()`: Функции для математических операций.
    *   `ipairs()`, `pairs()`: Функции для итерации по таблицам.
    *   `table.insert()`, `table.remove()`, `table.concat()`: Функции для работы с таблицами.
    *   `string.match()`, `string.lower()`, `string.find()`, `string.sub()`, `string.gsub()`, `string.gmatch()`: Функции для работы со строками.
    *   `pcall()`: Функция для защищенного вызова функции.
    *   `os.time()`, `os.date()`, `os.getenv()`: Функции для работы со временем и переменными окружения.
    *   `tonumber()`: Функция для преобразования значения в число.
    *   `io.popen()`, `io.open()`: Функции для работы с файлами и выполнения команд.
*   **Внешние библиотеки Lua**:
    *   `socket.core`: Для сетевых операций.
    *   `json.decode()`, `json.encode()`: Для работы с JSON.
