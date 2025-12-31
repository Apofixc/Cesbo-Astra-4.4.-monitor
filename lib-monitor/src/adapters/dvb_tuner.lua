-- 1. Стандартные Lua функции
local type = type
local ipairs = ipairs
local setmetatable = setmetatable

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local Utils = ModuleManager.get_module("utils")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local EventDispatcher = ModuleManager.get_module("event_dispatcher")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local dvb_tune = ModuleManager.get_global_dependency("dvb_tune")
local json_encode = ModuleManager.get_global_dependency("json.encode")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "DvbTuner"

--- @class DvbTuner
--- @field private name_adapter string
--- @field private config table
--- @field private status table
--- @field private instance any
--- @field private check_timer number
local DvbTuner = {}
DvbTuner.__index = DvbTuner

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
               Utils.ratio(prev.signal, curr.signal) > rate or 
               Utils.ratio(prev.snr, curr.snr) > rate or 
               prev.ber ~= curr.ber or 
               prev.unc ~= curr.unc
    end
}

--- Валидирует конфигурацию тюнера
--- @param config table
--- @return boolean success
local function validate_config(config)
    if not config or type(config) ~= "table" then
        Logger.error(COMPONENT_NAME, "validate_config: config must be a table")
        return false
    end

    if not config.name_adapter or type(config.name_adapter) ~= "string" then
        Logger.error(COMPONENT_NAME, "validate_config: name_adapter is required")
        return false
    end

    local schema = MonitorConfig and MonitorConfig.ValidationSchema or {}
    
    -- Валидация rate
    local s_rate = schema.dvb_rate
    if s_rate then
        if config.rate == nil then
            config.rate = s_rate.default
        elseif type(config.rate) ~= s_rate.type or config.rate < s_rate.min or config.rate > s_rate.max then
            Logger.warn(COMPONENT_NAME, "validate_config: invalid rate, using default")
            config.rate = s_rate.default
        end
    end

    -- Валидация time_check
    local s_tc = schema.dvb_time_check
    if s_tc then
        if config.time_check == nil then
            config.time_check = s_tc.default
        elseif type(config.time_check) ~= s_tc.type or config.time_check < s_tc.min or config.time_check > s_tc.max then
            Logger.warn(COMPONENT_NAME, "validate_config: invalid time_check, using default")
            config.time_check = s_tc.default
        end
    end

    -- Валидация method_comparison
    local s_mc = schema.dvb_method_comparison
    if s_mc then
        if config.method_comparison == nil then
            config.method_comparison = s_mc.default
        elseif type(config.method_comparison) ~= s_mc.type or config.method_comparison < s_mc.min or config.method_comparison > s_mc.max then
            Logger.warn(COMPONENT_NAME, "validate_config: invalid method_comparison, using default")
            config.method_comparison = s_mc.default
        end
    end

    return true
end

--- Создает новый экземпляр DvbTuner
--- @param conf table
--- @return boolean success
--- @return DvbTuner|nil
function DvbTuner.new(conf)
    if not validate_config(conf) then
        return false, nil
    end

    local self = setmetatable({}, DvbTuner)
    self.name_adapter = conf.name_adapter
    self.config = conf
    self.check_timer = 0
    self.status = {
        type = "dvb",
        server = Utils.get_server_name(),
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
    return true, self
end

--- Публикует данные через EventDispatcher
--- @param content string JSON данные
--- @param event_type string Тип события
function DvbTuner:publish(content, event_type)
    EventDispatcher.publish(event_type, content)
end

--- Запускает тюнер
--- @return boolean success
function DvbTuner:start()
    self.config.callback = function(data) self:on_data(data) end
    self.instance = dvb_tune(self.config)
    if not self.instance then
        Logger.error(COMPONENT_NAME, "start: dvb_tune returned nil")
        return false
    end
    return true
end

--- Обработка данных
function DvbTuner:on_data(data)
    if self.check_timer < self.config.time_check then
        self.check_timer = self.check_timer + 1
        return
    end
    self.check_timer = 0

    local comparison = COMPARISON_METHODS[self.config.method_comparison]
    if comparison(self.status, data, self.config.rate) then
        self.status.status = data.status or -1
        self.status.signal = data.signal or -1
        self.status.snr = data.snr or -1
        self.status.ber = data.ber or -1
        self.status.unc = data.unc or -1

        self:publish(json_encode(self.status), "dvb")
    end
end

--- Обновляет параметры
function DvbTuner:update_parameters(params)
    if not params or type(params) ~= "table" then return false end

    local schema = MonitorConfig and MonitorConfig.ValidationSchema or {}
    
    if params.rate ~= nil then
        local s = schema.dvb_rate
        if type(params.rate) == 'number' and params.rate >= s.min and params.rate <= s.max then
            self.config.rate = params.rate
        end
    end
    if params.time_check ~= nil then
        local s = schema.dvb_time_check
        if type(params.time_check) == 'number' and params.time_check >= s.min and params.time_check <= s.max then
            self.config.time_check = params.time_check
        end
    end
    return true
end

return DvbTuner
