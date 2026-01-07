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
local os_clock = os.clock
local tonumber = tonumber

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
local RESTART_RETRY_DELAY = 1
local MAX_PAYLOAD_SIZE = 1024 * 1024 -- 1 MB limit

-- Внутреннее состояние сервера
HttpServer._instance = nil
HttpServer._sentinel = nil
HttpServer._stats = {
    total_requests = 0,
    total_errors = 0,
    routes = {} -- Статистика по путям: { count, total_time, errors }
}

--- Middleware: Защита от слишком больших запросов (Payload Limit)
local function payload_limit_middleware(handler)
    return function(server, client, request)
        local content_length = tonumber(request.headers and request.headers["content-length"]) or 0
        if content_length > MAX_PAYLOAD_SIZE then
            Logger.warn(COMPONENT_NAME, "Payload too large from %s (%d bytes)", tostring(request.addr), content_length)
            return HttpHelpers.error(server, client, 413, "Payload Too Large")
        end
        return handler(server, client, request)
    end
end

--- Middleware: Поддержка CORS
local function cors_middleware(handler)
    return function(server, client, request)
        -- Обработка preflight запросов OPTIONS
        if request.method == "OPTIONS" then
            server:send(client, {
                code = 204,
                headers = {
                    "Access-Control-Allow-Origin: *",
                    "Access-Control-Allow-Methods: GET, POST, PATCH, DELETE, OPTIONS",
                    "Access-Control-Allow-Headers: X-Api-Key, Content-Type",
                    "Access-Control-Max-Age: 86400",
                    "Connection: close"
                }
            })
            return true
        end
        
        -- Для обычных запросов перехватываем отправку, чтобы добавить заголовок (упрощенно)
        -- В Astra мы не можем легко обернуть server:send, поэтому просто полагаемся на то, 
        -- что роутеры используют HttpHelpers, но для надежности добавим логику здесь если нужно.
        return handler(server, client, request)
    end
end

--- Middleware: Логирование и замер производительности
local function logger_middleware(handler, path)
    return function(server, client, request)
        local start_time = os_clock()
        
        if not HttpServer._stats.routes[path] then
            HttpServer._stats.routes[path] = { count = 0, total_time = 0, errors = 0 }
        end
        local route_stats = HttpServer._stats.routes[path]
        
        local success, result = handler(server, client, request)
        
        local duration = os_clock() - start_time
        HttpServer._stats.total_requests = HttpServer._stats.total_requests + 1
        route_stats.count = route_stats.count + 1
        route_stats.total_time = route_stats.total_time + duration
        
        if not success then
            HttpServer._stats.total_errors = HttpServer._stats.total_errors + 1
            route_stats.errors = route_stats.errors + 1
        end
        
        return success, result
    end
end

--- Создает обертку для маршрута с полной цепочкой Middleware
--- @param methods table Таблица обработчиков по методам
--- @param path string Путь маршрута
--- @return function Обработчик для Astra http_server
local function make_resource_handler(methods, path)
    local function core_handler(server, client, request)
        if not request then return nil end

        -- Централизованная авторизация
        if not HttpHelpers.check_auth(server, client, request) then return true end

        local handler = methods[request.method]
        if not handler then
            return HttpHelpers.error(server, client, 405, "Method Not Allowed")
        end

        -- Глобальный перехват ошибок
        local ok, success, result_or_msg = pcall(function()
            return Logger.with_error(handler, server, client, request)
        end)

        if not ok then
            Logger.error(COMPONENT_NAME, "Panic in handler %s: %s", tostring(path), tostring(success))
            return HttpHelpers.error(server, client, 500, "Critical Server Error")
        end

        if not success then
            if result_or_msg then
                HttpHelpers.error(server, client, 500, result_or_msg)
            end
            return false, result_or_msg
        end
        
        return true, result_or_msg
    end

    -- Цепочка Middleware: Logger -> CORS -> Payload Limit -> Core
    return logger_middleware(cors_middleware(payload_limit_middleware(core_handler)), path)
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
        pcall(instance.close, instance)
    end

    collectgarbage("collect")
    collectgarbage("collect")
    
    Logger.info(COMPONENT_NAME, "HTTP Server stopped and port should be free")
end

--- Возвращает статистику производительности API
function HttpServer.get_stats()
    return HttpServer._stats
end

--- Запускает HTTP сервер мониторинга
function HttpServer.start(addr, port, retry_count)
    if HttpServer._instance then
        HttpServer.stop()
    end

    addr = addr or DEFAULT_ADDR
    port = port or DEFAULT_PORT
    retry_count = retry_count or 0

    local resources = {
        -- HOT ROUTES
        ["/api/monitors/data"] = { GET = MonitorRoutes.get_monitor_data },
        ["/api/dvb/adapters/data"] = { GET = DvbRoutes.get_adapter_data },
        ["/api/monitors/status"] = { GET = MonitorRoutes.get_monitors_status },
        ["/api/system/resources"] = { GET = SystemRoutes.get_resources },
        ["/api/system/health"] = { GET = SystemRoutes.get_health },
        ["/api/system/api-stats"] = { 
            GET = function(s, c, r) return HttpHelpers.success(s, c, HttpServer.get_stats()) end 
        },

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

        -- Monitors
        ["/api/monitors"] = { GET = MonitorRoutes.get_monitors, POST = MonitorRoutes.create_monitor },
        ["/api/monitors/update"] = { PATCH = MonitorRoutes.update_monitor },
        ["/api/monitors/kill"] = { DELETE = MonitorRoutes.kill_monitor },
        ["/api/monitors/pause"] = { POST = MonitorRoutes.pause_monitor },
        ["/api/monitors/resume"] = { POST = MonitorRoutes.resume_monitor },
        ["/api/monitors/pids"] = { GET = MonitorRoutes.get_monitor_pids, DELETE = MonitorRoutes.clear_monitor_pids },
        ["/api/monitors/rate_stat"] = { GET = MonitorRoutes.get_monitor_rate_stat },

        -- DVB Adapters
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

        -- System
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

    local routes = {}
    local priority_order = {
        "/api/monitors/data", "/api/dvb/adapters/data", "/api/monitors/status",
        "/api/system/resources", "/api/system/health", "/api/system/api-stats"
    }
    
    for _, path in ipairs(priority_order) do
        if resources[path] then
            table_insert(routes, { path, make_resource_handler(resources[path], path) })
            resources[path] = nil
        end
    end
    
    for path, methods in pairs(resources) do
        table_insert(routes, { path, make_resource_handler(methods, path) })
    end

    local ok, result = pcall(http_server, {
        addr = addr,
        port = port,
        server_name = "Astra Monitor API",
        route = routes
    })

    if ok then
        HttpServer._instance = result
        HttpServer._sentinel = setmetatable({}, {
            __gc = function()
                if HttpServer._instance then pcall(HttpServer._instance.close, HttpServer._instance) end
            end
        })
        Logger.info(COMPONENT_NAME, "HTTP Server started on %s:%s", addr, tostring(port))
        return true
    else
        if retry_count < RESTART_RETRY_COUNT then
            Logger.warn(COMPONENT_NAME, "Failed to bind port %s (attempt %d/%d). Retrying...", tostring(port), retry_count + 1, RESTART_RETRY_COUNT)
            if timer then
                timer({
                    interval = RESTART_RETRY_DELAY,
                    callback = function(self) self:close(); HttpServer.start(addr, port, retry_count + 1) end
                })
                return true
            end
        end
        Logger.error(COMPONENT_NAME, "Failed to start HTTP Server: %s", tostring(result))
        return false
    end
end

return HttpServer
