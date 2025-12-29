-- ===========================================================================
-- Модуль `http.routes.channel_routes`
--
-- Определяет HTTP-маршруты и обработчики для управления каналами и их мониторами.
-- Предоставляет API-эндпоинты для остановки/перезагрузки потоков, каналов и мониторов,
-- обновления параметров мониторов, а также получения списков и данных мониторинга.
-- ===========================================================================

-- 1. Стандартные Lua функции
local type, tostring, tonumber = type, tostring, tonumber
local string_lower = string.lower

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("utils.logger")
local log_info = Logger.info
local log_error = Logger.error
local ChannelMonitorManager = ModuleManager.get_module("dispatchers.channel_monitor_dispatcher")
local ChannelModule = ModuleManager.get_module("channel.channel")
local http_helpers = ModuleManager.get_module("http.http_helpers")
local Utils = ModuleManager.get_module("utils.utils")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local timer_lib = ModuleManager.get_global_dependency("timer")
local json_encode = ModuleManager.get_global_dependency("json.encode")
local json_decode = ModuleManager.get_global_dependency("json.decode")
local make_channel = ModuleManager.get_global_dependency("make_channel")
local find_channel = ModuleManager.get_global_dependency("find_channel")
local kill_channel = ModuleManager.get_global_dependency("kill_channel")
local string_split = ModuleManager.get_global_dependency("string.split")
local channel_list = ModuleManager.get_global_dependency("channel_list")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ChannelRoutes"

-- 5. Инициализация объектов из загруженных модулей
local channel_monitor_manager = ChannelMonitorManager:new()
local validate_request = http_helpers.validate_request
local check_auth = http_helpers.check_auth
local get_param = http_helpers.get_param
local validate_delay = http_helpers.validate_delay
local send_response = http_helpers.send_response
local handle_kill_with_reboot = http_helpers.handle_kill_with_reboot
local shallow_table_copy = Utils.shallow_table_copy

--- Обработчик HTTP-запроса для остановки или перезагрузки потока.
-- Требует аутентификации по API-ключу.
-- Метод: POST
-- Параметры запроса (JSON или Query String):
--   - channel (string): Имя потока (обязательно).
--   - reboot (boolean, optional): true для перезагрузки потока после остановки.
--   - delay (number, optional): Задержка в секундах перед перезагрузкой (по умолчанию 30).
-- Возвращает: HTTP 200 OK или 400 Bad Request / 401 Unauthorized / 404 Not Found.
local kill_stream = function(server, client, request)
    if not request then 
        log_error(COMPONENT_NAME, "Запрос равен nil.")
        return nil 
    end
    
    if not check_auth(request) then
        return send_response(server, client, 401, "Несанкционированный доступ.")
    end

    handle_kill_with_reboot(
        function(name)
            local channel_data = find_channel(name)
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
    if not request then 
        log_error(COMPONENT_NAME, "Запрос равен nil.")
        return nil 
    end
    
    if not check_auth(request) then
        return send_response(server, client, 401, "Несанкционированный доступ.")
    end

    handle_kill_with_reboot(
        function(name)
            local channel_data = find_channel(name)
            if not channel_data then
                return nil, "Канал '" .. name .. "' не найден."
            end
            return channel_data, nil
        end, 
        function(channel_data)
            local cfg = shallow_table_copy(channel_data.config) 
            kill_channel(channel_data) -- kill_channel ничего не возвращает, предполагаем успех
            log_info(COMPONENT_NAME, "Канал '%s' остановлен через kill_channel.", channel_data.config.name)
            return cfg, nil
        end, 
        function(cfg, name)
            local new_channel = make_channel(cfg)
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
    if not request then 
        log_error(COMPONENT_NAME, "Запрос равен nil.")
        return nil 
    end

    if not check_auth(request) then
        return send_response(server, client, 401, "Несанкционированный доступ.")
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
    if not request then 
        log_error(COMPONENT_NAME, "Запрос равен nil.")
        return nil 
    end
    
    if not check_auth(request) then
        return send_response(server, client, 401, "Несанкционированный доступ.")
    end

    local req = validate_request(request)

    local name = get_param(req, "channel")
    if not name then 
        return send_response(server, client, 400, "Отсутствует канал.")   
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
        log_info(COMPONENT_NAME, "Монитор '%s' успешно обновлен.", name)
        send_response(server, client, 200, "ОК")
    else
        log_error(COMPONENT_NAME, "Обновление монитора '%s' не удалось: %s.", name, err or "неизвестная ошибка")
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
    if not request then 
        log_error(COMPONENT_NAME, "Запрос равен nil.")
        return nil 
    end
    
    if not check_auth(request) then
        return send_response(server, client, 401, "Несанкционированный доступ.")
    end

    if not channel_list then
        log_error(COMPONENT_NAME, "channel_list равен nil.")
        return send_response(server, client, 500, "Внутренняя ошибка сервера: Список каналов недоступен.")
    end

    local content = {}
    for _, channel_data in ipairs(channel_list) do
        table.insert(content, channel_data.config.name)
    end
    
    local json_content = json_encode(content)
    if not json_content then
        log_error(COMPONENT_NAME, "Не удалось закодировать список каналов в JSON.")
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
    if not request then 
        log_error(COMPONENT_NAME, "Запрос равен nil.")
        return nil 
    end
    
    if not check_auth(request) then
        return send_response(server, client, 401, "Несанкционированный доступ.")
    end

    local content = {}
    for name, _ in pairs(channel_monitor_manager:get_all_monitors()) do
        table.insert(content, name)
    end
    
    local json_content = json_encode(content)
    if not json_content then
        log_error(COMPONENT_NAME, "Не удалось закодировать список мониторов в JSON.")
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
    if not request then 
        log_error(COMPONENT_NAME, "Запрос равен nil.")
        return nil 
    end
    
    if not check_auth(request) then
        return send_response(server, client, 401, "Несанкционированный доступ.")
    end

    local req = validate_request(request)

    local name = get_param(req, "channel")
    if not name then 
        return send_response(server, client, 400, "Отсутствует канал.")   
    end

    local monitor, get_err = channel_monitor_manager:get_monitor(name)
    
    if not monitor then
        return send_response(server, client, 404, "Монитор канала '%s' не найден. Ошибка: %s.", name, (get_err or "неизвестно"))
    end

    local json_cache = monitor:get_json_cache()
    if not json_cache then
        return send_response(server, client, 404, "Кэш монитора для '%s' не найден или пуст.", name)
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
    if not request then 
        log_error(COMPONENT_NAME, "Запрос равен nil.")
        return nil 
    end
    
    if not check_auth(request) then
        return send_response(server, client, 401, "Несанкционированный доступ.")
    end

    local req = validate_request(request)

    local name = get_param(req, "channel")
    if not name then 
        return send_response(server, client, 400, "Отсутствует канал.")   
    end

    local monitor, get_err = channel_monitor_manager:get_monitor(name)

    if not monitor then
        return send_response(server, client, 404, "Монитор канала '%s' не найден. Ошибка: %s.", name, (get_err or "неизвестно"))
    end

    local psi_cache_table = monitor:get_psi_data_cache()
    if not psi_cache_table or next(psi_cache_table) == nil then -- Проверяем, что таблица не пуста
        return send_response(server, client, 404, "Кэш PSI для '%s' не найден или пуст.", name)
    end

    local json_content = json_encode(psi_cache_table)
    if not json_content then
        log_error(COMPONENT_NAME, "Не удалось закодировать данные PSI в JSON.")
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
