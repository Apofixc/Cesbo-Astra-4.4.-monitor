# Справочник REST API

Все API-запросы требуют аутентификации с помощью заголовка `X-Api-Key`. Значение ключа устанавливается через переменную окружения `ASTRA_API_KEY` (по умолчанию "test"). Все успешные ответы возвращаются с кодом `200 OK`. Ошибки возвращаются в формате JSON с описанием причины.

## 1. Каналы (`/api/channels`)

Управление конфигурацией каналов Astra.

### GET `/api/channels`
*   **Описание**: Возвращает список всех каналов с их адресами вещания.
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

### GET `/api/channels/stats`
*   **Описание**: Возвращает агрегированную статистику по каналам.
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

### GET `/api/channels/info`
*   **Описание**: Возвращает детальную информацию о канале (конфигурацию Astra).
*   **Параметры**: `name` (имя канала).
*   **JSON-ответ**:
```json
{
  "name": "TV3",
  "input": ["http://..."],
  "output": ["udp://..."],
  "map": "..."
}
```

### DELETE `/api/channels/kill`
*   **Описание**: Удаляет или перезапускает канал (Raw Astra Channel).
*   **Параметры**: `name` (имя канала), `reboot` (опционально).
*   **JSON-ответ**:
```json
{
  "message": "Channel killed/rebooting",
  "config": { "name": "TV3", "input": [...] }
}
```

### GET `/api/channels/inputs`
*   **Описание**: Возвращает список входов канала и активный вход.
*   **Параметры**: `name` (имя канала).
*   **JSON-ответ**:
```json
{
  "name": "Discovery",
  "inputs": ["http://input1", "http://input2"],
  "active_input": 1
}
```

### GET `/api/channels/psi`
*   **Описание**: Возвращает все собранные PSI/SI таблицы канала.
*   **Параметры**: `name` (имя канала), `table` (опционально).
*   **JSON-ответ**:
```json
{
  "name": "TV3",
  "PMT": { "pid": 1000, "streams": [...] },
  "SDT": { "sid": 1, "services": [...] }
}
```

### POST `/api/channels`
*   **Описание**: Создает новый канал (Raw Astra Channel).
*   **Параметры**: Конфигурация канала в JSON.
*   **JSON-ответ**:
```json
{
  "message": "Channel created"
}
```

## 2. Потоки с мониторингом (`/api/streams`)

Комбинированные операции (канал + монитор).

### POST `/api/streams`
*   **Описание**: Создает поток с мониторингом (канал + монитор).
*   **Параметры**: Конфигурация потока в JSON.
*   **JSON-ответ**:
```json
{
  "message": "Stream and monitor created"
}
```

### DELETE `/api/streams/kill`
*   **Описание**: Удаляет поток и монитор.
*   **Параметры**: `name` (имя потока), `reboot` (опционально).
*   **JSON-ответ**:
```json
{
  "message": "Stream and monitor killed/rebooting",
  "config": { "name": "TV3", "input": [...] }
}
```

## 3. Мониторы (`/api/monitors`)

Управление активными экземплярами мониторов.

### GET `/api/monitors`
*   **Описание**: Возвращает список активных мониторов.
*   **JSON-ответ**:
```json
[
  { "name": "TV3", "display_name": "TV3", "type": "output" }
]
```

### GET `/api/monitors/status`
*   **Описание**: Возвращает сводный статус по всем мониторам.
*   **JSON-ответ**:
```json
{
  "total": 10,
  "ok": 8,
  "error": 2,
  "total_cc_errors": 150
}
```

### GET `/api/monitors/data`
*   **Описание**: Возвращает текущие метрики конкретного монитора.
*   **Параметры**: `name` (имя монитора).
*   **JSON-ответ**:
```json
{
  "type": "Channel",
  "channel": "Discovery",
  "ready": true,
  "bitrate": 12500,
  "cc_errors": 0,
  "timestamp": 1673791200
}
```

### POST `/api/monitors`
*   **Описание**: Создает новый монитор (без создания канала).
*   **Параметры**: JSON с конфигурацией монитора.
*   **JSON-ответ**:
```json
{
  "message": "Monitor created"
}
```

