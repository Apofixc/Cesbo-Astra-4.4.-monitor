-- 1. Стандартные Lua функции
local type = type
local math_max = math.max
local math_abs = math.abs

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local MonitorSettings = ModuleManager.get_module("monitor_settings")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local utils_hostname = ModuleManager.get_global_dependency("utils.hostname")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "Utils"

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
    if type(old) ~= "number" or type(new) ~= "number" then
        return 0
    end
    
    if new == 0 then
        return 0
    end

    return math_abs(old - new) / math_max(old, new)
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

--- Проверяет условие и логирует ошибку, если условие ложно
--- @param cond boolean Проверяемое условие
--- @param msg string Сообщение об ошибке
--- @return boolean Результат условия
function Utils.check(cond, msg)
    if not cond then
        Logger.error(COMPONENT_NAME, msg)
        return false
    end

    return true
end

--- Возвращает имя хоста сервера
--- @return string Имя хоста
function Utils.get_server_name()
    return utils_hostname and utils_hostname() or "unknown"
end

return Utils
