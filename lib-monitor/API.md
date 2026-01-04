

## API Endpoints:

Все API-запросы требуют аутентификации с помощью заголовка `X-Api-Key`. Значение ключа устанавливается через переменную окружения `ASTRA_API_KEY` (по умолчанию "test"). Все успешные ответы содержат `"status": "ok"` (или `"healthy"` для health-check) и `"timestamp"`.

### Channel Routes (`/api/channels`)

*   **GET `/api/channels`**
    *   **Описание**: Получает список всех каналов, настроенных в системе Astra.
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Получает список всех каналов, настроенных в системе Astra может только через обращение к таблице channels_list. Если хотите получить поле display_name, то это нужно искать этот канал в списке мониторов ChannelStorage.
```json
        [
          {
            "name": "Discovery",
            "display_name": "Discovery HD",
            "output": ["udp://239.255.1.1:1234"]
          }
        ]
```

*   **GET `/api/channels/stats`**
    *   **Описание**: Возвращает агрегированную статистику по каналам (общее количество в Astra и детально по мониторингу).
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: total_astra_channels можно получить подсчитав количество каналов в channels_list. Остальные поля можно получить только с ChannelStorage, после анализа всех мониторов    
```json
        {
          "total_astra_channels": 50,
          "total_monitored": 10,
          "online": 8,
          "offline": 2,
          "with_errors": 1
        }
```

*   **GET `/api/channels/{id}`**
    *   **Описание**: Возвращает детальную информацию о канале (входы, выходы, карта PID). Ищет канал во всей системе Astra.
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Если убрать поле display_name, то это полный конфиг для создание каналов в функций make_channel. Все эти данные по именни канала можно получить из channels_list. Если хотите получить поле display_name, то это нужно искать этот канал в списке мониторов ChannelStorage, но я не вижу смысла в нем здесь
```json
        {
          "name": "Discovery",
          "input": ["http://..."],
          "output": ["udp://..."],
          "map": "..."
        }
```

*   **GET `/api/channels/{id}/inputs`**
    *   **Описание**: Возвращает список входов канала из конфигурации Astra и индекс активного входа (если запущен мониторинг).
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Все эти данные по именни канала можно получить из channels_list.
```json
        {
          "name": "Discovery",        
          "inputs": ["http://input1", "http://input2"],
          "active_input": 1
        }
```

*   **GET `/api/channels/{id}/psi`**
    *   **Описание**: Возвращает собранные PSI данные для канала.
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Все эти данные можно получить из ChannelStorage. Структура PSI-таблицы будет очень сложная.
```json
        {
          "name": "Discovery",
          "display_name": "Discovery HD",          
          "pmt": { "pid": 256, "streams": [...] },
          "sdt": { "pid": 17, "services": [...] }
        }
```
*   **POST `/api/channels/create`**
    *   **Описание**: Создает новый канал Astra (без автоматического мониторинга).
    *   **Параметры (JSON)**: Стандартная конфигурация канала Astra.
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Вызывается функция make_channel.
```json
        {
          "message": "Channel created"
        }
```

*   **POST `/api/channels/{id}/kill`**
    *   **Описание**: Останавливает или перезагружает канал Astra.
    *   **Параметры (Query String)**: `reboot` (boolean).
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Вызывается функция kill_channel. Чтобы перезапустить канал, нужно сохранить конфигурацию прошлого запуска и снова вызвать функцию make_channel. Желательно это делать с задержкой.
```json
        {
          "message": "Channel killed/rebooting",
          "config": { "name": "Discovery", "input": [...], "output": [...] }          
        }
```

### Stream Routes (`/api/streams`)

*   **POST `/api/streams`**
    *   **Описание**: Создает канал Astra и автоматически запускает для него мониторинг.
    *   **Параметры (JSON)**: Конфигурация канала + секция `monitor`.
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Вызывается функция make_stream.
```json
        {
          "message": "Stream and monitor created"
        }
```

*   **POST `/api/streams/{id}/kill`**
    *   **Описание**: Корректно останавливает и монитор, и канал.
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Вызывается функция kill_stream. Чтобы перезапустить канал, нужно сохранить конфигурацию прошлого запуска и снова вызвать функцию make_stream. Желательно это делать с задержкой.
```json
        {
          "message": "Stream and monitor killed",
          "config": { "name": "Discovery", "input": [...], "output": [...], "monitor": {...} }
        }
```

### DVB Routes (`/api/dvb`)

*   **GET `/api/dvb/adapters`**
    *   **Описание**: Получает список всех DVB-адаптеров, видимых ядром Astra.
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Есть два способа получить данные данные. Обратится к dvb_list, но здесь данные заполняются после выполнения функций dvb_tune(). Другой способ dvbls(), но я не знаю структуру возврата данных.
```json
        [
          { ... },
          { ... },
          { ... }          
        ]
```

*   **GET `/api/dvb/adapters/monitor`**
    *   **Описание**: Получает список всех DVB-адаптеров, для которых активен монитор.
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Вызывается метод get_all_dvb_monitors().
```json
        [
          "name1": "name1",
          "name2": "name2",
          "name3": "name3",
          ....   
        ]
```

*   **GET `/api/dvb/adapters/{id}/data`**
    *   **Описание**: Получает детальные метрики тюнера (Signal, SNR, Quality).
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Получить из DvbStorage объект монитора и обратится к полю self._json_cache, чтобы получить готовый json с последней отправки данных.
```json
        {
          "type": "dvb",
          "server": "astra-1",
          "format": "S2",
          "modulation": "QPSK",
          "source": "11044:V:43200",
          "name_adapter": "dvb0",
          "status": 1,
          "signal": 75.5,
          "snr": 24.8,
          "ber": 0,
          "unc": 0,
          "quality": 100
}
```

