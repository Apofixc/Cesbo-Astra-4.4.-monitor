-- ===========================================================================
-- Модуль `core.subscription_manager`
--
-- Динамическое управление подписками на события мониторинга.
-- Поддерживает HTTP, WebSocket, Console и Lua callback транспорты.
-- Реализует оптимизацию Fast Path для подписок без фильтров.
-- ===========================================================================

-- 1. Стандартные Lua функции
local type = type
local tostring = tostring
local string_format = string.format
local ipairs = ipairs
local pairs = pairs
local table_insert = table.insert
local table_remove = table.remove
local os_time = os.time
local pcall = pcall
local setmetatable = setmetatable

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local FilterEngine = ModuleManager.get_module("utils.filter_engine")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local http_request = ModuleManager.get_global_dependency("http_request")
local astra_version = ModuleManager.get_global_dependency("astra.version")
local json_encode = ModuleManager.get_global_dependency("json.encode")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "SubscriptionManager"
local USER_AGENT = "User-Agent: Astra v." .. (astra_version or "unknown")
local CONTENT_TYPE = "Content-Type: application/json;charset=utf-8"

--- @class SubscriptionManager
local SubscriptionManager = {}
SubscriptionManager.__index = SubscriptionManager

-- Генерация UUID (упрощенная версия)
local function generate_uuid()
    local template ='xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function (c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end)
end

--- Транспорты для доставки событий
local Transport = {
    -- HTTP транспорт
    HTTP = function(config, event_data)
        if not http_request then return false, "http_request not available" end
        
        local content
        if type(event_data) == "table" then
            local ok, res = pcall(json_encode, event_data)
            if ok then content = res else return false, "JSON encode failed" end
        else
            content = tostring(event_data)
        end
        
        local headers = {
            USER_AGENT,
            "Host: " .. config.host .. ":" .. config.port,
            CONTENT_TYPE,
            "Content-Length: " .. #content,
            "Connection: close",
        }
        
        if config.headers then
            for _, header in ipairs(config.headers) do table_insert(headers, header) end
        end
        
        http_request({
            host = config.host,
            port = config.port,
            path = config.path or "/",
            method = "POST",
            content = content,
            headers = headers,
            callback = function(s, r)
                -- Логирование результата при необходимости
            end
        })
        return true
    end,
    
    -- WebSocket транспорт
    WS = function(config, event_data, event_type)
        local WsSubscriber = ModuleManager.get_module("ws_subscriber")
        if WsSubscriber and WsSubscriber.broadcast_raw then
            local json_data = event_data
            if type(event_data) == "table" then
                local ok, res = pcall(json_encode, event_data)
                if ok then json_data = res end
            end
            WsSubscriber.broadcast_raw(event_type, json_data)
            return true
        end
        return false, "WsSubscriber not available"
    end,

    -- Lua callback
    LUA_CALLBACK = function(config, event_data)
        if type(config.callback) ~= "function" then return false, "Invalid callback" end
        return pcall(config.callback, event_data)
    end,
    
    -- Console transport
    CONSOLE = function(config, event_data, event_type)
        local message = event_data
        if type(event_data) == "table" then
            local ok, res = pcall(json_encode, event_data)
            if ok then message = res end
        end
        Logger.info("Console", "[EVENT:%s] %s", tostring(event_type), tostring(message))
        return true
    end
}

--- Создает новый экземпляр SubscriptionManager
--- @return SubscriptionManager
function SubscriptionManager.new()
    local self = setmetatable({}, SubscriptionManager)
    self.subscriptions = {} -- [event_type][subscription_id] = subscription_data
    self.stats = {
        total_subscriptions = 0,
        events_delivered = 0,
        events_failed = 0,
        last_reset = os_time()
    }
    Logger.info(COMPONENT_NAME, "Subscription Manager initialized")
    return self
end

--- Определяет тип транспорта
function SubscriptionManager:detect_transport(callback_config)
    if type(callback_config) == "function" then return "LUA_CALLBACK" end
    if type(callback_config) == "table" then
        local t = callback_config.type and callback_config.type:upper()
        if t == "HTTP" or t == "WS" or t == "CONSOLE" or t == "LUA_CALLBACK" then return t end
        if callback_config.host and callback_config.port then return "HTTP" end
    end
    return nil
end

--- Создает новую подписку
--- @param event_type string Тип события
--- @param sub_data table Данные подписки {callback, filters, throttle_ms}
--- @return string|nil ID подписки
function SubscriptionManager:subscribe(event_type, sub_data)
    if not event_type or type(sub_data) ~= "table" or not sub_data.callback then
        Logger.error(COMPONENT_NAME, "subscribe: Invalid arguments")
        return nil
    end

    local transport = self:detect_transport(sub_data.callback)
    if not transport then
        Logger.error(COMPONENT_NAME, "subscribe: Could not detect transport")
        return nil
    end

    local sub_id = generate_uuid()
    local subscription = {
        id = sub_id,
        event_type = event_type,
        callback = sub_data.callback,
        transport = transport,
        filters = sub_data.filters or {},
        throttle_ms = sub_data.throttle_ms or 0,
        active = true,
        created_at = os_time(),
        last_event_at = 0,
        stats = { delivered = 0, failed = 0 }
    }

    if not self.subscriptions[event_type] then self.subscriptions[event_type] = {} end
    self.subscriptions[event_type][sub_id] = subscription
    self.stats.total_subscriptions = self.stats.total_subscriptions + 1

    Logger.info(COMPONENT_NAME, "New subscription %s for '%s' (type: %s)", sub_id, event_type, transport)
    return sub_id
end

--- Публикует событие для всех подписчиков
--- @param event_type string Тип события
--- @param event_data table Данные события
--- @return number, number Количество доставленных и проваленных
function SubscriptionManager:publish(event_type, event_data)
    local targets = self.subscriptions[event_type]
    if not targets then return 0, 0 end

    local delivered, failed = 0, 0
    local now = os_time()

    for id, sub in pairs(targets) do
        if sub.active then
            local should_send = true
            
            -- 1. Троттлинг
            if sub.throttle_ms > 0 and sub.last_event_at > 0 then
                if (now - sub.last_event_at) < (sub.throttle_ms / 1000) then
                    should_send = false
                end
            end

            -- 2. Фильтрация (Fast Path: если фильтров нет, пропускаем проверку)
            if should_send and sub.filters and next(sub.filters) ~= nil then
                if FilterEngine and not FilterEngine.match(event_data, sub.filters) then
                    should_send = false
                end
            end

            if should_send then
                local success, err = Transport[sub.transport](sub.callback, event_data, event_type)
                if success then
                    delivered = delivered + 1
                    sub.stats.delivered = sub.stats.delivered + 1
                    sub.last_event_at = now
                else
                    failed = failed + 1
                    sub.stats.failed = sub.stats.failed + 1
                    Logger.error(COMPONENT_NAME, "Delivery failed for %s: %s", id, tostring(err))
                end
            end
        end
    end

    self.stats.events_delivered = self.stats.events_delivered + delivered
    self.stats.events_failed = self.stats.events_failed + failed
    return delivered, failed
end

--- Отписывает клиента
function SubscriptionManager:unsubscribe(sub_id)
    for event_type, subs in pairs(self.subscriptions) do
        if subs[sub_id] then
            subs[sub_id] = nil
            self.stats.total_subscriptions = self.stats.total_subscriptions - 1
            Logger.info(COMPONENT_NAME, "Subscription removed: %s", sub_id)
            return true
        end
    end
    return false
end

--- Возвращает статистику
function SubscriptionManager:get_stats()
    return self.stats
end

return SubscriptionManager
