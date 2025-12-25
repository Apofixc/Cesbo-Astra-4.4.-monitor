local function ratio(op1, op2)
    local div1 = op1
    local div2 = op2
    if div1 == 0 or div1 == nil then div1 = 1 end
    if div2 == 0 or div2 == nil then div2 = 1 end

    local result = div1 / div2
    return result < 1 and (1 - result) or (result - 1)
end

MONITORING = {}

local sources = {}
local localization = {}
local hostname = utils.hostname()
local server_port 

---@param source table
function MONITORING.set_source(source)
    if not source or #source == 0 then
        log.error("[set_source] source is not found")
        return nil        
    end

    for ip, name in pairs(source) do
        sources[ip] = name
    end
end

---@param loc table
function MONITORING.set_localization(loc)
    if not loc or #loc == 0 then
        log.error("[set_localization] localization is not found")
        return nil        
    end

    for name, loc_name in pairs(loc) do
        localization[name] = loc_name
    end
end

---@param server_name string
function MONITORING.set_server_name(server_name)
    hostname = server_name
end

--  oooooooo8 ooooooooooo oooo   oooo ooooooooo  
-- 888         888    88   8888o  88   888    88o
--  888oooooo  888ooo8     88 888o88   888    888
--         888 888    oo   88   8888   888    888
-- o88oooo888 o888ooo8888 o88o    88  o888ooo88  

local clients = {}

---@param host string
---@param port number
---@param path string
function MONITORING.set_client(host, port, path)
    for _, client in ipairs(clients) do
        if client.host == host and client.port == port and client.path == path then
            log.error("[set_client] client is found")
            return
        end
    end

    table.insert(clients, {host = host, port = port, path = path})
end

---@param host string
---@param port number
---@param path string
function MONITORING.delete_client(host, port, path)
    for key, client in ipairs(clients) do
        if client.host == host and client.port == port and client.path == path then
            table.remove(clients, key)
            return
        end
    end

    log.error("[delete_client] client is not found")
end

local function send_monitor(content)
    if #clients > 0 then
        for i = 1, #clients do
            http_request({
                host = clients[i].host,
                path = clients[i].path,
                method = "POST",
                content = content,
                port = clients[i].port,
                headers = {
                    "User-Agent: Astra v." .. astra.version,
                    "Host: " .. clients[i].host,
                    "Content-Type: application/json;charset=utf-8",
                    "Content-Length: " .. #content,
                    "Connection: close",
                },
                callback = function(s,r)
                end
            })
        end
    else
        print(content)
    end
end

-- ooooooooo  ooooo  oooo oooooooooo
--  888    88o 888    88   888    888
--  888    888  888  88    888oooo88
--  888    888   88888     888    888
-- o888ooo88      888     o888ooo888

local dvb_config = {}

local dvb_monitor_update = {
    function() -- для совместимости
        return true
    end,
    function(status_signal, data) -- по любому измнению параметров
        if status_signal.status ~= data.status or 
            status_signal.signal ~= data.signal or 
            status_signal.snr ~= data.snr or 
            status_signal.ber ~= data.ber or 
            status_signal.unc ~= data.unc then
                return true
        end

        return false
    end,
    function(status_signal, data, rate) -- по любому измнению параметров, с учетом погрешности 
        if status_signal.status ~= data.status or 
            status_signal.signal ~= data.signal or 
            ratio(status_signal.snr, data.snr) > rate or 
            status_signal.ber ~= data.ber or 
            status_signal.unc ~= data.unc then
                return true
        end

        return false
    end
}

