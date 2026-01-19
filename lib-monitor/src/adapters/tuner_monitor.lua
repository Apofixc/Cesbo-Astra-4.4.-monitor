-- ===========================================================================
-- Модуль `adapters.tuner_monitor`
--
-- Класс для мониторинга физических DVB-адаптеров. Отслеживает уровень сигнала,
-- SNR, ошибки BER/UNC и рассчитывает интегральный показатель качества.
-- ===========================================================================

-- 1. Стандартные Lua функции
local math_max = math.max
local os_time = os.time
local pairs = pairs
local setmetatable = setmetatable
local string_format = string.format
local tostring = tostring
local type = type
local bit32 = bit32
local pcall = pcall
local bit32_band = bit32.band

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local Utils = ModuleManager.get_module("utils")
local BaseMonitor = ModuleManager.get_module("core.base_monitor")
local Scheduler = ModuleManager.get_module("core.scheduler")
local MonitorConfig = ModuleManager.get_module("monitor_config")

-- 3. Глобальные зависимости Astra
local dvb_tune = ModuleManager.get_global_dependency("dvb_tune")
local dvb_input_instance_list = ModuleManager.get_global_dependency("dvb_input_instance_list")
local analyze = ModuleManager.get_global_dependency("analyze")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "TunerMonitor"
local MAX_STATS_COUNT = (MonitorConfig and MonitorConfig.MaxCounterValue) or 1000000

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
local METHOD_RATIO = 2
local METHOD_LOCK_ONLY = 3
local METHOD_ERROR_CRITICAL = 4
local METHOD_QUALITY_RATIO = 5
local METHOD_STATUS_ANY = 6
local METHOD_SIGNAL_DROP = 7

local ratio = Utils.ratio

local COMPARISON_METHODS = {
    -- 1. Всегда отправлять отчет при каждой проверке
    [METHOD_ALWAYS] = function(prev, curr, rate, quality)
        return true
    end,

    -- 2. Любые изменения параметров через ratio
    [METHOD_RATIO] = function(prev, curr, rate, quality)
        return (prev.status or -1) ~= (curr.status or -1) or
               ratio(prev.signal or 0, curr.signal or 0) > rate or
               ratio(prev.snr or 0, curr.snr or 0) > rate or
               (prev.ber or -1) ~= (curr.ber or -1) or
               (prev.unc or -1) ~= (curr.unc or -1)
    end,

    -- 3. Только изменение бита Lock
    [METHOD_LOCK_ONLY] = function(prev, curr, rate, quality)
        local prev_lock = bit32.band(prev.status or 0, 0x10) ~= 0
        local curr_lock = bit32.band(curr.status or 0, 0x10) ~= 0
        return prev_lock ~= curr_lock
    end,

    -- 4. Изменение Lock или появление ошибок BER/UNC
    [METHOD_ERROR_CRITICAL] = function(prev, curr, rate, quality)
        local prev_lock = bit32.band(prev.status or 0, 0x10) ~= 0
        local curr_lock = bit32.band(curr.status or 0, 0x10) ~= 0
        return prev_lock ~= curr_lock or (curr.ber or 0) > 0 or (curr.unc or 0) > 0
    end,

    -- 5. Изменение Lock или расчетного показателя Quality
    [METHOD_QUALITY_RATIO] = function(prev, curr, rate, quality)
        local prev_lock = bit32.band(prev.status or 0, 0x10) ~= 0
        local curr_lock = bit32.band(curr.status or 0, 0x10) ~= 0
        return prev_lock ~= curr_lock or ratio(prev.quality or 0, quality or 0) > rate
    end,

    -- 6. Любое изменение битовой маски статуса (Signal, Carrier, Viterbi, Sync, Lock)
    [METHOD_STATUS_ANY] = function(prev, curr, rate, quality)
        return (prev.status or -1) ~= (curr.status or -1)
    end,

    -- 7. Изменение Lock или только падение уровня сигнала/SNR
    [METHOD_SIGNAL_DROP] = function(prev, curr, rate, quality)
        local prev_lock = bit32.band(prev.status or 0, 0x10) ~= 0
        local curr_lock = bit32.band(curr.status or 0, 0x10) ~= 0
        if prev_lock ~= curr_lock then return true end

        local is_signal_drop = (prev.signal or 0) > (curr.signal or 0) and
                               ratio(prev.signal or 0, curr.signal or 0) > rate
        local is_snr_drop = (prev.snr or 0) > (curr.snr or 0) and
                            ratio(prev.snr or 0, curr.snr or 0) > rate

        return is_signal_drop or is_snr_drop or (curr.ber or 0) > 0 or (curr.unc or 0) > 0
    end
}

