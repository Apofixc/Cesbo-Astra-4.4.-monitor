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

--- Обработчик HTTP-запроса для получения данных о системных ресурсах.
-- Требует аутентификации по API-ключу.
-- Метод: GET
-- Возвращает: JSON-объект с данными о системных ресурсах.
local get_system_resources = function (server, client, request, resource_adapter)
    if not request then return nil end

    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    if not resource_adapter then
        log_error(COMPONENT_NAME, "ResourceAdapter instance is not available.")
        return send_response(server, client, 500, "Internal server error: ResourceAdapter not initialized.")
    end

    local data = resource_adapter:collect_system_data()
    local json_content, encode_err = json_encode(data)
    if not json_content then
        local error_msg = "Failed to encode system resource data to JSON: " .. (encode_err or "unknown")
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

--- Обработчик HTTP-запроса для получения данных о ресурсах конкретного процесса.
-- Требует аутентификации по API-ключу.
-- Метод: GET
-- Параметры запроса (JSON или Query String):
--   - pid (number, required): PID процесса для мониторинга.
-- Возвращает: JSON-объект с данными о ресурсах процесса.
local get_process_resources = function (server, client, request, resource_adapter)
    if not request then return nil end

    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    if not resource_adapter then
        log_error(COMPONENT_NAME, "ResourceAdapter instance is not available.")
        return send_response(server, client, 500, "Internal server error: ResourceAdapter not initialized.")
    end

    local req = http_helpers.validate_request(request)
    local pid_str = http_helpers.get_param(req, "pid")
    local pid = tonumber(pid_str)

    if not pid then
        return http_helpers.send_response(server, client, 400, "Bad Request: 'pid' parameter is required and must be a number.")
    end

    local data = resource_adapter:collect_process_data(pid)
    local json_content, encode_err = json_encode(data)
    if not json_content then
        local error_msg = "Failed to encode process resource data to JSON: " .. (encode_err or "unknown")
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

return {
    astra_reload = astra_reload,
    kill_astra = kill_astra,
    health = health,
    get_system_resources = get_system_resources,
    get_process_resources = get_process_resources
}
