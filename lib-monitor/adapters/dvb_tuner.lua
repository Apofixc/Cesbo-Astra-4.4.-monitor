-- ===========================================================================
-- DvbTunerMonitor Class
-- ===========================================================================

local type = type
local log_info = log.info
local log_error = log.error
local json_encode = json.encode

local ratio = ratio
local get_server_name = get_server_name
local send_monitor = send_monitor
local check = check

local dvb_tune = dvb_tune -- Предполагается, что эта функция глобально доступна или будет передана

local DvbTunerMonitor = {}
DvbTunerMonitor.__index = DvbTunerMonitor

-- Методы сравнения для DVB-монитора
local dvb_monitor_method_comparison = {
    [1] = function() -- для совместимости
        return true
    end,
    [2] = function(prev, curr) -- по любому измнению параметров
        if prev.status ~= curr.status or 
            prev.signal ~= curr.signal or 
            prev.snr ~= curr.snr or 
            prev.ber ~= curr.ber or 
            prev.unc ~= curr.unc then
                return true
        end
        return false
    end,
    [3] = function(prev, curr, rate) -- по любому измнению параметров, с учетом погрешности 
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

--- Конструктор для DvbTunerMonitor.
-- @param table conf Таблица конфигурации для DVB-тюнера.
-- @return DvbTunerMonitor Новый экземпляр DvbTunerMonitor.
function DvbTunerMonitor:new(conf)
    local self = setmetatable({}, DvbTunerMonitor)
    self.conf = conf
    self.conf.time_check = self.conf.time_check or 10
    self.conf.rate = self.conf.rate or 0.015
    self.conf.method_comparison = self.conf.method_comparison or 3

    self.status_signal = {
        type = "dvb",
        server = get_server_name(),
        format = self.conf.type or "",
        modulation = self.conf.modulation or "",
        source = self.conf.tp or self.conf.frequency,
        name_adapter = self.conf.name_adapter,
        status = -1,
        signal = -1,
        snr = -1,
        ber = -1,
        unc = -1
    }
    self.time = 0
    self.json_cache = nil
    self.instance = nil -- Экземпляр dvb_tune

    return self
end

--- Запускает мониторинг DVB-тюнера.
-- @return userdata Экземпляр DVB-тюнера, если инициализация прошла успешно, иначе nil.
function DvbTunerMonitor:start()
    local comparison_method = dvb_monitor_method_comparison[self.conf.method_comparison]
    local self_ref = self -- Сохраняем ссылку на self для использования в замыкании

    self.conf.callback = function(data)
        if self_ref.time < self_ref.conf.time_check then
            self_ref.time = self_ref.time + 1
            return
        end
        self_ref.time = 0

        if comparison_method(self_ref.status_signal, data, self_ref.conf.rate) then
            self_ref.status_signal.status = data.status or -1
            self_ref.status_signal.signal = data.signal or -1
            self_ref.status_signal.snr = data.snr or -1
            self_ref.status_signal.ber = data.ber or -1
            self_ref.status_signal.unc = data.unc or -1

            self_ref.json_cache = json_encode(self_ref.status_signal)
            send_monitor(self_ref.json_cache, "dvb")
        end
    end

    self.instance = dvb_tune(self.conf)

    if self.instance then
        log_info("[DvbTunerMonitor] Started monitor for adapter: " .. self.conf.name_adapter)
        return self.instance
    else
        log_error("[DvbTunerMonitor] Failed to start monitor for adapter: " .. self.conf.name_adapter)
        return nil
    end
end

--- Обновляет параметры мониторинга DVB-тюнера.
-- @param table params Таблица с новыми параметрами.
-- @return boolean true, если параметры успешно обновлены, иначе false.
function DvbTunerMonitor:update_parameters(params)
    if type(params) ~= 'table' then
        log_error("[DvbTunerMonitor:update_parameters] params must be a table")
        return false
    end

    if params.rate ~= nil and check(type(params.rate) == 'number' and params.rate >= 0.001 and params.rate <= 1, "params.rate must be between 0.001 and 1") then
        self.conf.rate = params.rate
    end
    if params.time_check ~= nil and check(type(params.time_check) == 'number' and params.time_check >= 0, "params.time_check must be non-negative") then
        self.conf.time_check = params.time_check
    end

    log_info("[DvbTunerMonitor:update_parameters] Parameters updated successfully for monitor: " .. self.conf.name_adapter)
    return true
end

--- Возвращает текущий кэш JSON статуса.
-- @return string Кэш JSON.
function DvbTunerMonitor:get_json_cache()
    return self.json_cache
end

return DvbTunerMonitor
