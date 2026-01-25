-- ===========================================================================
-- Модуль `core.event_dispatcher`
--
-- Центральная шина событий для системы мониторинга.
-- Реализует очередь с приоритетами, асинхронную обработку и кэш последних состояний (LVC).
-- Поддерживает маски (wildcards) в именах событий через SubscriptionManager.
-- ===========================================================================

-- 1. Стандартные Lua функции
local type = _G.type
local tostring = _G.tostring
local pairs = _G.pairs
local table_insert = _G.table.insert
local table_remove = _G.table.remove
local os_clock = _G.os.clock
local pcall = _G.pcall
local setmetatable = _G.setmetatable
local collectgarbage = _G.collectgarbage

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local SubscriptionManager = ModuleManager.get_module("core.subscription_manager")
local TablePool = ModuleManager.get_module("table_pool")
local Scheduler = ModuleManager.get_module("core.scheduler")

-- 3. Глобальные зависимости Astra
local _json_encode = nil

--- Возвращает функцию json.encode
--- @return function|nil
local function get_json_encode()
    if _json_encode then return _json_encode end
    _json_encode = ModuleManager.get_global_dependency("json.encode")
    return _json_encode
end

-- 4. Константы и конфигурации
local COMPONENT_NAME = "EventDispatcher"

--- Локальная конфигурация модуля (значения по умолчанию)
local _m_config = {
    LvcTtl = 3600,
    MaxLvcSize = 1000,
    MaxQueueSize = 1000,
    EventBatchLimit = 100,
    MaxBatchLimit = 1000,
    MaxTickTime = 0.005,
}

-- 5. Внутреннее состояние (Private State)
--- @class EventDispatcherState
--- @field instance EventDispatcher|nil Единственный экземпляр (Singleton)
--- @field event_counter number Счетчик для генерации ID событий
local state = {
    instance = nil,
    event_counter = 0,
}

--- @class EventDispatcher
--- @field public subscription_manager SubscriptionManager Менеджер подписок
--- @field private _lvc table<string, table> Кэш последних значений (Last Value Cache)
--- @field private _lvc_keys table<number, string> Очередь ключей для FIFO вытеснения из LVC
--- @field private _lvc_head number Индекс головы очереди ключей LVC
--- @field private _lvc_tail number Индекс хвоста очереди ключей LVC
--- @field private _lvc_size number Текущий размер LVC
--- @field private _last_lvc_check_key any Последний проверенный ключ в LVC (для инкрементальной очистки)
--- @field private event_queues table<number, table> Очереди событий по приоритетам
--- @field private _total_queued_count number Общее количество событий в очередях
--- @field private _active_queues_mask number Битовая маска активных очередей
--- @field private stats table Статистика диспетчера
--- @field private active boolean Флаг активности обработки
local EventDispatcher = {}
EventDispatcher.__index = EventDispatcher

-- ===========================================================================
-- Внутренние функции (Private/Protected)
-- ===========================================================================

--- Генерация уникального ID события
--- @private
--- @return string ID события
local function _generate_event_id()
    state.event_counter = state.event_counter + 1
    return "evt_" .. state.event_counter
end

--- Копирует таблицу, используя пул для всех уровней вложенности.
--- Оптимизировано: итеративный подход для предотвращения переполнения стека.
--- @private
--- @param data any Данные для копирования (таблица или примитив)
--- @return any Глубокая копия данных, размещенная в пуле таблиц
local function _deep_copy_to_pool(data)
    if type(data) ~= "table" then return data end

    local visited = {}
    local root_copy = TablePool.get("lvc_sub")
    visited[data] = root_copy

    local stack = { { src = data, dst = root_copy } }
    local stack_ptr = 1

    while stack_ptr > 0 do
        local curr = stack[stack_ptr]
        local src = curr.src
        local dst = curr.dst
        stack_ptr = stack_ptr - 1

        for k, v in pairs(src) do
            -- Защита от копирования служебных полей пула
            if k ~= "__pool_type" and k ~= "__in_pool" then
                if type(v) == "table" then
                    if visited[v] then
                        dst[k] = visited[v]
                    else
                        local v_copy = TablePool.get("lvc_sub")
                        visited[v] = v_copy
                        dst[k] = v_copy
                        stack_ptr = stack_ptr + 1
                        stack[stack_ptr] = { src = v, dst = v_copy }
                    end
                else
                    dst[k] = v
                end
            end
        end
    end

    return root_copy
