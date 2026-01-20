-- ===========================================================================
-- Модуль `utils.utils`
--
-- Набор вспомогательных функций для работы с таблицами, строками,
-- валидации параметров и измерения производительности.
-- ===========================================================================

-- 1. Стандартные Lua функции
local math_abs = _G.math.abs
local math_max = _G.math.max
local math_min = _G.math.min
local pairs = _G.pairs
local tostring = _G.tostring
local type = _G.type
local string_format = _G.string.format
local io_popen = _G.io.popen
local os_execute = _G.os.execute
local os_clock = _G.os.clock
local math_huge = _G.math.huge
local pcall = _G.pcall
local unpack = _G.table.unpack
local error = _G.error

-- 2. Функции из ModuleManager.get_module()
local Logger = nil -- Кэшируется при первом обращении
local MonitorConfig = nil -- Кэшируется при первом обращении

-- 3. Глобальные зависимости Astra
local utils_hostname = ModuleManager.get_global_dependency("utils.hostname")
local astra_parse_url = ModuleManager.get_global_dependency("parse_url")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "Utils"
local HOSTNAME = utils_hostname and utils_hostname() or "unknown"

-- 5. Внутреннее состояние (Private State)

--- @class PerformanceStats
--- @field count number Количество вызовов функции
--- @field total_time number Суммарное время выполнения в секундах
--- @field avg_time number Среднее время выполнения в секундах
--- @field max_time number Максимальное зафиксированное время выполнения
--- @field min_time number Минимальное зафиксированное время выполнения

local state = {
    --- Хранилище статистики производительности
    --- @type table<string, PerformanceStats>
    performance_stats = {}
}

-- ===========================================================================
-- Внутренние функции (Private/Protected)
-- ===========================================================================

--- Возвращает модуль логгера (ленивая загрузка)
--- @return Logger|nil
local function _get_logger()
    if Logger then return Logger end
    Logger = ModuleManager.get_module("logger")
    return Logger
end

--- Возвращает модуль конфигурации (ленивая загрузка)
--- @return MonitorConfig|nil
local function _get_monitor_config()
    if MonitorConfig then return MonitorConfig end
    MonitorConfig = ModuleManager.get_module("monitor_config")
    return MonitorConfig
end

--- Обновляет статистику производительности для указанной операции
--- @param name string Уникальное имя операции
--- @param duration number Длительность выполнения в секундах
local function _update_stats(name, duration)
    if not state.performance_stats[name] then
        state.performance_stats[name] = {
            count = 0,
            total_time = 0,
            avg_time = 0,
            max_time = 0,
            min_time = math_huge
        }
    end

    local stats = state.performance_stats[name]
    stats.count = stats.count + 1
    stats.total_time = stats.total_time + duration
    stats.avg_time = stats.total_time / stats.count
    stats.max_time = math_max(stats.max_time, duration)
    stats.min_time = math_min(stats.min_time, duration)
end

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- @class Utils
local Utils = {}

--- Возвращает имя потока по IP-адресу
--- @param ip_address string IP-адрес потока
--- @return string|nil Имя потока или исходный IP-адрес, nil в случае ошибки
function Utils.get_stream_name(ip_address)
    if type(ip_address) ~= "string" or not ip_address then
        local log = _get_logger()
        if log then log.error(COMPONENT_NAME, "get_stream_name: некорректный ip_address") end
        return nil
    end

    local config = _get_monitor_config()
    local stream_map = config and config.STREAM or {}
    return stream_map[ip_address] or ip_address
end

--- Вычисляет отношение абсолютной разницы между двумя числами к их максимальному значению
--- @param old number Старое значение
--- @param new number Новое значение
--- @return number Отношение (от 0 до 1)
function Utils.ratio(old, new)
    if old == new then return 0 end

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

