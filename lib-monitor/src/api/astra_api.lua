local AstraAPI = {}

AstraAPI.find_channel = find_channel
AstraAPI.make_channel = make_channel
AstraAPI.kill_channel = kill_channel
AstraAPI.parse_url = parse_url
AstraAPI.init_input = init_input
AstraAPI.http_request = http_request
AstraAPI.astra_version = astra.version
AstraAPI.utils_hostname = utils.hostname
AstraAPI.timer = timer
AstraAPI.json_decode = json.decode
AstraAPI.json_encode = json.encode
AstraAPI.string_split = string.split
AstraAPI.os_exit = os.exit
AstraAPI.astra_reload = astra.reload
AstraAPI.dvb_tune = dvb_tune
AstraAPI.analyze = analyze
AstraAPI.kill_input = kill_input
AstraAPI.io_popen = io.popen
AstraAPI.table_insert = table.insert
AstraAPI.os_time = os.time
AstraAPI.os_date = os.date
AstraAPI.channel_list = channel_list

return AstraAPI