end

--- Инициализирует диспетчер событий, создает менеджер подписок и запускает обработчик очереди
--- @private
function EventDispatcher:_initialize()
    -- Тонкая настройка Garbage Collector для инкрементальной очистки
    -- (Значения по умолчанию, будут обновлены через события System)
    collectgarbage("setpause", 100)
    collectgarbage("setstepmul", 500)

    self.subscription_manager = SubscriptionManager.new()

    -- Кэш последних значений (Last Value Cache)
    -- Используется для мгновенного получения состояния при подписке
    self._lvc = {}
    self._lvc_keys = {}
    self._lvc_head = 1
    self._lvc_tail = 1
    self._lvc_size = 0

    -- Очереди событий по приоритетам (FIFO круговые буферы)
    self.event_queues = {}
    self._total_queued_count = 0
    self._active_queues_mask = 0
    for _, p in pairs(self.PRIORITIES) do
        self.event_queues[p] = {
            data = {},
            head = 1,
            tail = 1,
            size = 0,
            max_size = _m_config.MaxQueueSize,
            priority_bit = 2 ^ (p - 1)
        }
    end

    self.stats = {
        emitted = 0,
        processed = 0,
        dropped = 0,
        max_queue_size = 0,
        last_reset = os_clock()
    }

    self.active = true
    self:_start_queue_processor()

    Logger.info(COMPONENT_NAME,
        "Диспетчер событий инициализирован с поддержкой LVC и масок (Wildcards)")
end

--- Приоритеты событий (1 - самый высокий, 4 - самый низкий)
--- @type table<string, number>
EventDispatcher.PRIORITIES = {
    CRITICAL = 1,
    HIGH = 2,
    MEDIUM = 3,
    LOW = 4
}

--- Стандартные имена событий системы
--- @type table<string, string>
EventDispatcher.EVENTS = {
    ADAPTER_STOPPED = "adapter:stopped",
    CHANNEL_CREATED = "channel:created",
    CHANNEL_KILLED = "channel:killed",
    MONITOR_ERROR = "monitor:error",
    SYS_CONNECTED = "sys:connected"
}

--- Возвращает единственный экземпляр EventDispatcher (Singleton)
--- @return EventDispatcher Экземпляр диспетчера
function EventDispatcher.get_instance()
    if not state.instance then
        state.instance = setmetatable({}, EventDispatcher)
        state.instance:_initialize()
    end
    return state.instance
end


--- Вспомогательная функция для очистки записи LVC и возврата таблиц в пул
--- @private
--- @param entry table Запись LVC
function EventDispatcher:_release_lvc_entry(entry)
    if not entry then return end
    if TablePool then
        -- Используем автоматический рекурсивный возврат вложенных таблиц
        TablePool.release(entry, "lvc_wrapper", true)
    end
end

--- Инициализирует подписку на обновление конфигурации
function EventDispatcher:init_config_subscription()
    self:subscribe("config:updated:event", function(new_config)
        for k, v in pairs(new_config) do
            _m_config[k] = v
        end
        -- Обновляем лимиты очередей
        for _, queue in pairs(self.event_queues) do
            queue.max_size = _m_config.MaxQueueSize
        end
        Logger.info(COMPONENT_NAME, "Конфигурация событий обновлена")
    end)

    self:subscribe("config:updated:system", function(new_config)
        if new_config.GcPause then collectgarbage("setpause", new_config.GcPause) end
        if new_config.GcStepMul then collectgarbage("setstepmul", new_config.GcStepMul) end
    end)
