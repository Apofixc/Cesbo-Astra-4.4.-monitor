-- 1. Стандартные Lua функции
local collectgarbage = collectgarbage
local math_max = math.max
local pairs = pairs
local setmetatable = setmetatable
local string_format = string.format
local tostring = tostring
local type = type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local Utils = ModuleManager.get_module("utils")
local HttpSubscriber = ModuleManager.get_module("http_subscriber")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local dvb_tune = ModuleManager.get_global_dependency("dvb_tune")
local json_encode = ModuleManager.get_global_dependency("json.encode")
local dvb_input_instance_list = ModuleManager.get_global_dependency("dvb_input_instance_list")
local analyze = ModuleManager.get_global_dependency("analyze")
local timer = ModuleManager.get_global_dependency("timer")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "DvbTuner"

local STATE = {
    IDLE = 1,
    RUNNING = 2,
    STOPPED = 3,
}

-- Методы сравнения
local METHOD_ALWAYS = 1
local METHOD_STRICT = 2
local METHOD_RATIO = 3

--- @class DvbTuner
--- @field private _name string|nil Уникальное имя адаптера
--- @field private _config table|nil Оригинальная конфигурация тюнера (Read-Only)
--- @field private _status table|nil Текущий статус (signal, snr, ber, unc)
--- @field private _instance any|nil Экземпляр dvb_tune из Astra
--- @field private _check_timer number|nil Счетчик для интервала проверки
--- @field private _json_cache string|nil Кэш последнего отправленного JSON
--- @field private _stats table|nil Накопленная статистика для расчета качества
--- @field private _astra_conf table|nil Рабочая конфигурация для Astra
--- @field private _current_method function|nil Прямая ссылка на метод сравнения
--- @field private _temp_analyzer any|nil Временный экземпляр анализатора для PSI
--- @field private _psi table|nil Таблица с PSI данными
--- @field private _backup table|nil Бэкап предыдущего состояния (config, channels)
--- @field private _reports table Пул таблиц для разных типов отчетов
--- @field private _active boolean|nil Статус активности мониторинга
--- @field private _state number Текущее состояние (IDLE, RUNNING, STOPPED)
local DvbTuner = {}
DvbTuner.__index = DvbTuner

local ratio = Utils.ratio
local validate_monitor_param = Utils.validate_monitor_param

local COMPARISON_METHODS = {
    [METHOD_ALWAYS] = function() return true end,
    [METHOD_STRICT] = function(prev, curr)
        return (prev.status or -1) ~= (curr.status or -1) or 
               (prev.signal or -1) ~= (curr.signal or -1) or 
               (prev.snr or -1) ~= (curr.snr or -1) or 
               (prev.ber or -1) ~= (curr.ber or -1) or 
               (prev.unc or -1) ~= (curr.unc or -1)
    end,
    [METHOD_RATIO] = function(prev, curr, rate)
        return (prev.status or -1) ~= (curr.status or -1) or 
               ratio(prev.signal or 0, curr.signal or 0) > rate or 
               ratio(prev.snr or 0, curr.snr or 0) > rate or 
               (prev.ber or -1) ~= (curr.ber or -1) or 
               (prev.unc or -1) ~= (curr.unc or -1)
    end
}

--- Вспомогательная функция для очистки ресурсов PSI
function DvbTuner:_clear_psi()
    if self._psi_timer then
        if type(self._psi_timer.close) == "function" then
            self._psi_timer:close()
        end
        self._psi_timer = nil
    end
    if self._temp_analyzer then
        if self._temp_analyzer.__options then
            self._temp_analyzer.__options.callback = nil
        end
        if type(self._temp_analyzer.close) == "function" then
            self._temp_analyzer:close()
        end
        self._temp_analyzer = nil
        collectgarbage()
    end
end

--- Вспомогательная функция для установки параметра конфигурации
--- @param param_name string Имя параметра
--- @param value any Значение
--- @return boolean Статус выполнения
function DvbTuner:_set_config_param(param_name, value)
    local result = validate_monitor_param(param_name, value)
    if result == nil then
        Logger.error(COMPONENT_NAME, "[%s] Invalid parameter value for %s: %s", tostring(self._name), param_name, tostring(value))
        return false
    end
    local key = param_name:gsub("dvb_", "")
    self._config[key] = result
    return true