*   **POST `/api/dvb/adapters/{id}/psi/update`**
    *   **Описание**: Запускает 10-секундный процесс сбора PSI таблиц для адаптера.
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Выполнить функцию update_dvb_psi.
```json
        {
          "message": "PSI update started"
        }
```

*   **GET `/api/dvb/adapters/{id}/psi`**
    *   **Описание**: Возвращает собранные PSI данные из кэша.
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Выполнить функцию get_dvb_psi. Структура PSI-таблицы будет очень сложная.
```json
        {
          "pmt": { "pid": 256, "streams": [...] },
          "sdt": { "pid": 17, "services": [...] }
        }
```

*   **POST `/api/dvb/adapters/{id}/switch-transponder`**
    *   **Описание**: Сценарий переключения частоты с сохранением выходов зависимых каналов.
    *   **Параметры (JSON)**: `tp` (новые параметры тюнера), `reserve_input` (опционально).
    *   **Ответ**: `HTTP 200 OK`.
```json
        {
          "message": "Transponder switched successfully",
          "backup": { "tuner_params": {...}, "channels_configs": [...] }
        }
```

*   **POST `/api/dvb/adapters/{id}/pause` / `resume`**
    *   **Описание**: Управление активностью мониторинга адаптера.
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Выполнить функцию pause_dvb_monitor/ resume_dvb_monitor
```json
        {
          "message": "Adapter monitoring paused/resumed"
        }
```

*   **POST `/api/adapters/{id}/update`**
    *   **Описание**: Обновляет параметры монитора (rate, time_check, method_comparison).
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Выполнить функцию update_dvb_monitor_parameters.
```json
        {
          "message": "Monitor updated"
        }
```

### Monitor Routes (`/api/monitors`)

*   **GET `/api/monitors`**
    *   **Описание**: Получает список всех активных мониторов каналов.
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Получить из ChannelStorage.
```json
        [
          { "name": "Discovery", "display_name": "Discovery HD", "type": "output" }
        ]
```

*   **GET `/api/monitors/{id}/data`**
    *   **Описание**: Получает текущее состояние потока (Bitrate, CC, Scrambled).
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Получить из ChannelStorage объект монитора и обратится к полю self._json_cache, чтобы получить готовый json с последней отправки данных.
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

*   **POST `/api/monitors/create`**
    *   **Описание**: Создает новый монитор для существующего канала.
    *   **Параметры (JSON)**: Конфигурация монитора.
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Вызывается функция make_monitor.
```json
        {
          "message": "Monitor created"
        }
```

*   **POST `/api/monitors/{id}/update`**
    *   **Описание**: Обновляет параметры монитора (rate, time_check, method_comparison).
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Выполнить функцию update_monitor_parameters.
```json
        {
          "message": "Monitor updated"
        }
```

*   **POST `/api/monitors/{id}/pause` / `resume`**
    *   **Описание**: Приостановка/возобновление анализа потока.
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Выполнить функцию pause_monitor/ resume_monitor.
```json
        {
          "message": "Monitoring paused/resumed"
        }
```

*   **POST `/api/monitors/{id}/kill`**
    *   **Описание**: Удаляет монитор (без удаления канала).
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Вызывается функция kill_monitor. Чтобы перезапустить канал, нужно сохранить конфигурацию прошлого запуска и снова вызвать функцию make_monitor. Желательно это делать с задержкой.
```json
        {
          "message": "Monitor killed",
          "config": { "name": "Discovery", "monitor": "output" }
        }
```

*   **GET `/api/monitors/{id}/pids`**
    *   **Описание**: Получает детальную статистику ошибок в разрезе каждого PID.
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Получить из ChannelStorage объект монитора и обратится к функций get_stats().
```json
        {
          "256": { "type": "VIDEO", "cc": 10, "pes": 0, "sc": 0 },
          "257": { "type": "AUDIO", "cc": 0, "pes": 0, "sc": 0 }
        }
```

*   **GET `/api/monitors/{id}/rate_stat`**
    *   **Описание**: Получает детальную статистику по bitrate.
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Получить из ChannelStorage объект монитора и обратится к функций get_rate_stat().


*   **POST `/api/monitors/{id}/pids/clear`**
    *   **Описание**: Сбрасывает накопленную статистику по PID и rate_stat.
    *   **Ответ**: `HTTP 200 OK`.
    *   **Способ реализаций**: Получить из ChannelStorage объект монитора и обратится к функций clear_stats().
```json
        {
          "message": "PID stats cleared"
        }
```

### System Routes (`/api/system`)

*   **GET `/api/system/reload`**
    *   **Описание**: Перезагружает Astra.
    *   **Способ реализаций**: Стоит добавить задержку.
    *   **Ответ**: `HTTP 200 OK`.

*   **GET `/api/system/exit`**
    *   **Описание**: Останавливает Astra.
    *   **Способ реализаций**: Стоит добавить задержку.
    *   **Ответ**: `HTTP 200 OK`.


*   **GET `/api/system/resources`**
    *   **Описание**: Получает данные о системных ресурсах (CPU, Memory, Network).
    *   **Ответ**: `HTTP 200 OK`.
```json
        {
          "cpu": { "total": 12.5, "temp_c": 45.0 },
          "memory": { "rss_kb": 262809, "lua_kb": 1500 },
          "network": { "eth0": { "rx_bps": 1250000, "tx_bps": 750000 } }
        }
```

*   **GET `/api/system/health`**
    *   **Описание**: Проверяет состояние сервера мониторинга.
    *   **Ответ**: `HTTP 200 OK`.
```json
        {
          "status": "healthy",
          "pid": 12345,
          "astra_version": "4.4.182",
          "server_time": "2024-01-15 14:30:00"
        }
```