-- 1. Стандартные Lua функции
local math_abs = math.abs
local math_max = math.max
local math_min = math.min
local pairs = pairs
local tostring = tostring
local type = type
local string_format = string.format
local io_popen = io.popen
local os_execute = os.execute
local os_clock = os.clock
local math_huge = math.huge
local pcall = pcall
local unpack = table.unpack
local select = select

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local MonitorConfig = ModuleManager.get_module("monitor_config")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local utils_hostname = ModuleManager.get_global_dependency("utils.hostname")
local astra_parse_url = ModuleManager.get_global_dependency("parse_url")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "Utils"
local HOSTNAME = utils_hostname and utils_hostname() or "unknown"

-- 5. Инициализация объектов из загруженных модулей
--- @class Utils
local Utils = {}

-- Внутреннее состояние для статистики производительности
Utils._performance_stats = {}

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
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = v
    end

    return copy
end

--- Разделяет строку по разделителю (аналог string.split из Astra)
--- @param s string Исходная строка
--- @param d string Разделитель
--- @return table|nil Таблица частей строки или nil
function Utils.split(s, d)
    if type(s) ~= "string" then return nil end
    local p = 1
    local t = {}
    while true do
        local b = s:find(d, p)
        if not b then
            t[#t + 1] = s:sub(p)
            return t
        end
        t[#t + 1] = s:sub(p, b - 1)
        p = b + #d
    end
end

--- Создает глубокую копию таблицы
--- @param t table Исходная таблица
--- @param cache? table [Внутренний кэш для обработки циклических ссылок]
--- @return table Глубокая копия таблицы
function Utils.deep_copy(t, cache)
    if type(t) ~= "table" then
        return t
    end

    cache = cache or {}
    if cache[t] then
        return cache[t]
    end

    local copy = {}
    cache[t] = copy
    
    for k, v in pairs(t) do
        if type(v) == "table" then
            copy[k] = Utils.deep_copy(v, cache)
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

--- Разбирает медиа-адрес Astra
--- @param url string URL для разбора
--- @return table|nil Таблица с параметрами URL или nil при ошибке
function Utils.parse_url(url)
    if type(url) ~= "string" or url == "" then return nil end
    if not astra_parse_url then
        Logger.error(COMPONENT_NAME, "parse_url: dependency not found")
        return nil
    end
    return astra_parse_url(url)
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

--- Проверяет, занят ли TCP-порт
--- @param port number Номер порта
--- @return boolean true если занят, иначе false
function Utils.is_port_busy(port)
    if not port then return false end
    local p = io_popen(string_format("ss -Hlnt 'sport == :%d'", port))
    if not p then return false end
    local res = p:read("*a")
    p:close()
    return res ~= ""
end

--- Принудительно освобождает TCP-порт, завершая процесс
--- @param port number Номер порта
--- @return boolean true если порт свободен или был успешно освобожден
function Utils.free_port(port)
    if not port then return false end
    if not Utils.is_port_busy(port) then return true end
    
    Logger.info(COMPONENT_NAME, "Порт %d занят, пытаемся освободить...", port)
    os_execute(string_format("fuser -k %d/tcp >/dev/null 2>&1", port))
    
    -- Ожидание освобождения (до 2 секунд)
    local start = os_clock()
    while os_clock() - start < 2 do
        if not Utils.is_port_busy(port) then
            Logger.info(COMPONENT_NAME, "Порт %d успешно освобожден", port)
            return true
        end
    end
    
    local busy = Utils.is_port_busy(port)
    if busy then
        Logger.error(COMPONENT_NAME, "Не удалось освободить порт %d", port)
    end
    return not busy
end

--- Очищает таблицу без удаления самой ссылки (для переиспользования в пулах)
--- @param t table Таблица для очистки
function Utils.table_clear(t)
    if type(t) ~= "table" then return end
    for k, v in pairs(t) do
        t[k] = nil
    end
end

--- Измеряет время выполнения функции и сохраняет статистику.
--- @param name string Уникальное имя операции
--- @param func function Функция для выполнения
--- @param ... any Аргументы функции
--- @return any ... Результаты выполнения функции
function Utils.measure_time(name, func, ...)
    local start_time = os_clock()
    local results = { pcall(func, ...) }
    local end_time = os_clock()
    
    local duration = end_time - start_time
    
    if not Utils._performance_stats[name] then
        Utils._performance_stats[name] = {
            count = 0,
            total_time = 0,
            avg_time = 0,
            max_time = 0,
            min_time = math_huge
        }
    end
    
    local stats = Utils._performance_stats[name]
    stats.count = stats.count + 1
    stats.total_time = stats.total_time + duration
    stats.avg_time = stats.total_time / stats.count
    stats.max_time = math_max(stats.max_time, duration)
    stats.min_time = math_min(stats.min_time, duration)
    
    local ok = results[1]
    if not ok then
        -- Если функция упала, пробрасываем ошибку дальше после записи статистики
        error(results[2])
    end
    
    return unpack(results, 2)
end

--- Возвращает копию накопленной статистики производительности.
--- @return table Статистика производительности
function Utils.get_performance_stats()
    return Utils.deep_copy(Utils._performance_stats)
end

return Utils
