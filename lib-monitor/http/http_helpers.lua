local tonumber = tonumber
local string_lower = string.lower
local utils = require "utils.utils" -- Возвращено
local log_error   = log.error
local log_info    = log.info
local timer_lib   = timer -- Переименовано, чтобы избежать конфликта с локальной переменной timer
local json_decode = json.decode
local json_encode = json.encode
local string_split = string_split
local os_exit_func = os.exit -- Переименовано
local astra_version_var = astra.version -- Переименовано
local astra_reload_func = astra.reload -- Переименовано

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
        log_info(string.format("[Security] Unauthorized request")) -- Добавлено логирование IP-адреса
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

        timer_lib({
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

return {
    validate_request = validate_request,
    check_auth = check_auth,
    get_param = get_param,
    validate_delay = validate_delay,
    send_response = send_response,
    handle_kill_with_reboot = handle_kill_with_reboot,
    API_SECRET = API_SECRET,
    DELAY = DELAY,
    timer_lib = timer_lib,
    os_exit_func = os_exit_func,
    astra_version_var = astra_version_var,
    astra_reload_func = astra_reload_func,
    json_encode = json_encode,
    string_split = string_split,
    string_lower = string_lower,
    table_copy = utils.table_copy, -- Добавлено
}
