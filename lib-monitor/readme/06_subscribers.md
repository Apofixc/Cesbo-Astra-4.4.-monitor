# Методы получения данных (Push/Pull)

Библиотека `lib-monitor` поддерживает гибкие механизмы доставки данных, адаптированные под различные сценарии использования.

## 1. Pull-метод (HTTP API)

Классический метод получения данных по запросу. Клиент (например, Zabbix или Grafana) периодически опрашивает API-эндпоинты.
*   **Преимущества**: Простота реализации на стороне клиента, отсутствие необходимости держать постоянное соединение.
*   **Эндпоинты**: `/api/monitors/data`, `/api/dvb/adapters/data`, `/api/system/health`.

## 2. Push-методы (Транспорты)

Система поддерживает различные способы доставки уведомлений и метрик. Все внешние вызовы (кроме стандартного HTTP) выполняются асинхронно через системный `curl`, что гарантирует поддержку HTTPS и отсутствие блокировок основного потока Astra.

### Поддерживаемые транспорты:

| Тип | Описание | Параметры конфигурации |
| :--- | :--- | :--- |
| `HTTP` | Стандартный Webhook | `host`, `port`, `path` |
| `TELEGRAM` | Уведомления в Telegram | `token`, `chat_id` |
| `INFLUXDB` | Метрики в InfluxDB v3 | `host`, `port`, `token`, `org`, `bucket`, `ssl` |
| `DISCORD` | Webhook в Discord | `url` |
| `SLACK` | Webhook в Slack | `url` |
| `GOTIFY` | Push через Gotify | `url`, `token`, `priority` |
| `PUSHOVER` | Push через Pushover | `token`, `user`, `priority` |
| `GENERIC_WEBHOOK` | Универсальный HTTP запрос | `url`, `method`, `headers` |

### Примеры конфигурации подписок:

**Telegram:**
```json
{
  "event_type": "channel:*",
  "callback": {
    "type": "TELEGRAM",
    "token": "123456:ABCDEF...",
    "chat_id": "-100..."
  }
}
```

**InfluxDB v3:**
```json
{
  "event_type": "sys:resource",
  "callback": {
    "type": "INFLUXDB",
    "host": "influx.example.com",
    "bucket": "astra_metrics",
    "token": "my-secret-token",
    "ssl": true
  }
}
```

## 3. Real-time метод (WebSocket)

Наиболее эффективный метод для создания "живых" панелей мониторинга.
*   **Эндпоинт**: `ws://[addr]:[port]/api/ws`.
*   **Протокол**:
    1.  Клиент подключается.
    2.  Клиент отправляет команду подписки: `{"command": "subscribe", "event_type": "channel:*"}`.
    3.  Сервер начинает стримить события.
*   **Команды WebSocket**:
    *   `subscribe`: Подписка на тип события.
    *   `unsubscribe`: Отмена подписки.
    *   `batch`: Включение/выключение пакетной отправки для этого соединения.
*   **Оптимизация**: Использование **Hybrid LVC** позволяет мгновенно отправить последнее состояние сразу после подписки без нагрузки на CPU.

## 4. Форматы событий

### Событие `channels` (Мониторинг каналов)
```json
{
  "type": "Channel",
  "channel": "Discovery",
  "display_name": "Discovery HD",
  "monitor": "output",
  "ready": true,
  "bitrate": 12500,
  "cc_errors": 0,
  "timestamp": 1673791200
}
```

### Событие `dvb` (Мониторинг DVB-адаптеров)
```json
{
  "type": "dvb",
  "name_adapter": "dvb0",
  "has_lock": true,
  "signal": 75.5,
  "snr": 24.8,
  "bitrate": 45000,
  "timestamp": 1673791200
}
```

### Событие `sys:resource_warning` (Системные алерты)
```json
{
  "type": "system",
  "resource": "cpu",
  "value": 95.2,
  "threshold": 90.0,
  "message": "High CPU usage detected",
  "timestamp": 1673791200
}
