-- ===========================================================================
-- Модуль `core.subscription_manager`
--
-- Динамическое управление подписками на события мониторинга.
-- Поддерживает HTTP, WebSocket, Console и Lua callback транспорты.
-- Реализует оптимизацию Fast Path, троттлинг, сохранение подписок и повторы.
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
local io = io

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local FilterEngine = ModuleManager.get_module("utils.filter_engine")
local Wildcard = ModuleManager.get_module("utils.wildcard")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local http_request = ModuleManager.get_global_dependency("http_request")
local astra_version = ModuleManager.get_global_dependency("astra.version")
local json_encode = ModuleManager.get_global_dependency("json.encode")
local json_decode = ModuleManager.get_global_dependency("json.decode")
local timer = ModuleManager.get_global_dependency("timer")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "SubscriptionManager"
local USER_AGENT = "User-Agent: Astra v." .. (astra_version or "unknown")
local CONTENT_TYPE = "Content-Type: application/json;charset=utf-8"
local STORAGE_PATH = "/opt/astra/lib-monitor/subscribers.json"
local MAX_RETRIES = 3
local RETRY_DELAY = 5

--- @class SubscriptionManager
--- @field private subscriptions table<string, table<string, table>> Хранилище подписок по типам событий
--- @field private stats table Глобальная статистика подписок
--- @field private _matchers table<string, function> Кэш скомпилированных матчеров
local SubscriptionManager = {}
SubscriptionManager.__index = SubscriptionManager

-- Очередь на повторную отправку
local retry_queue = {}

--- Генерирует уникальный идентификатор (UUID v4) для подписки.
--- @return string UUID
local function generate_uuid()
    local template ='xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return (string.gsub(template, '[xy]', function (c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end))
end

--- Вспомогательная функция для получения JSON из события (Lazy JSON)
--- @param event table Объект события
--- @return string|nil JSON-строка
local function get_event_json(event)
    if not event then return nil end
    if event.json_cache then return event.json_cache end
    
    if type(event.data) == "string" then
        event.json_cache = event.data
    else
        event.json_cache = json_encode(event.data)
    end
    return event.json_cache
end

