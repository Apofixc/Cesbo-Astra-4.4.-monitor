package.path = "/opt/Cesbo-Astra-4.4.-monitor/lib-monitor/?.lua;;" .. package.path
local init = require("init_monitor")("/var/run/test2.pid")

server_start("0.0.0.0", 5001)

make_channel({name ="test2-name1", input = {"http://38.130.202.110/httpts/tv3by/avchigh.ts"}, output = {"udp://224.100.100.19:1237#sync&cbr=4"}})

make_channel({name ="test2-name2", input = {"http://33.130.202.110/httpts/tv3by/avchigh.ts"}, output = {"udp://224.100.100.19:1238#sync&cbr=4"}})

make_channel({name ="test2-name3", input = {"http://38.130.202.110/httpts/tv3by/avchigh.ts"}, output = {"udp://224.100.100.19:1239#sync&cbr=4"}})