---@param conf table
function MONITORING.dvb_tune(conf)
    if not conf.name then
        log.error("[dvb_tune] name is not found")
        return
    end

    if _G[conf.name] or dvb_config[conf.name] then
        log.error("[dvb_tune] tuner is found")
        return
    end

    conf.update = conf.update or 0
    conf.rate = conf.rate or 0.015

    local time = 0
    local func_update = dvb_monitor_update[conf.type_update] or dvb_monitor_update[3]
    local template = '{"type":"dvb","server":"' .. hostname ..
        '","format":"' .. conf.type .. 
        '","source":"' .. (conf.tp or conf.frequency) ..
        '","name":"' .. conf.name .. '",'

    if conf.short_message then
        conf.id = base64.encode(conf.name)
        conf.template = template .. '"id_channel":"' .. conf.id .. '"}'

        send_monitor(conf.template)
        
        template = '{"id_channel":"' .. conf.id .. '",'
    end

    local status_signal = {}
    conf.callback = function(data)
        if time < conf.update then
            time = time + 1
            return
        end
        time = 0

        if func_update(status_signal, data, conf.rate) then
            local content = template .. '"status":' .. (data.status or -1) ..
                ',"signal":' .. (data.signal or -1) ..
                ',"snr":' .. (data.snr or -1) ..
                ',"ber":' .. (data.ber or -1) ..
                ',"unc":' .. (data.unc or -1) ..
                ',"control_port":' .. (server_port or -1) .. '}'

            send_monitor(content)

            status_signal.status = data.status
            status_signal.signal = data.signal
            status_signal.snr = data.snr
            status_signal.ber = data.ber
            status_signal.unc = data.unc
        end
    end
    --hook из-за кривости init_dvb
    _G[conf.name] = dvb_tune(conf)
    dvb_config[conf.name] = conf
end

--      o      oooo   oooo     o      ooooo    ooooo  oooo ooooooooooo ooooooooooo
--     888      8888o  88     888      888       888  88   88    888    888    88
--    8  88     88 888o88    8  88     888         888         888      888ooo8
--   8oooo88    88   8888   8oooo88    888      o  888       888    oo  888    oo
-- o88o  o888o o88o    88 o88o  o888o o888ooooo88 o888o    o888oooo888 o888ooo8888

local analyze_list_channel = {}

local get_upstream = {
    input = function(instance, conf) -- мониторинг первого input
        local channel_data = find_channel("name", conf.name)

        if channel_data and not channel_data.input[1].analyze then
            return channel_data.input[1].input.tail:stream() 
        end

        log.error("[get_upstream] input-upstream is not create")
        return nil
    end,
    output = function(instance, conf) -- мониторинг output
        local channel_data = find_channel("name", conf.name)

        if channel_data then
            return channel_data.tail:stream()
        end

        log.error("[get_upstream] output-upstream is not create")
        return nil
    end,
    new_instance = function(instance, conf) -- мониторинг новый экземпляр
        instance.input = init_input(conf)

        if instance.input then
            return instance.input.tail:stream()
        end

        log.error("[get_upstream] new_instance-upstream is not create")
        return nil
    end
}

local channel_monitor_update = {
    function(instance) -- по времени
        return true
    end,
    function(status, data) -- по любому измнению параметров
        if status.on_air ~= data.on_air or 
            status.scrambled ~= data.total.scrambled or 
            status.cc_error ~= status.total_cc_error or 
            status.pes_error ~= status.total_pes_error or 
            status.bitrate ~= data.total.bitrate then
                return true
        end

        return false
    end,
    function(status, data, rate) -- по любому измнению параметров, с учетом погрешности
        if status.on_air ~= data.on_air or 
            status.scrambled ~= data.total.scrambled or 
            status.cc_error ~= status.total_cc_error or 
            status.pes_error ~= status.total_pes_error or 
            ratio(status.bitrate, data.total.bitrate) > rate then
                return true
        end

        return false
    end
}

