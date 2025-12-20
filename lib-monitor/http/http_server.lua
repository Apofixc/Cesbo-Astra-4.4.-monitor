local tonumber = tonumber
local string_lower = string.lower
local table_copy = table.copy
local table_concat = table.concat
local table_insert = table.insert
local os_exit = os.exit
local log_info    = log.info
local log_error   = log.error
local timer       = timer
local http_server = http_server
local astra_version = astra.version
local _astra_reload = astra.reload
local json_decode = json.decode
local json_encode = json.encode
local string_split = string_split -- Объявлена в модуле base.lua

local MonitorManager = require "monitor_manager"
local monitor_manager = MonitorManager:new()

-- ===========================================================================
-- Константы и конфигурация
-- ===========================================================================

local API_SECRET = os.getenv("ASTRA_API_KEY") or "test"
local DELAY = 30

-- =============================================
-- Хелперы (Helpers)
-- =============================================

--- Валидирует входящий HTTP-запрос и извлекает параметры.
-- Поддерживает параметры из query string или из JSON-тела запроса.
-- @param table request Объект HTTP-запроса.
-- @return table Таблица с параметрами запроса или пустая таблица, если запрос невалиден.
local function validate_request(request) 
    if not request then
        log_error("[validate_request] request is nil.")
        return {}
    end
    
    if request.query then
        return request.query
    end

    local content_type = request.content and request.headers and request.headers["content-type"] and request.headers["content-type"]:lower() or ""
    if content_type == "application/json" then
        local success, decoder = pcall(json_decode, request.content)
        if success and type(decoder) == "table" then -- Проверяем, что декодированный JSON является таблицей
            return decoder
        else
            log_error("[validate_request] Failed to decode JSON or decoded content is not a table: %s", tostring(decoder))
        end
    end

    log_error("[validate_request] Invalid or empty request content") 
    return {}
end

--- Проверяет наличие и валидность API-ключа в заголовках запроса.
-- @param table request Объект HTTP-запроса.
-- @return boolean true, если аутентификация успешна, иначе `false`.
local function check_auth(request)
    local api_key = request and request.headers and request.headers["x-api-key"]
    if not api_key or api_key ~= API_SECRET then
        log_info(string.format("[Security] Unauthorized request from %s", request.peer)) -- Добавлено логирование IP-адреса
        return false
    end
    return true
end

--- Извлекает параметр из таблицы запроса.
-- @param table req Таблица с параметрами запроса.
-- @param string key Ключ параметра.
-- @return any Значение параметра или `nil`, если параметр отсутствует.
local function get_param(req, key)
    if not req then
        log_error("[get_param] req is nil.")
        return nil
    end
    
    return req[key] -- Возвращаем значение напрямую, nil если отсутствует
end

--- Валидирует значение задержки.
-- @param any value Значение для валидации (может быть строкой или числом).
-- @return number Валидное значение задержки (не менее 1) или значение по умолчанию.
local function validate_delay(value) 
    local i = tonumber(value)
    if i and i >= 1 then
        return i
    else
        log_error("[validate_delay] Invalid delay value: %s, using default %d", tostring(value), DELAY)
        return DELAY
    end
end

--- Отправляет HTTP-ответ клиенту.
-- @param table server Объект HTTP-сервера.
-- @param table client Объект клиента.
-- @param number code HTTP-код ответа.
-- @param string msg (optional) Сообщение для отправки в теле ответа.
-- @param table headers (optional) Таблица с дополнительными HTTP-заголовками.
local function send_response(server, client, code, msg, headers)
    local response_headers = headers or {"Connection: close"}
    if code == 200 then
        server:send(client, {
            code = 200,
            headers = response_headers, 
            content = msg or ""
        })
    else
        local error_message = msg or "Unknown error"
        log_error(string.format("[send_response] %s (code: %d)", error_message, code))
        server:abort(client, code, error_message) -- Передаем сообщение об ошибке в abort
    end
end

