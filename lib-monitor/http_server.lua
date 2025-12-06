local tonumber = tonumber
local string_lower = string.lower
local table_copy = table.copy
local table_concat = table.concat
local table_insert = table.insert
local os_exit = os.exit
local log_info = log.info
local log_error = log.error
local timer = timer
local http_server = http_server
local astra_version = astra.version
local _astra_reload = astra.reload
local json_decode = json.decode
local json_encode = json.encode

-- =============================================
-- Хелперы (Helplers)
-- =============================================

local function validate_request(request) 
    if not request then
        log_error("[validate_request] request is nil.")
        return {}
    end
    
    if request.query then
        return request.query
    end

    local content_type = request.content and request.headers and request.headers["content-type"] and request.headers["content-type"]:lower() or ""
    if content_type == "application/json" or content_type == "multipart/json" then
        local decoder = json_decode(request.content)
        if decoder then
            return decoder
        end
    end

    log_error("[validate_request] request is empty.") 
    return {}
end

local function get_param(req, key)
    if not req then
        log_error("[get_param] req is nil.")
        return nil
    end
    
    if req[key] ~= nil then
        return req[key]
    end
end

local function validate_interval(s) 
    local i = tonumber(s)
    return (i and i >= 1) and i or 30
end

local function send_response(server, client, code, msg, headers)
    if code == 200 then
        server:send(client, {
            code = 200,
            headers = headers or {"Connection: close"}, 
            content = msg or ""
        })
    else
        log_error(string.format("[Error] %s (code: %d)", msg or "Unknown error", code))
        server:abort(client, code) 
    end
end

-- Основной хелпер для логики kill/reboot
local function handle_kill_with_reboot(find_func, kill_func, make_func, log_prefix, server, client, req)
    local name = get_param(req, "channel")

    if not name then 
        return send_response(server, client, 400, "Missing channel") 
    end

    local data = find_func(name)
    if not data then 
        return send_response(server, client, 404, "Not found") 
    end
    
    local cfg = kill_func(data)
    log_info(string.format("[%s] %s killed", log_prefix, name))

    if string_lower(get_param(req, "reboot") or "") == "true" then 
        local interval = validate_interval(get_param(req, "interval"))
        log_info(string.format("[%s] %s rebooted after %d seconds", log_prefix, name, interval)) 

        timer({
            interval = interval, 
            callback = function(t) 
                t:close()
                make_func(cfg, name)
                log_info(string.format("[%s] %s was reboot", log_prefix, name)) 
            end
        })
    end

    send_response(server, client, 200, "OK")
end

-- =============================================
-- Управления каналами и их мониторами (Route Handlers)
-- =============================================

local control_kill_stream = function(server, client, request)
    if not request then return nil end
    
    handle_kill_with_reboot(find_channel, kill_stream, make_stream, "Stream", server, client, validate_request(request))
end

local control_kill_channel = function(server, client, request)
    if not request then return nil end

    handle_kill_with_reboot(find_channel, function(channel_data)
        local cfg = table_copy(channel_data.config) 
        kill_channel(channel_data)
        return cfg
    end, make_channel, "Channel", server, client, validate_request(request))
end

local control_kill_monitor = function(server, client, request)
    if not request then return nil end

    handle_kill_with_reboot(find_monitor, kill_monitor, make_monitor, "Monitor", server, client, validate_request(request))
end

local update_monitor_channel = function(server, client, request)
    if not request then return nil end
    local req = validate_request(request)

    local name = get_param(req, "channel")
    if not name then 
        return send_response(server, client, 400, "Missing channel")   
    end

    local params = {}
    for _, param_name in ipairs({ "analyze", "time_check", "rate", "method_comparison" }) do
        local val = get_param(req, param_name)
        if param_name = "analyze" then
            if val and val ~= "" then params[param_name] = val end            
        else
            if val and val ~= "" then params[param_name] = tonumber(val) end
        end
    end

    local result = update_monitor_parameters(name, params)
    if result then
        log_info(string.format("[Monitor] %s updated successfully", name))
    else
        log_error(string.format("[Monitor] %s update failed (invalid params or monitor not found)", name))
    end

    send_response(server, client, result and 200 or 400)
end

local create_channel = function(server, client, request) -- заглушка
    if not request then return nil end
    send_response(server, client, 200)
end

local get_channel_list = function(server, client, request)
    if not request then return nil end

    local content = {}
    for key, channel_data in ipairs(channel_list) do
        content["channel_" .. key] = channel_data.config.name
    end
    
    local json_content = json_encode(content)

    local headers = {
        "Content-Type: application/json;charset=utf-8",
        "Content-Length: " .. #json_content,
        "Connection: close",
    }    
    
    send_response(server, client, 200, json_content, headers)   
end

local get_monitor_list = function(server, client, request)
    if not request then return nil end

    local content = {}
    local monitor_list = get_list_monitor()
    for key, monitor_data in pairs(monitor_list) do
        content["monitor_" .. key] = monitor_data.name
    end
    
    local json_content = json_encode(content)

    local headers = {
        "Content-Type: application/json;charset=utf-8",
        "Content-Length: " .. #json_content,
        "Connection: close",
    }    
    
    send_response(server, client, 200, json_content, headers) 
