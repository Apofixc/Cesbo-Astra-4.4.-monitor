-- ===========================================================================
-- Модуль `http.http_helpers`
--
-- Предоставляет набор вспомогательных функций для обработки HTTP-запросов
-- и ответов в системе мониторинга. Включает валидацию запросов,
-- аутентификацию по API-ключу, извлечение параметров и управление
-- операциями остановки/перезагрузки.
-- ===========================================================================

-- 1. Стандартные Lua функции
local type, tostring, tonumber = type, tostring, tonumber
local string_lower = string.lower

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local log_info = Logger.info
local log_error = Logger.error
local log_debug = Logger.debug
local utils = ModuleManager.get_module("utils")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local timer_lib = ModuleManager.get_global_dependency("timer")
local json_decode = ModuleManager.get_global_dependency("json.decode")
local json_encode = ModuleManager.get_global_dependency("json.encode")
local string_split = ModuleManager.get_global_dependency("string.split")
local os_exit_func = os.exit -- Встроенная функция Lua
local astra_version_var = ModuleManager.get_global_dependency("astra.version")
local astra_reload_func = ModuleManager.get_global_dependency("astra.reload")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "HTTPHelpers"
local API_SECRET = os.getenv("ASTRA_API_KEY") or "test"
local DELAY = 1

if not API_SECRET then
    log_error(COMPONENT_NAME, "ASTRA_API_KEY не установлен. Аутентификация API завершится неудачей.")
end

-- 5. Инициализация объектов из загруженных модулей
-- Нет объектов для инициализации в этом модуле

-- =============================================
-- Вспомогательные функции
-- =============================================

local function sanitize_input(str)
    if not str or type(str) ~= "string" then return nil end
    -- Удаление опасных символов
    return str:gsub("[<>%[%]{}()$&|;`]", "")
end

--- Валидирует входящий HTTP-запрос и извлекает параметры.
--- Поддерживает параметры из query string или из JSON-тела запроса.
--- @param request table Объект HTTP-запроса.
--- @return table result Таблица с параметрами запроса или пустая таблица, если запрос невалиден.
local function validate_request(request) 
    if not request then
        log_error(COMPONENT_NAME, "Запрос равен nil.")
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
            log_error(COMPONENT_NAME, "Не удалось декодировать JSON или декодированное содержимое не является таблицей: %s.", tostring(decoder))
        end
    end

    log_error(COMPONENT_NAME, "Недопустимое или пустое содержимое запроса.") 
    return {}
end

--- Проверяет наличие и валидность API-ключа в заголовках запроса.
--- @param request table Объект HTTP-запроса.
--- @return boolean success true, если аутентификация успешна, иначе `false`.
local function check_auth(request)
    local api_key = request and request.headers and request.headers["x-api-key"]
    if not API_SECRET then
        log_error(COMPONENT_NAME, "[Безопасность] API_SECRET не настроен. Аутентификация API завершится неудачей.")
        return false
    end
    if not api_key or api_key ~= API_SECRET then
        log_info(COMPONENT_NAME, "Несанкционированный запрос.")
        return false
    end
    return true
end

--- Извлекает параметр из таблицы запроса.
--- @param req table Таблица с параметрами запроса.
--- @param key string Ключ параметра.
--- @return any|nil result Значение параметра или `nil`, если параметр отсутствует.
local function get_param(req, key)
    if not req then
        log_error(COMPONENT_NAME, "req равен nil.")
        return nil
    end
    
    local value = req[key]
    if type(value) == "string" then
        return sanitize_input(value)
    end
    return value
end

--- Валидирует значение задержки.
--- @param value any Значение для валидации (может быть строкой или числом).
--- @return number result Валидное значение задержки (не менее 1) или значение по умолчанию.
local function validate_delay(value) 
    local i = tonumber(value)
    if i and i >= 1 then
        return i
    else
        log_error(COMPONENT_NAME, "Недопустимое значение задержки: %s, используется значение по умолчанию %d.", tostring(value), DELAY)
        return DELAY
    end
end

--- Отправляет HTTP-ответ клиенту.
--- @param server table Объект HTTP-сервера.
--- @param client table Объект клиента.
--- @param code number HTTP-код ответа.
--- @param msg string|nil [msg] Сообщение для отправки в теле ответа.
--- @param headers table|nil [headers] Таблица с дополнительными HTTP-заголовками.
local function send_response(server, client, code, msg, headers)
    local response_headers = headers or {"Connection: close"}
    if code == 200 then
        server:send(client, {
            code = 200,
            headers = response_headers, 
            content = msg or ""
        })
    else
        local error_message = msg or "Неизвестная ошибка."
        log_error(COMPONENT_NAME, "Ошибка HTTP-ответа: %s (код: %d).", error_message, code)
        server:abort(client, code, error_message) -- Передаем сообщение об ошибке в abort
    end
end

-- Основной хелпер для логики kill/reboot
--- Универсальный обработчик для операций остановки/перезагрузки потоков, каналов или мониторов.
--- @param find_func function Функция для поиска объекта (поток, канал, монитор) по имени.
--- @param kill_func function Функция для остановки объекта.
--- @param make_func function Функция для создания/перезапуска объекта.
--- @param log_prefix string Префикс для сообщений в логе.
--- @param server table Объект HTTP-сервера.
--- @param client table Объект клиента.
--- @param req table Таблица с параметрами запроса (должна содержать "channel" и опционально "reboot", "delay").
local function handle_kill_with_reboot(find_func, kill_func, make_func, log_prefix, server, client, req)
    local name = get_param(req, "channel")

    if not name then 
        return send_response(server, client, 400, "Отсутствует имя канала в запросе.") 
    end

    local data, find_err = find_func(name)
    if not data then 
        return send_response(server, client, 404, "Элемент '%s' не найден. Ошибка: %s.", name, (find_err or "неизвестная ошибка")) 
    end
    
    local cfg, kill_err = kill_func(data)
    if not cfg then
        return send_response(server, client, 500, "Не удалось остановить элемент '%s'. Ошибка: %s.", name, (kill_err or "неизвестная ошибка"))
    end
    log_info(COMPONENT_NAME, "%s '%s' остановлен.", log_prefix, name)

    local reboot = get_param(req, "reboot")
    if type(reboot) == "boolean" and reboot == true or string_lower(tostring(reboot)) == "true" then 
        local delay = validate_delay(get_param(req, "delay"))
        log_info(COMPONENT_NAME, "%s '%s' запланирован на перезагрузку через %d секунд.", log_prefix, name, delay) 

        timer_lib({
            interval = delay, 
            callback = function(t) 
                t:close()
                local make_result, make_err = make_func(cfg, name)
                if not make_result then
                    log_error(COMPONENT_NAME, "Не удалось перезагрузить %s '%s'. Ошибка: %s.", log_prefix, name, make_err or "неизвестная ошибка")
                else
                    log_info(COMPONENT_NAME, "%s '%s' был успешно перезагружен.", log_prefix, name) 
                end
            end
        })
    end

    send_response(server, client, 200, "ОК")
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
    string_lower = string_lower,
    shallow_table_copy = utils.shallow_table_copy, -- Поверхностное копирование таблицы
    sanitize_input = sanitize_input,
}
