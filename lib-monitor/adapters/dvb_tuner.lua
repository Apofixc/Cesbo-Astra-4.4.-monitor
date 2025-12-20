-- ===========================================================================
-- DvbTunerMonitor Class
-- ===========================================================================

local type        = type
local Logger      = require "utils.logger"
local log_info    = Logger.info
local log_error   = Logger.error
local json_encode = json.encode -- Предполагается, что json.encode глобально доступен

local ratio                = ratio -- Предполагается, что ratio глобально доступен
local get_server_name      = get_server_name -- Предполагается, что get_server_name глобально доступен
local send_monitor         = send_monitor -- Предполагается, что send_monitor глобально доступен
local MonitorConfig        = require "config.monitor_config"
local validate_monitor_param = require "utils.utils".validate_monitor_param

local dvb_tune = dvb_tune -- Предполагается, что эта функция глобально доступна или будет передана

local COMPONENT_NAME = "DvbTunerMonitor"

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
    -- Таблица конфигурации для DVB-тюнера.
    self.conf = conf
    -- Интервал проверки состояния DVB-тюнера в секундах.
    self.conf.time_check = validate_monitor_param("dvb_time_check", conf.time_check) or MonitorConfig.ValidationSchema.dvb_time_check.default
    -- Допустимая погрешность для сравнения параметров сигнала (например, 0.015 = 1.5%).
    self.conf.rate = validate_monitor_param("dvb_rate", conf.rate) or MonitorConfig.ValidationSchema.dvb_rate.default
    -- Метод сравнения для определения изменений в параметрах DVB-тюнера.
    -- 1: Всегда возвращает true (для совместимости).
    -- 2: Сравнивает по любому изменению статуса, сигнала, SNR, BER, UNC.
    -- 3: Сравнивает по любому изменению статуса, а также сигнала и SNR с учетом погрешности (rate).
    self.conf.method_comparison = validate_monitor_param("dvb_method_comparison", conf.method_comparison) or MonitorConfig.ValidationSchema.dvb_method_comparison.default
    -- Текущее состояние сигнала DVB-тюнера.
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
    -- Счетчик времени для интервала проверки.
    self.time = 0
    -- Кэш JSON для последнего состояния сигнала.
    self.json_cache = nil 
    -- Экземпляр DVB-тюнера, управляемый функцией dvb_tune.
    self.instance = nil 

    return self
end

--- Запускает мониторинг DVB-тюнера.
-- @return userdata Экземпляр DVB-тюнера, если инициализация прошла успешно, иначе `nil` и сообщение об ошибке.
function DvbTunerMonitor:start()
    local comparison_method = dvb_monitor_method_comparison[self.conf.method_comparison]
    if not comparison_method then
        local error_msg = "Invalid comparison method specified: " .. tostring(self.conf.method_comparison)
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

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
        log_info(COMPONENT_NAME, "Started monitor for adapter: %s", self.conf.name_adapter)
        return self.instance, nil
    else
        local error_msg = "Failed to start monitor for adapter: " .. self.conf.name_adapter .. ". dvb_tune returned nil."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
end

--- Обновляет параметры мониторинга DVB-тюнера.
-- @param table params Таблица с новыми параметрами.
-- @return boolean true, если параметры успешно обновлены, иначе `nil` и сообщение об ошибке.
function DvbTunerMonitor:update_parameters(params)
    if type(params) ~= 'table' then
        local error_msg = "update_parameters: params must be a table. Got " .. type(params) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local updated_rate, err_rate = validate_monitor_param("dvb_rate", params.rate)
    if params.rate ~= nil then -- Only attempt to update if param is provided
        if err_rate then
            log_error(COMPONENT_NAME, "Failed to validate 'rate' parameter: %s", err_rate)
            return nil, err_rate
        end
        self.conf.rate = updated_rate
    end

    local updated_time_check, err_time_check = validate_monitor_param("dvb_time_check", params.time_check)
    if params.time_check ~= nil then -- Only attempt to update if param is provided
        if err_time_check then
            log_error(COMPONENT_NAME, "Failed to validate 'time_check' parameter: %s", err_time_check)
            return nil, err_time_check
        end
        self.conf.time_check = updated_time_check
    end

    local updated_method_comparison, err_method_comparison = validate_monitor_param("dvb_method_comparison", params.method_comparison)
    if params.method_comparison ~= nil then -- Only attempt to update if param is provided
        if err_method_comparison then
            log_error(COMPONENT_NAME, "Failed to validate 'method_comparison' parameter: %s", err_method_comparison)
            return nil, err_method_comparison
        end
        self.conf.method_comparison = updated_method_comparison
    end

    log_info(COMPONENT_NAME, "Parameters updated successfully for monitor: %s", self.conf.name_adapter)
    return true, nil
end

--- Возвращает текущий кэш JSON статуса.
-- @return string Кэш JSON.
function DvbTunerMonitor:get_json_cache()
    return self.json_cache
end

return DvbTunerMonitor
