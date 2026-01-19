--- @class HttpHelpers
local HttpHelpers = {}

-- 1. Стандартные Lua функции
local type = type
local pairs = pairs
local os_getenv = os.getenv
local os_time = os.time
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

-- Данные для Rate Limiting: [ip] = { count = N, reset_at = T }
local _rate_limit_data = {}

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
--- @return boolean Всегда true (сигнал завершения обработки)
function HttpHelpers.send_json(server, client, code, data)
    local ok, content = pcall(json_encode, data or {})
    if not ok then
        Logger.error(COMPONENT_NAME, "Не удалось закодировать JSON ответ: %s", tostring(content))
        server:abort(client, 500)
        return true
    end

    local allow_origin = (MonitorConfig and MonitorConfig.CorsAllowOrigin) or "*"
    local response_headers = {
        JSON_HEADERS[1],
        JSON_HEADERS[2],
        "Content-Length: " .. #content,
        "Access-Control-Allow-Origin: " .. allow_origin,
        "Access-Control-Allow-Methods: GET, POST, PATCH, DELETE, OPTIONS",
        "Access-Control-Allow-Headers: X-Api-Key, Content-Type",
    }

    server:send(client, {
        code = code,
        headers = response_headers,
        content = content,
    })
    return true
end

--- Проверяет лимиты запросов для IP адреса
--- @param request table Объект запроса
--- @return boolean true если лимит не превышен
function HttpHelpers.check_rate_limit(request)
    if not request or not request.addr then return true end

    local ip = request.addr
    local now = os_time()
    local window = (MonitorConfig and MonitorConfig.RateLimitWindow) or 60
    local max_req = (MonitorConfig and MonitorConfig.RateLimitMaxRequests) or 100

    local data = _rate_limit_data[ip]
    if not data or now >= data.reset_at then
        _rate_limit_data[ip] = { count = 1, reset_at = now + window }
        return true
    end

    data.count = data.count + 1
    if data.count > max_req then
        Logger.warning(COMPONENT_NAME, "Превышен лимит запросов для %s (%d/%d)", ip, data.count, max_req)
        return false
    end

    return true
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
        HttpHelpers.error(server, client, 401, "Доступ запрещен: неверный или отсутствует X-Api-Key")
        return false
    end
    return true
end

--- Формирует успешный JSON ответ
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param data table|nil Данные
--- @return boolean Всегда true
function HttpHelpers.success(server, client, data)
    return HttpHelpers.send_json(server, client, 200, data)
end

--- Формирует JSON ответ с ошибкой
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param code number HTTP статус код
--- @param message string Сообщение об ошибке
--- @return boolean Всегда true
function HttpHelpers.error(server, client, code, message)
    return HttpHelpers.send_json(server, client, code, {
        status = "error",
        message = message
    })
end

--- Отправляет сырой JSON контент (из кэша)
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param code number HTTP статус код
--- @param content string JSON строка
--- @return boolean Всегда true
function HttpHelpers.send_raw_json(server, client, code, content)
    if not content then
        return HttpHelpers.error(server, client, 404, "Данные недоступны в кэше")
    end

    local allow_origin = (MonitorConfig and MonitorConfig.CorsAllowOrigin) or "*"
    local response_headers = {
        JSON_HEADERS[1],
        JSON_HEADERS[2],
        "Content-Length: " .. #content,
        "Access-Control-Allow-Origin: " .. allow_origin,
        "Access-Control-Allow-Methods: GET, POST, PATCH, DELETE, OPTIONS",
        "Access-Control-Allow-Headers: X-Api-Key, Content-Type",
    }

    server:send(client, {
        code = code,
        headers = response_headers,
        content = content,
    })
    return true
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

    if request.query then
        for k, v in pairs(request.query) do
            params[k] = v
        end
    end

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
    if not params then return false, "Параметры не предоставлены" end
    if not schema then return true end

    for key, rules in pairs(schema) do
        local val = params[key]

        if rules.required and val == nil then
            return false, string.format("Параметр '%s' обязателен", key)
        end

        if val ~= nil then
            if rules.type and type(val) ~= rules.type then
                if rules.type == "number" and (type(val) == "string" or type(val) == "boolean") then
                    val = tonumber(val)
                    if val == nil then
                        return false, string.format("Параметр '%s' должен быть числом", key)
                    end
                    params[key] = val
                elseif rules.type == "boolean" and type(val) == "string" then
                    if val == "true" then val = true
                    elseif val == "false" then val = false
                    else
                        return false, string.format("Параметр '%s' должен быть логическим значением (boolean)", key)
                    end
                    params[key] = val
                else
                    return false, string.format("Параметр '%s' должен иметь тип %s", key, rules.type)
                end
            end

            if rules.type == "number" then
                if rules.min and val < rules.min then
                    return false, string.format("Параметр '%s' слишком мал (минимум: %s)", key, tostring(rules.min))
                end
                if rules.max and val > rules.max then
                    return false, string.format("Параметр '%s' слишком велик (максимум: %s)", key, tostring(rules.max))
                end
            end

            if rules.type == "string" and rules.pattern then
                if not string_match(val, rules.pattern) then
                    return false, string.format("Параметр '%s' имеет неверный формат", key)
                end
            end

            if rules.values then
                local found = false
                for _, allowed in pairs(rules.values) do
                    if val == allowed then
                        found = true
                        break
                    end
                end
                if not found then
                    return false, string.format("Параметр '%s' имеет недопустимое значение", key)
                end
            end
        end
    end

    return true
end

return HttpHelpers
