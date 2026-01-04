--- @class HttpHelpers
local HttpHelpers = {}

-- 1. Стандартные Lua функции
local type = type
local os_time = os.time
local os_getenv = os.getenv

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local json_encode = ModuleManager.get_global_dependency("json.encode")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "HttpHelpers"
local DEFAULT_API_KEY = "test"

--- Отправляет JSON ответ клиенту
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param code number HTTP статус код
--- @param data table Данные для отправки
function HttpHelpers.send_json(server, client, code, data)
    data = data or {}
    data.timestamp = os_time()
    
    local ok, content = pcall(json_encode, data)
    if not ok then
        Logger.error(COMPONENT_NAME, "Failed to encode JSON response: %s", tostring(content))
        server:abort(client, 500)
        return
    end

    server:send(client, {
        code = code,
        headers = {
            "Content-Type: application/json; charset=utf-8",
            "Connection: close",
            "Content-Length: " .. #content,
        },
        content = content,
    })
end

--- Проверяет API ключ в заголовках запроса
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
--- @return boolean true если ключ валиден
function HttpHelpers.check_auth(server, client, request)
    local expected_key = os_getenv("ASTRA_API_KEY") or DEFAULT_API_KEY
    -- В Astra заголовки могут быть как в нижнем регистре, так и в оригинальном
    local provided_key = request.headers and (request.headers["x-api-key"] or request.headers["X-Api-Key"])

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
    local response = { status = "ok" }
    if data then
        for k, v in pairs(data) do
            response[k] = v
        end
    end
    HttpHelpers.send_json(server, client, 200, response)
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

    server:send(client, {
        code = code,
        headers = {
            "Content-Type: application/json; charset=utf-8",
            "Connection: close",
            "Content-Length: " .. #content,
        },
        content = content,
    })
end

return HttpHelpers