end

--- Публикует событие в систему.
--- Реализует гибридную модель доставки:
--- 1. Fast Path (Direct Multicast): мгновенная отправка простым подписчикам.
--- 2. Queue Path (Event-Driven): асинхронная обработка через очередь для сложных подписчиков.
--- @param event_type string Тип события (например, "channel:error")
--- @param event_data table|string Данные события
--- @param priority? number Приоритет события (1 - Critical, 4 - Low). По умолчанию 3 (Medium).
--- @param options? table Дополнительные параметры: source (источник), no_cache (не сохранять в LVC), is_table (данные из пула).
--- @return string|nil ID созданного события или nil при ошибке
function EventDispatcher:emit(event_type, event_data, priority, options)
    -- io.write(string.format("DEBUG: EventDispatcher:emit(%s)\n", tostring(event_type)))
    if not self.active then return nil end

    -- Защита от "призрачных" вызовов: если монитор-источник уже уничтожен, игнорируем событие
    if options and options.source_monitor then
        local monitor = options.source_monitor
        -- STATE.STOPPED = 3
        if monitor.get_state and monitor:get_state() == 3 then
            return nil
        end
    end

    local now = os_clock()
    local p = priority or self.PRIORITIES.MEDIUM
    local sub_mgr = self.subscription_manager

    -- Оптимизация: Smart Emit (Fast Path)
    -- Проверяем план доставки перед созданием объекта события
    local plan = sub_mgr:get_delivery_plan(event_type)
    local fast_path_delivered = false

    if not plan then
        -- Если нет подписчиков и не нужно кэшировать в LVC, выходим немедленно
        if options and options.no_cache then return nil end
    else
        -- Если есть простые подписчики и нет сложных (или их мало), используем Direct Multicast
        -- Лимит в 10 простых групп для предотвращения блокировки основного потока
        if not plan.has_complex and plan.total_simple > 0 and plan.total_simple <= 10 then
            sub_mgr:multicast_direct(plan, event_type, event_data, now)
            fast_path_delivered = true
            
            -- Если не нужно кэшировать в LVC, задача выполнена без создания объектов
            if options and options.no_cache then
                self.stats.emitted = self.stats.emitted + 1
                -- Если данные из пула, освобождаем их
                if options.is_table and TablePool then
                    TablePool.release(event_data, nil, true)
                end
                return "direct_push"
            end
        end
    end

    -- Load Shedding: защита от перегрузок (сброс низкоприоритетных событий)
    local total_capacity = _m_config.MaxQueueSize * 4
    if self._total_queued_count > (total_capacity * 0.9) then
        if p == self.PRIORITIES.LOW then
            self.stats.dropped = self.stats.dropped + 1
            if TablePool then
                if options and options.__pool_type then
                    TablePool.release(options, options.__pool_type, true)
                end
                if options and options.is_table then
                    TablePool.release(event_data, nil, true)
                end
            end
            return nil
        end
    end
    if self._total_queued_count > (total_capacity * 0.95) then
        if p == self.PRIORITIES.MEDIUM then
            self.stats.dropped = self.stats.dropped + 1
            if TablePool then
                if options and options.__pool_type then
                    TablePool.release(options, options.__pool_type, true)
                end
                if options and options.is_table then
                    TablePool.release(event_data, nil, true)
                end
            end
            return nil
        end
    end

    -- Оптимизация: Subscription-aware Emitting
    -- Если нет подписчиков (плана) и не нужно кэшировать, выходим
    local no_cache = options and options.no_cache
    if no_cache and not plan then
        return nil
    end

    -- Обновляем LVC (если не запрещено в опциях)
    if not no_cache then
        -- Ограничить размер LVC для предотвращения утечек памяти (Burst Eviction)
        if not self._lvc[event_type] then
            if self._lvc_size >= _m_config.MaxLvcSize then
                -- Вытесняем пачкой по 5 записей для стабильности при шторме новых типов
                for _ = 1, 5 do
                    local oldest_key = self._lvc_keys[self._lvc_head]
                    if oldest_key then
                        self._lvc_keys[self._lvc_head] = nil
                        self._lvc_head = (self._lvc_head % _m_config.MaxLvcSize) + 1
                        self._lvc_size = self._lvc_size - 1

                        local old_entry = self._lvc[oldest_key]
                        self:_release_lvc_entry(old_entry)
                        self._lvc[oldest_key] = nil
                    end
                    if self._lvc_size < _m_config.MaxLvcSize then break end
                end
            end
            self._lvc_keys[self._lvc_tail] = event_type
            self._lvc_tail = (self._lvc_tail % _m_config.MaxLvcSize) + 1
            self._lvc_size = self._lvc_size + 1
        end

        local cache_data = event_data

        if type(event_data) == "table" then
            -- Глубокое копирование данных в пул для LVC
            cache_data = TablePool.get("lvc_entry")
            for k, v in pairs(event_data) do
                -- Защита от копирования служебных полей пула
                if k ~= "__pool_type" and k ~= "__in_pool" then
                    cache_data[k] = _deep_copy_to_pool(v)
                end
            end
        end

        -- Если в LVC уже есть данные для этого типа, возвращаем их в пул
        local old_entry = self._lvc[event_type]
        self:_release_lvc_entry(old_entry)

        local entry = TablePool and TablePool.get("lvc_wrapper") or {}
        entry.data = cache_data
        -- Оптимизация: ленивое кодирование JSON для LVC (Zero-copy)
        entry.json = (type(event_data) ~= "table") and tostring(event_data) or nil
        entry.timestamp = now
        self._lvc[event_type] = entry
    end

    local event = TablePool and TablePool.get("event") or {}

    event.id = _generate_event_id()
    event.type = event_type
    event.data = event_data
    event.priority = p
    event.timestamp = (type(event_data) == "table" and event_data.timestamp) or now
    event.options = options
    event.is_table = options and options.is_table == true
    event.fast_path_delivered = fast_path_delivered

    local queue = self.event_queues[p]
    if queue then
        -- Обновление метрики максимального размера
        if queue.size + 1 > self.stats.max_queue_size then
            self.stats.max_queue_size = queue.size + 1
        end

        -- Вставка в круговую очередь
        if queue.size >= queue.max_size then
            -- Вытеснение старого события (O(1))
            local dropped_event = queue.data[queue.head]
            queue.data[queue.head] = nil
            queue.head = (queue.head % queue.max_size) + 1
            queue.size = queue.size - 1
            self._total_queued_count = self._total_queued_count - 1

            if dropped_event then
                -- Возврат в пул (рекурсивно если is_table)
                self:_safe_return_to_pool(dropped_event)
            end
            self.stats.dropped = self.stats.dropped + 1
        end

        queue.data[queue.tail] = event
        queue.tail = (queue.tail % queue.max_size) + 1
        queue.size = queue.size + 1
        self._total_queued_count = self._total_queued_count + 1
        self._active_queues_mask = bit32.bor(self._active_queues_mask, queue.priority_bit)
    end

    self.stats.emitted = self.stats.emitted + 1
    return event.id
