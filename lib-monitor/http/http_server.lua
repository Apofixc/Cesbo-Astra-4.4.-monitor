local AstraAPI = require "../../src/api/astra_api"

local http_server = AstraAPI.http_server
local Logger      = require "../src/utils/logger"
local log_info    = Logger.info

local channel_routes = require "./routes/channel_routes"
local dvb_routes = require "./routes/dvb_routes"
local system_routes = require "./routes/system_routes"
local ResourceMonitor = require "../../src/system/resource_monitor"

--- Запускает HTTP-сервер мониторинга.
-- @param string addr IP-адрес, на котором будет слушать сервер.
-- @param number port Порт, на котором будет слушать сервер.
function server_start(addr, port)
    log_info(string.format("[Server] Type of system_routes: %s", type(system_routes)))
    http_server({
        addr = addr,
        port = port,
        route = {
            -- Channel Routes
            {"/api/channels/streams/kill", channel_routes.kill_stream},
            {"/api/channels/kill", channel_routes.kill_channel},
            {"/api/channels/monitors/kill", channel_routes.kill_monitor},
            {"/api/channels/monitors/update", channel_routes.update_channel_monitor},
            {"/api/channels", channel_routes.get_channels},
            {"/api/channels/monitors", channel_routes.get_channel_monitors},
            {"/api/channels/monitors/data", channel_routes.get_channel_monitor_data},
            {"/api/channels/psi", channel_routes.get_channel_psi},
            
            -- DVB Routes
            {"/api/dvb/adapters", dvb_routes.get_adapters},
            {"/api/dvb/adapters/data", dvb_routes.get_adapter_data},
            {"/api/dvb/adapters/monitors/update", dvb_routes.update_dvb_monitor},
            
            -- System Routes
            {"/api/system/reload", system_routes.astra_reload},
            {"/api/system/exit", system_routes.kill_astra},
            {"/api/system/health", system_routes.health},
            {"/api/system/resources", system_routes.get_system_resources},
            {"/api/system/monitor-stats", system_routes.get_monitor_stats},
            {"/api/system/clear-cache", system_routes.clear_monitor_cache},
            {"/api/system/set-cache-interval", system_routes.set_monitor_cache_interval},
        }
    })
    log_info(string.format("[Server] Started on %s:%d", addr, port))
end