### PATCH `/api/monitors/update`
*   **Описание**: Обновляет параметры монитора.
*   **Параметры**: `name` (имя монитора) + параметры.
*   **JSON-ответ**:
```json
{
  "message": "Monitor updated"
}
```

### DELETE `/api/monitors/kill`
*   **Описание**: Удаляет монитор.
*   **Параметры**: `name` (имя монитора).
*   **JSON-ответ**:
```json
{
  "message": "Monitor killed",
  "config": { "name": "TV3", "monitor": "output" }
}
```

### POST `/api/monitors/pause` / `resume`
*   **Описание**: Приостанавливает или возобновляет мониторинг канала.
*   **Параметры**: `name` (имя монитора).
*   **JSON-ответ**:
```json
{
  "message": "Monitoring paused/resumed"
}
```

### GET `/api/monitors/pids`
*   **Описание**: Получает статистику по PID.
*   **Параметры**: `name` (имя монитора).
*   **JSON-ответ**:
```json
{
  "256": { "type": "VIDEO", "cc": 10, "pes": 0, "sc": 0 },
  "257": { "type": "AUDIO", "cc": 0, "pes": 0, "sc": 0 }
}
```

### DELETE `/api/monitors/pids`
*   **Описание**: Очищает статистику по PID.
*   **Параметры**: `name` (имя монитора).
*   **JSON-ответ**:
```json
{
  "message": "PID and rate stats cleared"
}
```

## 4. DVB-адаптеры (`/api/dvb`)

Управление физическим оборудованием.

### GET `/api/dvb/adapters`
*   **Описание**: Возвращает список используемых DVB-адаптеров.
*   **JSON-ответ**:
```json
[
  { "name": "0", "type": "S2", "frequency": "11044" }
]
```

### GET `/api/dvb/adapters/monitor`
*   **Описание**: Возвращает список адаптеров с активным мониторингом.
*   **JSON-ответ**:
```json
{ "dvb0": "dvb0" }
```

### GET `/api/dvb/adapters/data`
*   **Описание**: Возвращает состояние тюнера (Signal, SNR, BER, Lock).
*   **Параметры**: `name` (имя адаптера).
*   **JSON-ответ**:
```json
{
  "type": "dvb",
  "name_adapter": "dvb0",
  "signal": 75.5,
  "snr": 24.8,
  "has_lock": true
}
```

### PATCH `/api/dvb/adapters/update`
*   **Описание**: Обновление параметров мониторинга адаптера.
*   **Параметры**: `name` (имя адаптера) + параметры.
*   **JSON-ответ**:
```json
{ "message": "Adapter monitor updated" }
```

### DELETE `/api/dvb/adapters/stop`
*   **Описание**: Остановка мониторинга адаптера.
*   **Параметры**: `name` (имя адаптера).
*   **JSON-ответ**:
```json
{ "message": "Adapter stopped successfully" }
```

### GET `/api/dvb/adapters/psi`
*   **Описание**: Возвращает собранные PSI/SI таблицы адаптера.
*   **Параметры**: `name` (имя адаптера).
*   **JSON-ответ**:
```json
{
  "adapter_name": "dvb0",
  "PMT": { ... },
  "SDT": { ... }
}
```

### POST `/api/dvb/adapters/psi`
*   **Описание**: Запуск обновления PSI таблиц.
*   **Параметры**: `name` (имя адаптера).
*   **JSON-ответ**:
```json
{ "message": "PSI update started" }
```

### GET `/api/dvb/hardware/all`
*   **Описание**: Возвращает список всех физических DVB-адаптеров.
*   **JSON-ответ**:
```json
[
  { "adapter": 0, "device": 0, "type": "S2", "frontend": "..." }
]
```

### POST `/api/dvb/adapters/tune`
*   **Описание**: Настройка частоты и запуск мониторинга.
*   **Тело**: JSON с параметрами тюнера.
*   **JSON-ответ**:
```json
{ "message": "Adapter tuning and monitoring started" }
```

### POST `/api/dvb/adapters/switch-transponder`
*   **Описание**: Переключение транспондера.
*   **Параметры**: `name` (имя адаптера) + новые параметры.
*   **JSON-ответ**:
```json
{ "message": "Transponder switched successfully" }
```

