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

--- Возвращает список всех активных подписок в системе.
--- @param server any Экземпляр http_server
--- @param client any Экземпляр клиента
--- @param request table Данные запроса
--- @return boolean Статус выполнения
function SubscriberRoutes.get_subscribers(server, client, request)
    local dispatcher = EventDispatcher.get_instance()
    local list = dispatcher.subscription_manager:get_all_subscriptions()
    return HttpHelpers.success(server, client, list)
end

--- Регистрирует новую подписку на события.
--- Ожидает JSON с полями: event_type, callback, [filters], [throttle_ms].
--- @param server any Экземпляр http_server
--- @param client any Экземпляр клиента
--- @param request table Данные запроса
--- @return boolean Статус выполнения
function SubscriberRoutes.subscribe(server, client, request)
    local data = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(data, {
        event_type = { type = "string", required = true },
        callback = { type = "table", required = true },
        batch_mode = { type = "string", values = { "single", "array" } },
        send_lvc = { type = "boolean" },
        throttle_ms = { type = "number", min = 0 }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local dispatcher = EventDispatcher.get_instance()
    local sub_id = dispatcher:subscribe(data.event_type, data.callback, data.filters, {
        batch_mode = data.batch_mode,
        send_lvc = data.send_lvc,
        throttle_ms = data.throttle_ms
    })

    if not sub_id then return HttpHelpers.error(server, client, 500, "Не удалось подписаться") end

    return HttpHelpers.success(server, client, { message = "Подписка оформлена", id = sub_id })
end

--- Удаляет существующую подписку по её уникальному ID.
--- Ожидает JSON с полем: id.
--- @param server any Экземпляр http_server
--- @param client any Экземпляр клиента
--- @param request table Данные запроса
--- @return boolean Статус выполнения
function SubscriberRoutes.unsubscribe(server, client, request)
    local data = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(data, {
        id = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local dispatcher = EventDispatcher.get_instance()
    local success = dispatcher.subscription_manager:unsubscribe(data.id)
    if not success then return HttpHelpers.error(server, client, 404, "Подписка не найдена") end

    return HttpHelpers.success(server, client, { message = "Подписка удалена" })
end

--- Тестирование подписки (отправка тестового уведомления)
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
--- @return boolean Всегда true
function SubscriberRoutes.test_subscription(server, client, request)
    local data = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(data, {
        id = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local dispatcher = EventDispatcher.get_instance()
    local sub_mgr = dispatcher.subscription_manager

    local test_event = {
        data = { message = "Test notification from Astra Monitor API", timestamp = os.time() },
        json = nil -- Будет закодировано транспортом
    }

    local success = sub_mgr:publish_to_single(data.id, "sys:test_ping", test_event)
    if not success then return HttpHelpers.error(server, client, 404, "Подписка не найдена") end

    return HttpHelpers.success(server, client, { message = "Тестовое уведомление отправлено" })
end

return SubscriberRoutes
