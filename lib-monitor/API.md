# lib-monitor HTTP API Documentation

Все API-запросы требуют аутентификации с помощью заголовка `X-Api-Key`.

---

## Группа: Channels
**GET `/api/channels`**: Список всех каналов.
**GET `/api/channels/stats`**: Агрегированная статистика.
**GET `/api/channels/{name}`**: Детальная информация о канале.
**DELETE `/api/channels/{name}`**: Удаление/перезапуск канала.
**POST `/api/channels`**: Создание нового канала.

---

## Группа: Streams
**POST `/api/streams`**: Создание потока с мониторингом.
**DELETE `/api/streams/{name}`**: Удаление потока и монитора.

---

## Группа: Monitors
**GET `/api/monitors`**: Список активных мониторов.
**GET `/api/monitors/status`**: Сводный статус.
**GET `/api/monitors/{name}`**: Метрики конкретного монитора.
**POST `/api/monitors`**: Создание монитора.
**PATCH `/api/monitors/{name}`**: Обновление параметров.
**DELETE `/api/monitors/{name}`**: Удаление монитора.

---

## Группа: DVB Adapters
**GET `/api/dvb/adapters`**: Список используемых адаптеров.
**GET `/api/dvb/adapters/{name_adapter}`**: Состояние тюнера.
**POST `/api/dvb/adapters/{name_adapter}/tune`**: Настройка частоты.

---

## Группа: System

### GET `/api/system/health`
- **Описание**: Проверяет состояние сервера и возвращает детальные метрики процесса Astra.
- **JSON-ответ**:
```json
{
  "status": "healthy",
  "astra_version": "4.4.182",
  "server_time": "2026-01-07 18:56:00",
  "timestamp": 1767801360,
  "resources": {
    "pid": 1234,
    "uptime": 3600,
    "cpu": { "usage": 12.5, "user": 10.2, "system": 2.3, "threads": 8 },
    "memory": { "lua": 1024, "resident": 51200, "virtual": 150000 },
    "network": [
      { "interface": "eth0", "ip": "192.168.1.10" }
    ]
  }
}
```

**POST `/api/system/reload`**: Перезагрузка Astra.
**POST `/api/system/exit`**: Остановка Astra.
**GET `/api/system/network/interfaces`**: Список сетевых интерфейсов.
**GET `/api/system/network/hostname`**: Имя хоста.

---

## Группа: Subscribers
**GET `/api/subscribers`**: Список получателей Webhooks.
**POST `/api/subscribers`**: Добавление подписки.
**DELETE `/api/subscribers`**: Удаление подписки.

---

## Группа: Utils
**GET `/api/utils/info`**: Информация о версии API.
