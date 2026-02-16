package.path = "/opt/Cesbo-Astra-4.4.-monitor/lib-monitor/?.lua;;" .. package.path
local init = require("init_monitor")()

server_start("0.0.0.0", 5003)

make_channel({
  name = "TV3",
  input =  {"http://31.130.202.110/httpts/tv3by/avchigh.ts",},
  output = { "udp://224.100.100.20:1234#sync&cbr=4",},
})