end

local get_monitor_data = function(server, client, request)
    if not request then return nil end
    local req = validate_request(request)

    local name = get_param(req, "channel")
    if not name then 
        return send_response(server, client, 400, "Missing channel")   
    end

    local monitor = find_monitor(name)
    
    if not monitor then
        return send_response(server, client, 404, "Monitor not found")
    end

    local json_content = json_encode(monitor.status)

    local headers = {
        "Content-Type: application/json;charset=utf-8",
        "Content-Length: " .. #json_content,
        "Connection: close",
    }    
    
    send_response(server, client, 200, json_content, headers)    
end

local get_psi_channel = function(server, client, request)
    if not request then return nil end
    local req = validate_request(request)

    local name = get_param(req, "channel")
    if not name then 
        return send_response(server, client, 400, "Missing channel")   
    end

    local monitor = find_monitor(name)

    if not monitor then
        return send_response(server, client, 404, "Monitor not found")
    end

    local json_content = json_encode(monitor.psi_data)

    local headers = {
        "Content-Type: application/json;charset=utf-8",
        "Content-Length: " .. #json_content,
        "Connection: close",
    }    
    
    send_response(server, client, 200, json_content, headers)   
end

local get_adapter_list = function(server, client, request)
    if not request then return nil end

    local content = {}
    local key = 1
    local monitor_list = get_list_adapter()
    for name, _ in pairs(monitor_list) do
        content["adapter_" .. key] = name
        key = key + 1
    end
    
    local json_content = json_encode(content)

    local headers = {
        "Content-Type: application/json;charset=utf-8",
        "Content-Length: " .. #json_content,
        "Connection: close",
    }    
    
    send_response(server, client, 200, json_content, headers) 
end

local get_adapter_data = function(server, client, request) -- заглушка
    if not request then return nil end
    -- local req = validate_request(request)

    -- local name = get_param(req, "channel")
    -- if not name then 
    --     return send_response(server, client, 400, "Missing channel")   
    -- end

    -- local monitor = find_monitor(name)
    
    -- local json_content = json_encode(monitor.status)

    -- local headers = {
    --     "Content-Type: application/json;charset=utf-8",
    --     "Content-Length: " .. #json_content,
    --     "Connection: close",
    -- }    
    
    send_response(server, client, 200)   
end

local update_monitor_dvb = function(server, client, request)
    if not request then return nil end
    local req = validate_request(request)

    local name_adapter = get_param(req, "name_adapter")
    if not name_adapter then 
        return send_response(server, client, 400, "Missing adapter")   
    end

    local params = {}
    for _, param_name in ipairs({ "time_check", "rate" }) do
        local val = get_param(req, param_name)
        if val and val ~= "" then params[param_name] = tonumber(val) end
    end

    local result = update_monitor_parameters(name_adapter, params)
    if result then
        log_info(string.format("[Monitor] %s updated successfully", name_adapter))
    else
        log_error(string.format("[Monitor] %s update failed (invalid params or monitor not found)", name_adapter))
    end

    send_response(server, client, result and 200 or 400)
end

local astra_reload = function(server, client, request)
    if not request then return nil end
    local req = validate_request(request)
    send_response(server, client, 200, "Reload scheduled")
    timer({
        interval = validate_interval(get_param(req, "interval")), 
        callback = function(t) 
            t:close()
            log_info("[Astra] Reloaded") 
            _astra_reload()
        end
    })
end

local kill_astra = function(server, client, request)
    if not request then return nil end
    local req = validate_request(request)
    send_response(server, client, 200, "Shutdown scheduled")
    timer({
        interval = validate_interval(get_param(req, "interval")), 
        callback = function(t) 
            t:close() 
            log_info("[Astra] Stopped") 
            os_exit(0)
        end
    })

end

local instance = function (server, client, request)
    if not request then return nil end

    local json_content = json_encode({addr = server.__options.addr, port = server.__options.port})

    local headers = {
        "Content-Type: application/json;charset=utf-8",
        "Content-Length: " .. #json_content,
        "Connection: close",
    }    
    
    send_response(server, client, 200, json_content, headers) 
end

function server_start(addr, port)
    http_server({
        addr = addr,
        port = port,
        route = {
            {"/api/control_kill_stream", control_kill_stream},
            {"/api/control_kill_channel", control_kill_channel},
            {"/api/control_kill_monitor", control_kill_monitor},
            {"/api/update_monitor_channel", update_monitor_channel},
            {"/api/create_channel", create_channel},
            {"/api/get_channel_list", get_channel_list},
            {"/api/get_monitor_list", get_monitor_list},
            {"/api/get_monitor_data", get_monitor_data},
            {"/api/get_psi_channel", get_psi_channel},
            {"/api/get_adapter_list", get_adapter_list},
            {"/api/get_adapter_data", get_adapter_data},
            {"/api/update_monitor_dvb", update_monitor_dvb},
            {"/api/reload", astra_reload},
            {"/api/exit", kill_astra},
            {"/api/instance", instance}
        }
    })
    log_info(string.format("[Server] Started on %s:%d", addr, port))
end