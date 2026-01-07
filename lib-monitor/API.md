# lib-monitor HTTP API Documentation

Все API-запросы требуют аутентификации с помощью заголовка `X-Api-Key`.

---

## Группа: Channels

### GET `/api/channels`
- **Описание**: Возвращает список всех каналов с их адресами вещания.
- **Параметры**: Нет.
- **Примеры вызова**:
  - **Query String**: `/api/channels`
- **Реализация**: Использует `channel_list` из Astra и дополняет данными из `ChannelRepository`.
- **JSON-ответ**:
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
- **Описание**: Возвращает агрегированную статистику по каналам.
- **Параметры**: Нет.
- **Примеры вызова**:
  - **Query String**: `/api/channels/stats`
- **Реализация**: Анализирует `channel_list` и все активные мониторы из `ChannelRepository`.
- **JSON-ответ**:
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
- **Описание**: Возвращает детальную информацию о канале.
- **Параметры**: `name` (имя канала).
- **Примеры вызова**:
  - **Query String**: `/api/channels/info?name=TV3`
  - **JSON Body**: `/api/channels/info` + `{"name": "TV3"}`
- **Реализация**: Использует `find_channel` из Astra.
- **JSON-ответ**:
```json
{
  "name": "TV3",
  "input": ["http://31.130.202.110/httpts/tv3by/avchigh.ts"],
  "output": ["udp://224.100.100.119:1234#sync"]
}
```

### DELETE `/api/channels/kill`
- **Описание**: Удаляет или перезапускает канал (Raw Astra Channel).
- **Параметры**: `name` (имя канала), `reboot` (опционально).
- **Примеры вызова**:
  - **Query String**: `/api/channels/kill?name=TV3&reboot=true`
  - **JSON Body**: `/api/channels/kill` + `{"name": "TV3", "reboot": true}`
- **Реализация**: Использует `kill_channel` и при необходимости `make_channel` с задержкой.
- **JSON-ответ**:
```json
{
  "message": "Channel killed",
  "config": { "name": "TV3", "input": ["..."] }
}
```

### GET `/api/channels/inputs`
- **Описание**: Возвращает список входов канала и активный вход.
- **Параметры**: `name` (имя канала).
- **Примеры вызова**:
  - **Query String**: `/api/channels/inputs?name=TV3`
  - **JSON Body**: `/api/channels/inputs` + `{"name": "TV3"}`
- **Реализация**: Извлекает данные из `find_channel` и информацию об активном входе из `ChannelRepository`.
- **JSON-ответ**:
```json
{
  "name": "TV3",
  "inputs": ["http://input1", "http://input2"],
  "active_input": 1,
  "display_name": "TV3"
}
```

### GET `/api/channels/psi`
- **Описание**: Возвращает собранные PSI/SI таблицы канала.
- **Параметры**: `name` (имя канала), `table` (опционально).
- **Примеры вызова**:
  - **Query String**: `/api/channels/psi?name=TV3&table=NIT`
  - **JSON Body**: `/api/channels/psi` + `{"name": "TV3", "table": "NIT"}`
- **Реализация**: Извлекает дамп таблиц из объекта монитора в `ChannelRepository`.
- **JSON-ответ**:
```json
{
  "name": "TV3",
  "display_name": "TV3",
  "PMT": { "pid": 1000, "streams": [...] },
  "SDT": { "sid": 1, "services": [...] }
}
```

### POST `/api/channels`
- **Описание**: Создает новый канал (Raw Astra Channel).
- **Параметры**: Конфигурация канала в JSON.
- **Примеры вызова**:
  - **JSON Body**: `/api/channels` + `{"name": "NewChannel", "input": ["..."]}`
- **Реализация**: Вызывает `make_channel` из Astra.
- **JSON-ответ**:
```json
{
  "message": "Channel created"
}
```

---

## Группа: Streams

### POST `/api/streams`
- **Описание**: Создает поток с мониторингом (канал + монитор).
- **Параметры**: Конфигурация потока в JSON.
- **Примеры вызова**:
  - **JSON Body**: `/api/streams` + `{"name": "TV3", "input": ["..."], "monitor": {...}}`
- **Реализация**: Вызывает `Channel.make_stream`.
- **JSON-ответ**:
```json
{
  "message": "Stream and monitor created"
}
```

