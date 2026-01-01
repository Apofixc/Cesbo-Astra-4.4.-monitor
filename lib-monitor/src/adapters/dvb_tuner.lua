-- 1. Стандартные Lua функции
local type = type
local ipairs = ipairs
local setmetatable = setmetatable

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local Utils = ModuleManager.get_module("utils")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local HttpSubscriber = ModuleManager.get_module("http_subscriber")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local dvb_tune = ModuleManager.get_global_dependency("dvb_tune")
local json_encode = ModuleManager.get_global_dependency("json.encode")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "DvbTuner"

--- @class DvbTuner
--- @field name_adapter string Уникальное имя адаптера
--- @field display_name string Отображаемое имя
--- @field config table Конфигурация тюнера
--- @field status table Текущий статус (signal, snr, ber, unc)
--- @field instance any Экземпляр dvb_tune из Astra
--- @field check_timer number Счетчик для интервала проверки
--- @field json_cache string|nil Кэш последнего отправленного JSON
--- @field stats table Накопленная статистика для расчета качества
local DvbTuner = {}
DvbTuner.__index = DvbTuner

local ratio = Utils.ratio
local validate_monitor_param = Utils.validate_monitor_param

local COMPARISON_METHODS = {
    [1] = function() return true end,
    [2] = function(prev, curr)
        return prev.status ~= curr.status or 
               prev.signal ~= curr.signal or 
               prev.snr ~= curr.snr or 
               prev.ber ~= curr.ber or 
               prev.unc ~= curr.unc
    end,
    [3] = function(prev, curr, rate)
        return prev.status ~= curr.status or 
               ratio(prev.signal, curr.signal) > rate or 
               ratio(prev.snr, curr.snr) > rate or 
               prev.ber ~= curr.ber or 
               prev.unc ~= curr.unc
    end
}

--- Вспомогательная функция для установки параметра конфигурации
--- @param self DvbTuner
--- @param param_name string
--- @param value any
local function set_config_param(self, param_name, value)
    local success, result = validate_monitor_param(param_name, value)
    if not success then return false end
    local key = param_name:gsub("dvb_", "")
    self.config[key] = result
    return true
end

--- Создает новый экземпляр DvbTuner.
--- @param conf table Конфигурация тюнера
--- @return boolean success Статус выполнения
--- @return DvbTuner|nil result Экземпляр DvbTuner или nil
function DvbTuner.new(conf)
    if not conf or type(conf) ~= "table" then
        Logger.error(COMPONENT_NAME, "new: config is required")
        return false, nil
    end

    local self = setmetatable({}, DvbTuner)
    self.config = conf

    -- Валидация и установка параметров по умолчанию
    set_config_param(self, "dvb_rate", conf.rate)
    set_config_param(self, "dvb_time_check", conf.time_check)
    set_config_param(self, "dvb_method_comparison", conf.method_comparison)

    if not conf.name_adapter or type(conf.name_adapter) ~= "string" then
        Logger.error(COMPONENT_NAME, "new: name_adapter is required")
        return false, nil
    end

    self.name_adapter = conf.name_adapter
    self.display_name = conf.display_name or self.name_adapter
    self.check_timer = 0
    self.json_cache = nil
    self.stats = {
        ber_sum = 0,
        unc_sum = 0,
        count = 0
    }
    self.status = {
        type = "dvb",
        server = Utils.get_server_name(),
        format = conf.type or "",
        modulation = conf.modulation or "",
        source = conf.tp or conf.frequency,
        name_adapter = self.name_adapter,
        display_name = self.display_name,
        status = -1,
        signal = -1,
        snr = -1,
        ber = -1,
        unc = -1,
        quality = 100
    }
    return true, self
end

--- Публикует данные через HttpSubscriber
--- @param content string JSON данные
--- @param event_type string Тип события
function DvbTuner:publish(content, event_type)
    HttpSubscriber.publish(event_type, content)
end

--- Запускает тюнер и инициализирует callback для мониторинга.
--- @return boolean success Статус выполнения
--- @return any|nil result Экземпляр dvb_tune или nil
function DvbTuner:start()
    local comparison_method = COMPARISON_METHODS[self.config.method_comparison]
    if not comparison_method then
        local err = string.format("start: Invalid comparison method %s", tostring(self.config.method_comparison))
        Logger.error(COMPONENT_NAME, err)
        return false, nil
    end

    self.config.callback = function(data)
        -- Накопление статистики для расчета качества (упрощенно)
        if data.status and data.status > 0 then
            self.stats.ber_sum = self.stats.ber_sum + (data.ber or 0)
            self.stats.unc_sum = self.stats.unc_sum + (data.unc or 0)
            self.stats.count = self.stats.count + 1
        end

        if self.check_timer < self.config.time_check then
            self.check_timer = self.check_timer + 1
            return
        end
        self.check_timer = 0

        if comparison_method(self.status, data, self.config.rate) then
            self.status.status = data.status or -1
            self.status.signal = data.signal or -1
            self.status.snr = data.snr or -1
            self.status.ber = data.ber or -1
            self.status.unc = data.unc or -1
            
            -- Расчет качества (quality) на основе ошибок
            if self.stats.count > 0 then
                local avg_ber = self.stats.ber_sum / self.stats.count
                if avg_ber > 0 or self.stats.unc_sum > 0 then
                    self.status.quality = math.max(0, 100 - (avg_ber / 1000) - (self.stats.unc_sum * 10))
                else
                    self.status.quality = 100
                end
                -- Сброс статистики после отправки
                self.stats.ber_sum = 0
                self.stats.unc_sum = 0
                self.stats.count = 0
            end

            local current_json = json_encode(self.status)
            if current_json ~= self.json_cache then
                HttpSubscriber.publish("dvb", current_json)
                self.json_cache = current_json
            end
        end
    end

    self.instance = dvb_tune(self.config)
    if not self.instance then
        Logger.error(COMPONENT_NAME, "start: dvb_tune returned nil")
        return false, nil
    end

    return true, self.instance
end

--- Обновляет параметры
function DvbTuner:update_parameters(params)
    if not params or type(params) ~= "table" then return false end

    if params.rate ~= nil then
        set_config_param(self, "dvb_rate", params.rate)
    end
    if params.time_check ~= nil then
        set_config_param(self, "dvb_time_check", params.time_check)
    end
    if params.method_comparison ~= nil then
        set_config_param(self, "dvb_method_comparison", params.method_comparison)
    end
    return true
end

--- Останавливает тюнер и очищает ресурсы
function DvbTuner:kill()
    if self.instance then
        self.instance = nil
    end
    self.name_adapter = nil
    self.display_name = nil
    self.config = nil
    self.status = nil
    self.check_timer = nil
    self.json_cache = nil
end

return DvbTuner
