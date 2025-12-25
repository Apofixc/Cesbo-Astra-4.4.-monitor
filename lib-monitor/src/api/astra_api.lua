local AstraAPI = {}

AstraAPI.find_channel = _G.find_channel
AstraAPI.make_channel = _G.make_channel
AstraAPI.kill_channel = _G.kill_channel
AstraAPI.parse_url = _G.parse_url
AstraAPI.init_input = _G.init_input
AstraAPI.http_request = _G.http_request
AstraAPI.astra_version = _G.astra.version
AstraAPI.utils_hostname = _G.utils.hostname
AstraAPI.timer = _G.timer
AstraAPI.json_decode = _G.json.decode
AstraAPI.json_encode = _G.json.encode
AstraAPI.string_split = _G.string.split
AstraAPI.os_exit = _G.os.exit
AstraAPI.astra_reload = _G.astra.reload
AstraAPI.dvb_tune = _G.dvb_tune
AstraAPI.analyze = _G.analyze
AstraAPI.kill_input = _G.kill_input
AstraAPI.io_popen = _G.io.popen
AstraAPI.table_insert = _G.table.insert
AstraAPI.os_time = _G.os.time
AstraAPI.os_date = _G.os.date
AstraAPI.channel_list = _G.channel_list

return AstraAPI
