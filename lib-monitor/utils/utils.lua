-- ===========================================================================
-- Кэширование встроенных функций для производительности
-- ===========================================================================

local type = type
local tostring = tostring
local string_format = string.format
local math_max = math.max
local math_abs = math.abs
local log_info = log.info
local log_error = log.error
local ipairs = ipairs
local http_request = http_request
local astra_version = astra.version

-- ===========================================================================
-- Константы и конфигурация
-- ===========================================================================

local config = require "config"
local MonitorConfig = require "config.monitor_config"

local hostname =  utils.hostname()

local STREAM = config.STREAM
local MONIT_ADDRESS = config.MONIT_ADDRESS

-- ===========================================================================
-- Основные функции модуля
-- ===========================================================================

--- Возвращает имя потока по IP-адресу, используя предопределенную карту STREAM.
-- Если IP-адрес не найден в карте, возвращает сам IP-адрес.
-- @param string ip_address IP-адрес потока.
-- @return string Имя потока или исходный IP-адрес, если имя не найдено.
function get_stream(ip_address)
    if type(ip_address) ~= "string" or not ip_address then
        log_error("[get_stream] Invalid ip_address: must be a non-empty string")
        return false
    end

    return STREAM[ip_address] or ip_address
end

--- Вычисляет отношение абсолютной разницы между двумя числами к их максимальному значению.
-- Используется для определения относительного изменения.
-- @param number old Старое значение.
-- @param number new Новое значение.
-- @return number Отношение (от 0 до 1) или 0, если новое значение равно 0.
function ratio(old, new)
    if type(old) ~= "number" or type(new) ~= "number" then
        log_error("[ratio] Invalid types: old and new must be numbers")
        return 0
    end
    
    if new == 0 then
        return 0
    end

    return math_abs(old - new) / math_max(old, new)
end

--- Создает поверхностную копию таблицы.
-- @param table t Исходная таблица.
-- @return table Копия таблицы.
table.copy = function(t)
    if type(t) ~= "table" then
        log_error("[table.copy] Invalid argument: must be a table")
        return {}
    end

    local copy = {} 
    for k, v in pairs(t) do
        copy[k] = v
    end

    return copy
end

--- Проверяет условие и логирует ошибку, если условие ложно.
-- @param boolean cond Проверяемое условие.
-- @param string msg Сообщение об ошибке, если условие ложно.
-- @return boolean Результат условия.
function check(cond, msg)
    if not cond then
        log_error(msg)
        return false
    end

    return true
end

--- Валидирует параметр монитора на основе его имени, значения и типа/диапазона, используя схему.
-- @param string name Имя параметра.
-- @param any value Значение параметра для валидации.
-- @return any Валидное значение параметра или nil, если значение невалидно.
function validate_monitor_param(name, value)
    local schema = MonitorConfig.ValidationSchema[name]
    if not schema then
        log_error(string_format("Unknown monitor parameter in schema: %s", name))
        return nil
    end

    if value == nil then
        return nil -- Позволяем вызывающей стороне использовать значение по умолчанию
    end

    if type(value) ~= schema.type then
        log_error(string_format("Invalid type for '%s': expected %s, got %s.", name, schema.type, type(value)))
        return nil
    end

    if schema.type == "number" then
        if schema.min ~= nil and value < schema.min then
            log_error(string_format("Value for '%s' (%s) is less than minimum allowed (%s).", name, tostring(value), tostring(schema.min)))
            return nil
        end
        if schema.max ~= nil and value > schema.max then
            log_error(string_format("Value for '%s' (%s) is greater than maximum allowed (%s).", name, tostring(value), tostring(schema.max)))
            return nil
        end
    end

    return value
end

--- Устанавливает или переопределяет адрес мониторинга для клиентов.
-- @param string host Хост для мониторинга.
-- @param number port Порт для мониторинга.
-- @param string path Путь для мониторинга.
-- @param string feed (optional) Имя клиента (например, "channels", "analyze"). Если не указано, обновляет все стандартные клиенты.
-- @return boolean true, если адрес успешно установлен, иначе false.
function set_client_monitoring(host, port, path, feed)
    if not check(type(host) == "string" and host ~= "", "[set_client_monitoring] host must be a non-empty string") then
        return false
    end

    if not check(type(port) == "number" and port > 0, "[set_client_monitoring] port must be a positive number") then
        return false
    end

    if not check(type(path) == "string" and path ~= "", "[set_client_monitoring] path must be a non-empty string") then
        return false
    end

    if feed then
        if not check(type(feed) == "string" and feed ~= "", "[set_client_monitoring] feed must be a non-empty string") then
            return false
        end

        if not MONIT_ADDRESS[feed] then
            log_error("[set_client_monitoring] Client '" .. feed .. "' not found in MONIT_ADDRESS. Cannot override non-standard address.")
            return false
        end

        MONIT_ADDRESS[feed] = {host = host, port = port, path = path}
        log_info("[set_client_monitoring] Overridden standard monitoring address for client '" .. feed .. "' with host=" .. host .. ", port=" .. port .. ", path=" .. path)
    else
        for _, feed in ipairs({"channels", "analyze", "errors", "psi", "dvb"}) do
            MONIT_ADDRESS[feed] = {host = host, port = port, path = path}
            log_info("[set_client_monitoring] Overridden standard monitoring address for client '" .. feed .. "' with host=" .. host .. ", port=" .. port .. ", path=" .. path)
        end
    end

    return true
end

--- Возвращает имя хоста сервера.
-- @return string Имя хоста.
function get_server_name()
    return hostname
end

--- Отправляет данные мониторинга на настроенные адреса.
-- @param string content Содержимое для отправки (JSON-строка).
-- @param string feed Тип фида (например, "channels", "analyze", "errors", "psi", "dvb").
function send_monitor(content, feed)
    local recipients = MONIT_ADDRESS[feed]
    if recipients then
        for _, addr in ipairs(recipients) do
            http_request({
                host = addr.host,
                path = addr.path,
                method = "POST",
                content = content,
                port = addr.port,
                headers = {
                    "User-Agent: Astra v." .. astra_version,
                    "Host: " .. addr.host .. ":" .. addr.port,
                    "Content-Type: application/json;charset=utf-8",
                    "Content-Length: " .. #content,
                    "Connection: close",
                },
                callback = function(s,r)
                    if not s or type(r) == "table" and r.code and r.code ~= 200 then
                        log_error(string_format("[send_monitor] HTTP request failed for feed '%s': status=%s", feed, r.code or "unknown"))
                    end
                end
            })
        end
    end
end
