local http_server = http_server
local log_info    = log.info

local channel_routes = require "http.routes.channel_routes"
local dvb_routes = require "http.routes.dvb_routes"
local system_routes = require "http.routes.system_routes"
local ResourceAdapter = require "adapters.resource_adapter"

--- Запускает HTTP-сервер мониторинга.
-- @param string addr IP-адрес, на котором будет слушать сервер.
-- @param number port Порт, на котором будет слушать сервер.
local resource_adapter_instance = nil

function server_start(addr, port)
    resource_adapter_instance = ResourceAdapter:new("system_monitor")
    http_server({
        addr = addr,
        port = port,
        route = {
            -- Channel Routes
            {"/api/channels/streams/kill", channel_routes.kill_stream},
            {"/api/channels/kill", channel_routes.kill_channel},
            {"/api/channels/monitors/kill", channel_routes.kill_monitor},
            {"/api/channels/monitors/update", channel_routes.update_channel_monitor},
            {"/api/channels", channel_routes.create_channel},
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
            {"/api/system/resources", system_routes.get_resourcesnd}
        }
    })
    log_info(string.format("[Server] Started on %s:%d", addr, port))
end
