-- 1. Стандартные Lua функции
local collectgarbage = collectgarbage
local math_max = math.max
local math_min = math.min
local os_time = os.time
local pairs = pairs
local setmetatable = setmetatable
local string_format = string.format
local tostring = tostring
local type = type
local bit32 = bit32
local pcall = pcall

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local Utils = ModuleManager.get_module("utils")
local BaseMonitor = ModuleManager.get_module("core.base_monitor")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local dvb_tune = ModuleManager.get_global_dependency("dvb_tune")
local json_encode = ModuleManager.get_global_dependency("json.encode")
local dvb_input_instance_list = ModuleManager.get_global_dependency("dvb_input_instance_list")
local analyze = ModuleManager.get_global_dependency("analyze")
local timer = ModuleManager.get_global_dependency("timer")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "DvbTuner"

-- Предварительно рассчитанная таблица состояний для всех возможных значений статуса (0-31)
-- Это исключает циклы и побитовые операции в основном callback-е, обеспечивая максимальную производительность.
local STATUS_LOOKUP = {}
for i = 0, 31 do
    STATUS_LOOKUP[i] = {
        has_signal  = bit32.band(i, 0x01) ~= 0,
        has_carrier = bit32.band(i, 0x02) ~= 0,
        has_viterbi = bit32.band(i, 0x04) ~= 0,
        has_sync    = bit32.band(i, 0x08) ~= 0,
        has_lock    = bit32.band(i, 0x10) ~= 0,
    }
end

-- Методы сравнения
local METHOD_ALWAYS = 1
local METHOD_STRICT = 2
local METHOD_RATIO = 3

--- @class DvbTuner : BaseMonitor
--- @field private _status table|nil Текущий статус (signal, snr, ber, unc)
--- @field private _current_flags table|nil Текущие битовые флаги состояния
--- @field private _last_status_num number|nil Последнее числовое значение статуса
--- @field private _check_timer number|nil Счетчик для интервала проверки
--- @field private _stats table|nil Накопленная статистика для расчета качества
--- @field private _astra_conf table|nil Рабочая конфигурация для Astra
--- @field private _temp_analyzer any|nil Временный экземпляр анализатора для PSI
--- @field private _backup table|nil Бэкап предыдущего состояния (config, channels)
--- @field private _psi_timer any|nil Таймер сбора PSI
local DvbTuner = setmetatable({}, BaseMonitor)
DvbTuner.__index = DvbTuner

-- 5. Инициализация объектов из загруженных модулей
local ratio = Utils.ratio

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
--- @private
function DvbTuner:_clear_psi_resources()
    if self._psi_timer then
        if self._psi_timer.close then
            self._psi_timer:close()
        end
        self._psi_timer = nil
    end
    if self._temp_analyzer then
        -- Очистка callback ОБЯЗАТЕЛЬНА перед закрытием (astra-api-usage.md)
        if type(self._temp_analyzer.__options) == "table" then
            self._temp_analyzer.__options.callback = nil
        end
        if self._temp_analyzer.close then
            self._temp_analyzer:close()
        end
        self._temp_analyzer = nil
    end
end

