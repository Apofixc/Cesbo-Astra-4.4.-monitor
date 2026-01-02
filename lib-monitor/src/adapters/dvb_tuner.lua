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

    local self = setmetatable({}, DvbTuner)
    self.config = conf

    -- Валидация и установка параметров (валидатор сам вернет default при необходимости)
    self:_set_config_param("dvb_rate", conf.rate)
    self:_set_config_param("dvb_time_check", conf.time_check)
    self:_set_config_param("dvb_method_comparison", conf.method_comparison)

    if not conf.name_adapter or type(conf.name_adapter) ~= "string" then
        Logger.error(COMPONENT_NAME, "new: name_adapter is required")
        return nil
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

--- Обновляет параметры тюнера. Если изменены параметры вещания (частота и т.д.), тюнер будет перезапущен.
--- @param params table Новые параметры
--- @return boolean success Статус выполнения
function DvbTuner:update_parameters(params)
    if not params or type(params) ~= "table" then
        Logger.error(COMPONENT_NAME, "[%s] update_parameters: params must be a table", tostring(self.name_adapter))
        return false
    end

    local tuning_params = {
        "frequency", "symbolrate", "modulation", "adapter", "device", "type",
        "polarization", "voltage", "lnb", "diseqc", "tp"
    }

    local tuning_changed = false
    for _, param in ipairs(tuning_params) do
        if params[param] ~= nil and params[param] ~= self.config[param] then
            tuning_changed = true
            break
        end
    end

    if tuning_changed then
        -- Проверка занятости тюнера перед сменой параметров
        if self.instance and self.instance.__options and self.instance.__options.channels and self.instance.__options.channels > 1 then
            Logger.error(COMPONENT_NAME, "Cannot change tuning parameters for '%s': tuner is used by %d channels. Stop channels first.", 
                self.name_adapter, self.instance.__options.channels - 1)
            return false
        end

        for _, param in ipairs(tuning_params) do
            if params[param] ~= nil then
                self.config[param] = params[param]
            end
        end

        Logger.info(COMPONENT_NAME, "Tuning parameters changed for '%s'. Restarting...", self.name_adapter)
        self.status.source = self.config.tp or self.config.frequency
        self.status.format = self.config.type or ""
        self.status.modulation = self.config.modulation or ""
        
        return self:restart() ~= nil
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

--- Останавливает тюнер и очищает внутренние списки Astra для предотвращения утечек памяти.
--- @return boolean success
function DvbTuner:stop()
    if self.instance then
        local can_close = true
        
        -- Безопасное управление счетчиком каналов Astra
        if self.instance.__options and self.instance.__options.channels then
            self.instance.__options.channels = self.instance.__options.channels - 1
            Logger.debug(COMPONENT_NAME, "[%s] Tuner channels counter decremented: %d", self.name_adapter, self.instance.__options.channels)
            
            if self.instance.__options.channels > 0 then
                can_close = false
                Logger.info(COMPONENT_NAME, "[%s] Tuner remains active for other channels", self.name_adapter)
            end
        end

        if can_close then
            -- Очистка внутреннего списка Astra (dvb_input_instance_list)
            local dvb_input_instance_list = dvb_input_instance_list
            if type(dvb_input_instance_list) == "table" and self.instance.__options then
                local opts = self.instance.__options
                if opts.adapter ~= nil and opts.device ~= nil then
                    local instance_id = string_format("%s.%s", tostring(opts.adapter), tostring(opts.device))
                    if dvb_input_instance_list[instance_id] then
                        dvb_input_instance_list[instance_id] = nil
                        Logger.debug(COMPONENT_NAME, "Removed tuner '%s' from Astra internal list (id: %s)", self.name_adapter, instance_id)
                    end
                end
            end

            -- Закрытие самого тюнера
            if type(self.instance.close) == "function" then
                self.instance:close()
            end
            Logger.info(COMPONENT_NAME, "Tuner '%s' physically stopped", self.name_adapter)
        end
        
        self.instance = nil
        return true
    end
    return false
end

--- Перезапускает тюнер.
--- @return any|nil result Новый экземпляр тюнера или nil
function DvbTuner:restart()
    Logger.info(COMPONENT_NAME, "Restarting tuner '%s'...", self.name_adapter)
    self:stop()
    return self:start()
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
    if self.status == nil then
        Logger.error(COMPONENT_NAME, "[%s] Cannot resume: tuner already killed", tostring(self.name_adapter))
        return false
    end
    self._active = true
    Logger.info(COMPONENT_NAME, "[%s] Tuner monitoring resumed", tostring(self.name_adapter))
    return true
end

--- Принудительно останавливает тюнер, игнорируя счетчики каналов.
--- Используется в экстренных случаях (зависание тюнера).
--- @return boolean success Статус выполнения
function DvbTuner:force_stop()
    if self.instance then
        -- Очистка внутреннего списка Astra (dvb_input_instance_list)
        local dvb_input_instance_list = dvb_input_instance_list
        if type(dvb_input_instance_list) == "table" and self.instance.__options then
            local opts = self.instance.__options
            if opts.adapter ~= nil and opts.device ~= nil then
                local instance_id = string_format("%s.%s", tostring(opts.adapter), tostring(opts.device))
                if dvb_input_instance_list[instance_id] then
                    dvb_input_instance_list[instance_id] = nil
                end
            end
        end

        -- Принудительное закрытие
        if type(self.instance.close) == "function" then
            self.instance:close()
        end
        
        self.instance = nil
        Logger.warn(COMPONENT_NAME, "Tuner '%s' FORCE STOPPED (Emergency Reset)", self.name_adapter)
        return true
    end
    return false
end

--- Принудительно перезапускает тюнер с сохранением и восстановлением счетчика каналов.
--- @param new_params table|nil Новые параметры тюнинга
--- @return boolean success Статус выполнения
function DvbTuner:force_restart(new_params)
    Logger.info(COMPONENT_NAME, "Force restarting tuner '%s'...", self.name_adapter)
    
    -- 1. Останавливаем и запоминаем счетчик
    local old_channels_count = self.instance and self.instance.__options and self.instance.__options.channels
    if not self:force_stop() then return false end

    -- 2. Обновляем параметры, если переданы
    if new_params and type(new_params) == "table" then
        for k, v in pairs(new_params) do
            self.config[k] = v
        end
        self.status.source = self.config.tp or self.config.frequency
    end

    -- 3. Запускаем заново
    local instance = self:start()
    if not instance then
        Logger.error(COMPONENT_NAME, "Failed to restart tuner '%s' after force stop", self.name_adapter)
        return false
    end

    -- 4. Восстанавливаем счетчик (вычитаем 1, так как start() уже прибавил 1 для монитора)
    if old_channels_count and instance.__options then
        instance.__options.channels = old_channels_count
        Logger.debug(COMPONENT_NAME, "[%s] Tuner channels counter restored to: %d", self.name_adapter, instance.__options.channels)
    end

    return true
end

--- Полностью удаляет тюнер и очищает ресурсы.
function DvbTuner:kill()
    self._active = false
    self:stop()
    self.name_adapter = nil
    self.display_name = nil
    self.config = nil
    self.status = nil
    self.check_timer = nil
    self.json_cache = nil
    self.stats = nil
end

return DvbTuner
