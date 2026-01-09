-- ===========================================================================
-- Модуль `core.event_dispatcher`
--
-- Центральная шина событий для системы мониторинга.
-- Реализует очередь с приоритетами и асинхронную обработку.
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

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local timer = ModuleManager.get_global_dependency("timer")
local json_encode = ModuleManager.get_global_dependency("json.encode")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "EventDispatcher"

--- @class EventDispatcher
local EventDispatcher = {}
EventDispatcher.__index = EventDispatcher

local instance = nil

--- Приоритеты событий
EventDispatcher.PRIORITIES = {
    CRITICAL = 1,
    HIGH = 2,
    MEDIUM = 3,
    LOW = 4
}

--- Стандартные имена событий (для совместимости)
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

--- Возвращает единственный экземпляр EventDispatcher
--- @return EventDispatcher
function EventDispatcher.get_instance()
    if not instance then
        instance = setmetatable({}, EventDispatcher)
        instance:initialize()
    end
    return instance
end

--- Инициализация диспетчера
function EventDispatcher:initialize()
    self.subscription_manager = SubscriptionManager.new()
    
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
    
    Logger.info(COMPONENT_NAME, "EventDispatcher initialized")
end

--- Публикует событие (основной API)
--- @param event_type string Тип события
--- @param event_data table Данные события
--- @param priority number Приоритет (1-4)
--- @param options table Дополнительные опции {source}
function EventDispatcher:emit(event_type, event_data, priority, options)
    if not self.active then return nil end
    
    local p = priority or self.PRIORITIES.MEDIUM
    local event = {
        id = generate_event_id(),
        type = event_type,
        data = event_data,
        priority = p,
        timestamp = (event_data and event_data.timestamp) or os_time(),
        source = (options and options.source) or "unknown"
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

--- Алиас для совместимости со старым EventBus
function EventDispatcher:publish(event_type, ...)
    local args = {...}
    local data = args[1]
    -- Если передано несколько аргументов, упаковываем их
    if #args > 1 then
        data = { args = args }
    end
    return self:emit(event_type, data)
end

--- Алиас для совместимости со старым EventBus
function EventDispatcher:subscribe(event_type, callback)
    return self.subscription_manager:subscribe(event_type, { callback = callback })
end

--- Запускает обработчик очереди
function EventDispatcher:start_queue_processor()
    if not timer then return end
    
    self._processor_timer = timer({
        interval = 0.1,
        callback = function()
            if self.active then self:process_queue() end
        end
    })
end

--- Обрабатывает очередь событий
function EventDispatcher:process_queue()
    for p = self.PRIORITIES.CRITICAL, self.PRIORITIES.LOW do
        local queue = self.event_queues[p]
        while #queue > 0 do
            local event = table_remove(queue, 1)
            if event then
                self.subscription_manager:publish(event.type, event.data)
                self.stats.processed = self.stats.processed + 1
            end
        end
    end
end

return EventDispatcher
