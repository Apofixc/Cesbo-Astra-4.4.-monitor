-- ===========================================================================
-- Модуль `core.event_dispatcher`
--
-- Центральная шина событий для системы мониторинга.
-- Реализует очередь с приоритетами, асинхронную обработку и кэш последних состояний (LVC).
-- Поддерживает маски (wildcards) в именах событий.
-- ===========================================================================

-- 1. Стандартные Lua функции
local type = type
local tostring = tostring
local string_format = string.format
local ipairs = ipairs
local pairs = pairs
local table_insert = table.insert
local table_remove = table.remove
local os_time = os.time
local pcall = pcall
local setmetatable = setmetatable
local math_random = math.random

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local SubscriptionManager = ModuleManager.get_module("core.subscription_manager")
local TablePool = ModuleManager.get_module("utils.table_pool")
local Utils = ModuleManager.get_module("utils")
local Wildcard = ModuleManager.get_module("utils.wildcard")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local Scheduler = ModuleManager.get_module("core.scheduler")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- (Используем Scheduler вместо прямого обращения к timer)

-- 4. Константы и конфигурации
local COMPONENT_NAME = "EventDispatcher"

--- @class EventDispatcher
--- @field public subscription_manager SubscriptionManager Менеджер подписок
--- @field private _lvc table<string, table> Кэш последних значений (Last Value Cache)
--- @field private _lvc_keys table<number, string> Очередь ключей для FIFO вытеснения из LVC
--- @field private _lvc_size number Текущий размер LVC
--- @field private event_queues table<number, table> Очереди событий по приоритетам
--- @field private stats table Статистика диспетчера
--- @field private active boolean Флаг активности обработки
local EventDispatcher = {}
EventDispatcher.__index = EventDispatcher

local instance = nil

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

-- Генерация уникального ID события
local function generate_event_id()
    return string_format("evt_%d_%d", os_time(), math_random(10000, 99999))
end

--- Возвращает единственный экземпляр EventDispatcher (Singleton)
--- @return EventDispatcher Экземпляр диспетчера
function EventDispatcher.get_instance()
    if not instance then
        instance = setmetatable({}, EventDispatcher)
        instance:initialize()
    end
    return instance
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
    self._lvc_size = 0
    
    self.event_queues = {
        [self.PRIORITIES.CRITICAL] = {},
        [self.PRIORITIES.HIGH] = {},
        [self.PRIORITIES.MEDIUM] = {},
        [self.PRIORITIES.LOW] = {}
    }
    
    self.stats = {
        emitted = 0,
        processed = 0,
        dropped = 0,
        last_reset = os_time()
    }
    
    self.active = true
    self:start_queue_processor()
    
    Logger.info(COMPONENT_NAME, "EventDispatcher initialized with LVC and Wildcard support")
end

