local Logger      = require "src.utils.logger"
local log_info    = Logger.info
local log_error   = Logger.error

local ChannelMonitorManager = require "src.dispatchers.channel_monitor_dispatcher"
local ChannelModule = require "src.channel.channel"

local channel_monitor_manager = ChannelMonitorManager:new()

local http_helpers = require "http.http_helpers"

local COMPONENT_NAME = "ChannelRoutes"
local validate_request = http_helpers.validate_request
local check_auth = http_helpers.check_auth
local get_param = http_helpers.get_param
local validate_delay = http_helpers.validate_delay
local send_response = http_helpers.send_response
local handle_kill_with_reboot = http_helpers.handle_kill_with_reboot
local string_lower = http_helpers.string_lower
local timer_lib = http_helpers.timer_lib
local json_encode = http_helpers.json_encode
local json_decode = http_helpers.json_decode
local AstraAPI = require "src.api.astra_api"
local Utils = require "src.utils.utils"

local string_split = AstraAPI.string_split
local shallow_table_copy = Utils.shallow_table_copy

local channel_list = AstraAPI.channel_list

-- =============================================
-- Управление каналами и их мониторами (Обработчики маршрутов)
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
        return send_response(server, client, 401, "Несанкционированный доступ")
    end

    handle_kill_with_reboot(
        function(name)
            local channel_data = AstraAPI.find_channel(name)
            if not channel_data then
                return nil, "Поток '" .. name .. "' не найден."
            end
            return channel_data, nil
        end, 
        function(channel_data) return ChannelModule.kill_stream(channel_data) end,
        function(cfg, name) return ChannelModule.make_stream(cfg) end,
        "Поток", server, client, validate_request(request)
    )
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
        return send_response(server, client, 401, "Несанкционированный доступ")
    end

    handle_kill_with_reboot(
        function(name)
            local channel_data = AstraAPI.find_channel(name)
            if not channel_data then
                return nil, "Канал '" .. name .. "' не найден."
            end
            return channel_data, nil
        end, 
        function(channel_data)
            local cfg = shallow_table_copy(channel_data.config) 
            AstraAPI.kill_channel(channel_data) -- AstraAPI.kill_channel ничего не возвращает, предполагаем успех
            log_info(COMPONENT_NAME, "Канал '%s' остановлен через AstraAPI.kill_channel", channel_data.config.name)
            return cfg, nil
        end, 
        function(cfg, name)
            local new_channel = AstraAPI.make_channel(cfg)
            if not new_channel then
                return nil, "Не удалось создать канал '" .. name .. "'."
            end
            return new_channel, nil
        end, 
        "Канал", server, client, validate_request(request)
    )
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
        return send_response(server, client, 401, "Несанкционированный доступ")
    end

    handle_kill_with_reboot(
        function(name)
            local monitor_data, err = ChannelModule.find_monitor(name)
            if not monitor_data then
                return nil, err or "Монитор канала '" .. name .. "' не найден."
            end
            return monitor_data, nil
        end, 
        function(monitor_data) return ChannelModule.kill_monitor(monitor_data) end,
        function(cfg, name) return ChannelModule.make_monitor(cfg, name) end,
        "Монитор", server, client, validate_request(request)
    )
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
        return send_response(server, client, 401, "Несанкционированный доступ")
    end

    local req = validate_request(request)

    local name = get_param(req, "channel")
    if not name then 
        return send_response(server, client, 400, "Отсутствует канал")   
    end

    local params = {}
    for _, param_name in ipairs({ "analyze", "time_check", "rate", "method_comparison" }) do
        local val = get_param(req, param_name)
        if val ~= nil then
            if param_name == "analyze" then
                if type(val) == "boolean" then
                    params[param_name] = val
                elseif type(val) == "string" then
                    local lower_val = string_lower(val)
                    if lower_val == "true" then
                        params[param_name] = true
                    elseif lower_val == "false" then
                        params[param_name] = false
                    end
                end
            else
                local num = tonumber(val)
                if num ~= nil then
                    params[param_name] = num
                end
            end
        end
    end

    local success, err = channel_monitor_manager:update_monitor_parameters(name, params)
    if success then
        log_info(COMPONENT_NAME, string.format("[Монитор] %s успешно обновлен", name))
        send_response(server, client, 200, "ОК")
    else
        log_error(COMPONENT_NAME, string.format("[Монитор] Обновление %s не удалось: %s", name, err or "неизвестная ошибка"))
        send_response(server, client, 400, "Обновление не удалось: " .. (err or "неизвестная ошибка"))
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
        return send_response(server, client, 401, "Несанкционированный доступ")
    end

    if not channel_list then
        log_error(COMPONENT_NAME, "[get_channels] channel_list равен nil.")
        return send_response(server, client, 500, "Внутренняя ошибка сервера: Список каналов недоступен.")
    end

    local content = {}
    for _, channel_data in ipairs(channel_list) do
        table.insert(content, channel_data.config.name)
    end
    
    local json_content = json_encode(content)
    if not json_content then
        log_error(COMPONENT_NAME, "Не удалось закодировать список каналов в JSON")
        return send_response(server, client, 500, "Внутренняя ошибка сервера: Не удалось закодировать список каналов.")
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
        return send_response(server, client, 401, "Несанкционированный доступ")
    end

    local content = {}
    for name, _ in pairs(channel_monitor_manager:get_all_monitors()) do
        table.insert(content, name)
    end
    
    local json_content = json_encode(content)
    if not json_content then
        log_error(COMPONENT_NAME, "Не удалось закодировать список мониторов в JSON")
        return send_response(server, client, 500, "Внутренняя ошибка сервера: Не удалось закодировать список мониторов.")
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
        return send_response(server, client, 401, "Несанкционированный доступ")
    end

    local req = validate_request(request)

    local name = get_param(req, "channel")
    if not name then 
        return send_response(server, client, 400, "Отсутствует канал")   
    end

    local monitor, get_err = channel_monitor_manager:get_monitor(name)
    
    if not monitor then
        return send_response(server, client, 404, "Монитор канала '" .. name .. "' не найден. Ошибка: " .. (get_err or "неизвестно"))
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
        return send_response(server, client, 401, "Несанкционированный доступ")
    end

    local req = validate_request(request)

    local name = get_param(req, "channel")
    if not name then 
        return send_response(server, client, 400, "Отсутствует канал")   
    end

    local monitor, get_err = channel_monitor_manager:get_monitor(name)

    if not monitor then
        return send_response(server, client, 404, "Монитор канала '" .. name .. "' не найден. Ошибка: " .. (get_err or "неизвестно"))
    end

    local psi_cache_table = monitor:get_psi_data_cache()
    if not psi_cache_table or next(psi_cache_table) == nil then -- Проверяем, что таблица не пуста
        return send_response(server, client, 404, "Кэш PSI для '" .. name .. "' не найден или пуст.")
    end

    local json_content = json_encode(psi_cache_table)
    if not json_content then
        log_error(COMPONENT_NAME, "Не удалось закодировать данные PSI в JSON")
        return send_response(server, client, 500, "Внутренняя ошибка сервера: Не удалось закодировать данные PSI.")
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
