-- 1. Стандартные Lua функции
local pairs = pairs
local table_insert = table.insert
local type = type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Нет прямых зависимостей

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ChannelStorage"

-- 5. Инициализация объектов из загруженных модулей
--- @class ChannelStorage
--- @field private monitors table<string, ChannelMonitor>
--- @field private count_active number
local ChannelStorage = {}

--- @type table<string, ChannelMonitor>
local monitors = {}
local count_active = 0

--- Регистрирует новый монитор в хранилище
--- @param name string Имя монитора
--- @param monitor_instance ChannelMonitor Экземпляр монитора
function ChannelStorage.register(name, monitor_instance)
    if monitors[name] then
        Logger.warn(COMPONENT_NAME, "Monitor '%s' already registered. Overwriting.", name)
    else
        count_active = count_active + 1
    end
    monitors[name] = monitor_instance
    Logger.debug(COMPONENT_NAME, "Monitor '%s' registered.", name)
end

--- Удаляет монитор из хранилища и останавливает его
--- @param name string Имя монитора
--- @return boolean Статус выполнения
function ChannelStorage.unregister(name)
    local monitor = monitors[name]
    if monitor then
        if type(monitor.stop) == "function" then
            monitor:stop()
        end
        monitors[name] = nil
        count_active = count_active - 1
        Logger.debug(COMPONENT_NAME, "Monitor '%s' unregistered and stopped.", name)
        return true
    end
    Logger.error(COMPONENT_NAME, "unregister: Monitor '%s' not found", name)
    return false
end

--- Находит монитор по имени
--- @param name string Имя монитора
--- @return ChannelMonitor|nil Экземпляр монитора или nil
function ChannelStorage.find(name)
    return monitors[name]
end

--- Возвращает список всех мониторов
--- @return table<string, ChannelMonitor> Таблица мониторов
function ChannelStorage.get_all()
    return monitors
end

--- Возвращает количество активных мониторов
--- @return number Количество мониторов
function ChannelStorage.count()
    return count_active
end

--- Находит все каналы в системе Astra, использующие указанный DVB-адаптер
--- @param adapter_name string Имя адаптера (например, "0" или "0.1")
--- @return table<string, table> Список найденных каналов (имя -> ch_data)
function ChannelStorage.find_by_adapter(adapter_name)
    local result = {}    
    local channel_list = ModuleManager.get_global_dependency("channel_list")
    
    if not channel_list then
        Logger.error(COMPONENT_NAME, "find_by_adapter: channel_list dependency not found")
        return result
    end

    local target_adapter = tostring(adapter_name)
    for _, ch_data in pairs(channel_list) do
        local inputs = ch_data.input
        if inputs then
            for i = 1, #inputs do
                local input = inputs[i]
                local cfg = input.config
                if cfg and cfg.format == "dvb" and tostring(cfg.addr) == target_adapter then
                    local name = ch_data.config and ch_data.config.name
                    if name then
                        result[name] = ch_data
                    end
                    break
                end
            end
        end
    end
    return result
end

return ChannelStorage