---@param monitor_data table
function MONITORING.make_monitor(monitor_data)
    if not monitor_data.name then
        log.error("[make_monitor] name is required")
        return nil
    end

    if analyze_list_channel[monitor_data.name] then
        log.error("[make_monitor] monitor is found")
        return nil
    end

    if not get_upstream[monitor_data.source_upstream] then
        log.error("[make_monitor] get_upstream is not found")
        return nil
    end

    local instance = {}
    instance.monitor_data = monitor_data
    instance.update = type(monitor_data.update) == "number" and monitor_data.update or 0
    instance.total = type(monitor_data.total) == "boolean" and monitor_data.total or true
    instance.rate = type(monitor_data.rate) == "number" and monitor_data.rate or 0.035

    local template  = '"server":"' .. hostname ..
            '","channel":"' .. monitor_data.name ..
            '","loc_name":"' .. (localization[monitor_data.name] or "") ..
            '","stream":"' .. monitor_data.stream ..
            '","output":"' .. monitor_data.output .. '",'

    if monitor_data.short_message then
        instance.id = base64.encode(monitor_data.name)
        instance.template = '{"type":"channel",' .. template .. '"id_channel":"' .. instance.id .. '"}'

        send_monitor(instance.template)

        template = '{"id_channel":"' .. instance.id .. '",'
    else
        template = '{"type":"channel",' .. template
    end

    local time = 0
    local status = {}
    local func_update = channel_monitor_update[monitor_data.method_update] or channel_monitor_update[3]
    instance.analyze = analyze({
        upstream = get_upstream[monitor_data.source_upstream](instance, monitor_data.conf),
        name = "_" .. monitor_data.name,
        callback = function(data)
            if data.error then
                local content = template .. '"error":"' .. data.error .. '"}'
                send_monitor(content)
            elseif data.psi then

            elseif instance.total and data.total then
                --Считаем общее количество ошибок между передачами данных
                status.total_cc_error = (status.total_cc_error or 0) + (data.total.cc_error or 0)
                status.total_pes_error = (status.total_pes_error or 0) + (data.total.pes_error or 0)

                if time < instance.update then
                    time = time + 1
                    return
                end
                time = 0

                if func_update(status, data, instance.rate) then
                    local content = template .. '"total":true,' ..
                        '"scrambled":'.. (data.total.scrambled and 1 or 0) ..
                        ',"bitrate":'.. (data.total.bitrate or 0) ..
                        ',"cc_error":'.. status.total_cc_error ..
                        ',"pes_error":'.. status.total_pes_error ..
                        ',"ready":'.. (data.on_air and 1 or 0) .. 
                        ',"control_port":' .. (server_port or -1) ..'}'
                    send_monitor(content)

                    status.on_air = data.on_air    
                    status.scrambled = data.total.scrambled
                    status.bitrate = data.total.bitrate
                    status.cc_error = status.total_cc_error
                    status.pes_error = status.total_pes_error
                    --Обнуляем счетчик
                    status.total_cc_error = 0
                    status.total_pes_error = 0
                end
            elseif data.analyze then
                if time < instance.update then
                    time = time + 1
                    return 
                end
                time = 0
                
                local content = template .. '"total":false,'
                for id, status in pairs(data.analyze) do
                    content = content .. '"' .. id .. '":{'

                    local count = 5
                    for key, stat in pairs(status) do
                        count = count - 1
                        content = count == 0 and content .. '"' .. key .. '":"' .. stat .. '"' or content .. '"' .. key .. '":"' .. stat .. '",'
                    end
                    content = id == #data.analyze and content .. "}" or content .. "},"
                end
                content = content .. '}'

                send_monitor(content)
            end
        end
    })

    if instance.analyze then 
        analyze_list_channel[monitor_data.name] = instance 
    end
end

---@param name_channel string
---@return table|nil
local function kill_monitor(name_channel)
    local instance = analyze_list_channel[name_channel]
    if instance then 
        local monitor_data = instance.monitor_data

        instance.monitor_data = nil
        instance.analyze  =  nil

        if instance.input then
            kill_input(instance.input)
            instance.input = nil
        end

        instance.update = nil
        instance.total = nil
        instance.rate = nil
        instance.id = nil
        instance.template = nil
        instance.psi = nil

        analyze_list_channel[name_channel] = nil

        collectgarbage()

        return monitor_data
    end

    return nil
end

--   oooooooo8 ooooo ooooo      o      oooo   oooo oooo   oooo ooooooooooo ooooo
-- o888     88  888   888      888      8888o  88   8888o  88   888    88   888
-- 888          888ooo888     8  88     88 888o88   88 888o88   888ooo8     888
-- 888o     oo  888   888    8oooo88    88   8888   88   8888   888    oo   888      o
--  888oooo88  o888o o888o o88o  o888o o88o    88  o88o    88  o888ooo8888 o888ooooo88

