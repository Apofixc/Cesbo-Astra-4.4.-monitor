-- ===========================================================================
-- DvbTunerMonitor Class
-- ===========================================================================

local type        = type
local Logger      = require "src.utils.logger"
local log_info    = Logger.info
local log_error   = Logger.error
local json_encode = json.encode -- Предполагается, что json.encode глобально доступен

local Utils                = require "src.utils.utils"
local ratio                = Utils.ratio
local get_server_name      = Utils.get_server_name
local send_monitor         = Utils.send_monitor
local MonitorConfig        = require "src.config.monitor_config"
local validate_monitor_param = Utils.validate_monitor_param

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

-- Заглушка для kill_dvb_tune, так как она должна быть реализована в lib-monitor
local function kill_dvb_tune(instance)
    -- Здесь будет логика для остановки DVB-тюнера
    -- Временно просто логируем
    Logger.info("DvbTunerMonitor", "kill_dvb_tune called for instance: %s", tostring(instance))
end

--- Вспомогательная функция для валидации и установки параметра конфигурации DVB.
-- @param table self Объект DvbTunerMonitor.
-- @param string param_name Имя параметра (например, "dvb_rate").
-- @param any value Значение для установки.
-- @return boolean true, если параметр успешно установлен; nil и сообщение об ошибке в случае ошибки.
local function set_dvb_config_param(self, param_name, value)
    local updated_value, err = validate_monitor_param(param_name, value)
    if err then
        log_error(COMPONENT_NAME, "Failed to validate '%s' parameter: %s", param_name, err)
        return nil, err
    end
    -- Извлекаем фактическое имя параметра из "dvb_param_name"
    local config_key = param_name:gsub("dvb_", "")
    self.conf[config_key] = updated_value
    return true
end

--- Конструктор для DvbTunerMonitor.
-- @param table conf Таблица конфигурации для DVB-тюнера.
-- @return DvbTunerMonitor Новый экземпляр DvbTunerMonitor.
function DvbTunerMonitor:new(conf)
    local self = setmetatable({}, DvbTunerMonitor)
    self.conf = conf

    -- Установка значений по умолчанию для параметров конфигурации, если они не заданы
    set_dvb_config_param(self, "dvb_time_check", conf.time_check)
    set_dvb_config_param(self, "dvb_rate", conf.rate)
    set_dvb_config_param(self, "dvb_method_comparison", conf.method_comparison)

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

            local current_json_cache = json_encode(self_ref.status_signal)
            if current_json_cache ~= self_ref.json_cache then
                send_monitor(current_json_cache, "dvb")
                self_ref.json_cache = current_json_cache
            end
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

    local success, err
    if params.rate ~= nil then
        success, err = set_dvb_config_param(self, "dvb_rate", params.rate)
        if not success then return nil, err end
    end
    if params.time_check ~= nil then
        success, err = set_dvb_config_param(self, "dvb_time_check", params.time_check)
        if not success then return nil, err end
    end
    if params.method_comparison ~= nil then
        success, err = set_dvb_config_param(self, "dvb_method_comparison", params.method_comparison)
        if not success then return nil, err end
    end

    log_info(COMPONENT_NAME, "Parameters updated successfully for monitor: %s", self.conf.name_adapter)
    return true, nil
end

--- Возвращает текущий кэш JSON статуса.
-- @return string Кэш JSON.
function DvbTunerMonitor:get_json_cache()
    return self.json_cache
end

--- Останавливает и очищает ресурсы, связанные с DVB-тюнер монитором.
-- Сбрасывает все внутренние ссылки для освобождения памяти.
function DvbTunerMonitor:kill()
    if self.instance then
        kill_dvb_tune(self.instance)
        self.instance = nil
    end
    self.conf = nil
    self.status_signal = nil
    self.json_cache = nil
    log_info(COMPONENT_NAME, "DVB Tuner Monitor killed for adapter: %s", self.conf.name_adapter)
end

return DvbTunerMonitor
