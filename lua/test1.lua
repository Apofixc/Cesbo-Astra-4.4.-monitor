package.path = "/opt/Cesbo-Astra-4.4.-monitor/lib-monitor/?.lua;;" .. package.path
local init = require("init_monitor")()

server_start("0.0.0.0", 5000)

make_channel({name ="test1-name1", input = {"http://31.130.202.110/httpts/tv3by/avchigh.ts"}, output = {"udp://224.100.100.19:1234#sync&cbr=4"}})

make_channel({name ="test1-name2", input = {"http://33.130.202.110/httpts/tv3by/avchigh.ts"}, output = {"udp://224.100.100.19:1235#sync&cbr=4"}})

make_channel({name ="test1-name3", input = {"http://32.130.202.110/httpts/tv3by/avchigh.ts"}, output = {"udp://224.100.100.19:1236#sync&cbr=4"}})