-- Основной хелпер для логики kill/reboot
--- Универсальный обработчик для операций остановки/перезагрузки потоков, каналов или мониторов.
-- @param function find_func Функция для поиска объекта (поток, канал, монитор) по имени.
-- @param function kill_func Функция для остановки объекта.
-- @param function make_func Функция для создания/перезапуска объекта.
-- @param string log_prefix Префикс для сообщений в логе.
-- @param table server Объект HTTP-сервера.
-- @param table client Объект клиента.
-- @param table req Таблица с параметрами запроса (должна содержать "channel" и опционально "reboot", "delay").
local function handle_kill_with_reboot(find_func, kill_func, make_func, log_prefix, server, client, req)
    local name = get_param(req, "channel")

    if not name then 
        return send_response(server, client, 400, "Missing channel name in request.") 
    end

    local data, find_err = find_func(name)
    if not data then 
        return send_response(server, client, 404, "Item '" .. name .. "' not found. Error: " .. (find_err or "unknown")) 
    end
    
    local cfg, kill_err = kill_func(data)
    if not cfg then
        return send_response(server, client, 500, "Failed to kill item '" .. name .. "'. Error: " .. (kill_err or "unknown"))
    end
    log_info(string.format("[%s] %s killed", log_prefix, name))

    local reboot = get_param(req, "reboot")
    if type(reboot) == "boolean" and reboot == true or string_lower(tostring(reboot)) == "true" then 
        local delay = validate_delay(get_param(req, "delay"))
        log_info(string.format("[%s] %s scheduled for reboot after %d seconds", log_prefix, name, delay)) 

        timer({
            interval = delay, 
            callback = function(t) 
                t:close()
                local success, make_err = make_func(cfg, name)
                if success then
                    log_info(string.format("[%s] %s was successfully rebooted", log_prefix, name)) 
                else
                    log_error(string.format("[%s] Failed to reboot %s. Error: %s", log_prefix, name, make_err or "unknown"))
                end
            end
        })
    end

    send_response(server, client, 200, "OK")
end

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
local control_kill_stream = function(server, client, request)
    if not request then return nil end
    
    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    handle_kill_with_reboot(find_channel, kill_stream, make_stream, "Stream", server, client, validate_request(request))
end

--- Обработчик HTTP-запроса для остановки или перезагрузки канала.
-- Требует аутентификации по API-ключу.
-- Метод: POST
-- Параметры запроса (JSON или Query String):
--   - channel (string): Имя канала (обязательно).
--   - reboot (boolean, optional): true для перезагрузки канала после остановки.
--   - delay (number, optional): Задержка в секундах перед перезагрузкой (по умолчанию 30).
-- Возвращает: HTTP 200 OK или 400 Bad Request / 401 Unauthorized / 404 Not Found.
local control_kill_channel = function(server, client, request)
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

