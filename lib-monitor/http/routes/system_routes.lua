local log_info    = log.info
local log_error   = log.error

local http_helpers = require "http.http_helpers"
local validate_request = http_helpers.validate_request
local check_auth = http_helpers.check_auth
local get_param = http_helpers.get_param
local validate_delay = http_helpers.validate_delay
local send_response = http_helpers.send_response
local timer_lib = http_helpers.timer_lib
local os_exit_func = http_helpers.os_exit_func
local astra_version_var = http_helpers.astra_version_var
local astra_reload_func = http_helpers.astra_reload_func
local json_encode = http_helpers.json_encode

-- =============================================
-- Управление системой Astra (Route Handlers)
-- =============================================

--- Обработчик HTTP-запроса для перезагрузки Astra.
-- Требует аутентификации по API-ключу.
-- Метод: POST
-- Параметры запроса (JSON или Query String):
--   - delay (number, optional): Задержка в секундах перед перезагрузкой (по умолчанию 30).
-- Возвращает: HTTP 200 OK или 401 Unauthorized.
local astra_reload = function(server, client, request)
    if not request then return nil end

    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end    

    local req = validate_request(request)
    send_response(server, client, 200, "Reload scheduled")
    timer_lib({
        interval = validate_delay(get_param(req, "delay")), 
        callback = function(t) 
            t:close()
            log_info(COMPONENT_NAME, "[Astra] Reloaded") -- Изменено на log_info с COMPONENT_NAME
            astra_reload_func()
        end
    })
end

--- Обработчик HTTP-запроса для остановки Astra.
-- Требует аутентификации по API-ключу.
-- Метод: POST
-- Параметры запроса (JSON или Query String):
--   - delay (number, optional): Задержка в секундах перед остановкой (по умолчанию 30).
-- Возвращает: HTTP 200 OK или 401 Unauthorized.
local kill_astra = function(server, client, request)
    if not request then return nil end

    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end   

    local req = validate_request(request)
    send_response(server, client, 200, "Shutdown scheduled")
    timer_lib({
        interval = validate_delay(get_param(req, "delay")), 
        callback = function(t) 
            t:close() 
            log_info(COMPONENT_NAME, "[Astra] Stopped") -- Изменено на log_info с COMPONENT_NAME
            os_exit_func(0)
        end
    })

end

--- Обработчик HTTP-запроса для проверки состояния сервера.
-- Требует аутентификации по API-ключу.
--
-- Возвращает JSON-объект с информацией о сервере. Структура JSON:
-- {
--   addr (string): IP-адрес сервера,
--   port (number): Порт сервера,
--   version (string): Версия Astra
-- }
local health = function (server, client, request)
    if not request then return nil end

    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end   

    local json_content, encode_err = json_encode({addr = server.__options.addr, port = server.__options.port, version = astra_version_var})
    if not json_content then
        local error_msg = "Failed to encode health data to JSON: " .. (encode_err or "unknown")
        log_error(COMPONENT_NAME, error_msg)
        return send_response(server, client, 500, "Internal server error: " .. error_msg)
    end

    local headers = {
        "Content-Type: application/json;charset=utf-8",
        "Content-Length: " .. #json_content,
        "Connection: close",
    }    
    
    send_response(server, client, 200, json_content, headers) 
end

--- Обработчик HTTP-запроса для получения списка всех ресурсных мониторов.
-- Требует аутентификации по API-ключу.
-- Метод: GET
-- Возвращает: HTTP 200 OK с JSON-массивом мониторов или 401 Unauthorized.
local get_all_resource_monitors = function(monitor_manager)
    return function(server, client, request)
        if not request then return nil end

        if not check_auth(request) then
            return send_response(server, client, 401, "Unauthorized")
        end

        local monitors_data = {}
        for name, monitor in monitor_manager.resource_manager:get_all_monitors() do
            table.insert(monitors_data, {
                name = name,
                config = monitor.config,
                status = "active" -- Или другая информация о статусе
            })
        end

        local json_content, encode_err = json_encode(monitors_data)
        if not json_content then
            local error_msg = "Failed to encode resource monitors data to JSON: " .. (encode_err or "unknown")
            log_error(COMPONENT_NAME, error_msg)
            return send_response(server, client, 500, "Internal server error: " .. error_msg)
        end

        local headers = {
            "Content-Type: application/json;charset=utf-8",
            "Content-Length: " .. #json_content,
            "Connection: close",
        }
        send_response(server, client, 200, json_content, headers)
    end
end

