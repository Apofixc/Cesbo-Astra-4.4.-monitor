-- 1. Стандартные Lua функции
local math_abs = math.abs
local math_max = math.max
local pairs = pairs
local tostring = tostring
local type = type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local MonitorConfig = ModuleManager.get_module("monitor_config")

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
--- @return string|nil Имя потока или исходный IP-адрес, nil в случае ошибки
function Utils.get_stream_name(ip_address)
    if type(ip_address) ~= "string" or not ip_address then
        Logger.error(COMPONENT_NAME, "get_stream_name: Invalid ip_address")
        return nil
    end

    local stream_map = MonitorConfig and MonitorConfig.STREAM or {}
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

--- Создает быструю поверхностную копию таблицы (без проверок типа)
--- @param t table Исходная таблица
--- @return table Копия таблицы
function Utils.fast_copy(t)
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = v
    end
    return copy
end

--- Создает глубокую копию таблицы
--- @param t table Исходная таблица
--- @return table Глубокая копия таблицы
function Utils.deep_copy(t)
    if type(t) ~= "table" then
        return t
    end

    local copy = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            copy[k] = Utils.deep_copy(v)
        else
            copy[k] = v
        end
    end

    return copy
end

--- Выполняет поверхностное сравнение двух таблиц
--- @param t1 table Первая таблица
--- @param t2 table Вторая таблица
--- @return boolean true если таблицы идентичны на первом уровне, иначе false
function Utils.shallow_compare(t1, t2)
    if t1 == t2 then return true end
    if type(t1) ~= "table" or type(t2) ~= "table" then return false end
    
    for k, v in pairs(t1) do
        if t2[k] ~= v then return false end
    end
    
    for k in pairs(t2) do
        if t1[k] == nil then return false end
    end
    
    return true
end

--- Валидирует параметр монитора на основе схемы.
--- Если значение невалидно или отсутствует, возвращает значение по умолчанию из схемы.
--- @param name string Имя параметра
--- @param value any Значение
--- @return any Валидированные данные или значение по умолчанию
function Utils.validate_monitor_param(name, value)
    local schema = MonitorConfig and MonitorConfig.ValidationSchema and MonitorConfig.ValidationSchema[name]
    if not schema then
        Logger.error(COMPONENT_NAME, "validate_monitor_param: Unknown parameter '%s'", name)
        return nil
    end

    if value == nil then
        return schema.default
    end

    if type(value) ~= schema.type then
        Logger.error(COMPONENT_NAME, "validate_monitor_param: Invalid type for '%s' (expected %s, got %s). Using default.", 
            name, schema.type, type(value))
        return schema.default
    end

    if schema.type == "number" then
        if schema.min and value < schema.min then
            Logger.error(COMPONENT_NAME, "validate_monitor_param: Value for '%s' is too small (%s < %s). Using default.", 
                name, tostring(value), tostring(schema.min))
            return schema.default
        end
        if schema.max and value > schema.max then
            Logger.error(COMPONENT_NAME, "validate_monitor_param: Value for '%s' is too large (%s > %s). Using default.", 
                name, tostring(value), tostring(schema.max))
            return schema.default
        end
    end

    return value
end

--- Валидирует имя монитора
--- @param name string Имя монитора
--- @return boolean Статус валидации
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

--- Инициализирует таблицу отчета базовыми статичными полями.
--- Используется для реализации пула таблиц и предотвращения лишних аллокаций.
--- @param t table Таблица для инициализации
--- @param type_name string Тип объекта (Channel, Dvb, System)
--- @param name string Техническое имя объекта
function Utils.init_report(t, type_name, name)
    if type(t) ~= "table" then return end
    t.type = type_name
    t.name = name
    t.server = HOSTNAME
end

--- Очищает таблицу без удаления самой ссылки (для переиспользования в пулах)
--- @param t table Таблица для очистки
function Utils.table_clear(t)
    if type(t) ~= "table" then return end
    for k in pairs(t) do
        t[k] = nil
    end
end

return Utils
