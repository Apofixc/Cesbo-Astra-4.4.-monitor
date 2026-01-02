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
--- @field private monitors table<string, DvbTuner>
local DvbStorage = {}

--- @type table<string, DvbTuner>
local monitors = {}

--- Регистрирует новый монитор в хранилище
--- @param name string Имя адаптера
--- @param monitor_instance DvbTuner Экземпляр монитора
--- @return boolean Статус выполнения
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
--- @param force boolean|nil Принудительная остановка
--- @return boolean Статус выполнения
function DvbStorage.unregister(name, force)
    local monitor = monitors[name]
    if monitor then
        if monitor:destroy(force) then
            monitors[name] = nil
            Logger.debug(COMPONENT_NAME, "DVB Monitor '%s' unregistered and stopped (force: %s).", name, tostring(force))
            return true
        else
            Logger.error(COMPONENT_NAME, "unregister: failed to destroy DVB Monitor '%s' (tuner busy)", name)
            return false
        end
    end
    Logger.error(COMPONENT_NAME, "unregister: DVB Monitor '%s' not found", name)
    return false
end

--- Находит монитор по имени адаптера
--- @param name string Имя адаптера
--- @return DvbTuner|nil Экземпляр монитора или nil
function DvbStorage.find(name)
    return monitors[name]
end

--- Возвращает список всех мониторов
--- @return table<string, DvbTuner> Таблица мониторов
function DvbStorage.get_all()
    return monitors
end

--- Возвращает количество активных мониторов
--- @return number Количество мониторов
function DvbStorage.count()
    local count = 0
    for _ in pairs(monitors) do
        count = count + 1
    end
    return count
end

return DvbStorage