### POST `/api/dvb/adapters/pause` / `resume` / `restart`
*   **Описание**: Управление состоянием мониторинга адаптера.
*   **Параметры**: `name` (имя адаптера).
*   **JSON-ответ**:
```json
{ "message": "Adapter monitoring paused/resumed/restarted" }
```

### GET `/api/dvb/adapters/status-info`
*   **Описание**: Возвращает детальные флаги состояния адаптера (has_signal, has_lock и т.д.).
*   **Параметры**: `name` (имя адаптера).
*   **JSON-ответ**:
```json
{
  "name_adapter": "dvb0",
  "has_signal": true,
  "has_carrier": true,
  "has_viterbi": true,
  "has_sync": true,
  "has_lock": true
}
```

## 5. Системные ресурсы (`/api/system`)

### GET `/api/system/health`
*   **Описание**: Проверяет состояние сервера и возвращает детальные метрики процесса Astra, статистику мониторов и статус зависимостей.
*   **JSON-ответ**:
```json
{
  "status": "healthy",
  "bind_address": "0.0.0.0",
  "bind_port": 8080,
  "astra_version": "4.4.182",
  "server_time": "2026-01-10 10:20:00",
  "timestamp": 1768033200,
  "uptime_human": "0d 02h 15m",
  "stats": {
    "active_channels": 5,
    "active_adapters": 2
  },
  "resources": {
    "pid": 1234,
    "uptime": 8100,
    "cpu": { "usage": 12.5, "user": 10.2, "system": 2.3, "threads": 8 },
    "memory": { "lua": 1024, "resident": 51200, "virtual": 150000 },
    "network": [
      { "interface": "eth0", "ip": "192.168.1.10" }
    ]
  }
}
```

### GET `/api/system/api-stats`
*   **Описание**: Возвращает статистику производительности API.
*   **JSON-ответ**:
```json
{
  "total_requests": 1000,
  "total_errors": 5,
  "routes": {
    "/api/system/health": { "count": 100, "total_time": 0.05, "errors": 0 }
  }
}
```

### POST `/api/system/reload` / `exit`
*   **Описание**: Управление процессом Astra.
*   **Параметры**: `delay` (опционально).
*   **JSON-ответ**:
```json
{ "message": "Astra reload/exit scheduled" }
```

### POST `/api/system/clear-cache`
*   **Описание**: Очищает кэш системных метрик.
*   **JSON-ответ**:
```json
{ "message": "Metrics updated" }
```

### GET `/api/system/network/interfaces`
*   **Описание**: Возвращает список всех сетевых интерфейсов сервера.
*   **JSON-ответ**:
```json
{
  "eth0": { "ipv4": ["192.168.1.10"], "mac": "..." }
}
```

### GET `/api/system/network/hostname`
*   **Описание**: Возвращает имя хоста сервера.
*   **JSON-ответ**:
```json
{ "hostname": "astra-server" }
```

## 6. Подписки (`/api/subscribers`)

### GET `/api/subscribers`
*   **Описание**: Возвращает список всех получателей данных.
*   **JSON-ответ**:
```json
[
  { "event_type": "channels", "host": "192.168.1.100", "port": 8080, "path": "/webhook" }
]
```

### POST `/api/subscribers`
*   **Описание**: Регистрация нового Webhook.
*   **Тело**: JSON с `event_type`, `host`, `port`, `path`, `filters`, `throttle_ms`.
*   **JSON-ответ**:
```json
{ "message": "Subscribed successfully" }
```

### DELETE `/api/subscribers`
*   **Описание**: Удаление подписки.
*   **JSON-ответ**:
```json
{ "message": "Unsubscribed successfully" }
```

## 7. Утилиты (`/api/utils`)

### GET `/api/utils/info`
*   **Описание**: Возвращает информацию о версии API и доступных методах.
*   **JSON-ответ**:
```json
{
  "api_version": "1.2.0",
  "library_version": "2.4.0",
  "supported_methods": ["GET", "POST", "PATCH", "DELETE"]
}
```

## Коды ответов

*   `200 OK`: Запрос успешно обработан.
*   `400 Bad Request`: Ошибка в параметрах или теле запроса.
*   `401 Unauthorized`: Отсутствует или неверен API-ключ.
*   `404 Not Found`: Ресурс (канал, монитор, адаптер) не найден.
*   `500 Internal Server Error`: Внутренняя ошибка при выполнении операции.