end

--- Создает новый экземпляр DvbTuner.
--- @param conf table Конфигурация тюнера
--- @return DvbTuner|nil Экземпляр DvbTuner или nil
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
    self._config = conf
    self._name = conf.name_adapter

    -- Валидация и установка параметров (валидатор сам вернет default при необходимости)
    if not self:_set_config_param("dvb_rate", conf.rate) then return nil end
    if not self:_set_config_param("dvb_time_check", conf.time_check) then return nil end
    if not self:_set_config_param("dvb_method_comparison", conf.method_comparison) then return nil end
    if not self:_set_config_param("dvb_analyze", conf.analyze) then return nil end
    
    self._current_method = COMPARISON_METHODS[self._config.method_comparison]
    self._check_timer = 0
    self._json_cache = nil
    self._stats = {
        ber_sum = 0,
        unc_sum = 0,
        count = 0
    }
    self._status = {
        type = "dvb",
        server = Utils.get_server_name(),
        format = conf.type or "",
        modulation = conf.modulation or "",
        source = conf.tp or conf.frequency,
        name_adapter = self._name,
        status = -1,
        signal = -1,
        snr = -1,
        ber = -1,
        unc = -1,
        quality = -1
    }
    self._temp_analyzer = nil
    self._psi = {}
    self._psi_timer = nil
    self._backup = nil
    
    -- Инициализация пула таблиц отчетов
    self._reports = {
        dvb = {}
    }
    for _, report in pairs(self._reports) do
        Utils.init_report(report, "dvb", self._name)
        report.name_adapter = self._name
        report.format = conf.type or ""
        report.modulation = conf.modulation or ""
        report.source = conf.tp or conf.frequency
    end

    self._state = STATE.IDLE

    return self
end

--- Публикует данные через HttpSubscriber
--- @param content string JSON данные
--- @param event_type string Тип события
function DvbTuner:publish(content, event_type)
    HttpSubscriber.publish(event_type, content)
end

--- Сохраняет бэкап предыдущего состояния
--- @param config table Предыдущая конфигурация
--- @param channels table Список конфигураций каналов
function DvbTuner:set_backup(config, channels)
    self._backup = {
        config = Utils.deep_copy(config),
        channels = Utils.deep_copy(channels)
    }
end

--- Возвращает бэкап предыдущего состояния
--- @return table|nil Бэкап или nil
function DvbTuner:get_backup()
    return self._backup
end

