# lib-monitor

`lib-monitor` — это высокопроизводительная библиотека Lua для Astra (Cesbo), предназначенная для глубокого мониторинга DVB-тюнеров, потоков каналов и системных ресурсов. Библиотека предоставляет программный интерфейс для автоматизации внутри Astra и полноценный HTTP REST API для интеграции с внешними панелями управления и системами мониторинга (Zabbix, Grafana и др.).

## Содержание
*   [Основные возможности](#основные-возможности)
*   [Структура проекта](#структура-проекта)
*   [Архитектура и принципы разработки](#архитектура-и-принципы-разработки)
*   [Обработка ошибок и логирование](#обработка-ошибок-и-логирование)
*   [Тестирование](#тестирование)
*   [Разработка и стандарты](#разработка-и-стандарты)
*   [Установка и использование](#установка)
*   [Методы получения данных (Pull/Push)](#методы-получения-данных-мониторинга)
*   [API Endpoints](#api-endpoints)
*   [Параметры конфигурации](#параметры-конфигурации-мониторов)

## Основные возможности:

*   **Мониторинг DVB-тюнеров**: Инициализация, запуск, динамическая перенастройка (TP), получение детальных метрик (Signal, SNR, BER, UNC) и расчет интегрального показателя качества (Quality). Поддержка побитового анализа статуса адаптера (Lock, Signal, Carrier и др.) через `bit32`. Автоматическое управление счетчиком каналов Astra для совместного использования адаптеров.
*   **Мониторинг каналов**: Создание, обновление, поиск и удаление мониторов для потоков каналов. Поддержка различных типов мониторов: `input` (вход), `output` (выход канала) и `ip` (прямой мониторинг UDP/RTP).
*   **Объектно-ориентированный подход**: Каждый монитор является экземпляром класса (`DvbTuner`, `ChannelMonitor`) с собственным состоянием и методами управления.
*   **Система подписок (Webhooks)**: Автоматическая отправка данных мониторинга на настроенные адреса при изменении состояния объектов.
*   **Мониторинг системных ресурсов**: Сбор метрик CPU, RAM, Disk, Network с высоким разрешением.
*   **Полноценный REST API**: Более 40 эндпоинтов для полного управления системой мониторинга.
*   **Гибкая конфигурация**: Настраиваемые параметры мониторинга, включая пороги сравнения, интервалы проверки и методы анализа.
*   **Безопасность**: Аутентификация по API-ключу для всех HTTP-запросов.

## Структура проекта:

```
lib-monitor/
├── init_monitor.lua        # Точка входа. Инициализирует модули и экспортирует функции в _G.
├── README.md               # Данная документация.
├── config.json             # Внешний файл конфигурации (JSON).
├── subscribers.json        # Постоянное хранилище активных HTTP-подписок.
├── http/                   # Слой HTTP-сервера.
│   ├── http_server.lua     # Ядро сервера (маршрутизация запросов).
│   ├── http_helpers.lua    # Утилиты (Auth, JSON-ответы, валидация заголовков).
│   └── routes/             # Обработчики API (маршруты).
│       ├── channel_routes.lua    # Маршруты для управления каналами.
│       ├── dvb_routes.lua        # Маршруты для управления DVB-тюнерами.
│       ├── monitor_routes.lua    # Маршруты для общего управления мониторами.
│       ├── subscriber_routes.lua # Маршруты для управления подписками.
│       ├── system_routes.lua     # Маршруты для системной информации.
│       └── routes_utils.lua      # Вспомогательные утилитарные маршруты.
├── src/                     # Исходный код бизнес-логики.
│   ├── core/                # Ядро системы (базовые классы).
│   │   ├── module_manager.lua # Управление жизненным циклом модулей и зависимостями.
│   │   ├── base_monitor.lua # Базовый класс для всех мониторов.
│   │   └── base_repository.lua # Базовый класс для всех репозиториев.
│   ├── adapters/            # Работа с DVB оборудованием.
│   │   ├── adapter.lua      # Высокоуровневый интерфейс управления тюнерами.
│   │   └── dvb_tuner.lua    # Класс для мониторинга DVB-тюнера.
│   ├── channel/             # Мониторинг потоков.
│   │   ├── channel.lua      # Высокоуровневый интерфейс управления каналами.
│   │   └── channel_monitor.lua # Класс для мониторинга канала.
│   ├── repository/         # Хранилища (Repository) активных экземпляров объектов.
│   │   ├── channel_repository.lua # Хранилище мониторов каналов.
│   │   └── dvb_repository.lua     # Хранилище DVB-мониторов.
│   ├── system/             # Сбор системных метрик.
│   │   └── resource_monitor.lua # Мониторинг CPU, RAM, Network, IO.
│   ├── config/             # Конфигурация и схемы валидации.
│   │   └── monitor_config.lua  # Основной файл настроек.
│   └── utils/              # Вспомогательные утилиты.
│       ├── logger.lua      # Модуль логирования с поддержкой контекста.
│       ├── utils.lua       # Общие вспомогательные функции.
│       └── http_subscriber.lua # Модуль для работы с Webhooks.
└── test/                   # Набор тестов (интеграционные, юнит-тесты).
```

*   `init_monitor.lua`: Точка входа для инициализации и загрузки всех необходимых компонентов библиотеки.
*   `src/adapters/`: Содержит модули, отвечающие за взаимодействие с различными аппаратными и программными адаптерами.
    *   `adapter.lua`: Предоставляет интерфейс для управления DVB-тюнерами.
    *   `dvb_tuner.lua`: Класс для мониторинга DVB-тюнеров.
*   `src/system/`: Содержит модули, отвечающие за мониторинг системных ресурсов.
    *   `resource_monitor.lua`: Менеджер для мониторинга системных ресурсов.
*   `src/channel/`: Включает модули для управления жизненным циклом каналов и их мониторингом.
    *   `channel.lua`: Основные операции с каналами.
    *   `channel_monitor.lua`: Логика мониторинга каналов.
*   `src/config/`: Хранит файлы конфигурации, определяющие параметры работы мониторов.
    *   `monitor_config.lua`: Конфигурация мониторов и схемы валидации.
*   `src/core/`: Содержит базовые абстракции и ядро системы.
    *   `base_monitor.lua`: Базовый класс для всех мониторов (DVB, Channel).
    *   `base_repository.lua`: Базовый класс для всех репозиториев.
*   `src/repository/`: Содержит менеджеры (Repository), которые координируют работу различных типов мониторов.
    *   `channel_repository.lua`: Менеджер для мониторов каналов.
    *   `dvb_repository.lua`: Менеджер для DVB-мониторов.
*   `http/`: Модули для создания и управления HTTP-сервером.
    *   `http_helpers.lua`: Вспомогательные функции для HTTP.
    *   `http_server.lua`: Реализация HTTP-сервера.
    *   `routes/`: Определения маршрутов HTTP API.
        *   `channel_routes.lua`: Маршруты для управления каналами.
        *   `dvb_routes.lua`: Маршруты для управления DVB-тюнерами.
        *   `monitor_routes.lua`: Маршруты для общего управления мониторами.
        *   `subscriber_routes.lua`: Маршруты для управления подписками.
        *   `system_routes.lua`: Маршруты для системной информации.
*   `src/utils/`: Вспомогательные утилиты.
    *   `logger.lua`: Модуль логирования.
    *   `utils.lua`: Общие вспомогательные функции.
    *   `http_subscriber.lua`: Модуль для работы с HTTP-подписками (Webhooks).

## Архитектура и принципы разработки

Библиотека построена на принципах модульности и объектно-ориентированного программирования:

1.  **Классы мониторов**: Реализуют логику конкретных экземпляров (`DvbTuner`, `ChannelMonitor`). Каждый объект инкапсулирует свое состояние, таймеры и callback-функции Astra.
2.  **Хранилища экземпляров (Repository)**: Специализированные модули (`DvbRepository`, `ChannelRepository`) для регистрации, поиска и централизованного управления жизненным циклом объектов.
3.  **Модули управления (API)**: Высокоуровневые модули (`adapter.lua`, `channel.lua`), предоставляющие упрощенный интерфейс для создания и манипуляции мониторами.

### Жизненный цикл монитора
*   **Инициализация**: Создание объекта через метод `new(config)`. Все параметры валидируются при создании.
*   **Запуск**: Метод `start()` инициализирует соответствующие модули Astra (dvb_tune, analyze) и запускает мониторинг.
*   **Очистка ресурсов**: Метод `destroy()` гарантирует корректное закрытие всех ресурсов Astra, обнуление callback-ов и остановку таймеров, что предотвращает утечки памяти.

## Обработка ошибок и логирование

В `lib-monitor` реализован единообразный подход к обработке ошибок и логированию:

*   **Возврат значений**: Функции бизнес-логики возвращают данные или `true` при успехе, и `nil` или `false` при ошибке. Текст ошибки никогда не возвращается напрямую.
*   **Logger.error**: Все ошибки записываются в лог через модуль `Logger`.
*   **Контекстное хранение**: Логгер поддерживает механизм `with_error`. Если функция вызывается через `Logger.with_error(func, ...)`, любая ошибка, возникшая внутри, автоматически сохраняется и может быть извлечена для передачи в HTTP-ответе. Это позволяет клиенту API получать понятное описание причины сбоя.

## Тестирование

Тесты библиотеки расположены в директории `test/` и разделены по функциональным зонам.

*   **Запуск тестов**: Для запуска интеграционных тестов используйте скрипт `tv3.lua` совместно с исполняемым файлом Astra:
    ```bash
    /opt/astra/astra4.4.182 /opt/tv3.lua
    ```
*   **Структура тестов**: При создании новых тестов следует придерживаться синтаксиса существующих примеров в `test/` и использовать официальные методы Astra для конфигурации адаптеров и каналов.

## Разработка и стандарты

*   **EmmyLua**: Весь код библиотеки документирован с использованием аннотаций EmmyLua (на русском языке). Это обеспечивает качественное автодополнение и проверку типов в современных IDE.
*   **Astra Core Reference**: При разработке и модификации библиотеки в качестве эталона используется исходный код Astra (Cesbo Astra), расположенный в `/opt/astra/cesbo-astra/`. Это гарантирует совместимость с ядром системы.

## Документация Astra:

Для получения подробной информации о функциях Astra, используемых в этой библиотеке, обратитесь к официальной документации: [https://cdn.cesbo.com/astra/4.4.182-free](https://cdn.cesbo.com/astra/4.4.182-free)

## Установка и использование

1.  **Копирование библиотеки**: Скопируйте содержимое репозитория в директорию `lib-monitor` вашего проекта Astra.

2.  **Подключение в скрипте**:
    ```lua
    require("lib-monitor.init_monitor")
    ```

3.  **Запуск HTTP-сервера**:
    ```lua
    server_start("0.0.0.0", 8080)
    ```

4.  **Настройка аутентификации**: Установите переменную окружения для API-ключа:
    ```bash
    export ASTRA_API_KEY="your_secret_key"
    ```

## Безопасность:

Все API-запросы требуют аутентификации с помощью заголовка `X-Api-Key`. Значение ключа устанавливается через переменную окружения `ASTRA_API_KEY`. Если переменная не задана, используется значение по умолчанию — `test`. Для продакшн-среды обязательно установите свой секретный ключ.

### Функции для инициализации и управления сервером:

*   `server_start(addr, port)`: Запускает HTTP-сервер мониторинга на указанном адресе и порту.

### Функции для DVB-мониторинга:

*   `dvb_tuner_monitor(conf)`: Инициализация и запуск мониторинга DVB-тюнера. Параметр `conf` должен содержать конфигурацию тюнера.
*   `update_dvb_monitor_parameters(name_adapter, params)`: Обновление параметров существующего монитора DVB-тюнера по его имени.
*   `pause_dvb_monitor(name_adapter)`: Приостановка мониторинга тюнера.
*   `resume_dvb_monitor(name_adapter)`: Возобновление мониторинга тюнера.
*   `switch_transponder(name_adapter, new_tuner_params, reserve_input)`: Сценарий переключения транспондера с сохранением выходов каналов.

### Функции для мониторинга каналов:

*   `make_monitor(config, channel_data)`: Создание и регистрация нового монитора канала. `config` определяет тип и параметры монитора, `channel_data` - данные о канале.
*   `make_stream(conf)`: Создание и запуск потока с мониторингом. `conf` содержит параметры потока.
*   `update_monitor_parameters(name, params)`: Обновление параметров существующего монитора канала по его имени.
*   `kill_monitor(name)`: Остановка и удаление монитора.
*   `kill_stream(name)`: Остановка потока и связанного с ним монитора.
*   `pause_monitor(name)`: Приостановка монитора.
*   `resume_monitor(name)`: Возобновление монитора.

### Функции для управления данными мониторинга (подписки):

*   `ModuleManager.get_module("http_subscriber").subscribe(event_type, addr)`: Программное добавление подписки.
*   `ModuleManager.get_module("http_subscriber").unsubscribe(event_type, addr)`: Программное удаление подписки.

### Продвинутое использование (ООП API):

Вы можете получить доступ к объектам мониторов напрямую через хранилища для использования специфических методов:
```lua
local DvbRepository = ModuleManager.get_module("dvb_repository")
local tuner = DvbRepository.find("dvb0")
if tuner then
    local status = tuner:get_full_status()
    tuner:psi_update() -- Запустить сбор PSI на 10 секунд
end
```

## Методы получения данных мониторинга:

Библиотека поддерживает два основных метода получения данных мониторинга:

### Pull-метод (через HTTP API)
Клиент отправляет HTTP GET-запросы к соответствующим API-эндпоинтам для получения актуальных данных. Подходит для периодического запроса информации по требованию.

### Push-метод (через подписку/Webhooks)
Клиент подписывается на получение данных мониторинга через API `/api/subscribers/subscribe`. Библиотека автоматически отправляет JSON-данные методом POST на настроенный адрес при изменении состояния объектов.

### Формат данных Webhooks

#### Событие `channels` (Мониторинг каналов)
```json
{
  "type": "Channel",
  "server": "astra-1",
  "channel": "Discovery",
  "display_name": "Discovery HD",
  "monitor": "output",
  "stream": "http://example.com/stream.ts",
  "format": "http",
  "addr": "example.com:80",
  "ready": true,
  "scrambled": false,
  "bitrate": 12500,
  "cc_errors": 0,
  "pes_errors": 0,
  "timestamp": 1673791200
}
```

#### Событие `dvb` (Мониторинг DVB-адаптеров)
```json
{
  "type": "dvb",
  "server": "astra-1",
  "format": "S2",
  "modulation": "QPSK",
  "source": "11044:V:43200",
  "name_adapter": "dvb0",
  "status": 31,
  "has_signal": true,
  "has_carrier": true,
  "has_viterbi": true,
  "has_sync": true,
  "has_lock": true,
  "signal": 75.5,
  "snr": 24.8,
  "ber": 0,
  "unc": 0,
  "quality": 100,
  "timestamp": 1673791200
}
```

#### Событие `error` (Критические ошибки потока)
```json
{
  "type": "Channel",
  "server": "astra-1",
  "channel": "Discovery",
  "display_name": "Discovery HD",
  "monitor": "output",
  "stream": "http://...",
  "format": "http",
  "addr": "...",
  "error": "Connection timeout",
  "timestamp": 1673791200
}
```

## API Endpoints:

Все API-запросы требуют аутентификации с помощью заголовка `X-Api-Key`. Значение ключа устанавливается через переменную окружения `ASTRA_API_KEY` (по умолчанию "test"). Все успешные ответы возвращаются с кодом `200 OK`. Ошибки возвращаются в формате JSON с описанием причины.

### Channel Routes (`/api/channels`)
Управление сырыми каналами Astra без автоматического мониторинга.

**GET `/api/channels`**
*   **Описание**: Возвращает список всех каналов с их адресами вещания.
*   **Реализация**: Использует `channel_list` из Astra и дополняет данными из `ChannelRepository`.
*   **JSON-ответ**:
```json
        [
          {
            "name": "Discovery",
            "display_name": "Discovery HD",
            "output": ["udp://239.255.1.1:1234"]
          }
        ]
```

**GET `/api/channels/stats`**
*   **Описание**: Возвращает агрегированную статистику по каналам.
*   **Реализация**: Анализирует `channel_list` и все активные мониторы из `ChannelRepository`.
*   **JSON-ответ**:
```json
        {
          "total_astra_channels": 50,
          "total_monitored": 10,
          "online": 8,
          "offline": 2,
          "with_errors": 1
        }
```

**GET `/api/channels/{name}`**
*   **Описание**: Возвращает детальную информацию о канале (конфигурацию Astra).
*   **Реализация**: Использует `find_channel` из Astra.
*   **JSON-ответ**: Полный конфиг канала (аналогично параметрам для `make_channel`)
```json
        {
          "name": "Discovery",
          "input": ["http://..."],
          "output": ["udp://..."],
          "map": "..."
        }
```

**DELETE `/api/channels/{name}`**
*   **Описание**: Удаляет или перезапускает канал (Raw Astra Channel).
*   **Параметры**: `reboot=true` для перезапуска.
*   **Реализация**: Использует `kill_channel` и при необходимости `make_channel` с задержкой.
*   **JSON-ответ**:
```json
        {
          "message": "Channel killed/rebooting",
          "config": { "name": "Discovery", "input": [...], "output": [...] }
        }
```

**GET `/api/channels/{name}/inputs`**
*   **Описание**: Возвращает список входов канала и активный вход.
*   **Реализация**: Извлекает данные из `find_channel` и информацию об активном входе из `ChannelRepository`.
*   **JSON-ответ**:
```json
        {
          "name": "Discovery",
          "inputs": ["http://input1", "http://input2"],
          "active_input": 1
        }
```

**GET `/api/channels/{name}/psi`**
*   **Описание**: Возвращает все собранные PSI/SI таблицы канала без фильтрации (включая NIT, CAT, BAT и др.).
*   **Реализация**: Извлекает полный дамп таблиц из объекта монитора в `ChannelRepository`.
*   **JSON-ответ**:
```json
        {
          "name": "Discovery",
          "display_name": "Discovery HD",
          "PMT": { ... },
          "SDT": { ... },
          "NIT": { ... },
          "CAT": { ... }
        }
```

**GET `/api/channels/{name}/psi/{table}`**
*   **Описание**: Возвращает конкретную PSI таблицу канала по её имени (например, NIT, CAT, BAT).
*   **Реализация**: Извлекает указанную таблицу из кэша монитора в `ChannelRepository`.
*   **JSON-ответ**: Данные запрошенной таблицы в формате JSON.

**POST `/api/channels`**
*   **Описание**: Создает новый канал (Raw Astra Channel).
*   **Параметры**: JSON с конфигурацией канала (`name`, `input`, `output` и др.)
*   **Реализация**: Вызывает `make_channel` из Astra.
*   **JSON-ответ**:
```json
        {
          "message": "Channel created"
        }
```

### Stream Routes (`/api/streams`)
Управление потоками с автоматическим мониторингом (канал + монитор).

**POST `/api/streams`**
*   **Описание**: Создает поток с мониторингом (канал + монитор).
*   **Параметры**: JSON с конфигурацией потока (`name`, `input`, `monitor` и др.)
*   **Реализация**: Вызывает `Channel.make_stream`.
*   **JSON-ответ**:
```json
        {
          "message": "Stream and monitor created"
        }
```

**DELETE `/api/streams/{name}`**
*   **Описание**: Удаляет поток и монитор.
*   **Параметры**: `reboot=true` для перезапуска.
*   **Реализация**: Использует `Channel.kill_stream` и при необходимости `Channel.make_stream` с задержкой.
*   **JSON-ответ**:
```json
        {
          "message": "Stream and monitor killed/rebooting",
          "config": { "name": "Discovery", "input": [...], "output": [...], "monitor": {...} }
        }
```

### Monitor Routes (`/api/monitors`)
Управление мониторами каналов.

**GET `/api/monitors`**
*   **Описание**: Возвращает список активных мониторов.
*   **Реализация**: Использует `ChannelRepository.get_all()`.
*   **JSON-ответ**:
```json
        [
  {
    "name": "Discovery",
    "display_name": "Discovery HD",
    "type": "output"
  }
        ]
```

**GET `/api/monitors/status`**
*   **Описание**: Возвращает сводный статус по всем мониторам.
*   **Реализация**: Анализирует все объекты в `ChannelRepository`.
*   **JSON-ответ**:
```json
        {
  "total": 10,
  "ok": 8,
  "error": 2,
  "total_cc_errors": 150
        }
```

**GET `/api/monitors/{name}`**
*   **Описание**: Возвращает текущие метрики конкретного монитора.
*   **Реализация**: Использует кэшированный JSON из объекта монитора или `get_full_status()`.
*   **JSON-ответ**:
```json
        {
  "type": "Channel",
  "server": "astra-1",
  "channel": "Discovery",
  "display_name": "Discovery HD",
  "monitor": "output",
  "stream": "http://example.com/stream.ts",
  "format": "http",
  "addr": "example.com:80",
  "ready": true,
  "scrambled": false,
  "bitrate": 12500,
  "cc_errors": 0,
  "pes_errors": 0
        }
```

**POST `/api/monitors`**
*   **Описание**: Создает новый монитор (без создания канала).
*   **Параметры**: JSON с конфигурацией монитора (`name`, `monitor`, `display_name`, параметры мониторинга)
*   **Реализация**: Вызывает `Channel.make_monitor`.
*   **JSON-ответ**:
```json
        {
  "message": "Monitor created"
        }
```

**PATCH `/api/monitors/{name}`**
*   **Описание**: Обновляет параметры монитора.
*   **Параметры**: JSON с новыми параметрами (`rate`, `time_check`, `method_comparison` и др.)
*   **Реализация**: Вызывает `Channel.update_monitor_parameters`.
*   **JSON-ответ**:
```json
        {
  "message": "Monitor updated"
        }
```

**DELETE `/api/monitors/{name}`**
*   **Описание**: Удаляет монитор (без удаления канала).
*   **Параметры**: `reboot=true` для перезапуска.
*   **Реализация**: Вызывает `Channel.kill_monitor` и при необходимости `Channel.make_monitor` с задержкой.
*   **JSON-ответ**:
```json
        {
  "message": "Monitor killed/rebooting",
  "config": { "name": "Discovery", "monitor": "output", ... }
        }
```

**POST `/api/monitors/{name}/pause`**
*   **Описание**: Приостанавливает мониторинг канала.
*   **Реализация**: Вызывает `Channel.pause_monitor`.
*   **JSON-ответ**:
```json
        {
  "message": "Monitoring paused"
        }
```

**POST `/api/monitors/{name}/resume`**
*   **Описание**: Возобновляет мониторинг канала.
*   **Реализация**: Вызывает `Channel.resume_monitor`.
*   **JSON-ответ**:
```json
        {
  "message": "Monitoring resumed"
        }
```

**GET `/api/monitors/{name}/pids`**
*   **Описание**: Получает статистику по PID.
*   **Реализация**: Использует метод `get_stats()` объекта монитора.
*   **JSON-ответ**:
```json
        {
  "256": { "type": "VIDEO", "cc": 10, "pes": 0, "sc": 0 },
  "257": { "type": "AUDIO", "cc": 0, "pes": 0, "sc": 0 }
        }
```

**DELETE `/api/monitors/{name}/pids`**
*   **Описание**: Очищает статистику по PID и битрейту.
*   **Реализация**: Вызывает `clear_stats()` объекта монитора.
*   **JSON-ответ**:
```json
        {
  "message": "PID and rate stats cleared"
        }
```

**GET `/api/monitors/{name}/rate_stat`**
*   **Описание**: Получает статистику по битрейту.
*   **Реализация**: Использует метод `get_rate_stat()` объекта монитора.
*   **JSON-ответ**:
```json
        {
  "bitrate": [12000, 12500, 12300, ...]
        }
```

### DVB Routes (`/api/dvb`)
Управление DVB-адаптерами и мониторинг тюнеров.

**GET `/api/dvb/adapters`**
*   **Описание**: Возвращает список используемых DVB-адаптеров.
*   **Реализация**: Использует `dvb_list` из Astra или `dvbls()`.
*   **JSON-ответ**:
```json
        [
  { "name": "0", "type": "S2", "frequency": "11044", ... },
  { "name": "1", "type": "T2", "frequency": "498" }
        ]
```

**GET `/api/dvb/adapters/monitor`**
*   **Описание**: Возвращает список адаптеров с активным мониторингом.
*   **Реализация**: Использует `DvbRepository.get_all()`.
*   **JSON-ответ**:
```json
        {
  "dvb0": "dvb0",
  "dvb1": "dvb1"
        }
```

**POST `/api/dvb/adapters/scan`**
*   **Описание**: Запуск быстрого сканирования адаптера (не реализовано).
*   **Реализация**: Возвращает ошибку 501.
*   **JSON-ответ**:
```json
        {
  "status": "error",
  "message": "Scan not implemented in this version"
}
```

**GET `/api/dvb/adapters/{name_adapter}`**
*   **Описание**: Возвращает состояние тюнера (Signal, SNR, BER, Lock).
*   **Реализация**: Использует кэшированный JSON из объекта тюнера или `get_full_status()`.
*   **JSON-ответ**:
```json
{
  "type": "dvb",
  "server": "astra-1",
  "name_adapter": "dvb0",
  "format": "S2",
  "modulation": "QPSK",
  "source": "11044:V:43200",
  "status": 1,
  "signal": 75.5,
  "snr": 24.8,
  "ber": 0,
  "unc": 0,
  "quality": 100
        }
```

**PATCH `/api/dvb/adapters/{name_adapter}`**
*   **Описание**: Обновление параметров мониторинга адаптера.
*   **Параметры**: JSON с новыми параметрами (`rate`, `time_check`, `method_comparison`, `analyze`)
*   **Реализация**: Вызывает `Adapter.update_dvb_monitor_parameters`.
*   **JSON-ответ**:
```json
        {
  "message": "Adapter monitor updated"
        }
```

**DELETE `/api/dvb/adapters/{name_adapter}`**
*   **Описание**: Остановка мониторинга адаптера.
*   **Параметры**: Опционально `force=true`.
*   **Реализация**: Вызывает `Adapter.stop_dvb_monitor`.
*   **JSON-ответ**:
```json
        {
  "message": "Adapter stopped successfully",
  "config": { "name_adapter": "dvb0", "tp": "11044:V:43200", ... }
        }
```

**GET `/api/dvb/adapters/{name_adapter}/psi`**
*   **Описание**: Возвращает все собранные PSI/SI таблицы адаптера без фильтрации.
*   **Реализация**: Использует метод `get_psi()` объекта тюнера без параметров.
*   **JSON-ответ**: Полный дамп всех доступных таблиц (NIT, CAT, BAT и др.).
```json
        {
  "adapter_name": "adapter1",
  "PMT": { "pid": 256, "streams": [...] },
  "SDT": { "pid": 17, "services": [...] }
        }
```

**POST `/api/dvb/adapters/{name_adapter}/psi`**
*   **Описание**: Запуск обновления PSI таблиц.
*   **Реализация**: Вызывает `Adapter.update_dvb_psi`.
*   **JSON-ответ**:
```json
        {
  "message": "PSI update started"
        }
```

**GET `/api/dvb/adapters/{name_adapter}/psi/{table}`**
*   **Описание**: Возвращает конкретную PSI таблицу адаптера по её имени.
*   **Реализация**: Извлекает указанную таблицу из кэша тюнера в `DvbRepository`.
*   **JSON-ответ**: Данные запрошенной таблицы.

**GET `/api/dvb/hardware/all`**
*   **Описание**: Возвращает список всех физических DVB-адаптеров, обнаруженных в системе.
*   **Реализация**: Использует функцию `dvbls()` ядра Astra.
*   **JSON-ответ**: Список объектов с параметрами адаптеров.

**POST `/api/dvb/adapters/{name_adapter}/tune`**
*   **Описание**: Настройка частоты (смена источника сигнала).
*   **Параметры**: JSON с параметрами тюнера (`tp`, `name_adapter` и др.)
*   **Реализация**: Вызывает `Adapter.dvb_tuner_monitor`.
*   **JSON-ответ**:
```json
        {
  "message": "Adapter tuning and monitoring started"
        }
```

**POST `/api/dvb/adapters/{name_adapter}/switch-transponder`**
*   **Описание**: Переключение транспондера.
*   **Параметры**: JSON с новыми параметрами тюнера (`tp`) и опционально `reserve_input`.
*   **Реализация**: Вызывает `Adapter.switch_transponder`.
*   **JSON-ответ**:
```json
        {
  "message": "Transponder switched successfully",
  "backup": { "tuner_params": {...}, "channels_configs": [...] }
        }
```

**POST `/api/dvb/adapters/{name_adapter}/pause`**
*   **Описание**: Приостановка мониторинга адаптера.
*   **Реализация**: Вызывает `Adapter.pause_dvb_monitor`.
*   **JSON-ответ**:
```json
        {
  "message": "Adapter monitoring paused"
        }
```

**POST `/api/dvb/adapters/{name_adapter}/resume`**
*   **Описание**: Возобновление мониторинга адаптера.
*   **Реализация**: Вызывает `Adapter.resume_dvb_monitor`.
*   **JSON-ответ**:
```json
        {
  "message": "Adapter monitoring resumed"
        }
```

**POST `/api/dvb/adapters/{name_adapter}/restart`**
*   **Описание**: Перезапуск мониторинга адаптера.
*   **Параметры**: Опционально `force=true` и другие параметры.
*   **Реализация**: Вызывает `Adapter.restart_dvb_monitor`.
*   **JSON-ответ**:
```json
{
  "message": "Adapter restarted successfully"
}
```

### System Routes (/api/system)
Системная информация и управление.

**GET `/api/env/astra`**
*   **Описание**: Возвращает информацию о версии Astra и аптайме.
*   **Реализация**: Использует `astra_version` и данные из `ResourceMonitor`.
*   **JSON-ответ**:
```json
        {
  "astra": {
    "version": "4.4.182",
    "uptime": 3600
  }
        }
```

**GET `/api/system/resources`**
*   **Описание**: Возвращает метрики CPU, RAM, Disk, Network.
*   **Реализация**: Использует `ResourceMonitor.get_stats()`.
*   **JSON-ответ**:
```json
{
  "type": "sys",
          "pid": 12345,
  "timestamp": 1673791200,
  "cpu": {
    "total": 12.5,
    "user": 8.2,
    "sys": 4.3,
    "threads": 24,
    "temp_c": 45.0,
    "ctxt_switches": 12000
  },
  "memory": {
    "lua_kb": 1500,
    "rss_kb": 262809,
    "vms_kb": 1048576,
    "shared_kb": 65536
  },
  "io": {
    "read_bps": 1024000,
    "write_bps": 512000
  },
  "network": {
    "eth0": {
      "rx_bps": 1250000,
      "tx_bps": 750000,
      "rx_errs": 0,
      "tx_errs": 0,
      "rx_drop": 0,
      "tx_drop": 0
    }
  },
  "system": {
    "load_avg": [1.2, 1.5, 1.8],
    "fd_count": 256
  }
}
```

**GET `/api/system/monitor-stats`**
*   **Описание**: Возвращает статистику работы `ResourceMonitor`.
*   **Реализация**: Использует данные из объекта `ResourceMonitor`.
*   **JSON-ответ**:
```json
        {
          "stats": {
            "is_running": true,
            "pid": 12345
          }
        }
```

**GET `/api/system/health`**
*   **Описание**: Проверяет состояние сервера.
*   **Реализация**: Возвращает базовую информацию о системе.
*   **JSON-ответ**:
```json
{
  "status": "ok",
  "pid": 12345,
  "astra_version": "4.4.182",
  "server_time": "2024-01-15 14:30:00"
}
```

**POST `/api/system/reload`**
*   **Описание**: Перезагружает Astra.
*   **Параметры**: Опционально `delay=1` (секунды).
*   **Реализация**: Использует `astra.reload()` с задержкой через `timer`.
*   **JSON-ответ**:
```json
        {
          "message": "Astra reload scheduled in 1s"
        }
```

**POST `/api/system/exit`**
*   **Описание**: Останавливает Astra.
*   **Параметры**: Опционально `delay=1` (секунды).
*   **Реализация**: Использует `astra.exit() or os.exit(0)` с задержкой через `timer`.
*   **JSON-ответ**:
```json
        {
          "message": "Astra exit scheduled in 1s"
        }
```

**POST `/api/system/clear-cache`**
*   **Описание**: Очищает кэш системных метрик.
*   **Реализация**: Вызывает `ResourceMonitor.check()`.
*   **JSON-ответ**:
```json
        {
          "message": "Metrics updated"
        }
```

### System Network Routes (`/api/system/network`):
Сетевая информация сервера.

**GET `/api/system/network/interfaces`**
*   **Описание**: Возвращает список всех сетевых интерфейсов сервера с их IP и MAC адресами.
*   **Реализация**: Использует `utils.ifaddrs()` ядра Astra.
*   **JSON-ответ**: Список интерфейсов с детальной информацией.

**GET `/api/system/network/hostname`**
*   **Описание**: Возвращает имя хоста сервера.
*   **Реализация**: Использует `utils.hostname()`.
*   **JSON-ответ**:
```json
        {
          "hostname": "astra-server"
        }
```

### Subscriber Routes (`/api/subscribers`)
Управление подписками на события мониторинга.

**GET `/api/subscribers`**
*   **Описание**: Возвращает список всех получателей данных.
*   **Реализация**: Использует `HttpSubscriber.get_subscribers()`.
*   **JSON-ответ**:
```json
[
  {
    "event_type": "channels",
    "host": "192.168.1.100",
    "port": "8080",
    "path": "/api/webhook"
  }
]
```

**POST `/api/subscribers`**
*   **Описание**: Добавляет нового получателя.
*   **Параметры**: JSON с параметрами (`event_type`, `host`, `port`, `path`).
*   **Реализация**: Вызывает `HttpSubscriber.subscribe`.
*   **JSON-ответ**:
```json
        {
          "message": "Subscribed successfully"
        }
```

**DELETE `/api/subscribers`**
*   **Описание**: Удаляет получателя.
*   **Параметры**: JSON с параметрами (`event_type`, `host`, `port`, `path`).
*   **Реализация**: Вызывает `HttpSubscriber.unsubscribe`.
*   **JSON-ответ**:
```json
        {
          "message": "Unsubscribed successfully"
        }
```

### Utility Routes (/api/utils)
Вспомогательные утилитарные эндпоинты для диагностики и управления.

**GET /api/utils/resource-stats**
*   **Описание**: Возвращает статистику использования ресурсов.
*   **Реализация**: Анализирует `ChannelRepository`, `DvbRepository` и `MonitorConfig`.
*   **JSON-ответ**:
```json
{
  "monitors": {
    "active": 15,
    "total_capacity": 200,
    "usage_percent": 7.5
  },
  "dvb_monitors": {
    "active": 3,
    "total_capacity": 20,
    "usage_percent": 15
  },
  "system": {
    "total_astra_channels": 45,
    "total_astra_adapters": 8
  }
}
```

**GET `/api/utils/channels/extended`**
*   **Описание**: Возвращает расширенную информацию обо всех каналах.
*   **Реализация**: Объединяет данные из `channel_list` и `ChannelRepository`.
*   **JSON-ответ**:
```json
[
  {
    "name": "Discovery",
    "display_name": "Discovery HD",
    "has_monitor": true,
    "monitor_type": "output",
    "inputs": ["http://..."],
    "outputs": ["udp://..."],
    "monitor_status": {
      "ready": true,
      "bitrate": 12500,
      "cc_errors": 0,
      "timestamp": 1673791200
    }
  }
]
```

**GET `/api/utils/monitors/{name}/errors`**
*   **Описание**: Возвращает историю ошибок для монитора (заглушка).
*   **Реализация**: Использует данные из `ChannelRepository`.
*   **JSON-ответ**:
```json
{
  "name": "Discovery",
  "display_name": "Discovery HD",
  "current_status": {
    "ready": true,
    "bitrate": 12500,
    "cc_errors": 0,
    "timestamp": 1673791200
  },
  "error_history": []
}
```

**GET `/api/utils/system/config`**
*   **Описание**: Возвращает конфигурацию системы мониторинга.
*   **Реализация**: Использует `MonitorConfig`.
*   **JSON-ответ**:
```json
{
  "LogLevel": "INFO",
  "ChannelMonitorLimit": 200,
  "DvbMonitorLimit": 20,
  "MaxMonitorNameLength": 64,
  "MinRate": 0.001,
  "MaxRate": 0.3,
  "MinTimeCheck": 0,
  "MaxTimeCheck": 300,
  "MinMethodComparison": 1,
  "MaxMethodComparison": 4,
  "HttpTimeout": 10,
  "STREAM": {
    "127.0.0.1": "Узда",
    "127.0.0.2": "Дружный"
  }
}
```

**GET `/api/utils/check`**
*   **Описание**: Проверяет доступность и статус монитора по имени.
*   **Параметры**: `name` (обязательный) - имя монитора для проверки.
*   **Реализация**: Проверяет наличие в `ChannelRepository` и `DvbRepository`.
*   **JSON-ответ**:
```json
{
  "name": "dvb0",
  "exists": true,
  "type": "dvb",
  "is_active": true,
  "state": 2,
  "details": {
    "format": "S2",
    "source": "11044:V:43200"
  }
}
```

**GET `/api/utils/objects`**
*   **Описание**: Возвращает список всех объектов (мониторы + адаптеры) с базовой информацией.
*   **Реализация**: Объединяет данные из `ChannelRepository` и `DvbRepository`.
*   **JSON-ответ**:
```json
{
  "total": 18,
  "objects": [
    {
      "id": "Discovery",
      "name": "Discovery",
      "type": "channel_monitor",
      "display_name": "Discovery HD",
      "active": true,
      "state": 2
    },
    {
      "id": "dvb0",
      "name": "dvb0",
      "type": "dvb_monitor",
      "adapter_name": "dvb0",
      "active": true,
      "state": 2,
      "source": "11044:V:43200"
    }
  ]
}
```

**POST `/api/utils/cleanup`**
*   **Описание**: Очищает все неактивные мониторы (временно отключено).
*   **Реализация**: Возвращает сообщение о временном отключении.
*   **JSON-ответ**:
```json
{
  "message": "Cleanup functionality is temporarily disabled for safety",
  "cleaned_count": 0,
  "cleaned_objects": []
}
```

**GET `/api/utils/info`**
*   **Описание**: Возвращает информацию о версии API и доступных методах.
*   **Реализация**: Возвращает статические данные об API.
*   **JSON-ответ**:
```json
{
  "api_version": "1.0.0",
  "library_version": "2.3.1",
  "supported_methods": ["GET", "POST"],
  "requires_auth": true,
  "auth_header": "X-Api-Key",
  "default_port": 8080,
  "endpoints": {
    "channels": "/api/channels",
    "streams": "/api/streams",
    "monitors": "/api/monitors",
    "dvb": "/api/dvb",
    "system": "/api/system",
    "subscribers": "/api/subscribers",
    "utils": "/api/utils"
  }
}
```

## Параметры конфигурации мониторов:

Библиотека поддерживает загрузку глобальных настроек из файла `config.json`, расположенного в корневой директории библиотеки. Если файл отсутствует, используются значения по умолчанию.

### Глобальные настройки (config.json)
*   **`LogLevel`**: Уровень логирования ("DEBUG", "INFO", "WARN", "ERROR", "NONE").
*   **`ChannelMonitorLimit`**: Максимальное количество активных мониторов каналов.
*   **`DvbMonitorLimit`**: Максимальное количество активных DVB-мониторов.
*   **`HttpTimeout`**: Таймаут для HTTP-запросов (в секундах).
*   **`STREAM`**: Карта соответствия IP-адресов и понятных имен потоков.

При создании или обновлении монитора можно настроить следующие параметры:

### Общие параметры (Channel & DVB)
*   **`method_comparison`**: Метод определения изменений для отправки данных (Push):
    1.  **Always (1)**: Отправка данных при каждом обновлении от Astra.
    2.  **Strict (2)**: Отправка при любом изменении статуса, битрейта или появлении хотя бы одной ошибки CC/PES.
    3.  **Ratio (3)**: (Рекомендуемый) Отправка при изменении статуса или если отклонение битрейта превысило порог `rate`.
    4.  **On-Air (4)**: (Только для каналов) Отправка только при изменении флага наличия сигнала (On-Air/Off-Air).
*   **`rate`**: Порог отклонения битрейта для метода `Ratio` (по умолчанию `0.035` для каналов, `0.015` для DVB).
*   **`time_check`**: Интервал между проверками состояния в циклах обновления Astra (по умолчанию `0` для каналов, `10` для DVB).
*   **`analyze`**: (boolean) Включение расширенного сбора статистики (PID для каналов, расчет Quality для DVB).

### Специфичные параметры ChannelMonitor
*   **`cc_limit`**: Порог ошибок CC для срабатывания триггера в Astra (по умолчанию `0`).
*   **`bitrate_limit`**: Порог битрейта (бит/с) для срабатывания триггера (по умолчанию `0`).
*   **`rate_stat`**: (boolean) Включение сбора детальной статистики битрейта (по умолчанию `false`).
*   **`join_pid`**: (boolean) Объединение статистики по PID (по умолчанию `false`).

## Пример использования:
```lua
-- Инициализация библиотеки
require("lib-monitor.init_monitor")

-- Запуск API сервера на порту 8080
server_start("0.0.0.0", 8080)

-- Создание стрима с мониторингом
make_stream({
    name = "Discovery",
    input = {"http://example.com/stream.ts"},
    output = {"udp://239.255.1.1:1234"},
    monitor = {
        monitor_type = "output",
        method_comparison = 3,
        rate = 0.05,
        display_name = "Discovery HD"
    }
})

-- Создание DVB монитора
dvb_tuner_monitor({
    name_adapter = "dvb0",
    tp = "11044:V:43200",
    modulation = "qpsk",
    rate = 0.02,
    method_comparison = 3
})
```

## Безопасность:
Все API-запросы требуют аутентификации с помощью заголовка `X-Api-Key`. Значение ключа устанавливается через переменную окружения `ASTRA_API_KEY`. Если переменная не задана, используется значение по умолчанию — `test`. Для продакшн-среды обязательно установите свой секретный ключ.

## Примечание:
Для полноценной работы библиотека требует наличия Astra 4.4.182 или выше. Все ошибки API возвращаются в формате JSON с описанием причины, полученным из системного логгера.

*   **Версия библиотеки**: 2.3.2
*   **Версия API**: 1.0.0
*   **Требуемая версия Astra**: 4.4.182+
*   **Количество реализованных эндпоинтов**: 45+
