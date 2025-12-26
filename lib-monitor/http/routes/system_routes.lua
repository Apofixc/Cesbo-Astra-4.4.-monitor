local Logger = require "src.utils.logger"
local log_info = Logger.info
local log_error = Logger.error
local log_debug = Logger.debug
local ResourceMonitor = require "src.system.resource_monitor"
local resource_monitor_instance = ResourceMonitor:new("system_monitor")
local http_helpers = require "http.http_helpers"
local validate_request = http_helpers.validate_request
local check_auth = http_helpers.check_auth
local get_param = http_helpers.get_param
local validate_delay = http_helpers.validate_delay
local send_response = http_helpers.send_response
local timer_lib = http_helpers.timer_lib
local AstraAPI = require "src.api.astra_api"

local json_encode = AstraAPI.json_encode

local COMPONENT_NAME = "SystemRoutes"

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
            log_info(COMPONENT_NAME, "[Astra] Reloaded")
            AstraAPI.astra_reload()
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
            log_info(COMPONENT_NAME, "[Astra] Stopped")
            AstraAPI.os_exit(0)
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
--   version (string): Версия Astra,
--   process (table, optional): Данные о ресурсах процесса (если доступен ResourceMonitor)
-- }
local health = function (server, client, request)
    if not request then return nil end

    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end   

    local response_data = {
        addr = server.__options.addr,
        port = server.__options.port,
        version = AstraAPI.astra_version,
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
    }

    local process_data = resource_monitor_instance:collect_process_data()
    if process_data and process_data.process then
        response_data.process = {
            pid = process_data.process.pid,
            cpu_usage_percent = process_data.process.cpu and process_data.process.cpu.usage_percent or 0,
            memory_usage_mb = process_data.process.memory and process_data.process.memory.rss_mb or 0,
            memory_usage_kb = process_data.process.memory and process_data.process.memory.rss_kb or 0
        }
    else
        log_error(COMPONENT_NAME, "Failed to collect process data for health endpoint: %s", 
                 tostring(process_data))
        response_data.process = {
            pid = resource_monitor_instance.pid or 0,
            cpu_usage_percent = -1,
            memory_usage_mb = -1,
            error = "Failed to collect process data"
        }
    end

    -- Кодируем в JSON
    local json_content = json_encode(response_data)
    if not json_content then
        local error_msg = "Failed to encode health data to JSON"
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
local get_system_resources = function (server, client, request)
    if not request then return nil end

    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    if not resource_monitor_instance then
        log_error(COMPONENT_NAME, "ResourceMonitor instance is not available.")
        return send_response(server, client, 500, "Internal server error: ResourceMonitor not initialized.")
    end

    local data = resource_monitor_instance:collect_system_data()
    local json_content = json_encode(data)
    if not json_content then
        local error_msg = "Failed to encode system resource data to JSON"
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

--- Обработчик HTTP-запроса для получения статистики работы ResourceMonitor.
-- Требует аутентификации по API-ключу.
-- Метод: GET
-- Возвращает: JSON-объект со статистикой работы монитора ресурсов.
local get_monitor_stats = function (server, client, request)
    if not request then return nil end

    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    if not resource_monitor_instance then
        log_error(COMPONENT_NAME, "ResourceMonitor instance is not available.")
        return send_response(server, client, 500, "Internal server error: ResourceMonitor not initialized.")
    end

    if resource_monitor_instance.get_stats then
        local stats = resource_monitor_instance:get_stats()
        local json_content = json_encode(stats)
        if not json_content then
            local error_msg = "Failed to encode monitor stats to JSON"
            log_error(COMPONENT_NAME, error_msg)
            return send_response(server, client, 500, "Internal server error: " .. error_msg)
        end

        local headers = {
            "Content-Type: application/json;charset=utf-8",
            "Content-Length: " .. #json_content,
            "Connection: close",
        }
        
        send_response(server, client, 200, json_content, headers)
    else
        log_error(COMPONENT_NAME, "ResourceMonitor does not support get_stats method.")
        return send_response(server, client, 501, "Not Implemented: get_stats method not available")
    end
end

--- Обработчик HTTP-запроса для очистки кэша ResourceMonitor.
-- Требует аутентификации по API-ключу.
-- Метод: POST
-- Возвращает: HTTP 200 OK или ошибку.
local clear_monitor_cache = function (server, client, request)
    if not request then return nil end

    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    if not resource_monitor_instance then
        log_error(COMPONENT_NAME, "ResourceMonitor instance is not available.")
        return send_response(server, client, 500, "Internal server error: ResourceMonitor not initialized.")
    end

    if resource_monitor_instance.clear_cache then
        resource_monitor_instance:clear_cache()
        log_info(COMPONENT_NAME, "ResourceMonitor cache cleared via API request.")
        send_response(server, client, 200, "Cache cleared successfully")
    else
        log_error(COMPONENT_NAME, "ResourceMonitor does not support clear_cache method.")
        return send_response(server, client, 501, "Not Implemented: clear_cache method not available")
    end
end
--- Обработчик HTTP-запроса для установки интервала кэширования ResourceMonitor.
-- Требует аутентификации по API-ключу.
-- Метод: POST
-- Параметры запроса:
--   - interval (number): Новый интервал кэширования в секундах.
-- Возвращает: HTTP 200 OK или ошибку.
local set_monitor_cache_interval = function (server, client, request)
    if not request then return nil end

    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    if not resource_monitor_instance then
        log_error(COMPONENT_NAME, "ResourceMonitor instance is not available.")
        return send_response(server, client, 500, "Internal server error: ResourceMonitor not initialized.")
    end

    local req = validate_request(request)
    local interval_str = get_param(req, "interval")
    
    if not interval_str then
        return send_response(server, client, 400, "Missing 'interval' parameter")
    end
    
    local interval = tonumber(interval_str)
    if not interval or interval < 0 then
        return send_response(server, client, 400, "Invalid interval value. Must be a non-negative number.")
    end

    if resource_monitor_instance.set_cache_interval then
        local success = resource_monitor_instance:set_cache_interval(interval)
        if success then
            log_info(COMPONENT_NAME, "ResourceMonitor cache interval set to %d seconds via API request.", interval)
            send_response(server, client, 200, string.format("Cache interval set to %d seconds", interval))
        else
            log_error(COMPONENT_NAME, "Failed to set cache interval for ResourceMonitor.")
            send_response(server, client, 500, "Failed to set cache interval")
        end
    else
        log_error(COMPONENT_NAME, "ResourceMonitor does not support set_cache_interval method.")
        return send_response(server, client, 501, "Not Implemented: set_cache_interval method not available")
    end
end

return {
    astra_reload = astra_reload,
    kill_astra = kill_astra,
    health = health,
    get_system_resources = get_system_resources,
    get_monitor_stats = get_monitor_stats,
    clear_monitor_cache = clear_monitor_cache,
    set_monitor_cache_interval = set_monitor_cache_interval
}
