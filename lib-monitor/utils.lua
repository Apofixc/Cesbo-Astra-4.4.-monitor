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

local hostname =  utils.hostname()

local STREAM = {
    ["127.0.0.1"] = "Узда",
    ["127.0.0.2"] = "Дружный",
    ["127.0.0.3"] = "Старобин",
    ["127.0.0.4"] = "Октябрьский",
    ["127.0.0.5"] = "Червень",
    ["127.0.0.6"] = "Mediatech",
    ["127.0.0.7"] = "PlayOut",
    ["127.0.0.8"] = "BeCloud",
    ["127.0.0.9"] = "WikiLink",
}

local MONIT_ADDRESS = {
    -- ["channels"] = {{host = "127.0.0.1", port = 8081, path = "/channels"}, {host = "127.0.0.1", port = 5000, path = "/channels"}}, 
    -- ["analyze"] = {{host = "127.0.0.1", port = 8082, path = "/analyze"}},    
    -- ["errors"] = {{host = "127.0.0.1", port = 8083, path = "/errors"}}, 
    -- ["dvb"] = {{host = "127.0.0.1", port = 8084, path = "/dvb"}, {host = "127.0.0.1", port = 5000, path = "/dvb"}}, 
}

local send_debug = true

-- ===========================================================================
-- Основные функции модуля
-- ===========================================================================

function get_stream(ip_address)
    if type(ip_address) ~= "string" or not ip_address then
        log_error("[get_stream] Invalid ip_address: must be a non-empty string")
        return false
    end

    return STREAM[ip_address] or ip_address
end

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

function check(cond, msg)
    if not cond then
        log_error(msg)
        return false
    end

    return true
end

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

function get_server_name()
    return hostname
end

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


