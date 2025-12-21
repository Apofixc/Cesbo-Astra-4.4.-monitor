local log_info    = log.info
local log_error   = log.error

local ChannelMonitorManager = require "dispatcher.channel_monitor_manager"
local ChannelModule = require "channel.channel"

local channel_monitor_manager = ChannelMonitorManager:new()

local http_helpers = require "http.http_helpers"

local COMPONENT_NAME = "ChannelRoutes" -- Определяем COMPONENT_NAME для логирования
local validate_request = http_helpers.validate_request
local check_auth = http_helpers.check_auth
local get_param = http_helpers.get_param
local validate_delay = http_helpers.validate_delay
local send_response = http_helpers.send_response
local handle_kill_with_reboot = http_helpers.handle_kill_with_reboot
local string_lower = http_helpers.string_lower
local timer_lib = http_helpers.timer_lib
local json_encode = http_helpers.json_encode
local json_decode = http_helpers.json_decode -- Добавляем json_decode
local string_split = http_helpers.string_split
local table_copy = http_helpers.table_copy -- Используем из http_helpers

-- =============================================
-- Управление каналами и их мониторами (Route Handlers)
-- =============================================

--- Обработчик HTTP-запроса для остановки или перезагрузки потока.
-- Требует аутентификации по API-ключу.
-- Метод: POST
-- Параметры запроса (JSON или Query String):
--   - channel (string): Имя потока (обязательно).
--   - reboot (boolean, optional): true для перезагрузки потока после остановки.
--   - delay (number, optional): Задержка в секундах перед перезагрузкой (по умолчанию 30).
-- Возвращает: HTTP 200 OK или 400 Bad Request / 401 Unauthorized / 404 Not Found.
local kill_stream = function(server, client, request)
    if not request then return nil end
    
    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    handle_kill_with_reboot(ChannelModule.find_channel, ChannelModule.kill_stream, ChannelModule.make_stream, "Stream", server, client, validate_request(request))
end

--- Обработчик HTTP-запроса для остановки или перезагрузки канала.
-- Требует аутентификации по API-ключу.
-- Метод: POST
-- Параметры запроса (JSON или Query String):
--   - channel (string): Имя канала (обязательно).
--   - reboot (boolean, optional): true для перезагрузки канала после остановки.
--   - delay (number, optional): Задержка в секундах перед перезагрузкой (по умолчанию 30).
-- Возвращает: HTTP 200 OK или 400 Bad Request / 401 Unauthorized / 404 Not Found.
local kill_channel = function(server, client, request)
    if not request then return nil end
    
    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    handle_kill_with_reboot(find_channel, function(channel_data)
        local cfg = table_copy(channel_data.config) 
        local success, err = kill_channel(channel_data)
        if not success then
            log_error(COMPONENT_NAME, "Failed to kill channel '%s': %s", channel_data.config.name, err or "unknown")
            return nil, err or "Failed to kill channel"
        end
        return cfg, nil
    end, make_channel, "Channel", server, client, validate_request(request))
end

--- Обработчик HTTP-запроса для остановки или перезагрузки монитора канала.
-- Требует аутентификации по API-ключу.
-- Метод: POST
-- Параметры запроса (JSON или Query String):
--   - channel (string): Имя монитора канала (обязательно).
--   - reboot (boolean, optional): true для перезагрузки монитора канала после остановки.
--   - delay (number, optional): Задержка в секундах перед перезагрузкой (по умолчанию 30).
-- Возвращает: HTTP 200 OK или 400 Bad Request / 401 Unauthorized / 404 Not Found.
local kill_monitor = function(server, client, request)
    if not request then return nil end

    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    local req = validate_request(request)
    local name = get_param(req, "channel")

    if not name then 
        return send_response(server, client, 400, "Missing channel") 
    end

    local monitor_obj, get_err
    local cfg, remove_err

    -- Ищем монитор только в ChannelMonitorManager
    monitor_obj, get_err = channel_monitor_manager:get_monitor(name)
    
    if not monitor_obj then 
        return send_response(server, client, 404, "Channel Monitor '" .. name .. "' not found. Error: " .. (get_err or "unknown")) 
    end
    
    cfg, remove_err = channel_monitor_manager:remove_monitor(name)
    if not cfg then
        return send_response(server, client, 500, "Failed to remove channel monitor '" .. name .. "'. Error: " .. (remove_err or "unknown"))
    end
    log_info(string.format("[Channel Monitor] %s killed", name))

    local reboot = get_param(req, "reboot")
    if type(reboot) == "boolean" and reboot == true or string_lower(tostring(reboot)) == "true" then 
        local delay = validate_delay(get_param(req, "delay"))
        log_info(string.format("[Channel Monitor] %s scheduled for reboot after %d seconds", name, delay)) 

        timer_lib({
            interval = delay, 
            callback = function(t) 
                t:close()
                local success, make_err = ChannelModule.make_monitor(cfg, name) -- make_monitor ожидает config и channel_data
                if success then
                    log_info(string.format("[Channel Monitor] %s was successfully rebooted", name)) 
                else
                    log_error(string.format("[Channel Monitor] Failed to reboot %s. Error: %s", name, make_err or "unknown"))
                end
            end
        })
    end

    send_response(server, client, 200, "OK")
