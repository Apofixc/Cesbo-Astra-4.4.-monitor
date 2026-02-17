package.path = "/opt/Cesbo-Astra-4.4.-monitor/lib-monitor/?.lua;;" .. package.path
local init = require("init_monitor")("/var/run/varjag.pid")

server_start("0.0.0.0", 5005)

make_channel({
  name = "Varjag",
  input =  { "http://217.21.34.252:12300/varjag",},
  output = { "udp://224.100.104.8:1234#sync&cbr=4",},
})
