-- ===========================================================================
-- Кэширование встроенных функций для производительности
-- ===========================================================================

local type        = type
local tostring    = tostring
local string_format = string.format
local math_max    = math.max
local math_abs    = math.abs
local Logger      = require "utils.logger"
local log_info    = Logger.info
local log_error   = Logger.error
local log_debug   = Logger.debug
local ipairs      = ipairs
local http_request = http_request
local astra_version = astra.version

-- ===========================================================================
-- Константы и конфигурация
-- ===========================================================================

local config = require "config.monitor_settings"
local MonitorConfig = require "config.monitor_config"

-- Предполагаем, что astra.version и http_request доступны глобально в окружении Astra.
-- Если это не так, их нужно будет передавать или явно требовать.

local hostname      = utils.hostname()

local STREAM        = config.STREAM or {}
local MONIT_ADDRESS = config.MONIT_ADDRESS or {} -- Убедиться, что MONIT_ADDRESS всегда является таблицей
local DEFAULT_FEEDS = {"channels", "analyze", "errors", "psi", "dvb"}

-- ===========================================================================
-- Основные функции модуля
-- ===========================================================================

--- Возвращает имя потока по IP-адресу, используя предопределенную карту STREAM.
-- Если IP-адрес не найден в карте, возвращает сам IP-адрес.
-- @param string ip_address IP-адрес потока.
-- @return string Имя потока или исходный IP-адрес, если имя не найдено; `nil` и сообщение об ошибке, если `ip_address` невалиден.
function get_stream(ip_address)
    if type(ip_address) ~= "string" or not ip_address then
        local error_msg = "Invalid ip_address: must be a non-empty string. Got " .. tostring(ip_address) .. "."
        log_error("[get_stream]", error_msg)
        return nil, error_msg
    end

    return STREAM[ip_address] or ip_address, nil
end

--- Вычисляет отношение абсолютной разницы между двумя числами к их максимальному значению.
-- Используется для определения относительного изменения.
-- @param number old Старое значение.
-- @param number new Новое значение.
-- @return number Отношение (от 0 до 1) или `nil` и сообщение об ошибке, если входные данные невалидны.
function ratio(old, new)
    if type(old) ~= "number" or type(new) ~= "number" then
        local error_msg = string_format("Invalid types: old and new must be numbers. Got old: %s, new: %s", type(old), type(new))
        log_error("[ratio]", error_msg)
        return nil, error_msg
    end
    
    if new == 0 then
        return 0, nil
    end

    return math_abs(old - new) / math_max(old, new), nil
end

--- Создает поверхностную копию таблицы.
-- @param table t Исходная таблица.
-- @return table Копия таблицы; `nil` и сообщение об ошибке, если входной аргумент невалиден.
-- table.copy: Предполагается, что эта функция может быть предоставлена Astra глобально.
-- Если Astra не предоставляет table.copy, то можно использовать следующую реализацию:
local table_copy = table.copy or function(t)
    if type(t) ~= "table" then
        local error_msg = "Invalid argument: must be a table. Got " .. type(t) .. "."
        log_error("[table.copy]", error_msg)
        return nil, error_msg
    end

    local copy = {}
    for k, v in pairs(t) do
        copy[k] = v
    end

    return copy, nil
end

--- Вспомогательная функция для валидации общих параметров мониторинга.
-- @param string host Хост.
-- @param number port Порт.
-- @param string path Путь.
-- @param string feed (optional) Имя клиента.
-- @return boolean true, если все параметры валидны, иначе `nil` и сообщение об ошибке.
local function validate_monitoring_params(host, port, path, feed)
    if not (type(host) == "string" and host ~= "") then
        local error_msg = "Host must be a non-empty string. Got " .. tostring(host) .. "."
        log_error("[validate_monitoring_params]", error_msg)
        return nil, error_msg
    end

    if not (type(port) == "number" and port > 0) then
        local error_msg = "Port must be a positive number. Got " .. tostring(port) .. "."
        log_error("[validate_monitoring_params]", error_msg)
        return nil, error_msg
    end

    if not (type(path) == "string" and path ~= "") then
        local error_msg = "Path must be a non-empty string. Got " .. tostring(path) .. "."
        log_error("[validate_monitoring_params]", error_msg)
        return nil, error_msg
    end

    if feed and not (type(feed) == "string" and feed ~= "") then
        local error_msg = "Feed must be a non-empty string if provided. Got " .. tostring(feed) .. "."
        log_error("[validate_monitoring_params]", error_msg)
        return nil, error_msg
    end
    return true, nil
