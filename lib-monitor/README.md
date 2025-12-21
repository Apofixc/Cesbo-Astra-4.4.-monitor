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

*   **GET `/api/channels/monitors`**
    *   **Описание**: Получает список активных мониторов каналов.
    *   **Ответ**: JSON-массив имен мониторов каналов. `HTTP 200 OK` или `401 Unauthorized` / `500 Internal Server Error`.

*   **GET `/api/channels/monitors/data`**
    *   **Описание**: Получает данные монитора канала.
    *   **Параметры (Query String)**:
        *   `channel` (string, **обязательно**): Имя канала.
    *   **Ответ**: JSON-объект со статусом монитора. `HTTP 200 OK` или `400 Bad Request` / `401 Unauthorized` / `404 Not Found`.

*   **GET `/api/channels/psi`**
    *   **Описание**: Получает данные PSI канала.
    *   **Параметры (Query String)**:
        *   `channel` (string, **обязательно**): Имя канала.
    *   **Ответ**: JSON-объект с данными PSI. `HTTP 200 OK` или `400 Bad Request` / `401 Unauthorized` / `404 Not Found` / `500 Internal Server Error`.

### DVB Routes (`/api/dvb`)

*   **GET `/api/dvb/adapters`**
    *   **Описание**: Получает список DVB-адаптеров.
    *   **Ответ**: JSON-массив имен адаптеров. `HTTP 200 OK` или `401 Unauthorized` / `500 Internal Server Error`.

*   **GET `/api/dvb/adapters/data`**
    *   **Описание**: Получает данные DVB-адаптера.
    *   **Параметры (Query String)**:
        *   `name_adapter` (string, **обязательно**): Имя адаптера.
    *   **Ответ**: JSON-объект со статусом DVB-адаптера. `HTTP 200 OK` или `400 Bad Request` / `401 Unauthorized` / `404 Not Found`.

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

*   **GET `/api/system/resources`**
    *   **Описание**: Получает данные о системных ресурсах (CPU, RAM, Disk I/O, Network I/O).
    *   **Ответ**: JSON-объект с данными о системных ресурсах. `HTTP 200 OK` или `401 Unauthorized` / `500 Internal Server Error`.

*   **GET `/api/system/monitor-stats`**
    *   **Описание**: Получает статистику работы ResourceMonitor.
    *   **Ответ**: JSON-объект со статистикой работы монитора ресурсов. `HTTP 200 OK` или `401 Unauthorized` / `501 Not Implemented` / `500 Internal Server Error`.

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
-- Пример инициализации монитора DVB-тюнера
local dvb_config = {
    name = "dvb0",
    adapter = 0,
    type = "DVB-S",
    frequency = 11747000,
    symbolrate = 27500,
    polarization = "H",
    fec = "3/4"
}
local dvb_monitor = require("lib-monitor.dispatcher.dvb_monitor_manager").dvb_tuner_monitor(dvb_config)

-- Пример создания монитора канала
local channel_data = {
    name = "Channel1",
    input = "udp://239.1.1.1:1234",
    output = "udp://239.1.1.2:1234"
}
local monitor_config = {
    name = "Channel1_Monitor",
    type = "input",
    bitrate_tolerance = 0.1,
    check_interval = 5
}
local channel_monitor = require("lib-monitor.dispatcher.channel_monitor_manager").make_monitor(monitor_config, channel_data)

-- Пример отправки данных мониторинга
local monitor_data = {
    timestamp = os.time(),
    channel = "Channel1",
    status = "OK",
    bitrate = 10000
}
require("lib-monitor.http.http_server").send_monitor(monitor_data, "default")
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
