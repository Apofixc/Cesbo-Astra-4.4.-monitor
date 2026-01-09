--- @class SubscriberRoutes
local SubscriberRoutes = {}

-- 1. Стандартные Lua функции
-- Нет

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")
local EventDispatcher = ModuleManager.get_module("core.event_dispatcher")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Нет

-- 4. Константы и конфигурации
local COMPONENT_NAME = "SubscriberRoutes"

--- Возвращает список всех получателей данных
function SubscriberRoutes.get_subscribers(server, client, request)
    local dispatcher = EventDispatcher.get_instance()
    local list = dispatcher.subscription_manager:get_all_subscriptions()
    return HttpHelpers.success(server, client, list)
end

--- Добавляет нового получателя
function SubscriberRoutes.subscribe(server, client, request)
    local data = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(data, {
        event_type = { type = "string", required = true },
        callback = { type = "table", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local dispatcher = EventDispatcher.get_instance()
    local sub_id = dispatcher.subscription_manager:subscribe(data.event_type, {
        callback = data.callback,
        filters = data.filters,
        throttle_ms = data.throttle_ms
    })
    
    if not sub_id then return HttpHelpers.error(server, client, 500, "Failed to subscribe") end

    return HttpHelpers.success(server, client, { message = "Subscribed", id = sub_id })
end

--- Удаляет получателя
function SubscriberRoutes.unsubscribe(server, client, request)
    local data = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(data, {
        id = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local dispatcher = EventDispatcher.get_instance()
    local success = dispatcher.subscription_manager:unsubscribe(data.id)
    if not success then return HttpHelpers.error(server, client, 404, "Subscription not found") end

    return HttpHelpers.success(server, client, { message = "Unsubscribed" })
end

return SubscriberRoutes
