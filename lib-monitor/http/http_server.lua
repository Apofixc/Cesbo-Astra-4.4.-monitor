--- @class HttpServer
local HttpServer = {}

-- 1. Стандартные Lua функции
local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local tostring = tostring
local table_insert = table.insert
local collectgarbage = collectgarbage
local setmetatable = setmetatable
local type = type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")
local ChannelRoutes = ModuleManager.get_module("channel_routes")
local MonitorRoutes = ModuleManager.get_module("monitor_routes")
local DvbRoutes = ModuleManager.get_module("dvb_routes")
local SystemRoutes = ModuleManager.get_module("system_routes")
local SubscriberRoutes = ModuleManager.get_module("subscriber_routes")
local RoutesUtils = ModuleManager.get_module("routes_utils")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local http_server = ModuleManager.get_global_dependency("http_server")
local timer = ModuleManager.get_global_dependency("timer")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "HttpServer"
local DEFAULT_ADDR = "0.0.0.0"
local DEFAULT_PORT = 8080
local RESTART_RETRY_COUNT = 3
local RESTART_RETRY_DELAY = 1 -- секунда

-- Внутреннее состояние сервера
HttpServer._instance = nil
HttpServer._sentinel = nil

--- Создает обертку для маршрута с поддержкой HTTP методов, авторизации и безопасной обработкой ошибок
--- @param methods table Таблица обработчиков по методам { GET = func, POST = func, ... }
--- @return function Обработчик для Astra http_server
local function make_resource_handler(methods)
    return function(server, client, request)
        -- 1. Централизованная проверка request
        if not request then return nil end

        -- 2. Централизованная авторизация (X-Api-Key)
        if not HttpHelpers.check_auth(server, client, request) then return end

        local handler = methods[request.method]
        if not handler then
            return HttpHelpers.error(server, client, 405, "Method Not Allowed")
        end

        -- 3. Глобальный перехват ошибок для стабильности ядра Astra
        local ok, err = pcall(function()
            -- Выполнение с поддержкой контекстных ошибок Logger
            local success, result_or_msg = Logger.with_error(handler, server, client, request)
            
            if not success then
                -- Если обработчик вернул false/nil (и не отправил ответ сам), отправляем ошибку
                HttpHelpers.error(server, client, 500, result_or_msg or "Internal Server Error")
            end
        end)

        if not ok then
            Logger.error(COMPONENT_NAME, "Panic in handler %s: %s", tostring(request.path), tostring(err))
            HttpHelpers.error(server, client, 500, "Critical Server Error")
        end
    end
end

--- Останавливает HTTP сервер и гарантированно освобождает порт
function HttpServer.stop()
    if not HttpServer._instance then
        return
    end

    Logger.info(COMPONENT_NAME, "Stopping HTTP Server and releasing port...")
    
    local instance = HttpServer._instance
    HttpServer._instance = nil
    HttpServer._sentinel = nil

    if type(instance.close) == "function" then
        local ok, err = pcall(instance.close, instance)
        if not ok then
            Logger.error(COMPONENT_NAME, "Error while closing HTTP server: %s", tostring(err))
        end
    end

    -- Агрессивный вызов GC для очистки userdata и окончательного закрытия сокетов на уровне ОС
    collectgarbage("collect")
    collectgarbage("collect")
    
    Logger.info(COMPONENT_NAME, "HTTP Server stopped and port should be free")
end

