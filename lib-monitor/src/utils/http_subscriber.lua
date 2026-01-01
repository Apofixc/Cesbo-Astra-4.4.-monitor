-- 1. Стандартные Lua функции
local ipairs = ipairs
local type = type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local MonitorSettings = ModuleManager.get_module("monitor_settings")

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

--- Публикует событие через HTTP рассылку
--- @param event_type string Тип события
--- @param data string JSON данные
--- @return boolean success
function HttpSubscriber.publish(event_type, data)
    if not event_type or not data then
        return false
    end

    local monit_addresses = MonitorSettings and MonitorSettings.MONIT_ADDRESS or {}
    local recipients = monit_addresses[event_type]
    
    if not recipients or #recipients == 0 then
        -- Если нет подписчиков, просто логируем (как это делал EventDispatcher)
        Logger.info(COMPONENT_NAME, "[%s] %s", event_type, tostring(data))
        return true
    end

    for _, addr in ipairs(recipients) do
        send_request(addr, data, event_type)
    end

    return true
end

return HttpSubscriber