--- Запускает тюнер и инициализирует callback для мониторинга.
--- Автоматически создает рабочую копию конфигурации для Astra.
--- @return any|nil Экземпляр dvb_tune или nil
function DvbTuner:start()
    if self._state == STATE.RUNNING then
        Logger.warn(COMPONENT_NAME, "[%s] Tuner already running", tostring(self._name))
        return self._instance
    end

    if not self._current_method then
        Logger.error(COMPONENT_NAME, string_format("start: Invalid comparison method %s", tostring(self._config.method_comparison)))
        return nil
    end

    -- Создаем рабочую копию конфига для Astra
    self._astra_conf = Utils.table_copy(self._config)
    self._astra_conf.callback = function(data)
        if not self._active or not data then return end
        
        -- Накопление статистики для расчета качества (упрощенно)
        if self._config.analyze and data.status and data.status > 0 then
            -- Защита от переполнения при длительном отсутствии изменений (когда сброс не происходит)
            local MAX_STATS_COUNT = 1000000
            if self._stats.count < MAX_STATS_COUNT then
                self._stats.ber_sum = self._stats.ber_sum + (data.ber or 0)
                self._stats.unc_sum = self._stats.unc_sum + (data.unc or 0)
                self._stats.count = self._stats.count + 1
            end
        end

        if self._check_timer < self._astra_conf.time_check then
            self._check_timer = self._check_timer + 1
            return
        end
        self._check_timer = 0

        -- Оптимизация: Сначала проверяем изменения в данных перед формированием JSON
        if self._current_method(self._status, data, self._astra_conf.rate) then
            -- Дополнительная проверка на изменения через Utils.shallow_compare неэффективна здесь,
            -- так как data - это сырые данные Astra, а self._status - наша структура.
            -- Но мы можем сравнить ключевые поля.
            
            local status = self._status
            status.status = data.status or -1
            status.signal = data.signal or -1
            status.snr = data.snr or -1
            status.ber = data.ber or -1
            status.unc = data.unc or -1
            
            -- Расчет качества (quality) на основе ошибок
            if self._config.analyze and self._stats.count > 0 then
                local avg_ber = self._stats.ber_sum / self._stats.count
                if avg_ber > 0 or self._stats.unc_sum > 0 then
                    status.quality = math_max(0, 100 - (avg_ber / 1000) - (self._stats.unc_sum * 10))
                else
                    status.quality = 100
                end
                -- Сброс статистики после отправки
                self._stats.ber_sum = 0
                self._stats.unc_sum = 0
                self._stats.count = 0
            else
                status.quality = -1
            end

            -- Формируем полный статус для публикации
            self:_build_status_table()
            local r = self._reports.dvb
            local current_json = json_encode(r)
            
            -- Публикуем если JSON изменился
            if current_json ~= self._json_cache then
                self:publish(current_json, "dvb")
                self._json_cache = current_json
            end
        end
    end

    local instance = dvb_tune(self._astra_conf)
    if not instance then
        Logger.error(COMPONENT_NAME, "start: dvb_tune returned nil")
        return nil
    end

    self._instance = instance
    self._state = STATE.RUNNING
    self._active = true

    -- Безопасное управление счетчиком каналов Astra
    if self._instance and self._instance.__options then
        local current_channels = self._instance.__options.channels or 0
        self._instance.__options.channels = current_channels + 1
        Logger.debug(COMPONENT_NAME, "[%s] Tuner channels counter incremented: %d", self._name, self._instance.__options.channels)
    end

    return self._instance
end

--- Обновляет параметры мониторинга тюнера.
--- @param params table Новые параметры (rate, time_check, method_comparison)
--- @return boolean Статус выполнения
function DvbTuner:update_parameters(params)
    if not params or type(params) ~= "table" then
        Logger.error(COMPONENT_NAME, "[%s] update_parameters: params must be a table", tostring(self._name))
        return false
    end

    -- Обновляем self._config (оригинал) и self._astra_conf (живой конфиг)
    if params.rate ~= nil then
        self:_set_config_param("dvb_rate", params.rate)
        if self._astra_conf then self._astra_conf.rate = self._config.rate end
    end
    if params.time_check ~= nil then
        self:_set_config_param("dvb_time_check", params.time_check)
        if self._astra_conf then self._astra_conf.time_check = self._config.time_check end
    end
    if params.method_comparison ~= nil then
        self:_set_config_param("dvb_method_comparison", params.method_comparison)
        if self._astra_conf then self._astra_conf.method_comparison = self._config.method_comparison end
        -- Обновляем прямую ссылку на метод для callback
        self._current_method = COMPARISON_METHODS[self._config.method_comparison]
    end
    if params.analyze ~= nil then
        self:_set_config_param("dvb_analyze", params.analyze)
        if self._astra_conf then self._astra_conf.analyze = self._config.analyze end
        -- Если анализ выключен, сбрасываем накопленную статистику
        if not self._config.analyze then
            self._stats.ber_sum = 0
            self._stats.unc_sum = 0
            self._stats.count = 0
        end
    end

    return true
end

--- Возвращает собранные PSI данные
--- @return table Таблица с PSI данными
function DvbTuner:get_psi()
    return self._psi
end

--- Возвращает оригинальную конфигурацию тюнера
--- @return table Конфигурация
function DvbTuner:get_config()
    return self._config
end

--- Возвращает экземпляр dvb_tune из Astra
--- @return any|nil Экземпляр Astra
function DvbTuner:get_instance()
    return self._instance
end

--- Возвращает уникальное имя адаптера
--- @return string|nil Имя адаптера
function DvbTuner:get_name()
    return self._name
end

--- Возвращает текущее состояние монитора
--- @return number Состояние (STATE)
function DvbTuner:get_state()
    return self._state
end

