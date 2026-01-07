--- @class SubscriberRoutes
local SubscriberRoutes = {}

-- 1. Стандартные Lua функции
-- Нет

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")
local HttpSubscriber = ModuleManager.get_module("http_subscriber")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Нет

-- 4. Константы и конфигурации
local COMPONENT_NAME = "SubscriberRoutes"

--- Возвращает список всех получателей данных
function SubscriberRoutes.get_subscribers(server, client, request)
    local list = HttpSubscriber and HttpSubscriber.get_subscribers and HttpSubscriber.get_subscribers() or {}
    return HttpHelpers.success(server, client, list)
end

--- Добавляет нового получателя
function SubscriberRoutes.subscribe(server, client, request)
    local data = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(data, {
        event_type = { type = "string", required = true },
        host = { type = "string", required = true },
        port = { type = "number", required = true },
        path = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_err = HttpSubscriber.subscribe(data.event_type, { host = data.host, port = data.port, path = data.path })
    if not success then return false, result_err or "Failed to subscribe" end

    return HttpHelpers.success(server, client, { message = "Subscribed" })
end

--- Удаляет получателя
function SubscriberRoutes.unsubscribe(server, client, request)
    local data = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(data, {
        event_type = { type = "string", required = true },
        host = { type = "string", required = true },
        port = { type = "number", required = true },
        path = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_err = HttpSubscriber.unsubscribe(data.event_type, { host = data.host, port = data.port, path = data.path })
    if not success then return false, result_err or "Failed to unsubscribe" end

    return HttpHelpers.success(server, client, { message = "Unsubscribed" })
end

return SubscriberRoutes
