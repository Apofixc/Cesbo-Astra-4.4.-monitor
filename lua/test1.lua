package.path = "/opt/Cesbo-Astra-4.4.-monitor/lib-monitor/?.lua;;" .. package.path
local init = require("init_monitor")

server_start("0.0.0.0", 5000)