### DELETE `/api/streams/kill`
- **Описание**: Удаляет поток и монитор.
- **Параметры**: `name` (имя потока), `reboot` (опционально).
- **Примеры вызова**:
  - **Query String**: `/api/streams/kill?name=TV3&reboot=true`
  - **JSON Body**: `/api/streams/kill` + `{"name": "TV3", "reboot": true}`
- **Реализация**: Использует `Channel.kill_stream` и при необходимости `Channel.make_stream` с задержкой.
- **JSON-ответ**:
```json
{
  "message": "Stream and monitor killed",
  "config": { "name": "TV3", "input": ["..."] }
}
```

---

## Группа: Monitors

### GET `/api/monitors`
- **Описание**: Возвращает список активных мониторов.
- **Параметры**: Нет.
- **Примеры вызова**:
  - **Query String**: `/api/monitors`
- **Реализация**: Использует `ChannelRepository.get_all()`.
- **JSON-ответ**:
```json
[
  {
    "name": "TV3",
    "display_name": "TV3",
    "type": "output"
  }
]
```

### GET `/api/monitors/status`
- **Описание**: Возвращает сводный статус по всем мониторам.
- **Параметры**: Нет.
- **Примеры вызова**:
  - **Query String**: `/api/monitors/status`
- **Реализация**: Анализирует все объекты в `ChannelRepository`.
- **JSON-ответ**:
```json
{
  "total": 1,
  "ok": 1,
  "error": 0,
  "total_cc_errors": 0
}
```

### GET `/api/monitors/data`
- **Описание**: Возвращает текущие метрики конкретного монитора.
- **Параметры**: `name` (имя монитора).
- **Примеры вызова**:
  - **Query String**: `/api/monitors/data?name=TV3`
  - **JSON Body**: `/api/monitors/data` + `{"name": "TV3"}`
- **Реализация**: Использует кэшированный JSON из объекта монитора или `get_full_status()`.
- **JSON-ответ**:
```json
{
  "type": "Channel",
  "name": "TV3",
  "ready": true,
  "bitrate": 2650,
  "cc_errors": 0,
  "timestamp": 1767788955
}
```

### POST `/api/monitors`
- **Описание**: Создает новый монитор (без создания канала).
- **Параметры**: JSON с конфигурацией монитора.
- **Примеры вызова**:
  - **JSON Body**: `/api/monitors` + `{"name": "TV3", "monitor": "http://..."}`
- **Реализация**: Вызывает `Channel.make_monitor`.
- **JSON-ответ**:
```json
{
  "message": "Monitor created"
}
```

### PATCH `/api/monitors/update`
- **Описание**: Обновляет параметры монитора.
- **Параметры**: `name` (имя монитора) + параметры мониторинга.
- **Примеры вызова**:
  - **Query String**: `/api/monitors/update?name=TV3&rate=0.05`
  - **JSON Body**: `/api/monitors/update` + `{"name": "TV3", "rate": 0.05}`
- **Реализация**: Вызывает `Channel.update_monitor_parameters`.
- **JSON-ответ**:
```json
{
  "message": "Monitor updated"
}
```

### DELETE `/api/monitors/kill`
- **Описание**: Удаляет монитор (без удаления канала).
- **Параметры**: `name` (имя монитора), `reboot` (опционально).
- **Примеры вызова**:
  - **Query String**: `/api/monitors/kill?name=TV3&reboot=true`
  - **JSON Body**: `/api/monitors/kill` + `{"name": "TV3", "reboot": true}`
- **Реализация**: Вызывает `Channel.kill_monitor` и при необходимости `Channel.make_monitor` с задержкой.
- **JSON-ответ**:
```json
{
  "message": "Monitor killed",
  "config": { "name": "TV3", "monitor": "output" }
}
```

### POST `/api/monitors/pause`
- **Описание**: Приостанавливает мониторинг канала.
- **Параметры**: `name` (имя монитора).
- **Примеры вызова**:
  - **Query String**: `/api/monitors/pause?name=TV3`
  - **JSON Body**: `/api/monitors/pause` + `{"name": "TV3"}`
- **Реализация**: Вызывает `Channel.pause_monitor`.
- **JSON-ответ**:
```json
{
  "message": "Monitoring paused"
}
```

### POST `/api/monitors/resume`
- **Описание**: Возобновляет мониторинг канала.
- **Параметры**: `name` (имя монитора).
- **Примеры вызова**:
  - **Query String**: `/api/monitors/resume?name=TV3`
  - **JSON Body**: `/api/monitors/resume` + `{"name": "TV3"}`
