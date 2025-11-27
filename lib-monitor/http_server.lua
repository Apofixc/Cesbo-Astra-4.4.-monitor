local tonumber = tonumber
local string_lower = string.lower
local table_copy = table.copy
local table_concat = table.concat
local os_exit = os.exit

local log_info = log.info
local log_error = log.error
local timer = timer
local http_server = http_server
local astra_version = astra.version
local astra_reload = astra.reload

-- =============================================
-- Хелперы (Helplers)
-- =============================================

local function get_param(req, key) 
    return req.query and req.query[key] 
end

local function validate_interval(s) 
    local i = tonumber(s)
    return (i and i >= 1) and i or 5 
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
        timer({
            interval = interval, 
            callback = function(t) 
                t:close()
                make_func(cfg, name)
                log_info(string.format("[%s] %s rebooted after %d seconds", log_prefix, name, interval)) 
            end
        })
    end

    send_response(server, client, 200, "OK")
end

-- =============================================
-- Управления каналами и их мониторами (Route Handlers)
-- =============================================

local control_kill_stream = function(server, client, req)
    handle_kill_with_reboot(find_channel, kill_stream, make_stream, "Stream", server, client, req)
end

local control_kill_channel = function(server, client, req)
    handle_kill_with_reboot(find_channel, function(channel_data)
        local cfg = table_copy(channel_data.config) 
        kill_channel(channel_data)
        return cfg
    end, make_channel, "Channel", server, client, req)
end

local control_kill_monitor = function(server, client, req)
    handle_kill_with_reboot(find_monitor, kill_monitor, function(cfg, name)
        make_monitor(name, cfg)
    end, "Monitors", server, client, req)
end

local update_monitor_channel = function(server, client, req)
    local name = get_param(req, "channel")
    if not name then 
        return send_response(server, client, 400, "Missing channel")   
    end

    local params = {}
    for _, param_name in ipairs({ "analyze", "time_update", "rate" }) do
        local val = get_param(req, param_name)
        if val and val ~= "" then params[param_name] = val end
    end

    local result = update_monitor_parameters(name, params)
    if result then
        log_info(string.format("[Monitor] %s updated successfully", name))
    else
        log_error(string.format("[Monitor] %s update failed (invalid params or monitor not found)", name))
    end

    send_response(server, client, result and 200 or 400)
end

-- Функция get_psi_channel была закомментирована, пропускаем ее оптимизацию.

local update_monitor_dvb = function(server, client, req)
    local name_adapter = get_param(req, "name_adapter")
    if not name_adapter then 
        return send_response(server, client, 400, "Missing adapter")   
    end

    local params = {}
    for _, param_name in ipairs({ "time_update", "rate" }) do
        local val = get_param(req, param_name)
        if val and val ~= "" then params[param_name] = val end
    end

    local result = update_monitor_parameters(name_adapter, params)
    if result then
        log_info(string.format("[Monitor] %s updated successfully", name_adapter))
    else
        log_error(string.format("[Monitor] %s update failed (invalid params or monitor not found)", name_adapter))
    end

    send_response(server, client, result and 200 or 400)
end

local reload_astra = function(server, client, req)
    timer({
        interval = validate_interval(get_param(req, "interval")), 
        callback = function(t) 
            t:close()
            astra_reload() -- Используем локализованную функцию
            log_info("[Astra] Reloaded") 
        end
    })
    send_response(server, client, 200, "Reload scheduled") -- Добавил сообщение
end

local kill_astra = function(server, client, req)
    timer({
        interval = validate_interval(get_param(req, "interval")), 
        callback = function(t) 
            t:close() 
            log_info("[Astra] Stopped") 
            os_exit(0) -- Используем локализованную функцию
        end
    })
    send_response(server, client, 200, "Shutdown scheduled") -- Добавил сообщение
end

function server_start(addr, port)
    http_server({
        addr = addr,
        port = port,
        route = {
            {"/control_kill_stream", control_kill_stream},
            {"/control_kill_channel", control_kill_channel},
            {"/control_kill_monitors", control_kill_monitor},
            {"/update_monitor_channel", update_monitor_channel},
            -- {"/get_psi_channel", get_psi_channel}, -- Закомментированный маршрут
            {"/update_monitor_dvb", update_monitor_dvb},
            {"/reload", reload_astra},
            {"/exit", kill_astra}
        }
    })
    log_info(string.format("[Server] Started on %s:%d", addr, port))
end