-- 5. Внутреннее состояние (Private State)
--- @class TunerMonitor : BaseMonitor
--- @field private _current_flags table|nil Текущие битовые флаги состояния
--- @field private _last_status_num number|nil Последнее числовое значение статуса
--- @field private _stats table|nil Накопленная статистика для расчета качества
--- @field private _astra_conf table|nil Рабочая конфигурация для Astra
--- @field private _temp_analyzer any|nil Временный экземпляр анализатора для PSI
--- @field private _backup table|nil Бэкап предыдущего состояния (config, channels)
local TunerMonitor = setmetatable({}, BaseMonitor)
TunerMonitor.__index = TunerMonitor

-- ===========================================================================
-- Внутренние функции (Private/Protected)
-- ===========================================================================

--- Вспомогательная функция для очистки ресурсов PSI
--- @private
function TunerMonitor:_clear_psi_resources()
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

--- Обработчик данных от тюнера Astra (горячий путь)
--- @private
--- @param data table Данные от тюнера
function TunerMonitor:_on_astra_data(data)
    if type(data) ~= "table" then return end

    local conf = self._astra_conf or self._config
    local master = self._current_status_table

    -- Накопление статистики для расчета качества (упрощенно)
    if conf.analyze and data.status and bit32_band(data.status, 0x10) ~= 0 then
        -- Защита от переполнения при длительном отсутствии изменений
        if self._stats.count < MAX_STATS_COUNT then
            self._stats.ber_sum = self._stats.ber_sum + (data.ber or 0)
            self._stats.unc_sum = self._stats.unc_sum + (data.unc or 0)
            self._stats.count = self._stats.count + 1
        end
    end

    -- Расчет качества (quality) для метода сравнения
    local current_quality = -1
    if conf.analyze and self._stats.count > 0 then
        local avg_ber = self._stats.ber_sum / self._stats.count
        if avg_ber > 0 or self._stats.unc_sum > 0 then
            current_quality = math_max(0, 100 - (avg_ber / 1000) - (self._stats.unc_sum * 10))
        else
            current_quality = 100
        end
    else
        current_quality = master.quality or -1
    end

    -- Оптимизированная проверка: сначала интервал, затем force или тяжелое условие
    if self:_should_send(conf.time_check) and
       (self:_is_force() or self._current_method(master, data, conf.rate, current_quality))
    then
        self:_reset_force_timer()

        -- Сброс статистики после отправки отчета
        if conf.analyze then
            self._stats.ber_sum = 0
            self._stats.unc_sum = 0
            self._stats.count = 0
        end

        -- Обновляем Master State (таблица для Pull-запросов)
        master.status = data.status or -1
        master.signal = data.signal or -1
        master.snr = data.snr or -1
        master.ber = data.ber or -1
        master.unc = data.unc or -1
        master.quality = current_quality
        master.timestamp = os_time()

        local s_num = data.status
        if s_num and s_num ~= self._last_status_num then
            -- Используем предрассчитанную таблицу для мгновенного получения флагов
            local flags = STATUS_LOOKUP[bit32_band(s_num, 0x1F)]
            if flags then
                self._current_flags = flags
                self._last_status_num = s_num
            end
        end

        -- Сбрасываем кэш JSON, так как данные изменились.
        self:_clear_json_cache()

        -- Создаем таблицу для Push-уведомления из пула через быстрое копирование
        local r = self:get_table_from_pool("report_dvb")
        Utils.init_report(r, "dvb", self._name)
        r.name_adapter = self._name
        r.format = conf.type or ""
        r.modulation = conf.modulation or ""
        r.source = conf.tp or conf.frequency

        -- Оптимизация: прямое копирование полей (горячий путь)
        r.status = master.status
        r.signal = master.signal
        r.snr = master.snr
        r.ber = master.ber
        r.unc = master.unc
        r.quality = master.quality
        r.timestamp = master.timestamp

        -- Публикуем таблицу с передачей горячего кэша
        self:publish(r, "dvb", true)
    end