- **Реализация**: Вызывает `Channel.resume_monitor`.
- **JSON-ответ**:
```json
{
  "message": "Monitoring resumed"
}
```

### GET `/api/monitors/pids`
- **Описание**: Получает статистику по PID.
- **Параметры**: `name` (имя монитора).
- **Примеры вызова**:
  - **Query String**: `/api/monitors/pids?name=TV3`
  - **JSON Body**: `/api/monitors/pids` + `{"name": "TV3"}`
- **Реализация**: Использует метод `get_stats()` объекта монитора.
- **JSON-ответ**:
```json
{
  "500": { "type": "VIDEO", "cc": 0, "pes": 0, "sc": 0 },
  "700": { "type": "AUDIO", "cc": 0, "pes": 0, "sc": 0 }
}
```

### DELETE `/api/monitors/pids`
- **Описание**: Очищает статистику по PID и битрейту.
- **Параметры**: `name` (имя монитора).
- **Примеры вызова**:
  - **Query String**: `/api/monitors/pids?name=TV3`
  - **JSON Body**: `/api/monitors/pids` + `{"name": "TV3"}`
- **Реализация**: Вызывает `clear_stats()` объекта монитора.
- **JSON-ответ**:
```json
{
  "message": "PID and rate stats cleared"
}
```

### GET `/api/monitors/rate_stat`
- **Описание**: Получает статистику по битрейту.
- **Параметры**: `name` (имя монитора).
- **Примеры вызова**:
  - **Query String**: `/api/monitors/rate_stat?name=TV3`
  - **JSON Body**: `/api/monitors/rate_stat` + `{"name": "TV3"}`
- **Реализация**: Использует метод `get_rate_stat()` объекта монитора.
- **JSON-ответ**:
```json
{
  "bitrate": [12000, 12500, 12300]
}
```

---

## Группа: DVB Adapters

### GET `/api/dvb/adapters`
- **Описание**: Возвращает список используемых DVB-адаптеров.
- **Параметры**: Нет.
- **Примеры вызова**:
  - **Query String**: `/api/dvb/adapters`
- **Реализация**: Использует `dvb_list` из Astra или `dvbls()`.
- **JSON-ответ**:
```json
[
  { "name": "0", "type": "S2", "frequency": "11044" }
]
```

### GET `/api/dvb/adapters/monitor`
- **Описание**: Возвращает список адаптеров с активным мониторингом.
- **Параметры**: Нет.
- **Примеры вызова**:
  - **Query String**: `/api/dvb/adapters/monitor`
- **Реализация**: Использует `DvbRepository.get_all()`.
- **JSON-ответ**:
```json
{
  "dvb0": "dvb0"
}
```

### GET `/api/dvb/adapters/data`
- **Описание**: Возвращает состояние тюнера (Signal, SNR, BER, Lock).
- **Параметры**: `name` (имя адаптера).
- **Примеры вызова**:
  - **Query String**: `/api/dvb/adapters/data?name=dvb0`
  - **JSON Body**: `/api/dvb/adapters/data` + `{"name": "dvb0"}`
- **Реализация**: Использует кэшированный JSON из объекта тюнера или `get_full_status()`.
- **JSON-ответ**:
```json
{
  "type": "dvb",
  "name_adapter": "dvb0",
  "signal": 75,
  "snr": 24,
  "has_lock": true
}
```

### PATCH `/api/dvb/adapters/update`
- **Описание**: Обновление параметров мониторинга адаптера.
- **Параметры**: `name` (имя адаптера) + параметры.
- **Примеры вызова**:
  - **Query String**: `/api/dvb/adapters/update?name=dvb0&rate=0.02`
  - **JSON Body**: `/api/dvb/adapters/update` + `{"name": "dvb0", "rate": 0.02}`
- **Реализация**: Вызывает `Adapter.update_dvb_monitor_parameters`.
- **JSON-ответ**:
```json
{
  "message": "Adapter monitor updated"
}
```

### DELETE `/api/dvb/adapters/stop`
- **Описание**: Остановка мониторинга адаптера.
- **Параметры**: `name` (имя адаптера), `force` (опционально).
- **Примеры вызова**:
  - **Query String**: `/api/dvb/adapters/stop?name=dvb0&force=true`
  - **JSON Body**: `/api/dvb/adapters/stop` + `{"name": "dvb0", "force": true}`
