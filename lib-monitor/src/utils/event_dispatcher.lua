-- 1. Стандартные Lua функции
local pairs = pairs
local ipairs = ipairs
local table_insert = table.insert
local type = type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Нет

-- 4. Константы и конфигурации
local COMPONENT_NAME = "EventDispatcher"

-- 5. Инициализация объектов из загруженных модулей
--- @class EventDispatcher
local EventDispatcher = {}

--- @type table<string, table<number, function>>
local subscribers = {}

--- Подписывает обработчик на событие
--- @param event_type string Тип события (например, "channels", "dvb", "error")
--- @param handler function Функция-обработчик
--- @return boolean success
function EventDispatcher.subscribe(event_type, handler)
    if type(event_type) ~= "string" or type(handler) ~= "function" then
        Logger.error(COMPONENT_NAME, "subscribe: Invalid arguments")
        return false
    end

    if not subscribers[event_type] then
        subscribers[event_type] = {}
    end

    table_insert(subscribers[event_type], handler)
    Logger.debug(COMPONENT_NAME, "Subscribed to event: %s", event_type)
    return true
end

--- Публикует событие для всех подписчиков
--- @param event_type string Тип события
--- @param data any Данные события (обычно JSON строка или таблица)
--- @return boolean success
function EventDispatcher.publish(event_type, data)
    if not event_type or not data then
        return false
    end

    local handlers = subscribers[event_type]
    if not handlers or #handlers == 0 then
        -- Если нет подписчиков, выводим данные в терминал (для отладки)
        print(string.format("[%s] No subscribers. Data: %s", event_type, tostring(data)))
        return true
    end

    for _, handler in ipairs(handlers) do
        local success, err = pcall(handler, data)
        if not success then
            Logger.error(COMPONENT_NAME, "Error in event handler for '%s': %s", event_type, tostring(err))
        end
    end

    return true
end

--- Очищает всех подписчиков (для тестов)
function EventDispatcher.reset()
    subscribers = {}
    return true
end

return EventDispatcher