--- Публикует событие в систему. Событие попадает в очередь и обрабатывается асинхронно.
--- @param event_type string Тип события (например, "channel:error")
--- @param event_data table|string Данные события
--- @param priority? number [Приоритет события (1 - Critical, 4 - Low). По умолчанию 3 (Medium).]
--- @param options? table [Дополнительные параметры: source (источник), no_cache (не сохранять в LVC), is_table (данные из пула).]
--- @return string|nil ID созданного события или nil при ошибке
function EventDispatcher:emit(event_type, event_data, priority, options)
    if not self.active then return nil end
    
    -- Обновляем LVC (если не запрещено в опциях)
    -- Если данные являются таблицей, создаем глубокую копию для кэша,
    -- так как оригинальная таблица может быть возвращена в пул и очищена.
    if not (options and options.no_cache) then
        -- Ограничить размер LVC для предотвращения утечек памяти (O(1) вытеснение)
        if not self._lvc[event_type] then
            if self._lvc_size >= 1000 then
                local oldest_key = table_remove(self._lvc_keys, 1)
                if oldest_key then
                    self._lvc[oldest_key] = nil
                    self._lvc_size = self._lvc_size - 1
                end
            end
            table_insert(self._lvc_keys, event_type)
            self._lvc_size = self._lvc_size + 1
        end

        local cache_data = event_data
        if type(event_data) == "table" then
            -- Оптимизация: "Умное" копирование с использованием пула
            cache_data = TablePool.get("lvc_entry")
            for k, v in pairs(event_data) do
                if type(v) == "table" then
                    local sub = TablePool.get("lvc_sub")
                    for sk, sv in pairs(v) do sub[sk] = sv end
                    cache_data[k] = sub
                else
                    cache_data[k] = v
                end
            end
        end

        -- Если в LVC уже есть данные для этого типа, возвращаем их в пул
        local old_entry = self._lvc[event_type]
        if old_entry and type(old_entry.data) == "table" then
            for k, v in pairs(old_entry.data) do
                if type(v) == "table" then
                    TablePool.release(v, "lvc_sub")
                end
            end
            TablePool.release(old_entry.data, "lvc_entry")
        end

        self._lvc[event_type] = {
            data = cache_data,
            timestamp = os_time()
        }
    end

    local p = priority or self.PRIORITIES.MEDIUM
    local event = TablePool and TablePool.get("event") or {}
    
    event.id = generate_event_id()
    event.type = event_type
    event.data = event_data
    event.priority = p
    event.timestamp = (type(event_data) == "table" and event_data.timestamp) or os_time()
    event.source = (options and options.source) or "unknown"
    event.is_table = options and options.is_table or (type(event_data) == "table")
    event.json_cache = nil -- Кэш для ленивой сериализации
    
    local queue = self.event_queues[p]
    if queue then
        table_insert(queue, event)
        if #queue > 1000 then
            local dropped_event = table_remove(queue, 1)
            if dropped_event then
                -- Если данные были из пула, возвращаем их перед удалением самого события
                if dropped_event.is_table and dropped_event.data and TablePool then
                    TablePool.release(dropped_event.data, "report")
                end
                if TablePool then TablePool.release(dropped_event, "event") end
            end
            self.stats.dropped = self.stats.dropped + 1
        end
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
    local ok, result = pcall(function()
        return self:emit(event_type, event_data, priority, options)
    end)
    
    if not ok then
        Logger.error(COMPONENT_NAME, "Event emit failed: %s", tostring(result))
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

--- Публикует событие (алиас для emit).
--- @param event_type string Тип события
--- @param ... any Аргументы события
--- @return string|nil ID события
function EventDispatcher:publish(event_type, ...)
    local args = {...}
    local data = args[1]
    if #args > 1 then data = { args = args } end
    return self:emit(event_type, data, nil, nil)
end

--- Регистрирует новую подписку на события.
--- @param event_type string Тип события или маска (например, "adapter:*")
--- @param callback function|table Функция-обработчик или конфигурация транспорта
--- @param filters? table [Схема фильтрации (условия, операторы или Lua-скрипт)]
--- @param options? table [Дополнительные опции: throttle_ms (ограничение частоты), send_lvc (отправить последнее состояние сразу)]
--- @return string|nil ID подписки (UUID)
function EventDispatcher:subscribe(event_type, callback, filters, options)
    local sub_id = self.subscription_manager:subscribe(event_type, { 
        callback = callback,
        filters = filters,
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
    for p = self.PRIORITIES.CRITICAL, self.PRIORITIES.LOW do
        local queue = self.event_queues[p]
        while #queue > 0 do
            local event = table_remove(queue, 1)
            if event then
                local ok, err = pcall(function()
                    self.subscription_manager:publish_event(event)
                end)
                
                if not ok then
                    Logger.error(COMPONENT_NAME, "Failed to process event %s: %s", 
                        event.id or "unknown", tostring(err))
                else
                    self.stats.processed = self.stats.processed + 1
                end
                
                -- Возврат в пул
                self:_safe_return_to_pool(event)
            end
        end
    end
end

--- Безопасно возвращает таблицы события в пул.
--- @private
--- @param event table Объект события
function EventDispatcher:_safe_return_to_pool(event)
    local ok, err = pcall(function()
        if event.is_table and event.data and TablePool then
            TablePool.release(event.data, "report")
        end
        
        if TablePool then
            TablePool.release(event, "event")
        end
    end)
    
    if not ok then
        Logger.warn(COMPONENT_NAME, "Failed to return event to pool: %s", tostring(err))
    end
end

--- Останавливает диспетчер событий и очищает очереди.
function EventDispatcher:shutdown()
    self.active = false
    Logger.info(COMPONENT_NAME, "Shutting down EventDispatcher...")
    
    if Scheduler then
        Scheduler.get_instance():remove_task("event_dispatcher_queue")
    end
    
    -- Очистка очередей
    for p, queue in pairs(self.event_queues) do
        while #queue > 0 do
            local event = table_remove(queue, 1)
            self:_safe_return_to_pool(event)
        end
    end
end

return EventDispatcher