end

--- Валидирует параметр монитора на основе его имени, значения и типа/диапазона, используя схему.
-- @param string name Имя параметра.
-- @param any value Значение параметра для валидации.
-- @return any Валидное значение параметра или `nil` и сообщение об ошибке, если значение невалидно.
function validate_monitor_param(name, value)
    local schema = MonitorConfig.ValidationSchema[name]
    if not schema then
        local error_msg = string_format("Unknown monitor parameter in schema: %s", name)
        log_error("[validate_monitor_param]", error_msg)
        return nil, error_msg
    end

    if value == nil then
        return nil, nil -- Позволяем вызывающей стороне использовать значение по умолчанию
    end

    if type(value) ~= schema.type then
        local error_msg = string_format("Invalid type for '%s': expected %s, got %s.", name, schema.type, type(value))
        log_error("[validate_monitor_param]", error_msg)
        return nil, error_msg
    end

    if schema.type == "number" then
        if schema.min ~= nil and value < schema.min then
            local error_msg = string_format("Value for '%s' (%s) is less than minimum allowed (%s).", name, tostring(value), tostring(schema.min))
            log_error("[validate_monitor_param]", error_msg)
            return nil, error_msg
        end
        if schema.max ~= nil and value > schema.max then
            local error_msg = string_format("Value for '%s' (%s) is greater than maximum allowed (%s).", name, tostring(value), tostring(schema.max))
            log_error("[validate_monitor_param]", error_msg)
            return nil, error_msg
        end
    end

    return value, nil
end