end

--- Публикует событие в систему с защитой от ошибок (pcall).
--- @param event_type string Тип события
--- @param event_data table|string Данные события
--- @param priority? number Приоритет
--- @param options? table Дополнительные параметры
--- @return string|nil ID созданного события или nil при ошибке
function EventDispatcher:emit_safe(event_type, event_data, priority, options)
    local ok, result = pcall(self.emit, self, event_type, event_data, priority, options)

    if not ok then
        Logger.error(COMPONENT_NAME, "Ошибка публикации события: %s", tostring(result))
        return nil
    end

    return result
end

--- Возвращает последние известные значения (LVC) для указанного типа события.
--- Поддерживает маски (wildcards), например "channel:*".
--- @param event_type string Тип события или маска
--- @return table<string, table> Таблица последних событий, где ключ - точное имя события
function EventDispatcher:get_last_values(event_type)
    local result = {}

    -- Оптимизация: Прямой поиск, если нет масок (O(1))
    if not event_type:find("*", 1, true) and not event_type:find("?", 1, true) then
        local entry = self._lvc[event_type]
        if entry then
            result[event_type] = entry
        end
        return result
    end

    -- Используем SubscriptionManager для сопоставления масок (O(N))
    for name, entry in pairs(self._lvc) do
        if self.subscription_manager:match(event_type, name) then
            result[name] = entry
        end
    end
    return result