end

--- Обработчик HTTP-запроса для обновления параметров монитора канала.
-- Требует аутентификации по API-ключу.
-- Метод: POST
-- Параметры запроса (JSON или Query String):
--   - channel (string): Имя канала (обязательно).
--   - analyze (boolean, optional): Включить/отключить расширенную информацию об ошибках потока.
--   - time_check (number, optional): Новый интервал проверки данных (от 0 до 300).
--   - rate (number, optional): Новое значение погрешности сравнения битрейта (от 0.001 до 0.3).
--   - method_comparison (number, optional): Новый метод сравнения состояния потока (от 1 до 4).
-- Возвращает: HTTP 200 OK или 400 Bad Request / 401 Unauthorized.
local update_channel_monitor = function(server, client, request)
    if not request then return nil end
    
    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    local req = validate_request(request)

    local name = get_param(req, "channel")
    if not name then 
        return send_response(server, client, 400, "Missing channel")   
    end

    local params = {}
    for _, param_name in ipairs({ "analyze", "time_check", "rate", "method_comparison" }) do
        local val = get_param(req, param_name)
        if param_name == "analyze" then
            if val and val ~= "" then params[param_name] = val end            
        else
            if val and val ~= "" then 
                local num = tonumber(val)
                if num then params[param_name] = num end
            end
        end
    end

    local success, err = channel_monitor_manager:update_monitor_parameters(name, params)
    if success then
        log_info(string.format("[Monitor] %s updated successfully", name))
        send_response(server, client, 200, "OK")
    else
        log_error(string.format("[Monitor] %s update failed: %s", name, err or "unknown error"))
        send_response(server, client, 400, "Update failed: " .. (err or "unknown error"))
    end
end

--- Обработчик HTTP-запроса для получения списка каналов.
-- Требует аутентификации по API-ключу.
--
-- Возвращает JSON-объект со списком каналов. Структура JSON:
-- {
--   channel_1 (table): {
--     name (string): Имя канала,
--     addr (string): Адрес канала
--   },
--   channel_2 (table): { ... }
-- }
local get_channels = function(server, client, request)
    if not request then return nil end
    
    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    if not channel_list then
        log_error(COMPONENT_NAME, "[get_channels] channel_list is nil.")
        return send_response(server, client, 500, "Internal server error: Channel list not available.")
    end

    local content = {}
    for _, channel_data in ipairs(channel_list) do
        table.insert(content, channel_data.config.name)
    end
    
    local json_content = json_encode(content)
    if not json_content then
        log_error(COMPONENT_NAME, "Failed to encode channel list to JSON: %s", encode_err or "unknown")
        return send_response(server, client, 500, "Internal server error: Failed to encode channel list.")
    end

    local headers = {
        "Content-Type: application/json;charset=utf-8",
        "Content-Length: " .. #json_content,
        "Connection: close",
    }    

    send_response(server, client, 200, json_content, headers)   
end