--- Вспомогательная функция для валидации имени монитора.
-- @param string name Имя монитора.
-- @return boolean true, если имя валидно; `nil` и сообщение об ошибке в случае ошибки.
--- Вспомогательная функция для валидации имени монитора.
-- Имя монитора должно быть непустой строкой, содержать только буквенно-цифровые символы,
-- дефисы, подчеркивания и точки, а также иметь ограниченную длину.
-- @param string name Имя монитора.
-- @return boolean true, если имя валидно; `nil` и сообщение об ошибке в случае ошибки.
function validate_monitor_name(name)
    if not name or type(name) ~= "string" or name == "" then
        local error_msg = "Invalid monitor name: expected non-empty string, got " .. tostring(name) .. "."
        log_error("[validate_monitor_name]", error_msg)
        return nil, error_msg
    end

    -- Проверка на допустимые символы (буквы, цифры, дефисы, подчеркивания, точки)
    if not string.match(name, "^[a-zA-Z0-9%._-]+$") then
        local error_msg = "Invalid monitor name: contains disallowed characters. Only alphanumeric, hyphens, underscores, and dots are allowed."
        log_error("[validate_monitor_name]", error_msg)
        return nil, error_msg
    end

    -- Проверка на максимальную длину имени
    if #name > MonitorConfig.MaxMonitorNameLength then
        local error_msg = string_format("Invalid monitor name: length (%s) exceeds maximum allowed (%s).", #name, MonitorConfig.MaxMonitorNameLength)
        log_error("[validate_monitor_name]", error_msg)
        return nil, error_msg
    end

    return true, nil
end

--- Устанавливает или переопределяет адрес мониторинга для клиентов.
-- @param string host Хост для мониторинга.
-- @param number port Порт для мониторинга.
-- @param string path Путь для мониторинга.
-- @param string feed (optional) Имя клиента (например, "channels", "analyze"). Если не указано, обновляет все стандартные клиенты.
-- @return boolean true, если адрес успешно установлен; `nil` и сообщение об ошибке в случае ошибки.
function set_client_monitoring(host, port, path, feed)
    local is_valid, validation_err = validate_monitoring_params(host, port, path, feed)
    if not is_valid then
        return nil, validation_err
    end

    if feed then
        -- Убедиться, что MONIT_ADDRESS[feed] является таблицей
        if type(MONIT_ADDRESS[feed]) ~= "table" then
            MONIT_ADDRESS[feed] = {}
        end

        local new_address = {host = host, port = port, path = path}
        local is_duplicate = false
        for _, existing_addr in ipairs(MONIT_ADDRESS[feed]) do
            if existing_addr.host == new_address.host and existing_addr.port == new_address.port and existing_addr.path == new_address.path then
                is_duplicate = true
                break
            end
        end

        if is_duplicate then
            log_info("[set_client_monitoring]", "Monitoring address for client '%s' with host=%s, port=%s, path=%s already exists. Skipping addition.", feed, host, tostring(port), path)
        else
            table.insert(MONIT_ADDRESS[feed], new_address)
            log_info("[set_client_monitoring]", "Added monitoring address for client '%s' with host=%s, port=%s, path=%s", feed, host, tostring(port), path)
        end
    else
        for _, feed_name in ipairs(DEFAULT_FEEDS) do
            -- Очистить существующий список и добавить новый адрес
            MONIT_ADDRESS[feed_name] = {{host = host, port = port, path = path}}
            log_info("[set_client_monitoring]", "Set default monitoring address for client '%s' with host=%s, port=%s, path=%s", feed_name, host, tostring(port), path)
        end
    end

    return true, nil
end

--- Удаляет конкретный адрес мониторинга для клиента.
-- @param string host Хост для удаления.
-- @param number port Порт для удаления.
-- @param string path Путь для удаления.
-- @param string feed Имя клиента (например, "channels", "analyze").
-- @return boolean true, если адрес успешно удален; `nil` и сообщение об ошибке в случае ошибки.
function remove_client_monitoring(host, port, path, feed)
    local is_valid, validation_err = validate_monitoring_params(host, port, path, feed)
    if not is_valid then
        return nil, validation_err
    end

    local recipients = MONIT_ADDRESS[feed]
    if not recipients or #recipients == 0 then
        log_info("[remove_client_monitoring]", "No monitoring addresses found for client '%s'.", feed)
        return nil, "No monitoring addresses found for client '" .. feed .. "'."
    end

    local removed = false
    for i = #recipients, 1, -1 do
        local addr = recipients[i]
        if addr.host == host and addr.port == port and addr.path == path then
            table.remove(recipients, i)
            removed = true
            log_info("[remove_client_monitoring]", "Removed monitoring address for client '%s' with host=%s, port=%s, path=%s", feed, host, tostring(port), path)
            break
        end
    end

    if not removed then
        local error_msg = string_format("Monitoring address for client '%s' with host=%s, port=%s, path=%s not found.", feed, host, tostring(port), path)
        log_info("[remove_client_monitoring]", error_msg)
        return nil, error_msg
    end

    return true, nil
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
    log_debug("[send_monitor]", "Sending monitor data for feed '%s'. Content: %s", feed, content)
    local recipients = MONIT_ADDRESS[feed]
    if recipients and #recipients > 0 then
        local content_length = #content
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
                    "Content-Length: " .. content_length,
                    "Connection: close",
                },
                callback = function(s,r)
                    if not s then
                        log_error("[send_monitor]", "HTTP request failed for feed '%s' to %s:%s%s: status=connection_error", feed, addr.host, tostring(addr.port), addr.path)
                    elseif type(r) == "table" and r.code and r.code ~= 200 then
                        log_error("[send_monitor]", "HTTP request failed for feed '%s' to %s:%s%s: status=%s", feed, addr.host, tostring(addr.port), addr.path, r.code)
                    elseif type(r) == "string" then -- Если r - это строка с ошибкой
                        log_error("[send_monitor]", "HTTP request failed for feed '%s' to %s:%s%s: error=%s", feed, addr.host, tostring(addr.port), addr.path, r)
                    end
                end
            })
        end
        return true, nil
    else
        log_info("[send_monitor]", "No recipients configured for feed '%s'. Skipping send.", feed)
        return nil, "No recipients configured for feed '" .. feed .. "'"
    end
end

return {
    get_stream = get_stream,
    ratio = ratio,
    table_copy = table_copy,
    validate_monitor_param = validate_monitor_param,
    validate_monitor_name = validate_monitor_name,
    set_client_monitoring = set_client_monitoring,
    remove_client_monitoring = remove_client_monitoring,
    get_server_name = get_server_name,
    send_monitor = send_monitor,
}
