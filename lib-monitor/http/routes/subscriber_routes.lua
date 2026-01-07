--- @class SubscriberRoutes
local SubscriberRoutes = {}

-- 1. Стандартные Lua функции
local type = type
local pcall = pcall

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")
local HttpSubscriber = ModuleManager.get_module("http_subscriber")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local json_decode = ModuleManager.get_global_dependency("json.decode")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "SubscriberRoutes"

--- Возвращает список всех получателей данных
--- @param server table
--- @param client table
--- @param request table
function SubscriberRoutes.get_subscribers(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local list = {}
    if HttpSubscriber and HttpSubscriber.get_subscribers then
        list = HttpSubscriber.get_subscribers()
    end

    HttpHelpers.success(server, client, list)
end

--- Добавляет нового получателя
--- @param server table
--- @param client table
--- @param request table
function SubscriberRoutes.subscribe(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local data = request.query
    if request.content_type == "application/json" and request.content then
        local ok, decoded = pcall(json_decode, request.content)
        if ok then data = decoded end
    end

    if not data or not data.event_type or not data.host or not data.port or not data.path then
        return HttpHelpers.error(server, client, 400, "event_type, host, port, and path are required")
    end

    local addr = {
        host = data.host,
        port = data.port,
        path = data.path
    }

    local success, err = Logger.with_error(HttpSubscriber.subscribe, data.event_type, addr)
    if success then
        HttpHelpers.success(server, client, { message = "Subscribed successfully" })
    else
        HttpHelpers.error(server, client, 500, err or "Failed to subscribe")
    end
end

--- Удаляет получателя
--- @param server table
--- @param client table
--- @param request table
function SubscriberRoutes.unsubscribe(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local data = request.query
    if request.content_type == "application/json" and request.content then
        local ok, decoded = pcall(json_decode, request.content)
        if ok then data = decoded end
    end

    if not data or not data.event_type or not data.host or not data.port or not data.path then
        return HttpHelpers.error(server, client, 400, "event_type, host, port, and path are required")
    end

    local addr = {
        host = data.host,
        port = data.port,
        path = data.path
    }

    local success, err = Logger.with_error(HttpSubscriber.unsubscribe, data.event_type, addr)
    if success then
        HttpHelpers.success(server, client, { message = "Unsubscribed successfully" })
    else
        HttpHelpers.error(server, client, 500, err or "Failed to unsubscribe")
    end
end

return SubscriberRoutes