end

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- Создает новый экземпляр TunerMonitor
--- @param conf table Конфигурация тюнера
--- @return TunerMonitor|nil Экземпляр TunerMonitor или nil
function TunerMonitor.new(conf)
    if not conf or type(conf) ~= "table" then
        Logger.error(COMPONENT_NAME, "new: конфигурация обязательна")
        return nil
    end

    if not conf.name_adapter or type(conf.name_adapter) ~= "string" then
        Logger.error(COMPONENT_NAME, "new: name_adapter обязателен")
        return nil
    end

    local self = setmetatable(BaseMonitor.new(conf, COMPONENT_NAME, "dvb_", COMPARISON_METHODS), TunerMonitor)

    -- 1. Идентификация
    self._name = conf.name_adapter

    -- 2. Унифицированная инициализация конфигурации
    self:_init_config(conf, {
        "rate",
        "time_check",
        "method_comparison",
        "analyze"
    })

    -- 3. Состояние тюнера и флаги
    self:_init_status_table("dvb")
    local master = self._current_status_table
    master.name_adapter = self._name
    master.format = conf.type or ""
    master.modulation = conf.modulation or ""
    master.source = conf.tp or conf.frequency
    master.status = -1
    master.signal = -1
    master.snr = -1
    master.ber = -1
    master.unc = -1
    master.quality = -1

    self._current_flags = STATUS_LOOKUP[0]
    self._last_status_num = -1

    -- 4. Статистика качества
    self._stats = {
        ber_sum = 0,
        unc_sum = 0,
        count = 0
    }

    -- 5. Вспомогательные объекты и бэкап
    self._astra_conf = nil
    self._temp_analyzer = nil
    self._backup = nil

    return self
end

--- Сохраняет бэкап предыдущего состояния
--- @param config table Предыдущая конфигурация
--- @param channels table Список конфигураций каналов
function TunerMonitor:set_backup(config, channels)
    self._backup = {
        config = Utils.deep_copy(config),
        channels = Utils.deep_copy(channels)
    }
end

--- Возвращает бэкап предыдущего состояния
--- @return table|nil Бэкап или nil
function TunerMonitor:get_backup()
    return self._backup
end

--- Запускает тюнер и инициализирует callback для мониторинга.
--- Автоматически создает рабочую копию конфигурации для Astra.
--- @return any|nil Экземпляр dvb_tune Astra или nil
function TunerMonitor:start()
    if self._state == BaseMonitor.STATE.RUNNING then
        Logger.warning(COMPONENT_NAME, "[%s] Тюнер уже запущен", tostring(self._name))
        return self._instance
    end

    if not self._current_method then
        Logger.error(COMPONENT_NAME, string_format("start: некорректный метод сравнения %s",
            tostring(self._config.method_comparison)))
        return nil
    end

    -- Создаем рабочую копию конфига для Astra
    self._astra_conf = Utils.table_copy(self._config)

    -- Оптимизация: используем именованный метод и передаем его в pcall напрямую
    self._astra_conf.callback = function(data)
        if not self._active then return end
        local ok, err = pcall(self._on_astra_data, self, data)
        if not ok then
            Logger.error(COMPONENT_NAME, "[%s] Ошибка в callback: %s", tostring(self._name), tostring(err))
        end
    end

    local instance = dvb_tune(self._astra_conf)
    if not instance then
        Logger.error(COMPONENT_NAME, "[%s] start: dvb_tune вернул nil",
            tostring(self._name))
        return nil
    end

    self._instance = instance
    self._state = BaseMonitor.STATE.RUNNING
    self._active = true

    -- Безопасное управление счетчиком каналов Astra
    if self._instance and type(self._instance.__options) == "table" then
        local opts = self._instance.__options
        opts.channels = (opts.channels or 0) + 1
        Logger.debug(COMPONENT_NAME, "[%s] Счетчик каналов тюнера увеличен: %d", tostring(self._name), opts.channels)
    end

    return self._instance
end