--- Создает новый экземпляр DvbTuner
--- @param conf table Конфигурация тюнера
--- @return DvbTuner|nil Экземпляр DvbTuner или nil
function DvbTuner.new(conf)
    if not conf or type(conf) ~= "table" then
        Logger.error(COMPONENT_NAME, "new: конфигурация обязательна")
        return nil
    end

    if not conf.name_adapter or type(conf.name_adapter) ~= "string" then
        Logger.error(COMPONENT_NAME, "new: name_adapter обязателен")
        return nil
    end

    local self = setmetatable(BaseMonitor.new(conf, COMPONENT_NAME), DvbTuner)
    self._name = conf.name_adapter

    -- Валидация и установка параметров
    if not self:_set_config_param("dvb_rate", conf.rate, "dvb_") then return nil end
    if not self:_set_config_param("dvb_time_check", conf.time_check, "dvb_") then return nil end
    if not self:_set_config_param("dvb_method_comparison", conf.method_comparison, "dvb_") then return nil end
    if not self:_set_config_param("dvb_analyze", conf.analyze, "dvb_") then return nil end
    
    self._current_method = COMPARISON_METHODS[self._config.method_comparison]
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
    self._psi_timer = nil
    self._backup = nil
    self._last_status_num = -1
    self._current_flags = STATUS_LOOKUP[0]

    -- Таблица для Pull-запросов (всегда актуальное состояние)
    self._current_status_table = {}
    Utils.init_report(self._current_status_table, "dvb", self._name)
    self._current_status_table.name_adapter = self._name
    self._current_status_table.format = conf.type or ""
    self._current_status_table.modulation = conf.modulation or ""
    self._current_status_table.source = conf.tp or conf.frequency

    return self
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
--- @return any|nil Экземпляр dvb_tune Astra или nil
function DvbTuner:start()
    if self._state == BaseMonitor.STATE.RUNNING then
        Logger.warn(COMPONENT_NAME, "[%s] Тюнер уже запущен", tostring(self._name))
        return self._instance
    end

    if not self._current_method then
        Logger.error(COMPONENT_NAME, string_format("start: Некорректный метод сравнения %s", tostring(self._config.method_comparison)))
        return nil
    end

    -- Создаем рабочую копию конфига для Astra
    self._astra_conf = Utils.table_copy(self._config)
    
    -- Оптимизация: используем именованный метод и передаем его в pcall напрямую
    self._astra_conf.callback = function(data)
        if not self._active then return end
        local ok, err = pcall(self._on_astra_data, self, data)
        if not ok then
            Logger.error(COMPONENT_NAME, "[%s] Callback error: %s", tostring(self._name), tostring(err))
        end
    end

    local instance = dvb_tune(self._astra_conf)
    if not instance then
        Logger.error(COMPONENT_NAME, "[%s] start: dvb_tune вернул nil", tostring(self._name))
        return nil
    end

    self._instance = instance
    self._state = BaseMonitor.STATE.RUNNING
    self._active = true

    -- Безопасное управление счетчиком каналов Astra
    if self._instance and type(self._instance.__options) == "table" then
        local opts = self._instance.__options
        opts.channels = (opts.channels or 0) + 1
        Logger.debug(COMPONENT_NAME, "[%s] Tuner channels counter incremented: %d", tostring(self._name), opts.channels)
    end

    return self._instance
end

--- Обработчик данных от тюнера Astra (горячий путь)
--- @private
--- @param data table Данные от тюнера
function DvbTuner:_on_astra_data(data)
    if type(data) ~= "table" then return end

    -- Накопление статистики для расчета качества (упрощенно)
    if self._config.analyze and data.status and data.status > 0 then
        -- Защита от переполнения при длительном отсутствии изменений
        local MAX_STATS_COUNT = 1000000
        if self._stats.count < MAX_STATS_COUNT then
            self._stats.ber_sum = self._stats.ber_sum + (data.ber or 0)
            self._stats.unc_sum = self._stats.unc_sum + (data.unc or 0)
            self._stats.count = self._stats.count + 1
        end
    end

    -- Оптимизированная проверка: сначала интервал, затем force или тяжелое условие
    if self:_should_send(self._astra_conf.time_check) and 
       (self._force_timer >= self._force_interval or self._current_method(self._status, data, self._astra_conf.rate)) 
    then
        self:_reset_force_timer()
        self:_clear_json_cache()

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

        local s_num = data.status
        if s_num and s_num ~= self._last_status_num then
            -- Используем предрассчитанную таблицу для мгновенного получения флагов
            local flags = STATUS_LOOKUP[bit32.band(s_num, 0x1F)]
            if flags then
                self._current_flags = flags
                self._last_status_num = s_num
            end
        end

        -- Обновляем таблицу для Pull-запросов
        self:_build_status_table(self._current_status_table)

        -- Создаем таблицу для Push-уведомления из пула
        local r = self:get_table_from_pool("report")
        Utils.init_report(r, "dvb", self._name)
        r.name_adapter = self._name
        r.format = self._config.type or ""
        r.modulation = self._config.modulation or ""
        r.source = self._config.tp or self._config.frequency
        self:_build_status_table(r)

        -- Публикуем таблицу
        self:publish(r, "dvb", true)
    end
end

--- Обновляет параметры мониторинга тюнера
--- @param params table Новые параметры (rate, time_check, method_comparison)
--- @return boolean Статус выполнения
function DvbTuner:update_parameters(params)
    if not params or type(params) ~= "table" then
        Logger.error(COMPONENT_NAME, "[%s] update_parameters: параметры должны быть таблицей", tostring(self._name))
        return false
    end

    -- Обновляем self._config (оригинал) и self._astra_conf (живой конфиг)
    if params.rate ~= nil then
        self:_set_config_param("dvb_rate", params.rate, "dvb_")
        if self._astra_conf then self._astra_conf.rate = self._config.rate end
    end
    if params.time_check ~= nil then
        self:_set_config_param("dvb_time_check", params.time_check, "dvb_")
        if self._astra_conf then self._astra_conf.time_check = self._config.time_check end
    end
    if params.method_comparison ~= nil then
        self:_set_config_param("dvb_method_comparison", params.method_comparison, "dvb_")
        if self._astra_conf then self._astra_conf.method_comparison = self._config.method_comparison end
        -- Обновляем прямую ссылку на метод для callback
        self._current_method = COMPARISON_METHODS[self._config.method_comparison]
    end
    if params.analyze ~= nil then
        self:_set_config_param("dvb_analyze", params.analyze, "dvb_")
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