--- Обработчик HTTP-запроса для получения списка активных мониторов каналов.
-- Требует аутентификации по API-ключу.
--
-- Возвращает JSON-объект со списком мониторов каналов. Структура JSON:
-- {
--   monitor_1 (string): Имя монитора канала,
--   monitor_2 (string): Имя монитора канала,
--   ...
-- }
local get_channel_monitors = function(server, client, request)
    if not request then return nil end
    
    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    local content = {}
    for name, _ in pairs(channel_monitor_manager:get_all_monitors()) do
        table.insert(content, name)
    end
    
    local json_content, encode_err = json_encode(content)
    if not json_content then
        log_error(COMPONENT_NAME, "Failed to encode monitor list to JSON: %s", encode_err or "unknown")
        return send_response(server, client, 500, "Internal server error: Failed to encode monitor list.")
    end

    local headers = {
        "Content-Type: application/json;charset=utf-8",
        "Content-Length: " .. #json_content,
        "Connection: close",
    }    
    
    send_response(server, client, 200, json_content, headers) 
end

--- Обработчик HTTP-запроса для получения данных монитора канала.
-- Требует аутентификации по API-ключу.
--
-- Возвращает JSON-объект со статусом монитора. Структура JSON:
-- {
--   type (string): "Channel",
--   server (string): Имя сервера,
--   channel (string): Имя канала,
--   output (string): Адрес мониторинга,
--   stream (string): Имя потока,
--   format (string): Формат потока,
--   addr (string): Адрес потока,
--   ready (boolean): Готовность канала,
--   scrambled (boolean): Зашифрован ли канал,
--   bitrate (number): Битрейт канала,
--   cc_errors (number): Количество CC-ошибок,
--   pes_errors (number): Количество PES-ошибок,
--   analyze (table, optional): Таблица с деталями ошибок PID, если включен анализ.
-- }
local get_channel_monitor_data = function(server, client, request)
    if not request then return nil end
    
    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    local req = validate_request(request)

    local name = get_param(req, "channel")
    if not name then 
        return send_response(server, client, 400, "Missing channel")   
    end

    local monitor, get_err = channel_monitor_manager:get_monitor(name)
    
    if not monitor then
        return send_response(server, client, 404, "Channel Monitor '" .. name .. "' not found. Error: " .. (get_err or "unknown"))
    end

    local json_cache = monitor:get_json_cache()
    if not json_cache then
        return send_response(server, client, 404, "Monitor cache for '" .. name .. "' not found or empty.")
    end

    local headers = {
        "Content-Type: application/json;charset=utf-8",
        "Content-Length: " .. #json_cache,
        "Connection: close",
    }    
    
    send_response(server, client, 200, json_cache, headers)    
end

--- Обработчик HTTP-запроса для получения данных PSI канала.
-- Требует аутентификации по API-ключу.
--
-- Возвращает JSON-объект с данными PSI. Структура JSON:
-- {
--   psi (string): Тип PSI данных (например, "pmt", "sdt").
-- }
local get_channel_psi = function(server, client, request)
    if not request then return nil end
    
    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    local req = validate_request(request)

    local name = get_param(req, "channel")
    if not name then 
        return send_response(server, client, 400, "Missing channel")   
    end

    local monitor, get_err = channel_monitor_manager:get_monitor(name)

    if not monitor then
        return send_response(server, client, 404, "Channel Monitor '" .. name .. "' not found. Error: " .. (get_err or "unknown"))
    end

    local psi_cache_table = monitor:get_psi_data_cache()
    if not psi_cache_table or next(psi_cache_table) == nil then -- Проверяем, что таблица не пуста
        return send_response(server, client, 404, "PSI cache for '" .. name .. "' not found or empty.")
    end

    local json_content = json_encode(psi_cache_table)
    if not json_content then
        log_error(COMPONENT_NAME, "Failed to encode PSI data to JSON: %s", encode_err or "unknown")
        return send_response(server, client, 500, "Internal server error: Failed to encode PSI data.")
    end

    local headers = {
        "Content-Type: application/json;charset=utf-8",
        "Content-Length: " .. #json_content,
        "Connection: close",
    }    
    
    send_response(server, client, 200, json_content, headers)    
end

return {
    kill_stream = kill_stream,
    kill_channel = kill_channel,
    kill_monitor = kill_monitor,
    update_channel_monitor = update_channel_monitor,
    get_channels = get_channels,
    get_channel_monitors = get_channel_monitors,
    get_channel_monitor_data = get_channel_monitor_data,
    get_channel_psi = get_channel_psi,
}
