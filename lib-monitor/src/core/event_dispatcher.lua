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
local os_time = _G.os.time
local pcall = _G.pcall
local setmetatable = _G.setmetatable
local collectgarbage = _G.collectgarbage

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local SubscriptionManager = ModuleManager.get_module("core.subscription_manager")
local TablePool = ModuleManager.get_module("table_pool")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local Scheduler = ModuleManager.get_module("core.scheduler")

-- 3. Глобальные зависимости Astra
-- (Используем Scheduler вместо прямого обращения к timer)

-- 4. Константы и конфигурации
local COMPONENT_NAME = "EventDispatcher"

--- Максимальный размер LVC (Last Value Cache)
local MAX_LVC_SIZE = 1000
--- Максимальный размер очереди событий на один приоритет
local MAX_QUEUE_SIZE = 1000
--- Лимит обработки событий за один тик планировщика
local DEFAULT_BATCH_LIMIT = 100
--- TTL для записей LVC по умолчанию (1 час)
local DEFAULT_LVC_TTL = 3600

-- 5. Внутреннее состояние (Private State)
--- @class EventDispatcherState
--- @field instance EventDispatcher|nil Единственный экземпляр (Singleton)
--- @field event_counter number Счетчик для генерации ID событий
local state = {
    instance = nil,
    event_counter = 0,
}

-- ===========================================================================
-- Внутренние функции (Private)
-- ===========================================================================

--- Генерация уникального ID события
--- @return string
local function _generate_event_id()
    state.event_counter = state.event_counter + 1
    return "evt_" .. state.event_counter
end

--- Рекурсивно копирует таблицу, используя пул для всех уровней вложенности
--- @param data any Данные для копирования
--- @return any Копия данных
local function _deep_copy_to_pool(data)
    if type(data) ~= "table" then return data end

    local copy = TablePool.get("lvc_sub")
    for k, v in pairs(data) do
        copy[k] = _deep_copy_to_pool(v)
    end
    return copy
end

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- @class EventDispatcher
--- @field public subscription_manager SubscriptionManager Менеджер подписок
--- @field private _lvc table<string, table> Кэш последних значений (Last Value Cache)
--- @field private _lvc_keys table<number, string> Очередь ключей для FIFO вытеснения из LVC
--- @field private _lvc_head number Индекс головы очереди ключей LVC
--- @field private _lvc_tail number Индекс хвоста очереди ключей LVC
--- @field private _lvc_size number Текущий размер LVC
--- @field private event_queues table<number, table> Очереди событий по приоритетам
--- @field private stats table Статистика диспетчера
--- @field private active boolean Флаг активности обработки
local EventDispatcher = {}
EventDispatcher.__index = EventDispatcher

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
    ADAPTER_BEFORE_RESTART = "adapter:before_restart",
    ADAPTER_AFTER_RESTART = "adapter:after_restart",
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
        state.instance:initialize()
    end
    return state.instance
end

--- Инициализирует диспетчер событий, создает менеджер подписок и запускает обработчик очереди.
--- @private
function EventDispatcher:initialize()
    -- Тонкая настройка Garbage Collector для инкрементальной очистки
    local gc_pause = (MonitorConfig and MonitorConfig.GcPause) or 100
    local gc_stepmul = (MonitorConfig and MonitorConfig.GcStepMul) or 500
    collectgarbage("setpause", gc_pause)
    collectgarbage("setstepmul", gc_stepmul)

    self.subscription_manager = SubscriptionManager.new()

    -- Кэш последних значений (Last Value Cache)
    self._lvc = {}
    self._lvc_keys = {}
    self._lvc_head = 1
    self._lvc_tail = 1
    self._lvc_size = 0

    self.event_queues = {}
    for _, p in pairs(self.PRIORITIES) do
        self.event_queues[p] = {
            data = {},
            head = 1,
            tail = 1,
            size = 0,
            max_size = MAX_QUEUE_SIZE
        }
    end

    self.stats = {
        emitted = 0,
        processed = 0,
        dropped = 0,
        last_reset = os_time()
    }

    self.active = true
    self:start_queue_processor()

    Logger.info(COMPONENT_NAME,
        "Диспетчер событий инициализирован с поддержкой LVC и масок (Wildcards)")
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