- **Реализация**: Вызывает `Adapter.stop_dvb_monitor`.
- **JSON-ответ**:
```json
{
  "message": "Adapter stopped successfully",
  "config": { "name_adapter": "dvb0", "tp": "11044:V:43200" }
}
```

### GET `/api/dvb/adapters/psi`
- **Описание**: Возвращает собранные PSI/SI таблицы адаптера.
- **Параметры**: `name` (имя адаптера), `table` (опционально).
- **Примеры вызова**:
  - **Query String**: `/api/dvb/adapters/psi?name=dvb0&table=SDT`
  - **JSON Body**: `/api/dvb/adapters/psi` + `{"name": "dvb0", "table": "SDT"}`
- **Реализация**: Использует метод `get_psi()` объекта тюнера.
- **JSON-ответ**: Дамп таблиц.

### POST `/api/dvb/adapters/psi`
- **Описание**: Запуск обновления PSI таблиц.
- **Параметры**: `name` (имя адаптера).
- **Примеры вызова**:
  - **Query String**: `/api/dvb/adapters/psi?name=dvb0`
  - **JSON Body**: `/api/dvb/adapters/psi` + `{"name": "dvb0"}`
- **Реализация**: Вызывает `Adapter.update_dvb_psi`.
- **JSON-ответ**:
```json
{
  "message": "PSI update started"
}
```

### GET `/api/dvb/hardware/all`
- **Описание**: Возвращает список всех физических DVB-адаптеров.
- **Параметры**: Нет.
- **Примеры вызова**:
  - **Query String**: `/api/dvb/hardware/all`
- **Реализация**: Использует функцию `dvbls()` ядра Astra.
- **JSON-ответ**: Список объектов с параметрами адаптеров.

### POST `/api/dvb/adapters/tune`
- **Описание**: Настройка частоты и запуск мониторинга.
- **Параметры**: JSON с параметрами тюнера.
- **Примеры вызова**:
  - **JSON Body**: `/api/dvb/adapters/tune` + `{"name_adapter": "dvb0", "tp": "11044:V:43200"}`
- **Реализация**: Вызывает `Adapter.dvb_tuner_monitor`.
- **JSON-ответ**:
```json
{
  "message": "Adapter tuning and monitoring started"
}
```

### POST `/api/dvb/adapters/switch-transponder`
- **Описание**: Переключение транспондера.
- **Параметры**: `name` (имя адаптера) + новые параметры тюнера.
- **Примеры вызова**:
  - **Query String**: `/api/dvb/adapters/switch-transponder?name=dvb0&tp=11044:V:43200`
  - **JSON Body**: `/api/dvb/adapters/switch-transponder` + `{"name": "dvb0", "tp": "11044:V:43200"}`
- **Реализация**: Вызывает `Adapter.switch_transponder`.
- **JSON-ответ**:
```json
{
  "message": "Transponder switched successfully",
  "backup": { "tuner_params": {...}, "channels_configs": [...] }
}
```

### POST `/api/dvb/adapters/pause`
- **Описание**: Приостановка мониторинга адаптера.
- **Параметры**: `name` (имя адаптера).
- **Примеры вызова**:
  - **Query String**: `/api/dvb/adapters/pause?name=dvb0`
  - **JSON Body**: `/api/dvb/adapters/pause` + `{"name": "dvb0"}`
- **Реализация**: Вызывает `Adapter.pause_dvb_monitor`.
- **JSON-ответ**:
```json
{
  "message": "Adapter monitoring paused"
}
```

### POST `/api/dvb/adapters/resume`
- **Описание**: Возобновление мониторинга адаптера.
- **Параметры**: `name` (имя адаптера).
- **Примеры вызова**:
  - **Query String**: `/api/dvb/adapters/resume?name=dvb0`
  - **JSON Body**: `/api/dvb/adapters/resume` + `{"name": "dvb0"}`
- **Реализация**: Вызывает `Adapter.resume_dvb_monitor`.
- **JSON-ответ**:
```json
{
  "message": "Adapter monitoring resumed"
}
```

### POST `/api/dvb/adapters/restart`
- **Описание**: Перезапуск мониторинга адаптера.
- **Параметры**: `name` (имя адаптера), `force` (опционально).
- **Примеры вызова**:
  - **Query String**: `/api/dvb/adapters/restart?name=dvb0&force=true`
  - **JSON Body**: `/api/dvb/adapters/restart` + `{"name": "dvb0", "force": true}`
- **Реализация**: Вызывает `Adapter.restart_dvb_monitor`.
- **JSON-ответ**:
```json
{
  "message": "Adapter restarted successfully"
}
```

