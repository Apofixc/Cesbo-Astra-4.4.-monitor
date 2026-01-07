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
-- Нет глобальных зависимостей

-- 4. Константы и конфигурации
local COMPONENT_NAME = "SubscriberRoutes"

--- Возвращает список всех получателей данных
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function SubscriberRoutes.get_subscribers(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local list = {}
    if HttpSubscriber and HttpSubscriber.get_subscribers then
        list = HttpSubscriber.get_subscribers()
    end

    HttpHelpers.success(server, client, list)
    return true
end

--- Добавляет нового получателя
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function SubscriberRoutes.subscribe(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local data = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(data, {
        event_type = { type = "string", required = true },
        host = { type = "string", required = true },
        port = { type = "number", required = true },
        path = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local addr = {
        host = data.host,
        port = data.port,
        path = data.path
    }

    local success, result_err = HttpSubscriber.subscribe(data.event_type, addr)
    if success then
        HttpHelpers.success(server, client, { message = "Subscribed successfully" })
        return true
    else
        return false, result_err or "Failed to subscribe"
    end
end

--- Удаляет получателя
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function SubscriberRoutes.unsubscribe(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local data = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(data, {
        event_type = { type = "string", required = true },
        host = { type = "string", required = true },
        port = { type = "number", required = true },
        path = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local addr = {
        host = data.host,
        port = data.port,
        path = data.path
    }

    local success, result_err = HttpSubscriber.unsubscribe(data.event_type, addr)
    if success then
        HttpHelpers.success(server, client, { message = "Unsubscribed successfully" })
        return true
    else
        return false, result_err or "Failed to unsubscribe"
    end
end

return SubscriberRoutes
