-- 1. Стандартные Lua функции
local ipairs = ipairs
local type = type
local tostring = tostring
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

-- 5. Инициализация объектов из загруженных модулей
--- @class HttpSubscriber
--- @field private subscribers table<string, table[]> Таблица подписчиков
local HttpSubscriber = {}

--- @type table<string, table[]> Таблица подписчиков: { [event_type] = { {host, port, path}, ... } }
local subscribers = {}

--- Загружает список подписчиков из файла
--- @return boolean Статус выполнения
local function load_subscribers()
    local path = MonitorConfig and MonitorConfig.SubscribersFilePath
    if not path then
        Logger.error(COMPONENT_NAME, "load_subscribers: SubscribersFilePath not configured")
        return false
    end

    local f, err = io.open(path, "r")
    if not f then
        Logger.info(COMPONENT_NAME, "Subscribers file not found or not readable: %s. Starting with empty list", tostring(err))
        subscribers = {}
        return true
    end

    local content = f:read("*a")
    f:close()

    if content and content:match("%S") then
        local ok, data = pcall(json_decode, content)
        if ok and type(data) == "table" then
            subscribers = data
            Logger.info(COMPONENT_NAME, "Subscribers loaded from %s", path)
            return true
        else
            Logger.error(COMPONENT_NAME, "Failed to decode subscribers from %s: %s", path, tostring(data))
        end
    else
        Logger.info(COMPONENT_NAME, "Subscribers file is empty")
    end

    subscribers = {}
    return true -- Возвращаем true, так как это валидное состояние (пустой список)
end

--- Сохраняет список подписчиков в файл
--- @return boolean Статус выполнения
local function save_subscribers()
    local path = MonitorConfig and MonitorConfig.SubscribersFilePath
    if not path then
        Logger.error(COMPONENT_NAME, "save_subscribers: SubscribersFilePath not configured")
        return false
    end

    local ok, content = pcall(json_encode, subscribers)
    if not ok then
        Logger.error(COMPONENT_NAME, "Failed to encode subscribers for saving")
        return false
    end

    local f, err = io.open(path, "w")
    if not f then
        Logger.error(COMPONENT_NAME, "Failed to open subscribers file for writing: %s (%s)", path, tostring(err))
        return false
    end

    local success, write_err = f:write(content)
    f:close()

    if not success then
        Logger.error(COMPONENT_NAME, "Failed to write subscribers to file: %s", tostring(write_err))
        return false
    end

    return true
end

--- Возвращает список всех подписчиков
--- @return table Таблица подписчиков
function HttpSubscriber.get_subscribers()
    return subscribers
end

--- Отправляет HTTP POST запрос
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
            "User-Agent: Astra v." .. (astra_version or "unknown"),
            "Host: " .. addr.host .. ":" .. addr.port,
            "Content-Type: application/json;charset=utf-8",
            "Content-Length: " .. #content,
            "Connection: close",
        },
        callback = function(s, r)
            if not s then
                Logger.error(COMPONENT_NAME, "HTTP request failed for event '%s' to %s: Connection error", event_type, url)
            elseif type(r) == "table" and r.code and r.code ~= 200 then
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