---@param conf table
function MONITORING.make_stream(conf)
    if not conf then 
        log.error("([make_stream] configuration is required")
        return nil
    end

    local base_monitor_data = conf.base_monitor_data or {}
    conf.base_monitor_data = nil
    
    if base_monitor_data.analyze_input ~= true or base_monitor_data.source_upstream == "input" then
        if not conf.input or #conf.input == 0 then
            log.error("[make_stream] option 'input' is required")
            return nil 
        end

        for i=2, #conf.input do
            conf.input[i] = nil
        end
        
        if not string.find(conf.input[1], "no_analyze") then
            if string.find(conf.input[1], "#") then
                conf.input[1] = conf.input[1] .. "&no_analyze"
            else
                conf.input[1] = conf.input[1] .. "#no_analyze"
            end
        end
    end

    local channel_data = make_channel(conf)
    if channel_data then
        if not base_monitor_data.source_upstream then 
            base_monitor_data.source_upstream = "new_instance"
        end
        
        if (not conf.output or #conf.output == 0) and base_monitor_data.source_upstream == "new_instance" then
            log.error("([make_stream] output > 0 is required")
            return nil
        end

        local input_data = parse_url(conf.input[1])

        local config_upstream, output
        if base_monitor_data.source_upstream == "new_instance" then
            config_upstream = parse_url(conf.output[1])

            local n = string.find(conf.output[1], "#")
            output = string.sub(conf.output[1], 1, n and n - 1 or nil)
        else
            config_upstream = {}

            if base_monitor_data.source_upstream == "input" then
                output = "input"
            else
                local temp = {}
                for i = 1, #conf.output do
                    local n = string.find(conf.output[i], "#")
                    temp[i] = string.sub(conf.output[i], 1, n and n - 1 or nil)
                end
                output = "output (" .. table.concat(temp, ",") .. ")"
            end
        end
        config_upstream.name = conf.name

        MONITORING.make_monitor({
            name = conf.name,
            stream = sources[input_data.addr] or input_data.addr or sources[input_data.host] or input_data.host or input_data.filename,
            conf = config_upstream,
            output = output,
            source_upstream = base_monitor_data.source_upstream,
            rate = base_monitor_data.rate,
            update = base_monitor_data.update,
            total = base_monitor_data.total,
            short_message = base_monitor_data.short_message,
            method_update = base_monitor_data.method_update
        })
    end
end

---@param channel_data table
---@return table
local function kill_stream(channel_data)
    local channel_info = {}

    channel_info.conf = channel_data.config

    local name =  channel_info.conf.name
    if analyze_list_channel[name] and not analyze_list_channel[name].input then
        channel_info.monitor_data = kill_monitor(name)
    end

    kill_channel(channel_data)

    collectgarbage()    

    return channel_info
end

--  oooooooo8 ooooooooooo oooooooooo ooooo  oooo ooooooooooo oooooooooo 
-- 888         888    88   888    888 888    88   888    88   888    888
--  888oooooo  888ooo8     888oooo88   888  88    888ooo8     888oooo88 
--         888 888    oo   888  88o     88888     888    oo   888  88o  
-- o88oooo888 o888ooo8888 o888o  88o8    888     o888ooo8888 o888o  88o8


local function control_channel(server, client, request)
    if not request then return nil end

    if request.query then
        local name_channel = request.query.channel

        local channel_data = find_channel("name", name_channel)
        if channel_data then 
            local channel_info = kill_stream(channel_data)
            log.info("[Channel]: " .. name_channel .. "was kill")

            local reboot = request.query.reboot
            if reboot and string.lower(reboot) == "true" then
                timer({
                    interval = 5,
                    callback = function(self)
                        self:close()

                        make_channel(channel_info.conf)
                        if channel_info.monitor_data then
                            MONITORING.make_monitor(channel_info.monitor_data)
                        end
                        log.info("[Channel]: " .. name_channel .. "was reboot")
                    end
                })
            end

            server:abort(client, 200)        
        else
            server:abort(client, 404)      
        end
    else
        server:abort(client, 405)
    end
end

local function control_monitor(server, client, request)
    if not request then return nil end

    if request.query then
        local name_channel = request.query.channel

        local monitor_data = kill_monitor(name_channel)
        if monitor_data then 
            log.info("[Monitor]: " .. name_channel .. "was kill")

            local reboot = request.query.reboot
            if reboot and string.lower(reboot) == "true" then
                timer({
                    interval = 5,
                    callback = function(self)
                        self:close()

                        MONITORING.make_monitor(monitor_data)
                        log.info("[Monitor]: " .. name_channel .. "was reboot")
                    end
                })
            end

            server:abort(client, 200)
        else
            server:abort(client, 404)
        end
    else
        server:abort(client, 405)
    end
end

local function update_monitor_channel(server, client, request)
    if not request then return nil end

    if request.query then
        local name_channel = request.query.channel
        local instance = analyze_list_channel[name_channel]
        if instance then 
            local total = request.query.total
            if total then
                instance.total =  string.lower(total) == "true" and true or false
                log.info("[Monitor]: Parameter 'total' channel '" .. name_channel .. "' was set to '" .. instance.total .. "'")
            end

            local update = request.query.update
            if update and tonumber(update) >= 0 then
                instance.update = tonumber(update)
                log.info("[Monitor]: Parameter 'update' channel '" .. name_channel .. "' was set to '" .. instance.update .. "'")
            end

            local rate = request.query.rate
            if rate and tonumber(rate) >= 0 then
                instance.rate = tonumber(rate)
                log.info("[Monitor]: Parameter 'rate' channel '" .. name_channel .. "' was set to '" .. instance.rate .. "'")
            end

            server:abort(client, 200)
        else
            server:abort(client, 404)
        end
    else
        server:abort(client, 405)
    end
end

local function get_template_channel(server, client, request)
    if not request then return nil end

    if request.query then
        local id = request.query.id

        local template
        for _, instance in pairs(analyze_list_channel) do
            if instance.id == id then
                template = instance.template
                break
            end
        end

        if template then
            server:send(client, {
                code = 200,
                headers =
                {
                    "User-Agent: Astra v." .. astra.version,
                    "Content-Type: application/json;charset=utf-8",
                    "Content-Length: " .. #template,
                    "Connection: close",
                },
                content = template,
            })
        else
            server:abort(client, 404)
        end
    else
        server:abort(client, 405)
    end
end

local function get_psi_channel(server, client, request)
    if not request then return nil end

    if request.query then
        local name_channel = request.query.channel

        if analyze_list_channel[name_channel] then
            local psi = analyze_list_channel[name_channel].psi

            server:send(client, {
                code = 200,
                headers =
                {
                    "User-Agent: Astra v." .. astra.version,
                    "Content-Type: application/json;charset=utf-8",
                    "Content-Length: " .. #psi,
                    "Connection: close",
                },
                content = psi,
            })
        else
            server:abort(client, 404)
        end
    else
        server:abort(client, 405)
    end
end

local function update_monitor_dvb(server, client, request)
    if not request then return nil end

    if request.query then
        local name = request.query.name
        local conf = dvb_config[name]
        if conf then 
            local update = request.query.update
            if update and tonumber(update) >= 0 then
                conf.update = tonumber(update)
                log.info("[Monitor_dvb]: Parameter 'update' dvb adapter '" .. name .. "' was set to '" .. conf.update .. "'")
            end

            local rate = request.query.rate
            if rate and tonumber(rate) >= 0 then
                conf.rate = tonumber(rate)
                log.info("[Monitor_dvb]: Parameter 'rate' dvb adapter '" .. name .. "' was set to '" .. conf.rate .. "'")
            end

            server:abort(client, 200)
        else
            server:abort(client, 404)
        end
    else
        server:abort(client, 405)
    end
end

local function get_template_dvb(server, client, request)
    if not request then return nil end

    if request.query then
        local id = request.query.id

        local template
        for _, conf in pairs(dvb_config) do
            if conf.id == id then
                template = conf.template
                break
            end
        end

        if template then
            server:send(client, {
                code = 200,
                headers =
                {
                    "User-Agent: Astra v." .. astra.version,
                    "Content-Type: application/json;charset=utf-8",
                    "Content-Length: " .. #template,
                    "Connection: close",
                },
                content = template,
            })
        else
            server:abort(client, 404)
        end
    else
        server:abort(client, 405)
    end
end

local function reload_astra(server, client, request)
    if not request then return nil end

    timer({
        interval = 5,
        callback = function(self)
            self:close()

            log.info("[Astra]: reload")            
            astra.reload()
        end
    })

    server:abort(client, 200)
end

local function kill_astra(server, client, request)
    if not request then return nil end

    timer({
        interval = 5,
        callback = function(self)
            self:close()

            log.info("[Kill_astra]: Astra was stop")
            os.exit()
        end
    })

    server:abort(client, 200)
end

---@param port number
function MONITORING.server_start(port)
    http_server({
        addr = "127.0.0.1",
        port = port,
        route = {
            { "/control_channel", control_channel },
            { "/control_monitor", control_monitor },
            { "/update_monitor_channel", update_monitor_channel },
            { "/template_channel", get_template_channel },
            { "/get_psi_channel", get_psi_channel },
            { "/update_monitor_dvb", update_monitor_dvb },
            { "/template_dvb", get_template_dvb },
            { "/reload", reload_astra },
            { "/exit", kill_astra }
        }
    })

    server_port = port
end