--- Публикует событие в систему. Событие попадает в очередь и обрабатывается асинхронно.
--- @param event_type string Тип события (например, "channel:error")
--- @param event_data table|string Данные события
--- @param priority? number [Приоритет события (1 - Critical, 4 - Low). По умолчанию 3 (Medium).]
--- @param options? table [Дополнительные параметры: source (источник), no_cache (не сохранять в LVC),
--- is_table (данные из пула).]
--- @return string|nil ID созданного события или nil при ошибке
function EventDispatcher:emit(event_type, event_data, priority, options)
    if not self.active then return nil end

    local now = os_time()
    local sub_mgr = self.subscription_manager

    -- Оптимизация: Subscription-aware Emitting
    local no_cache = options and options.no_cache
    if no_cache and not sub_mgr:has_subscriptions(event_type) then
        return nil
    end

    -- Обновляем LVC (если не запрещено в опциях)
    if not no_cache then
        -- Ограничить размер LVC для предотвращения утечек памяти (O(1) вытеснение через круговой буфер)
        if not self._lvc[event_type] then
            if self._lvc_size >= MAX_LVC_SIZE then
                local oldest_key = self._lvc_keys[self._lvc_head]
                self._lvc_keys[self._lvc_head] = nil
                self._lvc_head = (self._lvc_head % MAX_LVC_SIZE) + 1
                self._lvc_size = self._lvc_size - 1

                if oldest_key then
                    local old_entry = self._lvc[oldest_key]
                    self:_release_lvc_entry(old_entry)
                    self._lvc[oldest_key] = nil
                end
            end
            self._lvc_keys[self._lvc_tail] = event_type
            self._lvc_tail = (self._lvc_tail % MAX_LVC_SIZE) + 1
            self._lvc_size = self._lvc_size + 1
        end

        local cache_data = event_data
        if type(event_data) == "table" then
            -- Глубокое копирование данных в пул для LVC
            cache_data = TablePool.get("lvc_entry")
            for k, v in pairs(event_data) do
                cache_data[k] = _deep_copy_to_pool(v)
            end
        end

        -- Если в LVC уже есть данные для этого типа, возвращаем их в пул
        local old_entry = self._lvc[event_type]
        self:_release_lvc_entry(old_entry)

        local entry = TablePool and TablePool.get("lvc_wrapper") or {}
        entry.data = cache_data
        entry.timestamp = now
        self._lvc[event_type] = entry
    end

    local p = priority or self.PRIORITIES.MEDIUM
    local event = TablePool and TablePool.get("event") or {}

    event.id = _generate_event_id()
    event.type = event_type
    event.data = event_data
    event.priority = p
    event.timestamp = (type(event_data) == "table" and event_data.timestamp) or now
    event.options = options
    event.is_table = options and options.is_table == true

    local queue = self.event_queues[p]
    if queue then
        -- Вставка в круговую очередь
        if queue.size >= queue.max_size then
            -- Вытеснение старого события (O(1))
            local dropped_event = queue.data[queue.head]
            queue.data[queue.head] = nil
            queue.head = (queue.head % queue.max_size) + 1
            queue.size = queue.size - 1

            if dropped_event then
                -- Если данные были из пула, возвращаем их
                if dropped_event.is_table and dropped_event.data and TablePool then
                    TablePool.release(dropped_event.data, nil, true)
                end
                if TablePool then TablePool.release(dropped_event, "event") end
            end
            self.stats.dropped = self.stats.dropped + 1
        end

        queue.data[queue.tail] = event
        queue.tail = (queue.tail % queue.max_size) + 1
        queue.size = queue.size + 1
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

    -- Используем SubscriptionManager для сопоставления масок
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
--- @param filters? table [Схема фильтрации (условия, операторы или Lua-скрипт)]
--- @param options? table [Дополнительные опции: throttle_ms (ограничение частоты),
--- send_lvc (отправить последнее состояние сразу)]
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
            self.subscription_manager:publish_to_single(sub_id, name, entry.data)
        end
    end

    return sub_id
end

--- Запускает фоновый таймер для обработки очереди событий через планировщик.
--- @private
function EventDispatcher:start_queue_processor()
    if not Scheduler then return end

    local scheduler = Scheduler.get_instance()
    local interval = (MonitorConfig and MonitorConfig.SchedulerInterval) or 1

    scheduler:add_task("event_dispatcher_queue", function()
        if self.active then self:process_queue() end
    end, interval)
end

--- Извлекает события из очередей в порядке приоритета и передает их в SubscriptionManager.
--- @private
function EventDispatcher:process_queue()
    local now = os_time()
    local sub_mgr = self.subscription_manager

    -- Периодическая очистка старых записей LVC (TTL)
    -- Выполняется раз в минуту для снижения нагрузки
    if now % 60 == 0 then
        local lvc_ttl = (MonitorConfig and MonitorConfig.LvcTtl) or DEFAULT_LVC_TTL
        for name, entry in pairs(self._lvc) do
            if now - entry.timestamp > lvc_ttl then
                self:_release_lvc_entry(entry)
                self._lvc[name] = nil
                self._lvc_size = self._lvc_size - 1
            end
        end
    end

    local limit = (MonitorConfig and MonitorConfig.EventBatchLimit) or DEFAULT_BATCH_LIMIT
    local processed_in_batch = 0
    local priorities = self.PRIORITIES

    for p = priorities.CRITICAL, priorities.LOW do
        local queue = self.event_queues[p]
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

            processed_in_batch = processed_in_batch + 1
            if processed_in_batch >= limit then
                return -- Прерываем обработку до следующего тика
            end
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
        Logger.warn(COMPONENT_NAME, "Не удалось вернуть событие в пул: %s", tostring(err))
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

-- Регистрация пулов при загрузке модуля
local tp = ModuleManager.get_module("table_pool")
if tp then
    tp.register_type("event", {
        "id", "type", "data", "priority", "timestamp", "options", "is_table"
    }, 100, 10)
    tp.register_type("event_options", nil, 100, 10)
    tp.register_type("lvc_wrapper", { "data", "timestamp" }, 50, 5)
    tp.register_type("lvc_entry", nil, 50, 5)
    tp.register_type("lvc_sub", nil, 20, 2)
end

return EventDispatcher