end

--- Регистрирует новую подписку на события.
--- @param event_type string Тип события или маска (например, "adapter:*")
--- @param callback function|table Функция-обработчик или конфигурация транспорта
--- @param filters? table Схема фильтрации (условия, операторы или Lua-скрипт)
--- @param options? table Дополнительные опции: throttle_ms (ограничение частоты), send_lvc (отправить последнее состояние сразу)
--- @return string|nil ID подписки (UUID)
function EventDispatcher:subscribe(event_type, callback, filters, options)
    local sub_id = self.subscription_manager:subscribe(event_type, {
        callback = callback,
        filters = filters,
        batch_mode = options and options.batch_mode,
        throttle_ms = options and options.throttle_ms
    })

    -- Если запрошено получение последнего состояния при подписке
    if sub_id and options and type(options) == "table" and options.send_lvc then
        local last_values = self:get_last_values(event_type)
        for name, entry in pairs(last_values) do
            -- Отправляем немедленно (вне очереди) для инициализации подписчика
            -- Оптимизировано: передаем весь объект entry (с .data и .json)
            self.subscription_manager:publish_to_single(sub_id, name, entry)
        end
    end

    return sub_id
end

--- Удаляет подписку на события.
--- @param sub_id string ID подписки
--- @return boolean Статус выполнения
function EventDispatcher:unsubscribe(sub_id)
    if not self.subscription_manager then return false end
    return self.subscription_manager:unsubscribe(sub_id)
end

--- Запускает фоновый таймер для обработки очереди событий через планировщик
--- @private
function EventDispatcher:_start_queue_processor()
    if not Scheduler then return end

    local scheduler = Scheduler.get_instance()
    -- Интервал планировщика будет обновляться через события System
    local interval = 1

    scheduler:add_task("event_dispatcher_queue", function()
        if self.active then self:_process_queue() end
    end, interval)
end

