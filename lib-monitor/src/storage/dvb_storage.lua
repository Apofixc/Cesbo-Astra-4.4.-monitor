-- 1. Стандартные Lua функции
local pairs = pairs

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Нет прямых зависимостей

-- 4. Константы и конфигурации
local COMPONENT_NAME = "DvbStorage"

-- 5. Инициализация объектов из загруженных модулей
--- @class DvbStorage
local DvbStorage = {}

--- @type table<string, DvbTuner>
local monitors = {}

--- Регистрирует новый монитор в хранилище
--- @param name string Имя адаптера
--- @param monitor_instance DvbTuner Экземпляр монитора
--- @return boolean success
function DvbStorage.register(name, monitor_instance)
    if monitors[name] then
        Logger.warn(COMPONENT_NAME, "DVB Monitor '%s' already registered. Overwriting.", name)
    end
    monitors[name] = monitor_instance
    Logger.debug(COMPONENT_NAME, "DVB Monitor '%s' registered.", name)
    return true
end

--- Удаляет монитор из хранилища и останавливает его
--- @param name string Имя адаптера
--- @return boolean success
function DvbStorage.unregister(name)
    local monitor = monitors[name]
    if monitor then
        if type(monitor.kill) == "function" then
            monitor:kill()
        elseif type(monitor.stop) == "function" then
            monitor:stop()
        end
        monitors[name] = nil
        Logger.debug(COMPONENT_NAME, "DVB Monitor '%s' unregistered and stopped.", name)
        return true
    end
    return false
end

--- Находит монитор по имени адаптера
--- @param name string Имя адаптера
--- @return DvbTuner|nil
function DvbStorage.find(name)
    return monitors[name]
end

--- Возвращает список всех мониторов
--- @return table<string, DvbTuner>
function DvbStorage.get_all()
    return monitors
end

--- Возвращает количество активных мониторов
--- @return number
function DvbStorage.count()
    local count = 0
    for _ in pairs(monitors) do
        count = count + 1
    end
    return count
end

return DvbStorage
