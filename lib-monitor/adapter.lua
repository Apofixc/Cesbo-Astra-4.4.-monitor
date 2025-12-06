-- ===========================================================================
-- Оптимизации: Кэширование функций
-- ===========================================================================

local type = type
local log_info = log.info
local log_error = log.error
local json_encode = json.encode

local ratio = ratio

-- ===========================================================================
-- Константы и конфигурация
-- ===========================================================================

local dvb_monitor_method_comparison = {
    function() -- для совместимости
        return true
    end,
    function(prev, curr) -- по любому измнению параметров
        if prev.status ~= curr.status or 
            prev.signal ~= curr.signal or 
            prev.snr ~= curr.snr or 
            prev.ber ~= curr.ber or 
            prev.unc ~= curr.unc then
                return true
        end

        return false
    end,
    function(prev, curr, rate) -- по любому измнению параметров, с учетом погрешности 
        if prev.status ~= curr.status or 
            ratio(prev.signal, curr.signal) > rate or 
            ratio(prev.snr, curr.snr) > rate or 
            prev.ber ~= curr.ber or 
            prev.unc ~= curr.unc then
                return true
        end

        return false
    end
}

-- ===========================================================================
-- Основные функции модуля
-- ===========================================================================

local dvb_config = {}

function get_list_adapter()
    return dvb_config
end

function dvb_tuner_monitor(conf)
    if not conf.name_adapter then
        log_error("[dvb_tuner] name is not found")
        return
    end

    if _G[conf.name_adapter] or dvb_config[conf.name_adapter] then
        log_error("[dvb_tuner] tuner is found")
        return
    end

    conf.time_check = conf.time_check or 10
    conf.rate = conf.rate or 0.015
    conf.method_comparison = conf.method_comparison or 3

    local send = send_monitor
    local comparison = dvb_monitor_method_comparison[conf.method_comparison]
    
    local status_signal = {
        type = "dvb",
        server = get_server_name(),
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
    conf.callback = function(data)
        if time < conf.time_check then
            time = time + 1
            return
        end
        time = 0

        if comparison(status_signal, data, conf.rate) then
            status_signal.status = data.status or -1
            status_signal.signal = data.signal or -1
            status_signal.snr = data.snr or -1
            status_signal.ber = data.ber or -1
            status_signal.unc = data.unc or -1

            send(json_encode(status_signal), "dvb")
        end
    end

    --hook из-за кривости init_dvb
    local instance = dvb_tune(conf)
    _G[conf.name_adapter] = instance

    if _G[conf.name_adapter] then
        dvb_config[conf.name_adapter] = {
            instance = instance,
            status_signal = status_signal
        }

        return instance
    end
end

function find_dvb_conf(name_adapter)
    return dvb_config[name_adapter].instance
end

function update_dvb_monitor_parameters(name_adapter, params)
    if not name_adapter or type(params) ~= 'table' then
        log_error("[update_dvb_monitor_parameters] name_adapter and params table are required")
        return nil
    end

    if dvb_config[name_adapter] then
        local conf = dvb_config[name_adapter].instance
        -- Обновляем только переданные параметры (если ключ есть в params, обновляем; иначе оставляем старые)
        if params.rate ~= nil and check(type(params.rate) == 'number' and params.rate >= 0.001 and params.rate <= 1, "params.rate must be between 0.001 and 1") then
            conf.rate = params.rate
        end
        if params.time_check ~= nil and check(type(params.time_check) == 'number' and params.time_check >= 0, "params.time_check must be non-negative") then
            conf.time_check = params.time_check
        end

        log_info("[update_dvb_monitor_parameters] Parameters updated successfully for monitor: " .. name_adapter)

        return true
    else
        log_error("[update_dvb_monitor_parameters] Monitor not found for name: " .. name_adapter)       
    end
end