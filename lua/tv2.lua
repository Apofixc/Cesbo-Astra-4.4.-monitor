package.path = "/opt/Cesbo-Astra-4.4.-monitor/lib-monitor/?.lua;;" .. package.path
local init = require("init_monitor")("/var/run/tv2.pid")

server_start("0.0.0.0", 5004)

make_channel({
  name = "TV2",
  input =  { "http://217.21.34.252:12300/tv2",},
  output = { "udp://224.100.104.7:1234#sync&cbr=4",},
})
