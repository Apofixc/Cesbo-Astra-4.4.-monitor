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

local config = require "config.monitor_settings"
local MonitorConfig = require "config.monitor_config"

local hostname =  utils.hostname()

local STREAM = config.STREAM
    local MONIT_ADDRESS = config.MONIT_ADDRESS or {} -- Убедиться, что MONIT_ADDRESS всегда является таблицей
    local DEFAULT_FEEDS = {"channels", "analyze", "errors", "psi", "dvb"}

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

--- Вспомогательная функция для валидации общих параметров мониторинга.
-- @param string host Хост.
-- @param number port Порт.
-- @param string path Путь.
-- @param string feed (optional) Имя клиента.
-- @return boolean true, если все параметры валидны, иначе false.
local function validate_monitoring_params(host, port, path, feed)
    if not (type(host) == "string" and host ~= "") then
        log_error("[monitoring_params_validation] host must be a non-empty string")
        return false
    end

    if not (type(port) == "number" and port > 0) then
        log_error("[monitoring_params_validation] port must be a positive number")
        return false
    end

    if not (type(path) == "string" and path ~= "") then
        log_error("[monitoring_params_validation] path must be a non-empty string")
        return false
    end

    if feed and not (type(feed) == "string" and feed ~= "") then
        log_error("[monitoring_params_validation] feed must be a non-empty string if provided")
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
    if not validate_monitoring_params(host, port, path, feed) then
        return false
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
            log_info(string_format("[set_client_monitoring] Monitoring address for client '%s' with host=%s, port=%s, path=%s already exists. Skipping addition.", feed, host, tostring(port), path))
        else
            table.insert(MONIT_ADDRESS[feed], new_address)
            log_info(string_format("[set_client_monitoring] Added monitoring address for client '%s' with host=%s, port=%s, path=%s", feed, host, tostring(port), path))
        end
    else
        for _, feed_name in ipairs(DEFAULT_FEEDS) do
            -- Очистить существующий список и добавить новый адрес
            MONIT_ADDRESS[feed_name] = {{host = host, port = port, path = path}}
            local log_message = string_format("[set_client_monitoring] Set default monitoring address for client '%s' with host=%s, port=%s, path=%s", feed_name, host, tostring(port), path)
            log_info(log_message)
        end
    end

    return true
end

--- Удаляет конкретный адрес мониторинга для клиента.
-- @param string host Хост для удаления.
-- @param number port Порт для удаления.
-- @param string path Путь для удаления.
-- @param string feed Имя клиента (например, "channels", "analyze").
-- @return boolean true, если адрес успешно удален, иначе false.
function remove_client_monitoring(host, port, path, feed)
    if not validate_monitoring_params(host, port, path, feed) then
        return false
    end

    local recipients = MONIT_ADDRESS[feed]
    if not recipients or #recipients == 0 then
        log_info(string_format("[remove_client_monitoring] No monitoring addresses found for client '%s'.", feed))
        return false
    end

    local removed = false
    for i = #recipients, 1, -1 do
        local addr = recipients[i]
        if addr.host == host and addr.port == port and addr.path == path then
            table.remove(recipients, i)
            removed = true
            log_info(string_format("[remove_client_monitoring] Removed monitoring address for client '%s' with host=%s, port=%s, path=%s", feed, host, tostring(port), path))
            break
        end
    end

    if not removed then
        log_info(string_format("[remove_client_monitoring] Monitoring address for client '%s' with host=%s, port=%s, path=%s not found.", feed, host, tostring(port), path))
    end

    return removed
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