--- Внутренний метод для сборки таблицы полного статуса.
--- @private
--- @param t table Целевая таблица для заполнения
--- @return table Таблица статуса
function DvbTuner:_build_status_table(t)
    local status = self._status or {}
    t.status = status.status or 0
    t.signal = status.signal or 0
    t.snr = status.snr or 0
    t.ber = status.ber or 0
    t.unc = status.unc or 0
    t.quality = status.quality or 0
    
    t.timestamp = os_time()
    return t
end

--- Возвращает актуальные данные в виде таблицы (сырые данные).
--- @return table|nil Таблица данных
function DvbTuner:get_status_table()
    return self._current_status_table
end

--- Возвращает детальные флаги состояния тюнера (has_signal, has_lock и т.д.)
--- @return table Таблица флагов
function DvbTuner:get_status_flags()
    local flags = self._current_flags or STATUS_LOOKUP[0]
    local result = {
        name_adapter = self._name
    }
    for k, v in pairs(flags) do
        result[k] = v
    end
    return result
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
                self:_process_psi_data(data)
            end
        end
    })

    if not self._temp_analyzer then
        return false
    end

    -- Используем планировщик вместо отдельного таймера
    local scheduler = Scheduler.get_instance()
    scheduler:add_task("psi_update_" .. self._name, function()
        if not self or not self._name then return end
        self:_clear_psi_resources()
        scheduler:remove_task("psi_update_" .. self._name)
        Logger.info(COMPONENT_NAME, "[%s] PSI update finished", tostring(self._name))
    end, 10)

    return true
end

--- Полностью останавливает мониторинг тюнера и уничтожает объект.
--- Освобождает ресурсы и возвращает оригинальную конфигурацию.
--- @param force boolean Принудительная остановка (игнорировать счетчик каналов)
--- @return table|nil Оригинальная конфигурация при успехе, иначе nil
function DvbTuner:destroy(force)
    if self._state ~= BaseMonitor.STATE.RUNNING then
        return nil
    end

    local original_config = self._config and Utils.table_copy(self._config) or nil
    local opts = self._instance and self._instance.__options
    local channels = (type(opts) == "table") and (opts.channels or 0) or 0

    -- Согласно astra-api-usage.md: если адаптер занят другими стримами (channels > 1)
    -- и не передан флаг force, мы не можем изменять состояние и должны прервать выполнение.
    if channels > 1 and not force then
        Logger.warn(COMPONENT_NAME, "[%s] destroy: адаптер занят (%d канала), удаление отменено", 
            tostring(self._name), channels)
        return nil
    end

    -- Декрементируем счетчик, так как монитор отключается
    if type(opts) == "table" then
        opts.channels = (channels > 0) and (channels - 1) or 0
        channels = opts.channels
    end

    -- 1. Остановка логики мониторинга
    self._active = false
    self._state = BaseMonitor.STATE.STOPPED
    self:_clear_psi_resources()
    self:_clear_psi()

    -- 2. Физическое закрытие тюнера (если требуется)
    if self._instance then
        -- Очищаем callback во внутренней таблице параметров Astra ОБЯЗАТЕЛЬНО
        if type(opts) == "table" then
            opts.callback = nil
        end

        -- Безопасная очистка внутреннего списка Astra
        if type(dvb_input_instance_list) == "table" and type(opts) == "table" then
            local adapter = opts.adapter
            local device = opts.device or "0"
            if adapter ~= nil then
                local instance_id = string_format("%s.%s", tostring(adapter), tostring(device))
                dvb_input_instance_list[instance_id] = nil
                Logger.debug(COMPONENT_NAME, "Удален тюнер '%s' из внутреннего списка Astra (id: %s)", tostring(self._name), instance_id)
            end
        end

        -- Физическое закрытие инстанса Astra
        if self._instance.close then
            self._instance:close()
        end
        Logger.info(COMPONENT_NAME, "[%s] Тюнер физически закрыт", tostring(self._name))
        
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
    self._json_cache = nil
    self._stats = nil
    self._backup = nil
    self._current_status_table = nil

    Logger.debug(COMPONENT_NAME, "Объект тюнера уничтожен")
    collectgarbage()
    return original_config
end

return DvbTuner
