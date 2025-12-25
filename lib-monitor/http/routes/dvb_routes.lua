local Logger      = require "lib-monitor.src.utils.logger"
local log_error   = Logger.error
local tonumber = tonumber

local http_helpers = require "lib-monitor.http.http_helpers"
local json_encode = http_helpers.json_encode
local validate_request = http_helpers.validate_request
local check_auth = http_helpers.check_auth
local get_param = http_helpers.get_param
local send_response = http_helpers.send_response

local DvbMonitorManager = require "lib-monitor.src.dispatchers.dvb_monitor_dispatcher"
local dvb_monitor_manager = DvbMonitorManager:new()

local COMPONENT_NAME = "DvbRoutes" -- Определяем COMPONENT_NAME для логирования

-- =============================================
-- Управление DVB-адаптерами (Route Handlers)
-- =============================================

--- Обработчик HTTP-запроса для получения списка DVB-адаптеров.
-- Требует аутентификации по API-ключу.
--
-- Возвращает JSON-объект со списком адаптеров. Структура JSON:
-- {
--   adapter_1 (string): Имя адаптера,
--   adapter_2 (string): Имя адаптера,
--   ...
-- }
local get_adapters = function(server, client, request)
    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    local content = {}
    for name, _ in dvb_monitor_manager:get_all_monitors() do
        table.insert(content, name)
    end
    
    local json_content = json_encode(content)
    if not json_content then
        log_error(COMPONENT_NAME, "Failed to encode adapter list to JSON")
        return send_response(server, client, 500, "Internal server error: Failed to encode adapter list.")
    end

    local headers = {
        "Content-Type: application/json;charset=utf-8",
        "Content-Length: " .. #json_content,
        "Connection: close",
    }    
    
    send_response(server, client, 200, json_content, headers) 
end

--- Обработчик HTTP-запроса для получения данных DVB-адаптера.
-- Требует аутентификации по API-ключу.
--
-- Возвращает JSON-объект со статусом DVB-адаптера. Структура JSON:
-- {
--   type (string): "dvb",
--   server (string): Имя сервера,
--   format (string): Формат DVB (например, "T", "S", "C"),
--   modulation (string): Тип модуляции,
--   source (string/number): Транспондер или частота,
--   name_adapter (string): Имя адаптера,
--   status (number): Статус сигнала (-1 по умолчанию),
--   signal (number): Уровень сигнала (-1 по умолчанию),
--   snr (number): Соотношение сигнал/шум (-1 по умолчанию),
--   ber (number): Коэффициент битовых ошибок (-1 по умолчанию),
--   unc (number): Количество некорректируемых ошибок (-1 по умолчанию)
-- }
local get_adapter_data = function(server, client, request)
    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end    

    local req = validate_request(request)

    local name = get_param(req, "name_adapter")
    if not name then 
        return send_response(server, client, 400, "Missing adapter name in request.")   
    end

    local monitor, get_err = dvb_monitor_manager:get_monitor(name)
    
    if not monitor then
        return send_response(server, client, 404, "DVB Monitor '" .. name .. "' not found. Error: " .. (get_err or "unknown"))
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

--- Обработчик HTTP-запроса для обновления параметров DVB-монитора.
-- Требует аутентификации по API-ключу.
-- Метод: POST
-- Параметры запроса (JSON или Query String):
--   - name_adapter (string): Имя адаптера (обязательно).
--   - time_check (number, optional): Новый интервал проверки в секундах (неотрицательное число).
--   - rate (number, optional): Новое значение допустимой погрешности (от 0.001 до 1).
-- Возвращает: HTTP 200 OK или 400 Bad Request / 401 Unauthorized.
local update_dvb_monitor = function(server, client, request)
    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end    

    local req = validate_request(request)

    local name_adapter = get_param(req, "name_adapter")
    if not name_adapter then 
        return send_response(server, client, 400, "Missing adapter")   
    end

    local params = {}
    for _, param_name in ipairs({ "time_check", "rate" }) do
        local val = get_param(req, param_name)
        if val and val ~= "" then 
            local num = tonumber(val)
            if num then params[param_name] = num end
        end
    end

    local success, err = dvb_monitor_manager:update_monitor_parameters(name_adapter, params)
    if success then
        log_info(string.format("[Monitor] %s updated successfully", name_adapter))
        send_response(server, client, 200, "OK")
    else
        log_error(string.format("[Monitor] %s update failed: %s", name_adapter, err or "unknown error"))
        send_response(server, client, 400, "Update failed: " .. (err or "unknown error"))
    end
end

return {
    get_adapters = get_adapters,
    get_adapter_data = get_adapter_data,
    update_dvb_monitor = update_dvb_monitor,
}
