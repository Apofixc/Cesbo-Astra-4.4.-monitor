local http_server = http_server
local log_info    = log.info

local channel_routes = require "http.routes.channel_routes"
local dvb_routes = require "http.routes.dvb_routes"
local system_routes = require "http.routes.system_routes"

--- Запускает HTTP-сервер мониторинга.
-- @param string addr IP-адрес, на котором будет слушать сервер.
-- @param number port Порт, на котором будет слушать сервер.
function server_start(addr, port)
    http_server({
        addr = addr,
        port = port,
        route = {
            {"/api/control_kill_stream", channel_routes.control_kill_stream},
            {"/api/control_kill_channel", channel_routes.control_kill_channel},
            {"/api/control_kill_monitor", channel_routes.control_kill_monitor},
            {"/api/update_monitor_channel", channel_routes.update_monitor_channel},
            {"/api/create_channel", channel_routes.create_channel},
            {"/api/get_channel_list", channel_routes.get_channel_list},
            {"/api/get_monitor_list", channel_routes.get_monitor_list},
            {"/api/get_monitor_data", channel_routes.get_monitor_data},
            {"/api/get_psi_channel", channel_routes.get_psi_channel},
            {"/api/get_adapter_list", dvb_routes.get_adapter_list},
            {"/api/get_adapter_data", dvb_routes.get_adapter_data},
            {"/api/update_monitor_dvb", dvb_routes.update_monitor_dvb},
            {"/api/reload", system_routes.astra_reload},
            {"/api/exit", system_routes.kill_astra},
            {"/api/health", system_routes.health}
        }
    })
    log_info(string.format("[Server] Started on %s:%d", addr, port))
end
