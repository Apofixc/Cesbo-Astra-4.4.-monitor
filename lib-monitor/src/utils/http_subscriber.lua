-- 1. Стандартные Lua функции
local ipairs = ipairs
local type = type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local MonitorSettings = ModuleManager.get_module("monitor_settings")
local EventDispatcher = ModuleManager.get_module("event_dispatcher")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local http_request = ModuleManager.get_global_dependency("http_request")
local astra_version = ModuleManager.get_global_dependency("astra.version")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "HttpSubscriber"

-- 5. Инициализация объектов из загруженных модулей
--- @class HttpSubscriber
local HttpSubscriber = {}

--- Отправляет HTTP POST запрос
--- @param addr table {host, port, path}
--- @param content string JSON данные
--- @param event_type string Тип события для логирования
local function send_request(addr, content, event_type)
    http_request({
        host = addr.host,
        path = addr.path,
        method = "POST",
        content = content,
        port = addr.port,
        headers = {
            "User-Agent: Astra v." .. (astra_version or "unknown"),
            "Host: " .. addr.host .. ":" .. addr.port,
            "Content-Type: application/json;charset=utf-8",
            "Content-Length: " .. #content,
            "Connection: close",
        },
        callback = function(s, r)
            if not s or (type(r) == "table" and r.code and r.code ~= 200) then
                Logger.error(COMPONENT_NAME, "HTTP request failed for event '%s': %s", event_type, r and r.code or "unknown")
            end
        end
    })
end

--- Обработчик событий для HTTP рассылки
--- @param event_type string
--- @param data string JSON данные
local function handle_event(event_type, data)
    local monit_addresses = MonitorSettings and MonitorSettings.MONIT_ADDRESS or {}
    local recipients = monit_addresses[event_type]
    if not recipients then return end

    for _, addr in ipairs(recipients) do
        send_request(addr, data, event_type)
    end
end

--- Инициализирует HTTP подписчика
--- @return boolean success
function HttpSubscriber.init()
    local events = {"channels", "analyze", "error", "psi", "dvb"}
    for _, event in ipairs(events) do
        EventDispatcher.subscribe(event, function(data)
            handle_event(event, data)
        end)
    end
    Logger.info(COMPONENT_NAME, "HttpSubscriber initialized and subscribed to events")
    return true
end

return HttpSubscriber
