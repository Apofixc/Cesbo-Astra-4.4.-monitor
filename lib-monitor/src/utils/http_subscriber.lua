-- 1. Стандартные Lua функции
local ipairs = ipairs
local type = type
local tostring = tostring
local pcall = pcall
local io = io
local string_format = string.format
local table_insert = table.insert
local table_remove = table.remove

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local MonitorConfig = ModuleManager.get_module("monitor_config")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local http_request = ModuleManager.get_global_dependency("http_request")
local astra_version = ModuleManager.get_global_dependency("astra.version")
local json_decode = ModuleManager.get_global_dependency("json.decode")
local json_encode = ModuleManager.get_global_dependency("json.encode")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "HttpSubscriber"
local USER_AGENT = "User-Agent: Astra v." .. (astra_version or "unknown")
local CONTENT_TYPE = "Content-Type: application/json;charset=utf-8"

-- 5. Инициализация объектов из загруженных модулей
--- @class HttpSubscriber
--- @field private subscribers table<string, table[]> Таблица подписчиков
local HttpSubscriber = {}

--- @type table<string, table[]> Таблица подписчиков: { [event_type] = { {host, port, path}, ... } }
local subscribers = {}

--- @type table<string, function> Карта активных обработчиков EventBus
local active_handlers = {}

--- Внутренний обработчик событий для рассылки по HTTP
--- @private
local function internal_event_handler(event_type, data)
    if not event_type or not data then return end
    
    -- Если данные еще не в JSON, пробуем закодировать
    local json_data = data
    if type(data) == "table" then
        local json_encode = ModuleManager.get_global_dependency("json.encode")
        if json_encode then
            local ok, res = pcall(json_encode, data)
            if ok then json_data = res end
        end
    end

    HttpSubscriber.publish(event_type, json_data)
end

--- Синхронизирует подписки с EventBus
--- @private
local function sync_event_bus(event_type)
    local EventBus = ModuleManager.get_module("event_bus")
    if not EventBus then return end

    local recipients = subscribers[event_type]
    local has_recipients = recipients and #recipients > 0

    if has_recipients and not active_handlers[event_type] then
        -- Создаем замыкание для конкретного типа события
        local handler = function(data) internal_event_handler(event_type, data) end
        active_handlers[event_type] = handler
        EventBus.subscribe(event_type, handler)
        Logger.debug(COMPONENT_NAME, "Динамическая подписка на EventBus для типа '%s' активирована", event_type)
    elseif not has_recipients and active_handlers[event_type] then
        EventBus.unsubscribe(event_type, active_handlers[event_type])
        active_handlers[event_type] = nil
        Logger.debug(COMPONENT_NAME, "Динамическая подписка на EventBus для типа '%s' деактивирована", event_type)
    end
end

--- Загружает список подписчиков из конфигурации
--- @private
--- @return boolean Статус выполнения
local function load_subscribers()
    if MonitorConfig and MonitorConfig.subscribers then
        subscribers = MonitorConfig.subscribers
        Logger.info(COMPONENT_NAME, "Subscribers loaded from global config")
        
        -- Активируем подписки для всех загруженных типов
        for event_type, _ in pairs(subscribers) do
            sync_event_bus(event_type)
        end
    else
        subscribers = {}
        if MonitorConfig then
            MonitorConfig.subscribers = subscribers
        end
    end
    return true
end

--- Сохраняет список подписчиков в конфигурацию
--- @private
--- @return boolean Статус выполнения
local function save_subscribers()
    if not MonitorConfig then return false end
    MonitorConfig.subscribers = subscribers
    return MonitorConfig.save()
end

--- Возвращает список всех подписчиков
--- @return table Таблица подписчиков
function HttpSubscriber.get_subscribers()
    return subscribers
end

--- Отправляет HTTP POST запрос
--- @private
--- @param addr table {host, port, path}
--- @param content string JSON данные
--- @param event_type string Тип события для логирования
local function send_request(addr, content, event_type)
    local timeout = (MonitorConfig and MonitorConfig.HttpTimeout) or 10
    local url = string_format("http://%s:%s%s", addr.host, addr.port, addr.path)

    http_request({
        host = addr.host,
        path = addr.path,
        method = "POST",
        content = content,
        port = addr.port,
        timeout = timeout,
        headers = {
            USER_AGENT,
            "Host: " .. addr.host .. ":" .. addr.port,
            CONTENT_TYPE,
            "Content-Length: " .. #content,
            "Connection: close",
        },
        callback = function(self, r)
            if not r then
                Logger.error(COMPONENT_NAME, "HTTP request failed for event '%s' to %s: No response", event_type, url)
            elseif r.code and r.code ~= 200 then
                Logger.error(COMPONENT_NAME, "HTTP request failed for event '%s' to %s: Status %s", event_type, url, tostring(r.code))
            else
                Logger.debug(COMPONENT_NAME, "Event '%s' successfully sent to %s", event_type, url)
            end
        end
    })
end

--- Подписывает адрес на события определенного типа
--- @param event_type string Тип события
--- @param addr table {host, port, path}
--- @return boolean Статус выполнения
function HttpSubscriber.subscribe(event_type, addr)
    if not event_type or type(addr) ~= "table" or not addr.host or not addr.port or not addr.path then
        Logger.error(COMPONENT_NAME, "subscribe: Invalid arguments")
        return false
    end

    if not subscribers[event_type] then
        subscribers[event_type] = {}
    end

    -- Проверка на дубликаты
    for _, existing in ipairs(subscribers[event_type]) do
        if existing.host == addr.host and existing.port == addr.port and existing.path == addr.path then
            return true -- Уже подписан
        end
    end

    table_insert(subscribers[event_type], {
        host = addr.host,
        port = addr.port,
        path = addr.path
    })

    Logger.info(COMPONENT_NAME, "New subscriber added for '%s': %s:%s%s", event_type, addr.host, addr.port, addr.path)
    
    sync_event_bus(event_type)
    return save_subscribers()
end

--- Отписывает адрес от событий определенного типа
--- @param event_type string Тип события
--- @param addr table {host, port, path}
--- @return boolean Статус выполнения
function HttpSubscriber.unsubscribe(event_type, addr)
    if not event_type or not subscribers[event_type] or type(addr) ~= "table" then
        Logger.error(COMPONENT_NAME, "unsubscribe: Invalid arguments or event type not found")
        return false
    end

    local found = false
    for i, existing in ipairs(subscribers[event_type]) do
        if existing.host == addr.host and existing.port == addr.port and existing.path == addr.path then
            table_remove(subscribers[event_type], i)
            found = true
            break
        end
    end

    if found then
        Logger.info(COMPONENT_NAME, "Subscriber removed for '%s': %s:%s%s", event_type, addr.host, addr.port, addr.path)
        sync_event_bus(event_type)
        return save_subscribers()
    end

    return true
end

--- Публикует событие через HTTP рассылку
--- @param event_type string Тип события
--- @param data string JSON данные
function HttpSubscriber.publish(event_type, data)
    if not event_type or not data then
        Logger.error(COMPONENT_NAME, "publish: Invalid arguments")
        return
    end

    local recipients = subscribers[event_type]
    
    if not recipients or #recipients == 0 then
        -- Если нет подписчиков, просто логируем на уровне INFO
        Logger.debug(COMPONENT_NAME, "[%s] %s", event_type, tostring(data))
        return
    end

    for _, addr in ipairs(recipients) do
        send_request(addr, data, event_type)
    end
end

-- Инициализация при загрузке модуля
load_subscribers()

return HttpSubscriber