--- Обработчик HTTP-запроса для получения данных конкретного ресурсного монитора.
-- Требует аутентификации по API-ключу.
-- Метод: GET
-- Параметры URL:
--   - name (string): Имя ресурсного монитора.
-- Возвращает: HTTP 200 OK с JSON-объектом монитора, 404 Not Found или 401 Unauthorized.
local get_resource_monitor = function(monitor_manager)
    return function(server, client, request)
        if not request then return nil end

        if not check_auth(request) then
            return send_response(server, client, 401, "Unauthorized")
        end

        local req = validate_request(request)
        local name = get_param(req, "name")

        if not name then
            return send_response(server, client, 400, "Bad Request: 'name' parameter is missing.")
        end

        local monitor, err = monitor_manager.resource_manager:get_monitor(name)
        if not monitor then
            return send_response(server, client, 404, "Not Found: " .. (err or "Resource monitor not found."))
        end

        local monitor_data = {
            name = monitor.name,
            config = monitor.config,
            status = "active",
            latest_data = monitor:collect_data() -- Получаем текущие данные
        }

        local json_content, encode_err = json_encode(monitor_data)
        if not json_content then
            local error_msg = "Failed to encode resource monitor data to JSON: " .. (encode_err or "unknown")
            log_error(COMPONENT_NAME, error_msg)
            return send_response(server, client, 500, "Internal server error: " .. error_msg)
        end

        local headers = {
            "Content-Type: application/json;charset=utf-8",
            "Content-Length: " .. #json_content,
            "Connection: close",
        }
        send_response(server, client, 200, json_content, headers)
    end
end

--- Обработчик HTTP-запроса для добавления нового ресурсного монитора.
-- Требует аутентификации по API-ключу.
-- Метод: POST
-- Тело запроса (JSON):
--   - name (string): Уникальное имя монитора.
--   - config (table): Конфигурация монитора (например, interval).
-- Возвращает: HTTP 201 Created, 400 Bad Request, 409 Conflict или 401 Unauthorized.
local add_resource_monitor = function(monitor_manager)
    return function(server, client, request)
        if not request then return nil end

        if not check_auth(request) then
            return send_response(server, client, 401, "Unauthorized")
        end

        local req = validate_request(request)
        local name = get_param(req, "name")
        local config = get_param(req, "config")

        if not name or not config or type(config) ~= "table" then
            return send_response(server, client, 400, "Bad Request: 'name' and 'config' (table) parameters are required.")
        end

        local monitor, err = monitor_manager.resource_manager:add_monitor(name, config)
        if not monitor then
            if string.find(err or "", "already exists") then
                return send_response(server, client, 409, "Conflict: " .. err)
            else
                return send_response(server, client, 400, "Bad Request: " .. (err or "Failed to add resource monitor."))
            end
        end

        send_response(server, client, 201, "Resource monitor '" .. name .. "' added successfully.")
    end
end

--- Обработчик HTTP-запроса для обновления параметров ресурсного монитора.
-- Требует аутентификации по API-ключу.
-- Метод: PUT
-- Параметры URL:
--   - name (string): Имя ресурсного монитора.
-- Тело запроса (JSON):
--   - params (table): Новые параметры для обновления.
-- Возвращает: HTTP 200 OK, 400 Bad Request, 404 Not Found или 401 Unauthorized.
local update_resource_monitor_parameters = function(monitor_manager)
    return function(server, client, request)
        if not request then return nil end

        if not check_auth(request) then
            return send_response(server, client, 401, "Unauthorized")
        end

        local req = validate_request(request)
        local name = get_param(req, "name")
        local params = get_param(req, "params")

        if not name or not params or type(params) ~= "table" then
            return send_response(server, client, 400, "Bad Request: 'name' and 'params' (table) parameters are required.")
        end

        local success, err = monitor_manager.resource_manager:update_monitor_parameters(name, params)
        if not success then
            if string.find(err or "", "not found") then
                return send_response(server, client, 404, "Not Found: " .. err)
            else
                return send_response(server, client, 400, "Bad Request: " .. (err or "Failed to update resource monitor parameters."))
            end
        end

        send_response(server, client, 200, "Resource monitor '" .. name .. "' parameters updated successfully.")
    end
end

--- Обработчик HTTP-запроса для удаления ресурсного монитора.
-- Требует аутентификации по API-ключу.
-- Метод: DELETE
-- Параметры URL:
--   - name (string): Имя ресурсного монитора.
-- Возвращает: HTTP 200 OK, 404 Not Found или 401 Unauthorized.
local remove_resource_monitor = function(monitor_manager)
    return function(server, client, request)
        if not request then return nil end

        if not check_auth(request) then
            return send_response(server, client, 401, "Unauthorized")
        end

        local req = validate_request(request)
        local name = get_param(req, "name")

        if not name then
            return send_response(server, client, 400, "Bad Request: 'name' parameter is missing.")
        end

        local success, err = monitor_manager.resource_manager:remove_monitor(name)
        if not success then
            if string.find(err or "", "not found") then
                return send_response(server, client, 404, "Not Found: " .. err)
            else
                return send_response(server, client, 400, "Bad Request: " .. (err or "Failed to remove resource monitor."))
            end
        end

        send_response(server, client, 200, "Resource monitor '" .. name .. "' removed successfully.")
    end
end

local init_routes = function(monitor_manager)
    return {
        ["/astra/reload"] = {
            POST = astra_reload
        },
        ["/astra/kill"] = {
            POST = kill_astra
        },
        ["/astra/health"] = {
            GET = health
        },
        ["/resource_monitors"] = {
            GET = get_all_resource_monitors(monitor_manager),
            POST = add_resource_monitor(monitor_manager)
        },
        ["/resource_monitors/:name"] = {
            GET = get_resource_monitor(monitor_manager),
            PUT = update_resource_monitor_parameters(monitor_manager),
            DELETE = remove_resource_monitor(monitor_manager)
        }
    }
end

return init_routes
