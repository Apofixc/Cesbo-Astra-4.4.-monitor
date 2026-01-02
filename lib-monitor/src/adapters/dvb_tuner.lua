-- 1. Стандартные Lua функции
local ipairs = ipairs
local math_max = math.max
local setmetatable = setmetatable
local string_format = string.format
local tostring = tostring
local type = type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local Utils = ModuleManager.get_module("utils")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local HttpSubscriber = ModuleManager.get_module("http_subscriber")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local dvb_tune = ModuleManager.get_global_dependency("dvb_tune")
local json_encode = ModuleManager.get_global_dependency("json.encode")
local dvb_input_instance_list = ModuleManager.get_global_dependency("dvb_input_instance_list")
local analyze = ModuleManager.get_global_dependency("analyze")
local collectgarbage = collectgarbage
local timer = ModuleManager.get_global_dependency("timer")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "DvbTuner"

--- @class DvbTuner
--- @field name_adapter string|nil Уникальное имя адаптера
--- @field display_name string|nil Отображаемое имя
--- @field config table|nil Конфигурация тюнера
--- @field status table|nil Текущий статус (signal, snr, ber, unc)
--- @field instance any|nil Экземпляр dvb_tune из Astra
--- @field check_timer number|nil Счетчик для интервала проверки
--- @field json_cache string|nil Кэш последнего отправленного JSON
--- @field stats table|nil Накопленная статистика для расчета качества
--- @field _temp_analyzer any|nil Временный экземпляр анализатора для PSI
--- @field _psi table|nil Таблица с PSI данными
--- @field _active boolean|nil Статус активности мониторинга
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

--- Вспомогательная функция для очистки ресурсов PSI
function DvbTuner:_clear_psi()
    if self._psi_timer then
        self._psi_timer:close()
        self._psi_timer = nil
    end
    if self._temp_analyzer then
        self._temp_analyzer = nil
        collectgarbage()
    end
end

--- Вспомогательная функция для установки параметра конфигурации
--- @param param_name string Имя параметра
--- @param value any Значение
--- @return boolean success Статус выполнения
function DvbTuner:_set_config_param(param_name, value)
    local success, result = validate_monitor_param(param_name, value)
    if not success then
        Logger.error(COMPONENT_NAME, "[%s] Invalid parameter value for %s: %s", tostring(self.name_adapter), param_name, tostring(value))
        return false
    end
    local key = param_name:gsub("dvb_", "")
    self.config[key] = result
    return true
end

--- Создает новый экземпляр DvbTuner.
--- @param conf table Конфигурация тюнера
--- @return DvbTuner|nil result Экземпляр DvbTuner или nil
function DvbTuner.new(conf)
    if not conf or type(conf) ~= "table" then
        Logger.error(COMPONENT_NAME, "new: config is required")
        return nil
    end

    if not conf.name_adapter or type(conf.name_adapter) ~= "string" then
        Logger.error(COMPONENT_NAME, "new: name_adapter is required")
        return nil
    end

    ---@class DvbTuner
    local self = setmetatable({}, DvbTuner)
    self.config = conf
    self.name_adapter = conf.name_adapter

    -- Валидация и установка параметров (валидатор сам вернет default при необходимости)
    self:_set_config_param("dvb_rate", conf.rate)
    self:_set_config_param("dvb_time_check", conf.time_check)
    self:_set_config_param("dvb_method_comparison", conf.method_comparison)
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
        status = -1,
        signal = -1,
        snr = -1,
        ber = -1,
        unc = -1,
        quality = 100
    }
    self._temp_analyzer = nil
    self._psi = {}
    self._psi_timer = nil

    return self
end

--- Публикует данные через HttpSubscriber
--- @param content string JSON данные
--- @param event_type string Тип события
function DvbTuner:publish(content, event_type)
    HttpSubscriber.publish(event_type, content)
end

--- Запускает тюнер и инициализирует callback для мониторинга.
--- @return any|nil result Экземпляр dvb_tune или nil
function DvbTuner:start()
    local comparison_method = COMPARISON_METHODS[self.config.method_comparison]
    if not comparison_method then
        Logger.error(COMPONENT_NAME, string_format("start: Invalid comparison method %s", tostring(self.config.method_comparison)))
        return nil
    end

    self.config.callback = function(data)
        if not self._active or not data then return end
        
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
                    self.status.quality = math_max(0, 100 - (avg_ber / 1000) - (self.stats.unc_sum * 10))
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

    self._active = true
    self.instance = dvb_tune(self.config)
    if not self.instance then
        Logger.error(COMPONENT_NAME, "start: dvb_tune returned nil")
        return nil
    end

    -- Безопасное управление счетчиком каналов Astra
    if self.instance.__options then
        if self.instance.__options.channels == nil then
            self.instance.__options.channels = 1
        else
            self.instance.__options.channels = self.instance.__options.channels + 1
        end
        Logger.debug(COMPONENT_NAME, "[%s] Tuner channels counter incremented: %d", self.name_adapter, self.instance.__options.channels)
    end

    return self.instance
