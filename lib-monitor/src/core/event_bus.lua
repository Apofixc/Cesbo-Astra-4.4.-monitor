-- ===========================================================================
-- Модуль `core.event_bus`
--
-- Реализует паттерн "Шина событий" (Event Bus) для обеспечения слабой
-- связанности между компонентами системы.
-- ===========================================================================

-- 1. Стандартные Lua функции
local pairs = pairs
local ipairs = ipairs
local type = type
local table_insert = table.insert
local table_remove = table.remove
local pcall = pcall
local tostring = tostring

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Нет прямых зависимостей

-- 4. Константы и конфигурации
local COMPONENT_NAME = "EventBus"

--- @class EventBus
--- @field private _subscribers table<string, function[]> Список подписчиков по именам событий
local EventBus = {}

local subscribers = {}

--- Подписывает функцию на событие
--- @param event_name string Имя события
--- @param callback function Функция-обработчик
--- @return boolean Статус подписки
function EventBus.subscribe(event_name, callback)
    if type(event_name) ~= "string" or type(callback) ~= "function" then
        if Logger then Logger.error(COMPONENT_NAME, "subscribe: Некорректные параметры") end
        return false
    end

    if not subscribers[event_name] then
        subscribers[event_name] = {}
    end

    table_insert(subscribers[event_name], callback)
    if Logger then Logger.debug(COMPONENT_NAME, "Подписка на событие '%s' оформлена", event_name) end
    return true
end

--- Отписывает функцию от события
--- @param event_name string Имя события
--- @param callback function Функция-обработчик
--- @return boolean Статус отписки
function EventBus.unsubscribe(event_name, callback)
    if not subscribers[event_name] then return false end

    for i, cb in ipairs(subscribers[event_name]) do
        if cb == callback then
            table_remove(subscribers[event_name], i)
            if Logger then Logger.debug(COMPONENT_NAME, "Отписка от события '%s' выполнена", event_name) end
            return true
        end
    end
    return false
end

--- Публикует событие для всех подписчиков
--- @param event_name string Имя события
--- @param ... any Аргументы, передаваемые подписчикам
function EventBus.publish(event_name, ...)
    if not subscribers[event_name] then return end

    if Logger then Logger.debug(COMPONENT_NAME, "Публикация события '%s'", event_name) end

    for _, callback in ipairs(subscribers[event_name]) do
        local ok, err = pcall(callback, ...)
        if not ok then
            if Logger then 
                Logger.error(COMPONENT_NAME, "Ошибка в обработчике события '%s': %s", event_name, tostring(err))
            end
        end
    end
end

--- Список стандартных имен событий системы
EventBus.EVENTS = {
    ADAPTER_BEFORE_RESTART = "adapter:before_restart", -- Вызывается перед остановкой адаптера для рестарта. Аргументы: adapter_name
    ADAPTER_AFTER_RESTART = "adapter:after_restart",   -- Вызывается после успешного запуска адаптера. Аргументы: adapter_name
    ADAPTER_STOPPED = "adapter:stopped",               -- Вызывается при полной остановке адаптера. Аргументы: adapter_name
    
    CHANNEL_CREATED = "channel:created",               -- Вызывается при создании нового канала. Аргументы: channel_name, config
    CHANNEL_KILLED = "channel:killed",                 -- Вызывается при удалении канала. Аргументы: channel_name
    
    MONITOR_ERROR = "monitor:error",                   -- Вызывается при критической ошибке монитора. Аргументы: monitor_name, error_msg
}

return EventBus
