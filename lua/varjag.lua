pidfile("/var/run/varjag.pid")
-- log.set({ debug = true, stdout = true, filename = "/var/log/astra/varjag.log" })
log.set({ debug = false, stdout = false })

make_channel({
  name = "Varjag",
  input =  { "http://217.21.34.252:12300/varjag",},
  output = { "udp://224.100.104.8:1234#sync&cbr=4",},
})