--- Обработчик HTTP-запроса для остановки или перезагрузки монитора.
-- Требует аутентификации по API-ключу.
-- Метод: POST
-- Параметры запроса (JSON или Query String):
--   - channel (string): Имя монитора (обязательно).
--   - reboot (boolean, optional): true для перезагрузки монитора после остановки.
--   - delay (number, optional): Задержка в секундах перед перезагрузкой (по умолчанию 30).
-- Возвращает: HTTP 200 OK или 400 Bad Request / 401 Unauthorized / 404 Not Found.
local control_kill_monitor = function(server, client, request)
    if not request then return nil end

    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    local req = validate_request(request)
    local name = get_param(req, "channel")

    if not name then 
        return send_response(server, client, 400, "Missing channel") 
    end

    local monitor_obj, get_err = monitor_manager:get_monitor(name)
    if not monitor_obj then 
        return send_response(server, client, 404, "Monitor '" .. name .. "' not found. Error: " .. (get_err or "unknown")) 
    end
    
    local cfg, remove_err = monitor_manager:remove_monitor(name)
    if not cfg then
        return send_response(server, client, 500, "Failed to remove monitor '" .. name .. "'. Error: " .. (remove_err or "unknown"))
    end
    log_info(string.format("[Monitor] %s killed", name))

    local reboot = get_param(req, "reboot")
    if type(reboot) == "boolean" and reboot == true or string_lower(tostring(reboot)) == "true" then 
        local delay = validate_delay(get_param(req, "delay"))
        log_info(string.format("[Monitor] %s scheduled for reboot after %d seconds", name, delay)) 

        timer({
            interval = delay, 
            callback = function(t) 
                t:close()
                -- make_monitor ожидает config и channel_data. cfg здесь - это config остановленного монитора.
                -- name здесь - это имя канала/монитора, которое может быть использовано для поиска channel_data.
                -- Однако, make_monitor в channel.lua ожидает config и channel_data, а не config и name.
                -- Нужно передать правильные аргументы.
                -- Предполагаем, что cfg содержит всю необходимую информацию для make_monitor.
                local success, make_err = make_monitor(cfg, name) -- make_monitor ожидает config и channel_data
                if success then
                    log_info(string.format("[Monitor] %s was successfully rebooted", name)) 
                else
                    log_error(string.format("[Monitor] Failed to reboot %s. Error: %s", name, make_err or "unknown"))
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
local update_monitor_channel = function(server, client, request)
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

    local success, err = monitor_manager:update_monitor_parameters(name, params)
    if success then
        log_info(string.format("[Monitor] %s updated successfully", name))
        send_response(server, client, 200, "OK")
    else
        log_error(string.format("[Monitor] %s update failed: %s", name, err or "unknown error"))
        send_response(server, client, 400, "Update failed: " .. (err or "unknown error"))
    end
end

--- Обработчик HTTP-запроса для создания канала (заглушка).
-- Требует аутентификации по API-ключу.
-- Метод: POST
-- Параметры запроса: (в настоящее время не используются, заглушка)
-- Возвращает: HTTP 200 OK или 401 Unauthorized.
local create_channel = function(server, client, request) -- заглушка
    if not request then return nil end

    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    send_response(server, client, 200)
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
local get_channel_list = function(server, client, request)
    if not request then return nil end

    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    if not channel_list then -- Предполагается, что channel_list глобально доступен
        local error_msg = "[get_channel_list] channel_list is nil."
        log_error(COMPONENT_NAME, error_msg)
        return send_response(server, client, 500, "Internal server error: " .. error_msg)
    end
    
    local content = {}
    for key, channel_data in ipairs(channel_list) do
        local output_string = ""

        if channel_data.config and channel_data.config.output and channel_data.config.output[1] then
            output_string = channel_data.config.output[1]
        end

        content["channel_" .. key] = {
            name = channel_data.config and channel_data.config.name or "unknown",
            addr = string_split(output_string, "#")[1] or "unknown"
        }
    end
    
    local json_content, encode_err = json_encode(content)
    if not json_content then
        local error_msg = "Failed to encode channel list to JSON: " .. (encode_err or "unknown")
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

--- Обработчик HTTP-запроса для получения списка активных мониторов.
-- Требует аутентификации по API-ключу.
--
-- Возвращает JSON-объект со списком мониторов. Структура JSON:
-- {
--   monitor_1 (string): Имя монитора,
--   monitor_2 (string): Имя монитора,
--   ...
-- }
local get_monitor_list = function(server, client, request)
    if not request then return nil end

    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    local content = {}
    local key = 1
    for name, _ in monitor_manager:get_all_monitors() do -- Используем итератор
        content["monitor_" .. key] = name
        key = key + 1
    end
    
    local json_content, encode_err = json_encode(content)
    if not json_content then
        local error_msg = "Failed to encode monitor list to JSON: " .. (encode_err or "unknown")
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
local get_monitor_data = function(server, client, request)
    if not request then return nil end

    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    local req = validate_request(request)

    local name = get_param(req, "channel")
    if not name then 
        return send_response(server, client, 400, "Missing channel")   
    end

    local monitor, get_err = monitor_manager:get_monitor(name)
    
    if not monitor then
        return send_response(server, client, 404, "Monitor '" .. name .. "' not found. Error: " .. (get_err or "unknown"))
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
--   type (string): "psi",
--   server (string): Имя сервера,
--   channel (string): Имя канала,
--   output (string): Адрес мониторинга,
--   stream (string): Имя потока,
--   format (string): Формат потока,
--   addr (string): Адрес потока,
--   psi (string): Тип PSI данных (например, "pmt", "sdt").
--   [...]: Другие поля, специфичные для PSI данных.
-- }
local get_psi_channel = function(server, client, request)
    if not request then return nil end

    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    local req = validate_request(request)

    local name = get_param(req, "channel")
    if not name then 
        return send_response(server, client, 400, "Missing channel")   
    end

    local monitor, get_err = monitor_manager:get_monitor(name)

    if not monitor then
        return send_response(server, client, 404, "Monitor '" .. name .. "' not found. Error: " .. (get_err or "unknown"))
    end

    local psi_cache = monitor.psi_data_cache -- Предполагается, что psi_data_cache доступен напрямую
    if not psi_cache then
        return send_response(server, client, 404, "PSI cache for '" .. name .. "' not found or empty.")
    end

    -- psi_data_cache уже является JSON-строкой, нет необходимости повторно кодировать
    local headers = {
        "Content-Type: application/json;charset=utf-8",
        "Content-Length: " .. #psi_cache,
        "Connection: close",
    }    
    
    send_response(server, client, 200, psi_cache, headers)    
end

--- Обработчик HTTP-запроса для получения списка DVB-адаптеров.
-- Требует аутентификации по API-ключу.
--
-- Возвращает JSON-объект со списком адаптеров. Структура JSON:
-- {
--   adapter_1 (string): Имя адаптера,
--   adapter_2 (string): Имя адаптера,
--   ...
-- }
local get_adapter_list = function(server, client, request)
    if not request then return nil end

    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end

    local content = {}
    local key = 1
    for name, _ in monitor_manager.dvb_manager:get_all_monitors() do
        content["adapter_" .. key] = name
        key = key + 1
    end
    
    local json_content, encode_err = json_encode(content)
    if not json_content then
        local error_msg = "Failed to encode adapter list to JSON: " .. (encode_err or "unknown")
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
    if not request then return nil end

    if not check_auth(request) then
        return send_response(server, client, 401, "Unauthorized")
    end    

    local req = validate_request(request)

    local name = get_param(req, "name_adapter")
    if not name then 
        return send_response(server, client, 400, "Missing adapter")   
    end

    local monitor, get_err = monitor_manager:get_monitor(name)
    
    if not monitor then
        return send_response(server, client, 404, "Monitor '" .. name .. "' not found. Error: " .. (get_err or "unknown"))
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
local update_monitor_dvb = function(server, client, request)
    if not request then return nil end

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

    local success, err = monitor_manager:update_monitor_parameters(name_adapter, params)
    if success then
        log_info(string.format("[Monitor] %s updated successfully", name_adapter))
        send_response(server, client, 200, "OK")
    else
        log_error(string.format("[Monitor] %s update failed: %s", name_adapter, err or "unknown error"))
        send_response(server, client, 400, "Update failed: " .. (err or "unknown error"))
    end
end

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
    timer({
        interval = validate_delay(get_param(req, "delay")), 
        callback = function(t) 
            t:close()
            log_info(COMPONENT_NAME, "[Astra] Reloaded") -- Изменено на log_info с COMPONENT_NAME
            _astra_reload()
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
    timer({
        interval = validate_delay(get_param(req, "delay")), 
        callback = function(t) 
            t:close() 
            log_info(COMPONENT_NAME, "[Astra] Stopped") -- Изменено на log_info с COMPONENT_NAME
            os_exit(0)
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

    local json_content, encode_err = json_encode({addr = server.__options.addr, port = server.__options.port, version = astra_version})
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

--- Запускает HTTP-сервер мониторинга.
-- @param string addr IP-адрес, на котором будет слушать сервер.
-- @param number port Порт, на котором будет слушать сервер.
function server_start(addr, port)
    http_server({
        addr = addr,
        port = port,
        route = {
            {"/api/control_kill_stream", control_kill_stream},
            {"/api/control_kill_channel", control_kill_channel},
            {"/api/control_kill_monitor", control_kill_monitor},
            {"/api/update_monitor_channel", update_monitor_channel},
            {"/api/create_channel", create_channel},
            {"/api/get_channel_list", get_channel_list},
            {"/api/get_monitor_list", get_monitor_list},
            {"/api/get_monitor_data", get_monitor_data},
            {"/api/get_psi_channel", get_psi_channel},
            {"/api/get_adapter_list", get_adapter_list},
            {"/api/get_adapter_data", get_adapter_data},
            {"/api/update_monitor_dvb", update_monitor_dvb},
            {"/api/reload", astra_reload},
            {"/api/exit", kill_astra},
            {"/api/health", health}
        }
    })
    log_info(string.format("[Server] Started on %s:%d", addr, port))
end
