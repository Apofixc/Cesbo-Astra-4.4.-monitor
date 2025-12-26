local Logger      = require "src.utils.logger"
local log_info    = Logger.info
local log_error   = Logger.error
local tonumber = tonumber

local http_helpers = require "http.http_helpers"
local json_encode = http_helpers.json_encode
local validate_request = http_helpers.validate_request
local check_auth = http_helpers.check_auth
local get_param = http_helpers.get_param
local send_response = http_helpers.send_response

local DvbMonitorManager = require "src.dispatchers.dvb_monitor_dispatcher"
local dvb_monitor_manager = DvbMonitorManager:new()

local COMPONENT_NAME = "DvbRoutes"

-- =============================================
-- Управление DVB-адаптерами (Обработчики маршрутов)
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
        return send_response(server, client, 401, "Несанкционированный доступ")
    end

    local content = {}
    for name, _ in dvb_monitor_manager:get_all_monitors() do
        table.insert(content, name)
    end
    
    local json_content = json_encode(content)
    if not json_content then
        log_error(COMPONENT_NAME, "Не удалось закодировать список адаптеров в JSON")
        return send_response(server, client, 500, "Внутренняя ошибка сервера: Не удалось закодировать список адаптеров.")
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
        return send_response(server, client, 401, "Несанкционированный доступ")
    end    

    local req = validate_request(request)

    local name = get_param(req, "name_adapter")
    if not name then 
        return send_response(server, client, 400, "Отсутствует имя адаптера в запросе.")   
    end

    local monitor, get_err = dvb_monitor_manager:get_monitor(name)
    
    if not monitor then
        return send_response(server, client, 404, "Монитор DVB '" .. name .. "' не найден. Ошибка: " .. (get_err or "неизвестно"))
    end

    local json_cache = monitor:get_json_cache()
    if not json_cache then
        return send_response(server, client, 404, "Кэш монитора для '" .. name .. "' не найден или пуст.")
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
        return send_response(server, client, 401, "Несанкционированный доступ")
    end    

    local req = validate_request(request)

    local name_adapter = get_param(req, "name_adapter")
    if not name_adapter then 
        return send_response(server, client, 400, "Отсутствует адаптер")   
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
        log_info(COMPONENT_NAME, string.format("[Монитор] %s успешно обновлен", name_adapter))
        send_response(server, client, 200, "ОК")
    else
        log_error(COMPONENT_NAME, string.format("[Монитор] Обновление %s не удалось: %s", name_adapter, err or "неизвестная ошибка"))
        send_response(server, client, 400, "Обновление не удалось: " .. (err or "неизвестная ошибка"))
    end
end

return {
    get_adapters = get_adapters,
    get_adapter_data = get_adapter_data,
    update_dvb_monitor = update_dvb_monitor,
}