--- Копирует все поля из одной таблицы в другую (поверхностное слияние)
--- @param dst table Целевая таблица
--- @param src table Исходная таблица
function Utils.table_merge(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then return end
    for k, v in pairs(src) do
        dst[k] = v
    end
end

--- Разделяет строку по разделителю
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
--- @param t any Исходное значение
--- @param cache? table Внутренний кэш для обработки циклических ссылок
--- @return any Глубокая копия
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

--- Валидирует параметр монитора на основе схемы
--- @param name string Имя параметра
--- @param value any Значение
--- @return any Валидированные данные или значение по умолчанию
function Utils.validate_monitor_param(name, value)
    local config = _get_monitor_config()
    local schema = config and config.ValidationSchema and config.ValidationSchema[name]
    if not schema then
        local log = _get_logger()
        if log then log.error(COMPONENT_NAME, "validate_monitor_param: неизвестный параметр '%s'", name) end
        return nil
    end

    if value == nil then
        return schema.default
    end

    -- Приведение к числу для надежности (если пришла строка из JSON)
    if schema.type == "number" and type(value) ~= "number" then
        value = _G.tonumber(value)
    end

    if type(value) ~= schema.type then
        local log = _get_logger()
        if log then
            log.error(COMPONENT_NAME,
                "validate_monitor_param: некорректный тип для '%s' (ожидался %s, получен %s).",
                name, schema.type, type(value))
        end
        return schema.default
    end

    if schema.type == "number" then
        if schema.min and value < schema.min then
            local log = _get_logger()
            if log then
                log.error(COMPONENT_NAME,
                    "validate_monitor_param: значение для '%s' слишком мало (%s < %s).",
                    name, tostring(value), tostring(schema.min))
            end
            return schema.default
        end
        if schema.max and value > schema.max then
            local log = _get_logger()
            if log then
                log.error(COMPONENT_NAME,
                    "validate_monitor_param: значение для '%s' слишком велико (%s > %s).",
                    name, tostring(value), tostring(schema.max))
            end
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

    local config = _get_monitor_config()
    if config and config.MaxMonitorNameLength and #name > config.MaxMonitorNameLength then
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
        local log = _get_logger()
        if log then log.error(COMPONENT_NAME, "parse_url: зависимость не найдена") end
        return nil
    end
    return astra_parse_url(url)
end

--- Инициализирует таблицу отчета базовыми статичными полями
--- @param t table Таблица для инициализации
--- @param type_name string Тип объекта
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

--- Принудительно освобождает TCP-порт
--- @param port number Номер порта
--- @return boolean true если порт свободен или был успешно освобожден
function Utils.free_port(port)
    if not port then return false end
    if not Utils.is_port_busy(port) then return true end

    local log = _get_logger()
    if log then log.info(COMPONENT_NAME, "Порт %d занят, пытаемся освободить...", port) end
    os_execute(string_format("fuser -k %d/tcp >/dev/null 2>&1", port))

    -- Ожидание освобождения (до 2 секунд)
    local start = os_clock()
    while os_clock() - start < 2 do
        if not Utils.is_port_busy(port) then
            if log then log.info(COMPONENT_NAME, "Порт %d успешно освобожден", port) end
            return true
        end
    end

    local busy = Utils.is_port_busy(port)
    if busy then
        if log then log.error(COMPONENT_NAME, "Не удалось освободить порт %d", port) end
    end
    return not busy
end

--- Очищает таблицу без удаления самой ссылки
--- @param t table Таблица для очистки
function Utils.table_clear(t)
    if type(t) ~= "table" then return end
    for k, v in pairs(t) do
        t[k] = nil
    end
end

--- Экранирует строку для безопасного использования в shell-командах
--- @param s string Исходная строка
--- @return string Экранированная строка
function Utils.shell_escape(s)
    if type(s) ~= "string" then return "''" end
    -- Заменяем одиночную кавычку на '"'"' и оборачиваем в одиночные кавычки
    return "'" .. s:gsub("'", "'\"'\"'") .. "'"
end

--- Обрезает строку до указанного лимита
--- @param s string Исходная строка
--- @param limit number Максимальная длина
--- @return string Обрезанная строка
function Utils.truncate_string(s, limit)
    if type(s) ~= "string" then return "" end
    if #s <= limit then return s end
    return s:sub(1, limit - 3) .. "..."
end

--- Преобразует данные в формат InfluxDB Line Protocol
--- @param measurement string Имя измерения
--- @param tags table|nil Таблица тегов (строковые значения)
--- @param fields table Таблица полей (числа, строки, булевы)
--- @param timestamp? number Метка времени (в секундах)
--- @return string|nil Строка в формате Line Protocol
function Utils.to_line_protocol(measurement, tags, fields, timestamp)
    if type(measurement) ~= "string" or type(fields) ~= "table" then return nil end
    
    local res = { measurement }
    
    -- Теги (должны быть отсортированы для лучшей производительности InfluxDB, но здесь упростим)
    if tags then
        for k, v in pairs(tags) do
            if v ~= nil then
                table.insert(res, ",")
                table.insert(res, tostring(k))
                table.insert(res, "=")
                table.insert(res, tostring(v):gsub(" ", "\\ "):gsub(",", "\\,"):gsub("=", "\\="))
            end
        end
    end
    
    table.insert(res, " ")
    
    -- Поля
    local first_field = true
    for k, v in pairs(fields) do
        if v ~= nil then
            if not first_field then table.insert(res, ",") end
            table.insert(res, tostring(k))
            table.insert(res, "=")
            
            if type(v) == "string" then
                table.insert(res, "\"" .. v:gsub("\"", "\\\"") .. "\"")
            elseif type(v) == "boolean" then
                table.insert(res, v and "t" or "f")
            else
                table.insert(res, tostring(v))
            end
            first_field = false
        end
    end
    
    -- Метка времени (InfluxDB ожидает наносекунды по умолчанию, если не указано иное)
    -- Используем строковую конкатенацию для предотвращения потери точности Lua float
    if timestamp then
        table.insert(res, " ")
        table.insert(res, tostring(math.floor(timestamp)) .. "000000000")
    end
    
    return table.concat(res)
end

--- Измеряет время выполнения функции и сохраняет статистику
--- @param name string Уникальное имя операции
--- @param func function Функция для выполнения
--- @param ... any Аргументы функции
--- @return any ... Результаты выполнения функции
function Utils.measure_time(name, func, ...)
    local start_time = os_clock()
    local results = { pcall(func, ...) }
    local end_time = os_clock()

    _update_stats(name, end_time - start_time)

    local ok = results[1]
    if not ok then
        error(results[2])
    end

    return unpack(results, 2)
end

--- Возвращает копию накопленной статистики производительности
--- @return table<string, PerformanceStats> Статистика производительности
function Utils.get_performance_stats()
    return Utils.deep_copy(state.performance_stats)
end

-- ===========================================================================
-- Инициализация модуля
-- ===========================================================================

return Utils
