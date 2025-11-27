
local l_ratio = m_ratio
local dvb_monitor_method_comparison = {
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
            l_ratio(status_signal.snr, data.snr) > rate or 
            status_signal.ber ~= data.ber or 
            status_signal.unc ~= data.unc then
                return true
        end

        return false
    end
}

local dvb_config = {}

function dvb_tuner_monitor(conf)
    if not conf.name_adapter then
        log.error("[dvb_tuner] name is not found")
        return
    end

    if _G[conf.name_adapter] or dvb_config[conf.name_adapter] then
        log.error("[dvb_tuner] tuner is found")
        return
    end

    conf.time_update = conf.time_update or 0
    conf.rate = conf.rate or 0.015
    conf.method_comparison = conf.method_comparison or 3

    local send = send_monitor
    local comparison = dvb_monitor_method_comparison[conf.method_comparison]
    
    local content = {
        type = "dvb",
        server = Get_server_name(),
        format = conf.type or "",
        modulation = conf.modulation or "",
        source = conf.tp or conf.frequency,
        name_adapter = conf.name_adapter,
        status = -1,
        signal = -1,
        snr = -1,
        ber = -1,
        unc = -1
    }

    local time = 0
    local status_signal = {}
    conf.callback = function(data)
        if time < conf.time_update then
            time = time + 1
            return
        end
        time = 0

        if comparison(status_signal, data, conf.rate) then
            content.status = data.status or -1
            content.signal = data.signal or -1
            content.snr = data.snr or -1
            content.ber = data.ber or -1
            content.unc = data.unc or -1

            send(json.encode(content))
        end
    end
    --hook из-за кривости init_dvb
    _G[conf.name_adapter] = dvb_tune(conf)

    if _G[conf.name_adapter] then
        dvb_config[conf.name_adapter] = conf
    end
end

function find_dvb_conf(name_adapter)
    for _, config in ipairs(dvb_config) do
        if config.name_adapter == name_adapter then
            return config
        end
    end
    return nil
end

function update_dvb_monitor_parameters(name_adapter, params)
    if not name_adapter or type(params) ~= 'table' then
        log.error("[update_dvb_monitor_parameters] name_adapter and params table are required")
        return nil
    end

    if dvb_config[name_adapter] then
        local conf = dvb_config[name_adapter]
        -- Обновляем только переданные параметры (если ключ есть в params, обновляем; иначе оставляем старые)
        if params.rate ~= nil and check(type(params.rate) == 'number' and params.rate >= 0.001 and params.rate <= 1, "params.rate must be between 0.001 and 1") then
            conf.rate = params.rate
        end
        if params.time_update ~= nil and check(type(params.time_update) == 'number' and params.time_update >= 0, "params.time_update must be non-negative") then
            conf.time_update = params.time_update
        end

        log.info("[update_dvb_monitor_parameters] Parameters updated successfully for monitor: " .. name_adapter)

        return true
    else
        log.error("[update_dvb_monitor_parameters] Monitor not found for name: " .. tostring(name_adapter))       
    end
end