---

## Группа: System

### GET `/api/system/health`
- **Описание**: Проверяет состояние сервера.
- **Параметры**: Нет.
- **Примеры вызова**:
  - **Query String**: `/api/system/health`
- **Реализация**: Возвращает базовую информацию о системе.
- **JSON-ответ**:
```json
{
  "status": "healthy",
  "astra_version": "4.4.182",
  "server_time": "2026-01-07 15:16:53"
}
```

### GET `/api/system/resources`
- **Описание**: Возвращает метрики CPU, RAM, Disk, Network.
- **Параметры**: Нет.
- **Примеры вызова**:
  - **Query String**: `/api/system/resources`
- **Реализация**: Использует `ResourceMonitor.get_stats()`.
- **JSON-ответ**: Метрики системы.

### GET `/api/env/astra`
- **Описание**: Возвращает информацию о версии Astra и аптайме.
- **Параметры**: Нет.
- **Примеры вызова**:
  - **Query String**: `/api/env/astra`
- **Реализация**: Использует `astra_version` и данные из `ResourceMonitor`.
- **JSON-ответ**:
```json
{
  "astra": { "version": "4.4.182", "uptime": 3600 }
}
```

### POST `/api/system/reload`
- **Описание**: Перезагружает Astra.
- **Параметры**: `delay` (опционально).
- **Примеры вызова**:
  - **Query String**: `/api/system/reload?delay=5`
- **Реализация**: Использует `astra.reload()`.
- **JSON-ответ**:
```json
{
  "message": "Astra reload scheduled"
}
```

### POST `/api/system/exit`
- **Описание**: Останавливает Astra.
- **Параметры**: `delay` (опционально).
- **Примеры вызова**:
  - **Query String**: `/api/system/exit?delay=5`
- **Реализация**: Использует `astra.exit()`.
- **JSON-ответ**:
```json
{
  "message": "Astra exit scheduled"
}
```

---

## Группа: Subscribers

### GET `/api/subscribers`
- **Описание**: Возвращает список всех получателей данных.
- **Параметры**: Нет.
- **Примеры вызова**:
  - **Query String**: `/api/subscribers`
- **Реализация**: Использует `HttpSubscriber.get_subscribers()`.
- **JSON-ответ**:
```json
[
  { "event_type": "channels", "host": "192.168.1.100", "port": "8080", "path": "/api/webhook" }
]
```

### POST `/api/subscribers`
- **Описание**: Добавляет нового получателя.
- **Параметры**: JSON с `event_type`, `host`, `port`, `path`.
- **Примеры вызова**:
  - **JSON Body**: `/api/subscribers` + `{"event_type": "channels", "host": "..."}`
- **Реализация**: Вызывает `HttpSubscriber.subscribe`.
- **JSON-ответ**:
```json
{
  "message": "Subscribed successfully"
}
```

### DELETE `/api/subscribers`
- **Описание**: Удаляет получателя.
- **Параметры**: JSON с `event_type`, `host`, `port`, `path`.
- **Примеры вызова**:
  - **JSON Body**: `/api/subscribers` + `{"event_type": "channels", "host": "..."}`
- **Реализация**: Вызывает `HttpSubscriber.unsubscribe`.
- **JSON-ответ**:
```json
{
  "message": "Unsubscribed successfully"
}
```

---

## Группа: Utils

### GET `/api/utils/monitors/errors`
- **Описание**: Возвращает историю ошибок для монитора.
- **Параметры**: `name` (обязательно).
- **Примеры вызова**:
  - **Query String**: `/api/utils/monitors/errors?name=TV3`
  - **JSON Body**: `/api/utils/monitors/errors` + `{"name": "TV3"}`
- **Реализация**: Использует данные из `ChannelRepository`.
- **JSON-ответ**:
```json
{
  "name": "TV3",
  "current_status": { "ready": true, "cc_errors": 0 },
  "error_history": []
}
```

### GET `/api/utils/info`
- **Описание**: Возвращает информацию о версии API и доступных методах.
- **Параметры**: Нет.
- **Примеры вызова**:
  - **Query String**: `/api/utils/info`
- **Реализация**: Возвращает статические данные об API.
- **JSON-ответ**:
```json
{
  "api_version": "1.1.0",
  "library_version": "2.3.2",
  "supported_methods": ["GET", "POST", "PATCH", "DELETE"]
}
