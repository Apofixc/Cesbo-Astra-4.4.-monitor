--- @class HttpServer
local HttpServer = {}

-- 1. Стандартные Lua функции
local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local tostring = tostring

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local ChannelRoutes = ModuleManager.get_module("channel_routes")
local MonitorRoutes = ModuleManager.get_module("monitor_routes")
local DvbRoutes = ModuleManager.get_module("dvb_routes")
local SystemRoutes = ModuleManager.get_module("system_routes")
local SubscriberRoutes = ModuleManager.get_module("subscriber_routes")
local RoutesUtils = ModuleManager.get_module("routes_utils")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local http_server = ModuleManager.get_global_dependency("http_server")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "HttpServer"
local DEFAULT_ADDR = "0.0.0.0"
local DEFAULT_PORT = 8080

--- Создает обертку для маршрута с поддержкой HTTP методов
--- @param methods table Таблица обработчиков по методам { GET = func, POST = func, ... }
--- @return function Обработчик для Astra http_server
local function make_resource_handler(methods)
    return function(server, client, request)
        if not request then return nil end
        local handler = methods[request.method]
        if not handler then
            return HttpHelpers.error(server, client, 405, "Method Not Allowed")
        end
        return handler(server, client, request)
    end
end

--- Запускает HTTP сервер мониторинга
--- @param addr string|nil IP адрес для прослушивания
--- @param port number|nil Порт для прослушивания
function HttpServer.start(addr, port)
    addr = addr or DEFAULT_ADDR
    port = port or DEFAULT_PORT

    -- Ресурсно-ориентированные маршруты
    local resources = {
        -- Channels
        ["/api/channels"] = {
            GET = ChannelRoutes.get_channels,
            POST = ChannelRoutes.create_channel_raw,
        },
        ["/api/channels/stats"] = {
            GET = ChannelRoutes.get_channels_stats,
        },
        ["/api/channels/([^/]+)"] = {
            GET = ChannelRoutes.get_channel_info,
            DELETE = ChannelRoutes.kill_channel_raw,
        },
        ["/api/channels/([^/]+)/inputs"] = {
            GET = ChannelRoutes.get_channel_inputs,
        },
        ["/api/channels/([^/]+)/psi"] = {
            GET = ChannelRoutes.get_channel_psi,
        },
        ["/api/channels/([^/]+)/psi/([^/]+)"] = {
            GET = ChannelRoutes.get_channel_psi,
        },

        -- Streams
        ["/api/streams"] = {
            POST = ChannelRoutes.create_stream,
        },
        ["/api/streams/([^/]+)"] = {
            DELETE = ChannelRoutes.kill_stream,
        },

        -- Monitors
        ["/api/monitors"] = {
            GET = MonitorRoutes.get_monitors,
            POST = MonitorRoutes.create_monitor,
        },
        ["/api/monitors/status"] = {
            GET = MonitorRoutes.get_monitors_status,
        },
        ["/api/monitors/([^/]+)"] = {
            GET = MonitorRoutes.get_monitor_data,
            PATCH = MonitorRoutes.update_monitor,
            DELETE = MonitorRoutes.kill_monitor,
        },
        ["/api/monitors/([^/]+)/pause"] = {
            POST = MonitorRoutes.pause_monitor,
        },
        ["/api/monitors/([^/]+)/resume"] = {
            POST = MonitorRoutes.resume_monitor,
        },
        ["/api/monitors/([^/]+)/pids"] = {
            GET = MonitorRoutes.get_monitor_pids,
            DELETE = MonitorRoutes.clear_monitor_pids,
        },
        ["/api/monitors/([^/]+)/rate_stat"] = {
            GET = MonitorRoutes.get_monitor_rate_stat,
        },

        -- DVB Adapters
        ["/api/dvb/adapters"] = {
            GET = DvbRoutes.get_adapters,
        },
        ["/api/dvb/adapters/monitor"] = {
            GET = DvbRoutes.get_monitored_adapters,
        },
        ["/api/dvb/adapters/scan"] = {
            POST = DvbRoutes.scan_adapters,
        },
        ["/api/dvb/adapters/([^/]+)"] = {
            GET = DvbRoutes.get_adapter_data,
            PATCH = DvbRoutes.update_adapter,
            DELETE = DvbRoutes.stop_adapter,
        },
        ["/api/dvb/adapters/([^/]+)/psi"] = {
            GET = DvbRoutes.get_adapter_psi,
            POST = DvbRoutes.update_adapter_psi,
        },
        ["/api/dvb/adapters/([^/]+)/psi/([^/]+)"] = {
            GET = DvbRoutes.get_adapter_psi,
        },
        ["/api/dvb/adapters/([^/]+)/tune"] = {
            POST = DvbRoutes.tune_adapter,
        },
        ["/api/dvb/adapters/([^/]+)/switch-transponder"] = {
            POST = DvbRoutes.switch_transponder,
        },
        ["/api/dvb/adapters/([^/]+)/pause"] = {
            POST = DvbRoutes.pause_adapter,
        },
        ["/api/dvb/adapters/([^/]+)/resume"] = {
            POST = DvbRoutes.resume_adapter,
        },
        ["/api/dvb/adapters/([^/]+)/restart"] = {
            POST = DvbRoutes.restart_adapter,
        },
        ["/api/dvb/hardware/all"] = {
            GET = DvbRoutes.get_hardware_all,
        },

        -- System
        ["/api/system/resources"] = {
            GET = SystemRoutes.get_resources,
        },
        ["/api/system/monitor-stats"] = {
            GET = SystemRoutes.get_monitor_stats,
        },
        ["/api/system/health"] = {
            GET = SystemRoutes.get_health,
        },
        ["/api/system/reload"] = {
            POST = SystemRoutes.reload,
        },
        ["/api/system/exit"] = {
            POST = SystemRoutes.exit,
        },
        ["/api/system/clear-cache"] = {
            POST = SystemRoutes.clear_cache,
        },
        ["/api/system/network/interfaces"] = {
            GET = SystemRoutes.get_network_interfaces,
        },
        ["/api/system/network/hostname"] = {
            GET = SystemRoutes.get_hostname,
        },
        ["/api/env/astra"] = {
            GET = SystemRoutes.get_env_astra,
        },

        -- Subscribers
        ["/api/subscribers"] = {
            GET = SubscriberRoutes.get_subscribers,
            POST = SubscriberRoutes.subscribe,
            DELETE = SubscriberRoutes.unsubscribe,
        },

        -- Utils
        ["/api/utils/resource-stats"] = {
            GET = RoutesUtils.get_resource_stats,
        },
        ["/api/utils/channels/extended"] = {
            GET = RoutesUtils.get_channels_extended,
        },
        ["/api/utils/monitors/([^/]+)/errors"] = {
            GET = RoutesUtils.get_monitor_errors,
        },
        ["/api/utils/system/config"] = {
            GET = RoutesUtils.get_system_config,
        },
        ["/api/utils/check"] = {
            GET = RoutesUtils.check_object,
        },
        ["/api/utils/objects"] = {
            GET = RoutesUtils.get_all_objects,
        },
        ["/api/utils/cleanup"] = {
            POST = RoutesUtils.cleanup,
        },
        ["/api/utils/info"] = {
            GET = RoutesUtils.get_api_info,
        },
    }

    -- Преобразование в формат Astra http_server
    local routes = {}
    for pattern, methods in pairs(resources) do
        table.insert(routes, { pattern, make_resource_handler(methods) })
    end

    local ok, err = pcall(http_server, {
        addr = addr,
        port = port,
        server_name = "Astra Monitor API",
        route = routes
    })

    if ok then
        Logger.info(COMPONENT_NAME, "HTTP Server started on %s:%s", addr, tostring(port))
    else
        Logger.error(COMPONENT_NAME, "Failed to start HTTP Server: %s", tostring(err))
    end
end

return HttpServer
