-- ===========================================================================
-- Модуль `http.routes.system_routes`
--
-- Определяет HTTP-маршруты и обработчики для управления системными функциями Astra.
-- Предоставляет API-эндпоинты для перезагрузки/остановки Astra, проверки состояния
-- сервера, получения данных о системных ресурсах и управления ResourceMonitor.
-- ===========================================================================

-- 1. Стандартные Lua функции
local type, tostring, tonumber = type, tostring, tonumber
local string_format = string.format
local os_date = os.date
local os_exit = os.exit

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local log_info = Logger.info
local log_error = Logger.error
local log_debug = Logger.debug
local ResourceMonitor = ModuleManager.get_module("resource_monitor")
local http_helpers = ModuleManager.get_module("http_helpers")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local timer_lib = ModuleManager.get_global_dependency("timer")
local json_encode = ModuleManager.get_global_dependency("json.encode")
local astra_reload_func = ModuleManager.get_global_dependency("astra.reload")
local astra_version_var = ModuleManager.get_global_dependency("astra.version")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "SystemRoutes"

-- 5. Инициализация объектов из загруженных модулей
local resource_monitor_instance = ResourceMonitor and ResourceMonitor:new("system_monitor") or nil
local validate_request = http_helpers and http_helpers.validate_request or nil
local check_auth = http_helpers and http_helpers.check_auth or nil
local get_param = http_helpers and http_helpers.get_param or nil
local validate_delay = http_helpers and http_helpers.validate_delay or nil
local send_response = http_helpers and http_helpers.send_response or nil

-- =============================================
-- Управление системой Astra (Обработчики маршрутов)
-- =============================================

--- Обработчик HTTP-запроса для перезагрузки Astra.
--- Требует аутентификации по API-ключу.
--- Метод: POST
--- Параметры запроса (JSON или Query String):
---   - delay (number, optional): Задержка в секундах перед перезагрузкой (по умолчанию 30).
--- @param server table Объект HTTP-сервера.
--- @param client table Объект клиента.
--- @param request table Объект HTTP-запроса.
local astra_reload = function(server, client, request)
    if not request or not check_auth or not send_response or not validate_request or not get_param or not validate_delay then
        return nil
    end

    if not check_auth(request) then
        return send_response(server, client, 401, "Несанкционированный доступ")
    end

    local req = validate_request(request)
    send_response(server, client, 200, "Перезагрузка запланирована")
    timer_lib({
        interval = validate_delay(get_param(req, "delay")), 
        callback = function(t) 
            t:close()
            log_info(COMPONENT_NAME, "[Astra] Перезагружено")
            astra_reload_func()
        end
    })
end

--- Обработчик HTTP-запроса для остановки Astra.
--- Требует аутентификации по API-ключу.
--- Метод: POST
--- Параметры запроса (JSON или Query String):
---   - delay (number, optional): Задержка в секундах перед остановкой (по умолчанию 30).
--- @param server table Объект HTTP-сервера.
--- @param client table Объект клиента.
--- @param request table Объект HTTP-запроса.
local kill_astra = function(server, client, request)
    if not request or not check_auth or not send_response or not validate_request or not get_param or not validate_delay then
        return nil
    end

    if not check_auth(request) then
        return send_response(server, client, 401, "Несанкционированный доступ")
    end

    local req = validate_request(request)
    send_response(server, client, 200, "Завершение работы запланировано")
    timer_lib({
        interval = validate_delay(get_param(req, "delay")), 
        callback = function(t) 
            t:close() 
            log_info(COMPONENT_NAME, "[Astra] Остановлено")
            os_exit_func(0)
        end
    })
end

