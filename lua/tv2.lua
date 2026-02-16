package.path = "/opt/Cesbo-Astra-4.4.-monitor/lib-monitor/?.lua;;" .. package.path
-- name_pid, debug, filename, syslog, stdout
local init = require("init_monitor")("/var/run/tv2.pid", false, nil, nil, true)

server_start("0.0.0.0", 5003)

make_channel({
  name = "TV2",
  input =  { "http://217.21.34.252:12300/tv2",},
  output = { "udp://224.100.104.7:1234#sync&cbr=4",},
})
