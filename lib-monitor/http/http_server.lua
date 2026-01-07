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

--- Запускает HTTP сервер мониторинга
--- @param addr string|nil IP адрес для прослушивания
--- @param port number|nil Порт для прослушивания
function HttpServer.start(addr, port)
    addr = addr or DEFAULT_ADDR
    port = port or DEFAULT_PORT

    local routes = {
        -- Channels (Raw Astra Channels)
        { "/api/channels", ChannelRoutes.get_channels },
        { "/api/channels/stats", ChannelRoutes.get_channels_stats },
        { "/api/channels/create", ChannelRoutes.create_channel_raw },
        { "/api/channels/([^/]+)", ChannelRoutes.get_channel_info },
        { "/api/channels/([^/]+)/inputs", ChannelRoutes.get_channel_inputs },
        { "/api/channels/([^/]+)/psi/([^/]+)", ChannelRoutes.get_channel_psi },
        { "/api/channels/([^/]+)/psi", ChannelRoutes.get_channel_psi },
        { "/api/channels/([^/]+)/kill", ChannelRoutes.kill_channel_raw },
        
        -- Streams (Channels with automatic monitoring)
        { "/api/streams", ChannelRoutes.create_stream },
        { "/api/streams/([^/]+)/kill", ChannelRoutes.kill_stream },

        -- Monitors (Monitoring logic only)
        { "/api/monitors", MonitorRoutes.get_monitors },
        { "/api/monitors/status", MonitorRoutes.get_monitors_status },
        { "/api/monitors/create", MonitorRoutes.create_monitor },
        { "/api/monitors/([^/]+)/data", MonitorRoutes.get_monitor_data },
        { "/api/monitors/([^/]+)/update", MonitorRoutes.update_monitor },
        { "/api/monitors/([^/]+)/pause", MonitorRoutes.pause_monitor },
        { "/api/monitors/([^/]+)/resume", MonitorRoutes.resume_monitor },
        { "/api/monitors/([^/]+)/kill", MonitorRoutes.kill_monitor },
        { "/api/monitors/([^/]+)/pids", MonitorRoutes.get_monitor_pids },
        { "/api/monitors/([^/]+)/rate_stat", MonitorRoutes.get_monitor_rate_stat },
        { "/api/monitors/([^/]+)/pids/clear", MonitorRoutes.clear_monitor_pids },

        -- DVB Adapters
        { "/api/dvb/adapters", DvbRoutes.get_adapters },
        { "/api/dvb/adapters/monitor", DvbRoutes.get_monitored_adapters },
        { "/api/dvb/adapters/scan", DvbRoutes.scan_adapters },
        { "/api/dvb/adapters/([^/]+)/data", DvbRoutes.get_adapter_data },
        { "/api/dvb/adapters/([^/]+)/psi/([^/]+)", DvbRoutes.get_adapter_psi },
        { "/api/dvb/adapters/([^/]+)/psi", DvbRoutes.get_adapter_psi },
        { "/api/dvb/adapters/([^/]+)/psi/update", DvbRoutes.update_adapter_psi },
        { "/api/dvb/hardware/all", DvbRoutes.get_hardware_all },
        { "/api/dvb/adapters/([^/]+)/tune", DvbRoutes.tune_adapter },
        { "/api/dvb/adapters/([^/]+)/switch-transponder", DvbRoutes.switch_transponder },
        { "/api/adapters/([^/]+)/update", DvbRoutes.update_adapter },
        { "/api/dvb/adapters/([^/]+)/update", DvbRoutes.update_adapter },
        { "/api/dvb/adapters/([^/]+)/pause", DvbRoutes.pause_adapter },
        { "/api/dvb/adapters/([^/]+)/resume", DvbRoutes.resume_adapter },
        { "/api/dvb/adapters/([^/]+)/restart", DvbRoutes.restart_adapter },
        { "/api/dvb/adapters/([^/]+)/kill", DvbRoutes.stop_adapter },

        -- System & Env
        { "/api/env/astra", SystemRoutes.get_env_astra },
        { "/api/env/adapters", DvbRoutes.get_adapters }, -- Список всех адаптеров
        { "/api/system/resources", SystemRoutes.get_resources },
        { "/api/system/monitor-stats", SystemRoutes.get_monitor_stats },
        { "/api/system/health", SystemRoutes.get_health },
        { "/api/system/reload", SystemRoutes.reload },
        { "/api/system/exit", SystemRoutes.exit },
        { "/api/system/clear-cache", SystemRoutes.clear_cache },
        { "/api/system/network/interfaces", SystemRoutes.get_network_interfaces },
        { "/api/system/network/hostname", SystemRoutes.get_hostname },

        -- Subscribers
        { "/api/subscribers", SubscriberRoutes.get_subscribers },
        { "/api/subscribers/subscribe", SubscriberRoutes.subscribe },
        { "/api/subscribers/unsubscribe", SubscriberRoutes.unsubscribe },

        -- Utils
        { "/api/utils/resource-stats", RoutesUtils.get_resource_stats },
        { "/api/utils/channels/extended", RoutesUtils.get_channels_extended },
        { "/api/utils/monitors/([^/]+)/errors", RoutesUtils.get_monitor_errors },
        { "/api/utils/system/config", RoutesUtils.get_system_config },
        { "/api/utils/check", RoutesUtils.check_object },
        { "/api/utils/objects", RoutesUtils.get_all_objects },
        { "/api/utils/cleanup", RoutesUtils.cleanup },
        { "/api/utils/info", RoutesUtils.get_api_info },
    }

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