--- Извлекает события из очередей в порядке приоритета и передает их в SubscriptionManager.
--- Реализует инкрементальную очистку LVC и обработку батчей событий.
--- @private
function EventDispatcher:_process_queue()
    local now = os_clock()
    local sub_mgr = self.subscription_manager

    -- Инкрементальная очистка старых записей LVC (TTL)
    -- Оптимизация: проверяем по 10-20 записей за тик.
    local lvc_ttl = _m_config.LvcTtl
    local check_limit = (self._lvc_size > _m_config.MaxLvcSize * 0.8) and 20 or 10
    local checked = 0
    local current_key = self._last_lvc_check_key
    
    while checked < check_limit do
        local k, entry = next(self._lvc, current_key)
        if not k then 
            current_key = nil
            break 
        end
        
        if entry and now - entry.timestamp > lvc_ttl then
            self:_release_lvc_entry(entry)
            self._lvc[k] = nil
            self._lvc_size = self._lvc_size - 1
        else
            current_key = k
        end
        checked = checked + 1
    end
    self._last_lvc_check_key = current_key

    local limit = _m_config.EventBatchLimit
    
    -- Адаптивная частота: если суммарный размер очередей > 50%, увеличиваем лимит
    -- Оптимизировано: используем _total_queued_count вместо цикла
    if self._total_queued_count > (_m_config.MaxQueueSize * 0.5) then
        limit = math.min(_m_config.MaxBatchLimit, limit * 2)
    end

    local processed_in_batch = 0
    local start_time = os_clock()
    local priorities = self.PRIORITIES
    local mask = self._active_queues_mask

    for p = priorities.CRITICAL, priorities.LOW do
        local queue = self.event_queues[p]
        
        -- Оптимизация: проверяем маску перед входом в цикл очереди
        if bit32.band(mask, queue.priority_bit) ~= 0 then
            local q_data = queue.data
            local q_max = queue.max_size

            while queue.size > 0 do
                local event = q_data[queue.head]
                q_data[queue.head] = nil
                queue.head = (queue.head % q_max) + 1
                queue.size = queue.size - 1

                if event then
                    local ok, err = pcall(sub_mgr.publish_event, sub_mgr, event, now)

                    if not ok then
                        Logger.error(COMPONENT_NAME, "Не удалось обработать событие %s: %s",
                            event.id or "неизвестно", tostring(err))
                    else
                        self.stats.processed = self.stats.processed + 1
                    end

                    -- Возврат в пул
                    self:_safe_return_to_pool(event)
                end

                self._total_queued_count = self._total_queued_count - 1
                processed_in_batch = processed_in_batch + 1

                -- Time-Slicing: прерываем если превышен лимит времени или батча
                if processed_in_batch >= limit or (os_clock() - start_time) >= _m_config.MaxTickTime then
                    return -- Прерываем обработку до следующего тика
                end
            end
            
            -- Если очередь пуста, сбрасываем бит в маске
            self._active_queues_mask = bit32.band(self._active_queues_mask, bit32.bnot(queue.priority_bit))
        end
    end
end

--- Безопасно возвращает таблицы события в пул.
--- @private
--- @param event table Объект события
function EventDispatcher:_safe_return_to_pool(event)
    if not TablePool or not event then return end

    local ok, err = pcall(TablePool.release, event, "event", event.is_table == true)

    if not ok then
        Logger.warning(COMPONENT_NAME, "Не удалось вернуть событие в пул: %s", tostring(err))
    end
end

--- Останавливает диспетчер событий и очищает очереди.
function EventDispatcher:shutdown()
    self.active = false
    state.instance = nil
    Logger.info(COMPONENT_NAME, "Остановка диспетчера событий...")

    if Scheduler then
        Scheduler.get_instance():remove_task("event_dispatcher_queue")
    end

    -- Остановка менеджера подписок (сброс батчей и сохранение)
    if self.subscription_manager then
        self.subscription_manager:shutdown()
    end

    -- Очистка очередей
    for _, queue in pairs(self.event_queues) do
        while queue.size > 0 do
            local event = queue.data[queue.head]
            queue.data[queue.head] = nil
            queue.head = (queue.head % queue.max_size) + 1
            queue.size = queue.size - 1
            self:_safe_return_to_pool(event)
        end
    end

    -- Очистка LVC
    for name, entry in pairs(self._lvc) do
        self:_release_lvc_entry(entry)
        self._lvc[name] = nil
    end
    self._lvc_keys = {}
    self._lvc_head = 1
    self._lvc_tail = 1
    self._lvc_size = 0
end

-- ===========================================================================
-- Инициализация модуля
-- ===========================================================================

-- Регистрация пулов при загрузке модуля
local tp = ModuleManager.get_module("table_pool")
if tp then
    tp.register_type("event", {
        "id", "type", "data", "priority", "timestamp", "options", "is_table", "json_cache"
    }, 500, 50)
    tp.register_type("event_options", nil, 500, 50, true)
    tp.register_type("lvc_wrapper", { "data", "json", "timestamp" }, 200, 20)
    -- lvc_entry и lvc_sub не должны быть flat, так как могут содержать вложенные таблицы из пула
    tp.register_type("lvc_entry", nil, 500, 50)
    tp.register_type("lvc_sub", nil, 200, 20)
end

return EventDispatcher