--- @type table<string, function> Транспорты для доставки событий
local Transport = {
    --- Доставка через HTTP POST запрос
    --- @param config table Параметры (host, port, path)
    --- @param event table|string Объект события или данные
    --- @param event_type string Тип события
    --- @param retry_count? number [Текущая попытка повтора]
    HTTP = function(config, event, event_type, retry_count)
        if not http_request then return false, "http_request not available" end
        
        local content = (type(event) == "table" and event.id) and get_event_json(event) or 
                        ((type(event) == "table") and json_encode(event) or tostring(event))
        
        if not content then return false, "JSON encode failed" end
        
        retry_count = retry_count or 0
        
        http_request({
            host = config.host, port = config.port, path = config.path or "/",
            method = "POST", content = content,
            headers = { USER_AGENT, "Host: " .. config.host .. ":" .. config.port, CONTENT_TYPE, "Content-Length: " .. #content, "Connection: close" },
            callback = function(s, r)
                if not s and retry_count < MAX_RETRIES then
                    -- Для ретрая делаем копию данных, если это была таблица из пула
                    local retry_data = event
                    if type(event) == "table" and event.is_table then
                        -- Если это событие с таблицей из пула, к этому моменту таблица может быть уже возвращена в пул.
                        -- Поэтому для ретрая используем уже готовый JSON.
                        retry_data = content
                    end

                    table_insert(retry_queue, {
                        config = config, data = retry_data, type = event_type,
                        retries = retry_count + 1, time = os_time() + RETRY_DELAY
                    })
                end
            end
        })
        return true
    end,
    --- Доставка через WebSocket
    --- @param config table Параметры транспорта
    --- @param event table|string Объект события или данные
    --- @param event_type string Тип события
    WS = function(config, event, event_type)
        local WsSubscriber = ModuleManager.get_module("ws_subscriber")
        if WsSubscriber and WsSubscriber.broadcast_raw then
            local json_data = (type(event) == "table" and event.id) and get_event_json(event) or 
                             ((type(event) == "table") and json_encode(event) or event)
            WsSubscriber.broadcast_raw(event_type, json_data)
            return true
        end
        return false, "WsSubscriber not available"
    end,
    --- Доставка через вызов Lua функции
    --- @param config table Параметры (callback)
    --- @param event table|string Объект события или данные
    LUA_CALLBACK = function(config, event)
        if type(config.callback) ~= "function" then return false, "Invalid callback" end
        local data = (type(event) == "table" and event.id) and event.data or event
        return pcall(config.callback, data)
    end,
    --- Вывод события в консоль (лог Astra)
    --- @param config table Параметры транспорта
    --- @param event table|string Объект события или данные
    --- @param event_type string Тип события
    CONSOLE = function(config, event, event_type)
        local message = (type(event) == "table" and event.id) and get_event_json(event) or 
                        ((type(event) == "table") and json_encode(event) or event)
        Logger.info("Console", "[EVENT:%s] %s", tostring(event_type), tostring(message))
        return true
    end
}

--- Создает и инициализирует новый экземпляр SubscriptionManager.
--- Загружает сохраненные подписки из файла и запускает обработчик повторов.
--- @return SubscriptionManager Экземпляр менеджера
function SubscriptionManager.new()
    local self = setmetatable({}, SubscriptionManager)
    self.subscriptions = {} -- [event_type][subscription_id] = sub_data
    self.stats = { total = 0, delivered = 0, failed = 0 }
    self._matchers = {} -- [pattern] = function
    self:load()
    self:start_retry_processor()
    return self
end

--- Запускает фоновый процесс обработки очереди повторных попыток отправки HTTP-уведомлений.
--- @private
function SubscriptionManager:start_retry_processor()
    if not timer then return end
    timer({
        interval = 1,
        callback = function()
            local now = os_time()
            for i = #retry_queue, 1, -1 do
                local item = retry_queue[i]
                if now >= item.time then
                    table_remove(retry_queue, i)
                    Transport.HTTP(item.config, item.data, item.type, item.retries)
                end
            end
        end
    })
end

--- Сохраняет текущие активные подписки в JSON файл.
--- Lua-коллбэки игнорируются при сохранении.
--- @return boolean Статус выполнения
function SubscriptionManager:save()
    local data_to_save = {}
    for event_type, subs in pairs(self.subscriptions) do
        data_to_save[event_type] = {}
        for id, sub in pairs(subs) do
            if sub.transport ~= "LUA_CALLBACK" then
                data_to_save[event_type][id] = {
                    callback = sub.callback,
                    filters = sub.filters,
                    throttle_ms = sub.throttle_ms,
                    active = sub.active
                }
            end
        end
    end
    local f = io.open(STORAGE_PATH, "w")
    if f then
        f:write(json_encode(data_to_save))
        f:close()
        return true
    end
    return false
end

--- Загружает подписки из JSON файла и регистрирует их в системе.
--- @private
function SubscriptionManager:load()
    local f = io.open(STORAGE_PATH, "r")
    if not f then return end
    local content = f:read("*all")
    f:close()
    if not content or content == "" then return end
    local data = json_decode(content)
    if type(data) ~= "table" then return end
    for event_type, subs in pairs(data) do
        for id, sub_data in pairs(subs) do
            self:subscribe(event_type, sub_data, id)
        end
    end
end

--- Регистрирует новую подписку на события.
--- @param event_type string Тип события или маска
--- @param sub_data table Данные подписки (callback, filters, throttle_ms)
--- @param existing_id? string [Использовать существующий ID (для загрузки из файла)]
--- @return string|nil ID подписки (UUID) или nil при ошибке
function SubscriptionManager:subscribe(event_type, sub_data, existing_id)
    local transport = self:detect_transport(sub_data.callback)
    if not transport then return nil end

    local sub_id = existing_id or generate_uuid()
    local subscription = {
        id = sub_id, event_type = event_type, callback = sub_data.callback,
        transport = transport, filters = sub_data.filters or {},
        throttle_ms = sub_data.throttle_ms or 0, active = sub_data.active ~= false,
        last_event_at = 0, stats = { delivered = 0, failed = 0 }
    }

    if not self.subscriptions[event_type] then 
        self.subscriptions[event_type] = {} 
        -- Предкомпиляция маски
        if Wildcard then
            self._matchers[event_type] = Wildcard.compile(event_type)
        end
    end
    self.subscriptions[event_type][sub_id] = subscription
    self.stats.total = self.stats.total + 1
    
    if not existing_id then self:save() end
    return sub_id
end

--- Проверяет соответствие имени события маске.
--- @param pattern string Маска
--- @param name string Имя события
--- @return boolean Результат
function SubscriptionManager:match(pattern, name)
    local matcher = self._matchers[pattern]
    if matcher then return matcher(name) end
    return pattern == name
end

--- Рассылает событие всем подписчикам (устаревший метод).
--- @param event_type string Точное имя события
--- @param event_data table Данные события
--- @return number, number Количество успешно доставленных и проваленных уведомлений
function SubscriptionManager:publish(event_type, event_data)
    return self:publish_event({
        type = event_type,
        data = event_data,
        timestamp = os_time()
    })
end

--- Рассылает объект события всем подписчикам.
--- @param event table Объект события (из EventDispatcher)
--- @return number, number Количество успешно доставленных и проваленных уведомлений
function SubscriptionManager:publish_event(event)
    local delivered, failed = 0, 0
    local now = os_time()
    local event_type = event.type
    local event_data = event.data

    for pattern, subs in pairs(self.subscriptions) do
        if self:match(pattern, event_type) then
            for id, sub in pairs(subs) do
                if sub.active then
                    local should_send = true
                    if sub.throttle_ms > 0 and (now - sub.last_event_at) < (sub.throttle_ms / 1000) then
                        should_send = false
                    end
                    if should_send and sub.filters and next(sub.filters) ~= nil then
                        if FilterEngine and not FilterEngine.match(event_data, sub.filters, id) then
                            should_send = false
                        end
                    end
                    if should_send then
                        local success, err = Transport[sub.transport](sub.callback, event, event_type)
                        if success then
                            delivered = delivered + 1
                            sub.stats.delivered = sub.stats.delivered + 1
                            sub.last_event_at = now
                        else
                            failed = failed + 1
                            sub.stats.failed = sub.stats.failed + 1
                        end
                    end
                end
            end
        end
    end
    self.stats.delivered = self.stats.delivered + delivered
    self.stats.failed = self.stats.failed + failed
    return delivered, failed
end

--- Отправляет событие конкретному подписчику по его ID.
--- Используется для инициализации (LVC) или отладки.
--- @param sub_id string ID подписки
--- @param event_type string Имя события
--- @param event_data table Данные события
--- @return boolean Статус выполнения
function SubscriptionManager:publish_to_single(sub_id, event_type, event_data)
    for _, subs in pairs(self.subscriptions) do
        local sub = subs[sub_id]
        if sub then
            Transport[sub.transport](sub.callback, event_data, event_type)
            return true
        end
    end
    return false
end

--- Определяет тип транспорта на основе конфигурации callback.
--- @param cfg function|table Конфигурация коллбэка или функция
--- @return string|nil Тип транспорта (HTTP, WS, CONSOLE, LUA_CALLBACK)
function SubscriptionManager:detect_transport(cfg)
    if type(cfg) == "function" then return "LUA_CALLBACK" end
    if type(cfg) == "table" then
        local t = cfg.type and cfg.type:upper()
        if t == "HTTP" or t == "WS" or t == "CONSOLE" or t == "LUA_CALLBACK" then return t end
        if cfg.host and cfg.port then return "HTTP" end
    end
    return nil
end

--- Удаляет подписку по её ID и сохраняет изменения в файл.
--- @param sub_id string ID подписки
--- @return boolean Статус выполнения
function SubscriptionManager:unsubscribe(sub_id)
    for event_type, subs in pairs(self.subscriptions) do
        if subs[sub_id] then
            subs[sub_id] = nil
            self.stats.total = self.stats.total - 1
            
            -- Если подписок на этот тип больше нет, удаляем матчер
            if not next(subs) then
                self.subscriptions[event_type] = nil
                self._matchers[event_type] = nil
            end
            
            self:save()
            return true
        end
    end
    return false
end

--- Возвращает список всех активных подписок в системе.
--- @return table<string, table> Таблица подписок
function SubscriptionManager:get_all_subscriptions()
    local res = {}
    for _, subs in pairs(self.subscriptions) do
        for id, sub in pairs(subs) do res[id] = sub end
    end
    return res
end

return SubscriptionManager
