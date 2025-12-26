local function safe_get_global(path, api_key_name)
    local parts = {}
    for part in string.gmatch(path, "[^%.]+") do
        table.insert(parts, part)
    end

    local current = _G
    for i, part in ipairs(parts) do
        if type(current) == "table" and current[part] ~= nil then
            current = current[part]
        else
            print("ERROR: Глобальная переменная или функция '" .. path .. "' (сопоставленная с " .. api_key_name .. ") не найдена. Выход.")
            _G.os.exit(1) -- Завершаем работу с кодом ошибки
        end
    end
    return current
end

local AstraAPI = {}

AstraAPI.find_channel = safe_get_global("find_channel", "AstraAPI.find_channel")
AstraAPI.make_channel = safe_get_global("make_channel", "AstraAPI.make_channel")
AstraAPI.kill_channel = safe_get_global("kill_channel", "AstraAPI.kill_channel")
AstraAPI.parse_url = safe_get_global("parse_url", "AstraAPI.parse_url")
AstraAPI.init_input = safe_get_global("init_input", "AstraAPI.init_input")
AstraAPI.http_request = safe_get_global("http_request", "AstraAPI.http_request")
AstraAPI.astra_version = safe_get_global("astra.version", "AstraAPI.astra_version")
AstraAPI.utils_hostname = safe_get_global("utils.hostname", "AstraAPI.utils_hostname")
AstraAPI.timer = safe_get_global("timer", "AstraAPI.timer")
AstraAPI.json_decode = safe_get_global("json.decode", "AstraAPI.json_decode")
AstraAPI.json_encode = safe_get_global("json.encode", "AstraAPI.json_encode")
AstraAPI.string_split = safe_get_global("string.split", "AstraAPI.string_split")
AstraAPI.os_exit = safe_get_global("os.exit", "AstraAPI.os_exit")
AstraAPI.astra_reload = safe_get_global("astra.reload", "AstraAPI.astra_reload")
AstraAPI.dvb_tune = safe_get_global("dvb_tune", "AstraAPI.dvb_tune")
AstraAPI.analyze = safe_get_global("analyze", "AstraAPI.analyze")
AstraAPI.kill_input = safe_get_global("kill_input", "AstraAPI.kill_input")
AstraAPI.io_popen = safe_get_global("io.popen", "AstraAPI.io_popen")
AstraAPI.table_insert = safe_get_global("table.insert", "AstraAPI.table_insert")
AstraAPI.os_time = safe_get_global("os.time", "AstraAPI.os_time")
AstraAPI.os_date = safe_get_global("os.date", "AstraAPI.os_date")
AstraAPI.channel_list = safe_get_global("channel_list", "AstraAPI.channel_list")

return AstraAPI