--- Внутренний метод для сборки таблицы полного статуса.
--- Обновляет таблицу в пуле self._reports.dvb.
--- @return table Таблица статуса
function DvbTuner:_build_status_table()
    local status = self._status or {}
    local t = self._reports.dvb
    t.status = status.status or 0
    t.signal = status.signal or 0
    t.snr = status.snr or 0
    t.ber = status.ber or 0
    t.unc = status.unc or 0
    t.quality = status.quality or 0
    return t
end

--- Возвращает полный текущий статус тюнера
--- @return table Статус тюнера
function DvbTuner:get_full_status()
    return self:_build_status_table()
end

--- Запускает сбор PSI таблиц на 10 секунд
--- @return boolean Статус запуска процесса
function DvbTuner:psi_update()
    if not self._instance or self._temp_analyzer or self._psi_timer then
        return false
    end

    self._temp_analyzer = analyze({
        upstream = self._instance:stream(),
        name = "psi_update_" .. self._name,
        join_pid = true,
        callback = function(data)
            if not data or not self._temp_analyzer then return end
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
            if not self or not self._name then return end
            self:_clear_psi()
            Logger.info(COMPONENT_NAME, "[%s] PSI update finished", tostring(self._name))
        end
    })

    return true
end

--- Приостанавливает мониторинг тюнера
function DvbTuner:pause()
    self._active = false
    Logger.info(COMPONENT_NAME, "[%s] Tuner monitoring paused", tostring(self._name))
end

--- Возобновляет мониторинг тюнера
--- @return boolean Статус выполнения
function DvbTuner:resume()
    if not self._config then
        Logger.error(COMPONENT_NAME, "[%s] Cannot resume: tuner already destroyed", tostring(self._name))
        return false
    end
    self._active = true
    Logger.info(COMPONENT_NAME, "[%s] Tuner monitoring resumed", tostring(self._name))
    return true
end

--- Полностью останавливает тюнер и уничтожает объект.
--- Освобождает все ресурсы и возвращает оригинальную конфигурацию.
--- @param force boolean|nil Принудительная остановка (игнорировать счетчик каналов)
--- @return table|nil Оригинальная конфигурация при успехе, иначе nil
function DvbTuner:destroy(force)
    if self._state ~= STATE.RUNNING then
        return nil
    end

    local channels = 0
    if self._instance and self._instance.__options then
        channels = self._instance.__options.channels or 0
    end

    if channels > 1 and force ~= true then
        Logger.warn(COMPONENT_NAME, "[%s] Cannot destroy tuner: busy (channels: %d)", tostring(self._name), channels)
        return nil
    end

    local original_config = self._config and Utils.table_copy(self._config) or nil

    -- 2. Очистка ресурсов
    self._active = false
    self._state = STATE.STOPPED
    self:_clear_psi()

    if self._instance then
        -- Очищаем callback во внутренней таблице параметров Astra (ОБЯЗАТЕЛЬНО согласно astra-api-usage.md)
        local opts = self._instance.__options
        if opts then
            opts.callback = nil
        end

        -- Безопасная очистка внутреннего списка Astra и закрытие инстанса
        -- Мы попадаем сюда только если channels <= 1 или force == true
        if type(dvb_input_instance_list) == "table" and opts then
            local adapter = opts.adapter
            local device = opts.device or "0"
            if adapter ~= nil then
                local instance_id = string_format("%s.%s", tostring(adapter), tostring(device))
                if dvb_input_instance_list[instance_id] then
                    dvb_input_instance_list[instance_id] = nil
                    Logger.debug(COMPONENT_NAME, "Removed tuner '%s' from Astra internal list (id: %s)", tostring(self._name), instance_id)
                end
            end
        end

        -- Физическое закрытие инстанса Astra
        if type(self._instance.close) == "function" then
            self._instance:close()
        end
        self._instance = nil
    end

    -- Очищаем callback в рабочей конфигурации
    if self._astra_conf then
        self._astra_conf.callback = nil
        self._astra_conf = nil
    end

    -- 3. Полная очистка полей объекта
    self._name = nil
    self._config = nil
    self._current_method = nil
    self._status = nil
    self._check_timer = nil
    self._json_cache = nil
    self._stats = nil
    self._psi = nil
    self._backup = nil
    self._reports = nil

    Logger.debug(COMPONENT_NAME, "Tuner object destroyed")
    collectgarbage()
    return original_config
end

return DvbTuner