end

--- Обновляет параметры мониторинга тюнера.
--- @param params table Новые параметры (rate, time_check, method_comparison)
--- @return boolean success Статус выполнения
function DvbTuner:update_parameters(params)
    if not params or type(params) ~= "table" then
        Logger.error(COMPONENT_NAME, "[%s] update_parameters: params must be a table", tostring(self.name_adapter))
        return false
    end

    if params.rate ~= nil then
        self:_set_config_param("dvb_rate", params.rate)
    end
    if params.time_check ~= nil then
        self:_set_config_param("dvb_time_check", params.time_check)
    end
    if params.method_comparison ~= nil then
        self:_set_config_param("dvb_method_comparison", params.method_comparison)
    end

    return true
end

--- Возвращает собранные PSI данные
--- @return table psi Таблица с PSI данными
function DvbTuner:get_psi()
    return self._psi
end

--- Запускает сбор PSI таблиц на 10 секунд
--- @return boolean success Статус запуска процесса
function DvbTuner:psi_update()
    if not self.instance or self._temp_analyzer or self._psi_timer then
        return false
    end

    self._temp_analyzer = analyze({
        upstream = self.instance:stream(),
        name = "psi_update_" .. self.name_adapter,
        join_pid = true,
        callback = function(data)
            if data.psi then
                self._psi[data.psi:lower()] = data
            end
        end
    })

    if not self._temp_analyzer then
        return false
    end

    self._psi_timer = timer({
        interval = 10,
        callback = function()
            self._temp_analyzer = nil
            if self._psi_timer then
                self._psi_timer:close()
                self._psi_timer = nil
            end
            Logger.info(COMPONENT_NAME, "[%s] PSI update finished", tostring(self.name_adapter))
        end
    })

    return true
end

--- Приостанавливает мониторинг тюнера
--- @return boolean success Статус выполнения
function DvbTuner:pause()
    self._active = false
    Logger.info(COMPONENT_NAME, "[%s] Tuner monitoring paused", tostring(self.name_adapter))
    return true
end

--- Возобновляет мониторинг тюнера
--- @return boolean success Статус выполнения
function DvbTuner:resume()
    if not self.config then
        Logger.error(COMPONENT_NAME, "[%s] Cannot resume: tuner already destroyed", tostring(self.name_adapter))
        return false
    end
    self._active = true
    Logger.info(COMPONENT_NAME, "[%s] Tuner monitoring resumed", tostring(self.name_adapter))
    return true
end

--- Полностью останавливает тюнер и уничтожает объект.
--- @param force boolean|nil Принудительная остановка (игнорировать счетчик каналов)
--- @return boolean success Статус выполнения
function DvbTuner:destroy(force)
    if self.instance and not force then
        if self.instance.__options and self.instance.__options.channels and self.instance.__options.channels > 1 then
            Logger.warn(COMPONENT_NAME, "[%s] Cannot destroy: tuner is used by %d other channels. Use force=true to override.", 
                tostring(self.name_adapter), self.instance.__options.channels - 1)
            return false
        end
    end

    self._active = false
    self:_clear_psi()

    if self.instance then
        local can_close = true
        
        if not force then
            if self.instance.__options and self.instance.__options.channels then
                self.instance.__options.channels = self.instance.__options.channels - 1
                Logger.debug(COMPONENT_NAME, "[%s] Tuner channels counter decremented: %d", tostring(self.name_adapter), self.instance.__options.channels)
                
                if self.instance.__options.channels > 0 then
                    can_close = false
                    Logger.info(COMPONENT_NAME, "[%s] Tuner remains active for other channels", tostring(self.name_adapter))
                end
            end
        end

        if can_close then
            if type(dvb_input_instance_list) == "table" and self.instance.__options then
                local opts = self.instance.__options
                if opts.adapter ~= nil and opts.device ~= nil then
                    local instance_id = string_format("%s.%s", tostring(opts.adapter), tostring(opts.device))
                    if dvb_input_instance_list[instance_id] then
                        dvb_input_instance_list[instance_id] = nil
                        Logger.debug(COMPONENT_NAME, "Removed tuner '%s' from Astra internal list (id: %s)", tostring(self.name_adapter), instance_id)
                    end
                end
            end

            if type(self.instance.close) == "function" then
                self.instance:close()
            end
            Logger.info(COMPONENT_NAME, "Tuner '%s' physically stopped (force: %s)", tostring(self.name_adapter), tostring(force))
        end
        
        if self.config then
            self.config.callback = nil
        end
        self.instance = nil
    end

    -- Полная очистка полей объекта
    self.name_adapter = nil
    self.config = nil
    self.status = nil
    self.check_timer = nil
    self.json_cache = nil
    self.stats = nil
    self._psi = nil
    
    Logger.debug(COMPONENT_NAME, "Tuner object destroyed")
    return true
end

return DvbTuner
