--- @class HttpHelpers
local HttpHelpers = {}

-- 1. Стандартные Lua функции
local type = type
local pairs = pairs
local os_getenv = os.getenv
local pcall = pcall
local tostring = tostring
local string_find = string.find
local string_match = string.match

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local MonitorConfig = ModuleManager.get_module("monitor_config")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local json_encode = ModuleManager.get_global_dependency("json.encode")
local json_decode = ModuleManager.get_global_dependency("json.decode")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "HttpHelpers"
local DEFAULT_API_KEY = "test"

-- Кэшированные заголовки для минимизации аллокаций
local JSON_HEADERS = {
    "Content-Type: application/json; charset=utf-8",
    "Connection: close",
}

--- Отправляет JSON ответ клиенту
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param code number HTTP статус код
--- @param data table Данные для отправки
function HttpHelpers.send_json(server, client, code, data)
    local ok, content = pcall(json_encode, data or {})
    if not ok then
        Logger.error(COMPONENT_NAME, "Failed to encode JSON response: %s", tostring(content))
        server:abort(client, 500)
        return
    end

    -- Добавляем Content-Length динамически, но используем кэшированные базовые заголовки
    local response_headers = {
        JSON_HEADERS[1],
        JSON_HEADERS[2],
        "Content-Length: " .. #content,
    }

    server:send(client, {
        code = code,
        headers = response_headers,
        content = content,
    })
end

--- Проверяет API ключ в заголовках запроса
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
--- @return boolean true если ключ валиден
function HttpHelpers.check_auth(server, client, request)
    if not request then return false end
    
    local expected_key = os_getenv("ASTRA_API_KEY") or DEFAULT_API_KEY
    local headers = request.headers
    local provided_key = headers and (headers["x-api-key"] or headers["X-Api-Key"])

    if provided_key ~= expected_key then
        HttpHelpers.send_json(server, client, 401, {
            status = "error",
            message = "Unauthorized: Invalid or missing X-Api-Key"
        })
        return false
    end
    return true
end

--- Формирует успешный JSON ответ
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param data table|nil Данные
function HttpHelpers.success(server, client, data)
    HttpHelpers.send_json(server, client, 200, data)
end

--- Формирует JSON ответ с ошибкой
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param code number HTTP статус код
--- @param message string Сообщение об ошибке
function HttpHelpers.error(server, client, code, message)
    HttpHelpers.send_json(server, client, code, {
        status = "error",
        message = message
    })
end

--- Отправляет сырой JSON контент (из кэша)
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param code number HTTP статус код
--- @param content string JSON строка
function HttpHelpers.send_raw_json(server, client, code, content)
    if not content then
        return HttpHelpers.error(server, client, 404, "Data not available in cache")
    end

    local response_headers = {
        JSON_HEADERS[1],
        JSON_HEADERS[2],
        "Content-Length: " .. #content,
    }

    server:send(client, {
        code = code,
        headers = response_headers,
        content = content,
    })
end

--- Извлекает JSON данные из тела запроса
--- @param request table Объект запроса
--- @return table|nil Декодированные данные или nil
function HttpHelpers.get_json_body(request)
    if not request or not request.content or request.content == "" then return nil end
    
    local headers = request.headers
    local ct = headers and (headers["content-type"] or headers["Content-Type"])
    if ct and not string_find(ct, "application/json") then return nil end

    local ok, data = pcall(json_decode, request.content)
    if ok then return data end
    return nil
end

--- Унифицированное получение параметров из Query String или JSON Body
--- @param request table Объект запроса
--- @return table Таблица параметров
function HttpHelpers.get_params(request)
    if not request then return {} end
    local params = {}
    
    -- 1. Берем параметры из Query String
    if request.query then
        for k, v in pairs(request.query) do
            params[k] = v
        end
    end
    
    -- 2. Дополняем параметрами из JSON Body (они имеют приоритет)
    local body = HttpHelpers.get_json_body(request)
    if body and type(body) == "table" then
        for k, v in pairs(body) do
            params[k] = v
        end
    end
    
    return params
end

--- Валидация входных параметров
--- @param params table Таблица параметров для проверки
--- @param schema table Схема валидации
--- @return boolean success, string|nil error_message
function HttpHelpers.validate(params, schema)
    if not params then return false, "No parameters provided" end
    if not schema then return true end

    for key, rules in pairs(schema) do
        local val = params[key]

        -- Проверка обязательности
        if rules.required and val == nil then
            return false, string.format("Parameter '%s' is required", key)
        end

        if val ~= nil then
            -- Проверка типа
            if rules.type and type(val) ~= rules.type then
                -- Попытка приведения типов для чисел из Query String
                if rules.type == "number" and type(val) == "string" then
                    val = tonumber(val)
                    if not val then
                        return false, string.format("Parameter '%s' must be a number", key)
                    end
                    params[key] = val -- Сохраняем приведенное значение
                else
                    return false, string.format("Parameter '%s' must be a %s", key, rules.type)
                end
            end

            -- Проверка диапазона для чисел
            if rules.type == "number" then
                if rules.min and val < rules.min then
                    return false, string.format("Parameter '%s' is too small (min: %s)", key, tostring(rules.min))
                end
                if rules.max and val > rules.max then
                    return false, string.format("Parameter '%s' is too large (max: %s)", key, tostring(rules.max))
                end
            end

            -- Проверка паттерна для строк
            if rules.type == "string" and rules.pattern then
                if not string_match(val, rules.pattern) then
                    return false, string.format("Parameter '%s' has invalid format", key)
                end
            end

            -- Проверка допустимых значений
            if rules.values then
                local found = false
                for _, allowed in pairs(rules.values) do
                    if val == allowed then
                        found = true
                        break
                    end
                end
                if not found then
                    return false, string.format("Parameter '%s' has invalid value", key)
                end
            end
        end
    end

    return true
end

return HttpHelpers
