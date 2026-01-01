-- 1. Стандартные Lua функции
local pairs = pairs
local table_insert = table.insert

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Нет прямых зависимостей

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ChannelStorage"

-- 5. Инициализация объектов из загруженных модулей
--- @class ChannelStorage
local ChannelStorage = {}

--- @type table<string, ChannelMonitor>
local monitors = {}

--- Регистрирует новый монитор в хранилище
--- @param name string Имя монитора
--- @param monitor_instance ChannelMonitor Экземпляр монитора
--- @return boolean success Статус выполнения
--- @return nil result
function ChannelStorage.register(name, monitor_instance)
    if monitors[name] then
        Logger.warn(COMPONENT_NAME, "Monitor '%s' already registered. Overwriting.", name)
    end
    monitors[name] = monitor_instance
    Logger.debug(COMPONENT_NAME, "Monitor '%s' registered.", name)
    return true, nil
end

--- Удаляет монитор из хранилища и останавливает его
--- @param name string Имя монитора
--- @return boolean success Статус выполнения
--- @return nil result
function ChannelStorage.unregister(name)
    local monitor = monitors[name]
    if monitor then
        if type(monitor.stop) == "function" then
            monitor:stop()
        end
        monitors[name] = nil
        Logger.debug(COMPONENT_NAME, "Monitor '%s' unregistered and stopped.", name)
        return true, nil
    end
    return false, nil
end

--- Находит монитор по имени
--- @param name string Имя монитора
--- @return ChannelMonitor|nil
function ChannelStorage.find(name)
    return monitors[name]
end

--- Возвращает список всех мониторов
--- @return table<string, ChannelMonitor>
function ChannelStorage.get_all()
    return monitors
end

--- Возвращает количество активных мониторов
--- @return number
function ChannelStorage.count()
    local count = 0
    for _ in pairs(monitors) do
        count = count + 1
    end
    return count
end

return ChannelStorage