--- Запускает HTTP сервер мониторинга
--- @param addr string|nil IP адрес для прослушивания
--- @param port number|nil Порт для прослушивания
--- @param retry_count number|nil Текущий номер попытки
function HttpServer.start(addr, port, retry_count)
    if HttpServer._instance then
        Logger.warn(COMPONENT_NAME, "HTTP Server is already running. Stopping old instance...")
        HttpServer.stop()
    end

    addr = addr or DEFAULT_ADDR
    port = port or DEFAULT_PORT
    retry_count = retry_count or 0

    -- Ресурсно-ориентированные маршруты. 
    -- ПРИОРИТЕТ: Самые часто запрашиваемые (метрики/статус) идут первыми для ускорения поиска в C-ядре Astra.
    local resources = {
        -- HOT ROUTES (Metrics & Status)
        ["/api/monitors/data"] = { GET = MonitorRoutes.get_monitor_data },
        ["/api/dvb/adapters/data"] = { GET = DvbRoutes.get_adapter_data },
        ["/api/monitors/status"] = { GET = MonitorRoutes.get_monitors_status },
        ["/api/system/resources"] = { GET = SystemRoutes.get_resources },
        ["/api/system/health"] = { GET = SystemRoutes.get_health },

        -- Channels
        ["/api/channels"] = { GET = ChannelRoutes.get_channels, POST = ChannelRoutes.create_channel_raw },
        ["/api/channels/stats"] = { GET = ChannelRoutes.get_channels_stats },
        ["/api/channels/info"] = { GET = ChannelRoutes.get_channel_info },
        ["/api/channels/kill"] = { DELETE = ChannelRoutes.kill_channel_raw },
        ["/api/channels/inputs"] = { GET = ChannelRoutes.get_channel_inputs },
        ["/api/channels/psi"] = { GET = ChannelRoutes.get_channel_psi },

        -- Streams
        ["/api/streams"] = { POST = ChannelRoutes.create_stream },
        ["/api/streams/kill"] = { DELETE = ChannelRoutes.kill_stream },

        -- Monitors (Management)
        ["/api/monitors"] = { GET = MonitorRoutes.get_monitors, POST = MonitorRoutes.create_monitor },
        ["/api/monitors/update"] = { PATCH = MonitorRoutes.update_monitor },
        ["/api/monitors/kill"] = { DELETE = MonitorRoutes.kill_monitor },
        ["/api/monitors/pause"] = { POST = MonitorRoutes.pause_monitor },
        ["/api/monitors/resume"] = { POST = MonitorRoutes.resume_monitor },
        ["/api/monitors/pids"] = { GET = MonitorRoutes.get_monitor_pids, DELETE = MonitorRoutes.clear_monitor_pids },
        ["/api/monitors/rate_stat"] = { GET = MonitorRoutes.get_monitor_rate_stat },

        -- DVB Adapters (Management)
        ["/api/dvb/adapters"] = { GET = DvbRoutes.get_adapters },
        ["/api/dvb/adapters/monitor"] = { GET = DvbRoutes.get_monitored_adapters },
        ["/api/dvb/adapters/scan"] = { POST = DvbRoutes.scan_adapters },
        ["/api/dvb/adapters/update"] = { PATCH = DvbRoutes.update_adapter },
        ["/api/dvb/adapters/stop"] = { DELETE = DvbRoutes.stop_adapter },
        ["/api/dvb/adapters/psi"] = { GET = DvbRoutes.get_adapter_psi, POST = DvbRoutes.update_adapter_psi },
        ["/api/dvb/adapters/tune"] = { POST = DvbRoutes.tune_adapter },
        ["/api/dvb/adapters/switch-transponder"] = { POST = DvbRoutes.switch_transponder },
        ["/api/dvb/adapters/pause"] = { POST = DvbRoutes.pause_adapter },
        ["/api/dvb/adapters/resume"] = { POST = DvbRoutes.resume_adapter },
        ["/api/dvb/adapters/restart"] = { POST = DvbRoutes.restart_adapter },
        ["/api/dvb/hardware/all"] = { GET = DvbRoutes.get_hardware_all },

        -- System (Other)
        ["/api/system/monitor-stats"] = { GET = SystemRoutes.get_monitor_stats },
        ["/api/system/reload"] = { POST = SystemRoutes.reload },
        ["/api/system/exit"] = { POST = SystemRoutes.exit },
        ["/api/system/clear-cache"] = { POST = SystemRoutes.clear_cache },
        ["/api/system/network/interfaces"] = { GET = SystemRoutes.get_network_interfaces },
        ["/api/system/network/hostname"] = { GET = SystemRoutes.get_hostname },
        ["/api/env/astra"] = { GET = SystemRoutes.get_env_astra },

        -- Subscribers
        ["/api/subscribers"] = { GET = SubscriberRoutes.get_subscribers, POST = SubscriberRoutes.subscribe, DELETE = SubscriberRoutes.unsubscribe },

        -- Utils
        ["/api/utils/resource-stats"] = { GET = RoutesUtils.get_resource_stats },
        ["/api/utils/channels/extended"] = { GET = RoutesUtils.get_channels_extended },
        ["/api/utils/monitors/errors"] = { GET = RoutesUtils.get_monitor_errors },
        ["/api/utils/system/config"] = { GET = RoutesUtils.get_system_config },
        ["/api/utils/check"] = { GET = RoutesUtils.check_object },
        ["/api/utils/objects"] = { GET = RoutesUtils.get_all_objects },
        ["/api/utils/cleanup"] = { POST = RoutesUtils.cleanup },
        ["/api/utils/info"] = { GET = RoutesUtils.get_api_info },
    }

    -- Преобразование в формат Astra http_server. 
    local routes = {}
    local priority_order = {
        "/api/monitors/data", "/api/dvb/adapters/data", "/api/monitors/status",
        "/api/system/resources", "/api/system/health"
    }
    
    for _, path in ipairs(priority_order) do
        if resources[path] then
            table_insert(routes, { path, make_resource_handler(resources[path]) })
            resources[path] = nil
        end
    end
    
    for path, methods in pairs(resources) do
        table_insert(routes, { path, make_resource_handler(methods) })
    end

    local ok, result = pcall(http_server, {
        addr = addr,
        port = port,
        server_name = "Astra Monitor API",
        route = routes
    })

    if ok then
        HttpServer._instance = result
        
        -- Sentinel для автоматической очистки при выходе из программы
        HttpServer._sentinel = setmetatable({}, {
            __gc = function()
                if HttpServer._instance then
                    pcall(HttpServer._instance.close, HttpServer._instance)
                end
            end
        })

        Logger.info(COMPONENT_NAME, "HTTP Server started on %s:%s", addr, tostring(port))
        return true
    else
        -- Если порт занят, пробуем повторить через секунду (до 3 раз)
        if retry_count < RESTART_RETRY_COUNT then
            Logger.warn(COMPONENT_NAME, "Failed to bind port %s (attempt %d/%d). Retrying in %ds...", 
                tostring(port), retry_count + 1, RESTART_RETRY_COUNT, RESTART_RETRY_DELAY)
            
            if timer then
                timer({
                    interval = RESTART_RETRY_DELAY,
                    callback = function(self)
                        self:close()
                        HttpServer.start(addr, port, retry_count + 1)
                    end
                })
                return true
            end
        end

        Logger.error(COMPONENT_NAME, "Failed to start HTTP Server: %s", tostring(result))
        return false
    end
end

return HttpServer