--- Обработчик HTTP-запроса для проверки состояния сервера.
--- Требует аутентификации по API-ключу.
--- @param server table Объект HTTP-сервера.
--- @param client table Объект клиента.
--- @param request table Объект HTTP-запроса.
local health = function (server, client, request)
    if not request or not check_auth or not send_response then
        return nil
    end

    if not check_auth(request) then
        return send_response(server, client, 401, "Несанкционированный доступ")
    end

    local response_data = {
        addr = server.__options.addr,
        port = server.__options.port,
        version = astra_version_var,
        timestamp = os.date("%Y-%m-%d %H:%M:%S"), -- Встроенная функция Lua
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
        log_error(COMPONENT_NAME, "Не удалось собрать данные процесса для конечной точки health: %s", 
                 tostring(process_data))
        response_data.process = {
            pid = resource_monitor_instance.pid or 0,
            cpu_usage_percent = -1,
            memory_usage_mb = -1,
            error = "Не удалось собрать данные процесса"
        }
    end

    -- Кодируем в JSON
    local json_content = json_encode(response_data)
    if not json_content then
        local error_msg = "Не удалось закодировать данные health в JSON"
        log_error(COMPONENT_NAME, error_msg)
        return send_response(server, client, 500, "Внутренняя ошибка сервера: " .. error_msg)
    end

    local headers = {
        "Content-Type: application/json;charset=utf-8",
        "Content-Length: " .. #json_content,
        "Connection: close",
    }    
    
    send_response(server, client, 200, json_content, headers) 
end

--- Обработчик HTTP-запроса для получения данных о системных ресурсах.
--- Требует аутентификации по API-ключу.
--- Метод: GET
--- @param server table Объект HTTP-сервера.
--- @param client table Объект клиента.
--- @param request table Объект HTTP-запроса.
local get_system_resources = function (server, client, request)
    if not request or not check_auth or not send_response then
        return nil
    end

    if not check_auth(request) then
        return send_response(server, client, 401, "Несанкционированный доступ")
    end

    if not resource_monitor_instance then
        log_error(COMPONENT_NAME, "Экземпляр ResourceMonitor недоступен.")
        return send_response(server, client, 500, "Внутренняя ошибка сервера: ResourceMonitor не инициализирован.")
    end

    local data = resource_monitor_instance:collect_system_data()
    local json_content = json_encode(data)
    if not json_content then
        local error_msg = "Не удалось закодировать данные системных ресурсов в JSON"
        log_error(COMPONENT_NAME, error_msg)
        return send_response(server, client, 500, "Внутренняя ошибка сервера: " .. error_msg)
    end

    local headers = {
        "Content-Type: application/json;charset=utf-8",
        "Content-Length: " .. #json_content,
        "Connection: close",
    }
    
    send_response(server, client, 200, json_content, headers)
end

--- Обработчик HTTP-запроса для получения статистики работы ResourceMonitor.
--- Требует аутентификации по API-ключу.
--- Метод: GET
--- @param server table Объект HTTP-сервера.
--- @param client table Объект клиента.
--- @param request table Объект HTTP-запроса.
local get_monitor_stats = function (server, client, request)
    if not request or not check_auth or not send_response then
        return nil
    end

    if not check_auth(request) then
        return send_response(server, client, 401, "Несанкционированный доступ")
    end

    if not resource_monitor_instance then
        log_error(COMPONENT_NAME, "Экземпляр ResourceMonitor недоступен.")
        return send_response(server, client, 500, "Внутренняя ошибка сервера: ResourceMonitor не инициализирован.")
    end

    if resource_monitor_instance.get_stats then
        local stats = resource_monitor_instance:get_stats()
        local json_content = json_encode(stats)
        if not json_content then
            local error_msg = "Не удалось закодировать статистику монитора в JSON"
            log_error(COMPONENT_NAME, error_msg)
            return send_response(server, client, 500, "Внутренняя ошибка сервера: " .. error_msg)
        end

        local headers = {
            "Content-Type: application/json;charset=utf-8",
            "Content-Length: " .. #json_content,
            "Connection: close",
        }
        
        send_response(server, client, 200, json_content, headers)
    else
        log_error(COMPONENT_NAME, "ResourceMonitor не поддерживает метод get_stats.")
        return send_response(server, client, 501, "Не реализовано: метод get_stats недоступен")
    end
end

--- Обработчик HTTP-запроса для очистки кэша ResourceMonitor.
--- Требует аутентификации по API-ключу.
--- Метод: POST
--- @param server table Объект HTTP-сервера.
--- @param client table Объект клиента.
--- @param request table Объект HTTP-запроса.
local clear_monitor_cache = function (server, client, request)
    if not request or not check_auth or not send_response then
        return nil
    end

    if not check_auth(request) then
        return send_response(server, client, 401, "Несанкционированный доступ")
    end

    if not resource_monitor_instance then
        log_error(COMPONENT_NAME, "Экземпляр ResourceMonitor недоступен.")
        return send_response(server, client, 500, "Внутренняя ошибка сервера: ResourceMonitor не инициализирован.")
    end

    if resource_monitor_instance.clear_cache then
        resource_monitor_instance:clear_cache()
        log_info(COMPONENT_NAME, "Кэш ResourceMonitor очищен через API-запрос.")
        send_response(server, client, 200, "Кэш успешно очищен")
    else
        log_error(COMPONENT_NAME, "ResourceMonitor не поддерживает метод clear_cache.")
        return send_response(server, client, 501, "Не реализовано: метод clear_cache недоступен")
    end
end
--- Обработчик HTTP-запроса для установки интервала кэширования ResourceMonitor.
--- Требует аутентификации по API-ключу.
--- Метод: POST
--- Параметры запроса:
---   - interval (number): Новый интервал кэширования в секундах.
--- @param server table Объект HTTP-сервера.
--- @param client table Объект клиента.
--- @param request table Объект HTTP-запроса.
local set_monitor_cache_interval = function (server, client, request)
    if not request or not check_auth or not send_response or not validate_request or not get_param then
        return nil
    end

    if not check_auth(request) then
        return send_response(server, client, 401, "Несанкционированный доступ")
    end

    if not resource_monitor_instance then
        log_error(COMPONENT_NAME, "Экземпляр ResourceMonitor недоступен.")
        return send_response(server, client, 500, "Внутренняя ошибка сервера: ResourceMonitor не инициализирован.")
    end

    local req = validate_request(request)
    local interval_str = get_param(req, "interval")
    
    if not interval_str then
        return send_response(server, client, 400, "Отсутствует параметр 'interval'")
    end
    
    local interval = tonumber(interval_str)
    if not interval or interval < 0 then
        return send_response(server, client, 400, "Недопустимое значение интервала. Должно быть неотрицательным числом.")
    end

    if resource_monitor_instance.set_cache_interval then
        local success = resource_monitor_instance:set_cache_interval(interval)
        if success then
            log_info(COMPONENT_NAME, "Интервал кэширования ResourceMonitor установлен на %d секунд через API-запрос.", interval)
            send_response(server, client, 200, string.format("Интервал кэширования установлен на %d секунд", interval))
        else
            log_error(COMPONENT_NAME, "Не удалось установить интервал кэширования для ResourceMonitor.")
            send_response(server, client, 500, "Не удалось установить интервал кэширования")
        end
    else
        log_error(COMPONENT_NAME, "ResourceMonitor не поддерживает метод set_cache_interval.")
        return send_response(server, client, 501, "Не реализовано: метод set_cache_interval недоступен")
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
