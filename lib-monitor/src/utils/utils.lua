-- 1. Стандартные Lua функции
local ipairs = ipairs
local math_abs = math.abs
local math_max = math.max
local pairs = pairs
local table_insert = table.insert
local tostring = tostring
local type = type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local MonitorSettings = ModuleManager.get_module("monitor_settings")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local utils_hostname = ModuleManager.get_global_dependency("utils.hostname")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "Utils"
local HOSTNAME = utils_hostname and utils_hostname() or "unknown"

-- 5. Инициализация объектов из загруженных модулей
--- @class Utils
local Utils = {}

--- Возвращает имя потока по IP-адресу
--- @param ip_address string IP-адрес потока
--- @return string|boolean Имя потока или исходный IP-адрес, false в случае ошибки
function Utils.get_stream_name(ip_address)
    if type(ip_address) ~= "string" or not ip_address then
        Logger.error(COMPONENT_NAME, "get_stream_name: Invalid ip_address")
        return false
    end

    local stream_map = MonitorSettings and MonitorSettings.STREAM or {}
    return stream_map[ip_address] or ip_address
end

--- Вычисляет отношение абсолютной разницы между двумя числами к их максимальному значению
--- @param old number Старое значение
--- @param new number Новое значение
--- @return number Отношение (от 0 до 1)
function Utils.ratio(old, new)
    local abs_old = math_abs(old)
    local abs_new = math_abs(new)
    local max_abs = math_max(abs_old, abs_new)

    if max_abs == 0 then
        return 0
    elseif abs_old == 0 or abs_new == 0 then
        return 1
    end

    return math_abs(old - new) / max_abs
end

--- Создает поверхностную копию таблицы
--- @param t table Исходная таблица
--- @return table Копия таблицы
function Utils.table_copy(t)
    if type(t) ~= "table" then
        return {}
    end

    local copy = {} 
    for k, v in pairs(t) do
        copy[k] = v
    end

    return copy
end

--- Валидирует параметр монитора на основе схемы
--- @param name string Имя параметра
--- @param value any Значение
--- @return boolean success
--- @return any|nil result
function Utils.validate_monitor_param(name, value)
    local schema = MonitorConfig and MonitorConfig.ValidationSchema and MonitorConfig.ValidationSchema[name]
    if not schema then
        Logger.error(COMPONENT_NAME, "validate_monitor_param: Unknown parameter '%s'", name)
        return false, nil
    end

    if value == nil then
        return true, schema.default
    end

    if type(value) ~= schema.type then
        Logger.error(COMPONENT_NAME, "validate_monitor_param: Invalid type for '%s'", name)
        return false, nil
    end

    if schema.type == "number" then
        if schema.min and value < schema.min then return false, nil end
        if schema.max and value > schema.max then return false, nil end
    end

    return true, value
end

--- Валидирует имя монитора
--- @param name string
--- @return boolean success
function Utils.validate_monitor_name(name)
    if not name or type(name) ~= "string" or name == "" then
        return false
    end

    if not name:match("^[a-zA-Z0-9%._-]+$") then
        return false
    end

    if MonitorConfig and MonitorConfig.MaxMonitorNameLength and #name > MonitorConfig.MaxMonitorNameLength then
        return false
    end

    return true
end

--- Возвращает имя хоста сервера
--- @return string Имя хоста
function Utils.get_server_name()
    return HOSTNAME
end

return Utils
