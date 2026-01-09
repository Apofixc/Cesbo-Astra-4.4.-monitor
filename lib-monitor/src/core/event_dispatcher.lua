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

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local timer = ModuleManager.get_global_dependency("timer")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "EventDispatcher"

--- @class EventDispatcher
--- @field public subscription_manager SubscriptionManager Менеджер подписок
--- @field private _lvc table<string, table> Кэш последних значений (Last Value Cache)
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
    self.subscription_manager = SubscriptionManager.new()
    
    -- Кэш последних значений (Last Value Cache)
    self._lvc = {}
    
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
    if not (options and options.no_cache) then
        self._lvc[event_type] = {
            data = event_data,
            timestamp = os_time()
        }
    end

    local p = priority or self.PRIORITIES.MEDIUM
    local event = {
        id = generate_event_id(),
        type = event_type,
        data = event_data,
        priority = p,
        timestamp = (type(event_data) == "table" and event_data.timestamp) or os_time(),
        source = (options and options.source) or "unknown",
        is_table = options and options.is_table or (type(event_data) == "table"),
        json_cache = nil -- Кэш для ленивой сериализации
    }
    
    local queue = self.event_queues[p]
    if queue then
        table_insert(queue, event)
        if #queue > 1000 then
            table_remove(queue, 1)
            self.stats.dropped = self.stats.dropped + 1
        end
    end
    
    self.stats.emitted = self.stats.emitted + 1
    return event.id
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

--- Алиас для совместимости со старым EventBus.
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
    if sub_id and options and options.send_lvc then
        local last_values = self:get_last_values(event_type)
        for name, entry in pairs(last_values) do
            -- Отправляем немедленно (вне очереди) для инициализации подписчика
            self.subscription_manager:publish_to_single(sub_id, name, entry.data)
        end
    end

    return sub_id
end

--- Запускает фоновый таймер для обработки очереди событий.
--- @private
function EventDispatcher:start_queue_processor()
    if not timer then return end
    
    self._processor_timer = timer({
        interval = 0.1,
        callback = function()
            if self.active then self:process_queue() end
        end
    })
end

--- Извлекает события из очередей в порядке приоритета и передает их в SubscriptionManager.
--- @private
function EventDispatcher:process_queue()
    for p = self.PRIORITIES.CRITICAL, self.PRIORITIES.LOW do
        local queue = self.event_queues[p]
        while #queue > 0 do
            local event = table_remove(queue, 1)
            if event then
                -- Передаем весь объект события для поддержки ленивого JSON
                self.subscription_manager:publish_event(event)
                
                -- Если данные были из пула, возвращаем их
                if event.is_table and TablePool then
                    TablePool.release(event.data, "report")
                end
                
                self.stats.processed = self.stats.processed + 1
            end
        end
    end
end

return EventDispatcher
