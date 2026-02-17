package.path = "/opt/Cesbo-Astra-4.4.-monitor/lib-monitor/?.lua;;" .. package.path
local init = require("init_monitor")("/var/run/test3.pid")

server_start("0.0.0.0", 5002)


make_channel({name ="test3-name1", input = {"http://38.130.202.110/httpts/tv3by/avchigh.ts"}, output = {"udp://224.100.100.19:1240#sync&cbr=4"}})

make_channel({name ="test3-name2", input = {"http://33.130.202.110/httpts/tv3by/avchigh.ts"}, output = {"udp://224.100.100.19:1241#sync&cbr=4", "udp://224.100.100.19:2241#sync&cbr=4", "udp://224.100.100.19:3241#sync&cbr=4", "udp://224.100.100.19:4241#sync&cbr=4", "udp://224.100.100.19:5241#sync&cbr=4"}})

make_channel({name ="test3-name3", input = {"http://38.130.202.110/httpts/tv3by/avchigh.ts"}, output = {"udp://224.100.100.19:12342#sync&cbr=4"}})