--- Проверяет функциональное здоровье тюнера (наличие Lock)
--- @return boolean|nil true если всё в порядке, false если обнаружен сбой, nil если проверка не применима
function TunerMonitor:check_infrastructure_health()
    if self._state ~= BaseMonitor.STATE.RUNNING then return nil end

    local flags = self._current_flags
    if not flags then return false end

    -- Проверка Lock (0x10)
    return flags.has_lock == true
end

--- Вызывается при обновлении конфигурации.
--- Синхронизирует рабочую конфигурацию Astra.
--- @protected
--- @param key string Ключ параметра
--- @param value any Новое значение
function TunerMonitor:_on_config_updated(key, value)
    -- Вызываем базовый метод для синхронизации метода сравнения
    BaseMonitor._on_config_updated(self, key, value)

    -- Если рабочая копия еще не создана (до start), мы ничего не делаем.
    if not self._astra_conf then return end

    -- Синхронизируем рабочую копию
    self._astra_conf[key] = value

    -- Если анализ выключен, сбрасываем накопленную статистику
    if key == "analyze" and not value then
        self._stats.ber_sum = 0
        self._stats.unc_sum = 0
        self._stats.count = 0
    end

    -- Обновление параметров в работающем экземпляре тюнера Astra (если применимо)
    if self._instance and type(self._instance.__options) == "table" then
        local opts = self._instance.__options
        if opts[key] ~= nil then opts[key] = value end
    end
end

--- Возвращает детальные флаги состояния тюнера (has_signal, has_lock и т.д.)
--- @return table Таблица флагов
function TunerMonitor:get_status_flags()
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
function TunerMonitor:psi_update()
    if not self._instance or self._temp_analyzer then
        return false
    end

    self._temp_analyzer = analyze({
        upstream = self._instance:stream(),
        name = "psi_update_" .. self._name,
        join_pid = true,
        callback = function(data)
            if not data or not self._temp_analyzer then return end
            local ok, err = pcall(self._process_psi_data, self, data)
            if not ok then
                Logger.error(COMPONENT_NAME, "[%s] Ошибка в psi_update callback: %s",
                    tostring(self._name), tostring(err))
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
        Logger.info(COMPONENT_NAME, "[%s] Обновление PSI завершено", tostring(self._name))
    end, 10)

    return true
end

--- Проверяет возможность удаления тюнера (счетчик каналов).
--- @protected
--- @param force boolean Принудительное удаление
--- @return boolean Разрешено ли удаление
function TunerMonitor:_can_destroy(force)
    local opts = self._instance and self._instance.__options
    local channels = (type(opts) == "table") and (opts.channels or 0) or 0

    -- Согласно astra-api-usage.md: если адаптер занят другими стримами (channels > 1)
    -- и не передан флаг force, мы не можем изменять состояние и должны прервать выполнение.
    if channels > 1 and not force then
        Logger.warning(COMPONENT_NAME,
            "[%s] destroy: адаптер занят (%d канала), удаление отменено",
            tostring(self._name), channels)
        return false
    end

    -- Декрементируем счетчик, так как монитор отключается
    if type(opts) == "table" then
        opts.channels = (channels > 0) and (channels - 1) or 0
    end

    return true
end

--- Специфическая очистка ресурсов тюнера.
--- @protected
function TunerMonitor:_on_destroy()
    self:_clear_psi_resources()

    -- Очистка задачи планировщика, если она была запущена через psi_update
    local scheduler = Scheduler and Scheduler.get_instance()
    if scheduler and self._name then
        scheduler:remove_task("psi_update_" .. self._name)
    end

    -- Безопасная очистка внутреннего списка Astra
    local opts = self._instance and self._instance.__options
    if type(dvb_input_instance_list) == "table" and type(opts) == "table" then
        local adapter = opts.adapter
        local device = opts.device or "0"
        if adapter ~= nil then
            local instance_id = string_format("%s.%s", tostring(adapter),
                tostring(device))
            dvb_input_instance_list[instance_id] = nil
        end
    end

    self._current_flags = nil
    self._last_status_num = nil
    self._stats = nil
    self._backup = nil
    self._astra_conf = nil
end

-- ===========================================================================
-- Инициализация модуля
-- ===========================================================================

-- Регистрация пулов при загрузке модуля
local tp = ModuleManager.get_module("table_pool")
if tp then
    tp.register_type("report_dvb")
end

-- ===========================================================================
-- Инициализация модуля
-- ===========================================================================

return TunerMonitor
