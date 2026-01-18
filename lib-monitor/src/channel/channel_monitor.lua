-- ===========================================================================
-- Модуль `channel.channel_monitor`
--
-- Класс для мониторинга MPEG-TS потоков каналов. Анализирует ошибки CC/PES,
-- битрейт, скремблирование и PSI-таблицы. Поддерживает Pull и Push модели.
-- ===========================================================================

-- 1. Стандартные Lua функции
local ipairs = _G.ipairs
local pairs = _G.pairs
local os_time = _G.os.time
local setmetatable = _G.setmetatable
local tostring = _G.tostring
local type = _G.type
local pcall = _G.pcall

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local Utils = ModuleManager.get_module("utils")
local BaseMonitor = ModuleManager.get_module("core.base_monitor")
local MonitorConfig = ModuleManager.get_module("monitor_config")

-- 3. Глобальные зависимости Astra
local analyze = ModuleManager.get_global_dependency("analyze")
local kill_input = ModuleManager.get_global_dependency("kill_input")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ChannelMonitor"
local DEFAULT_SOURCE_TEMPLATE = { format = "Unknown", addr = "Unknown", stream = "Unknown" }
local MAX_COUNTER = (MonitorConfig and MonitorConfig.MaxCounterValue) or 1000000000
local MAX_ERROR_COUNT = (MonitorConfig and MonitorConfig.MaxErrorCount) or 1000000
local PID_LIMIT = (MonitorConfig and MonitorConfig.PidStatsLimit) or 100

-- Методы сравнения
local METHOD_ALWAYS = 1
local METHOD_RATIO = 2
local METHOD_ON_AIR = 3
local METHOD_CC_THRESHOLD = 4
local METHOD_ERROR_ONLY = 5
local METHOD_BITRATE_DROP = 6
local METHOD_PES_STRICT = 7
local METHOD_VIDEO_ONLY = 8

local ratio = Utils.ratio

-- Методы сравнения
local COMPARISON_METHODS = {
    -- 1. Всегда отправлять отчет при каждой проверке
    [METHOD_ALWAYS] = function(prev, curr, rate, cc_threshold, stats)
        return true
    end,

    -- 2. Любые изменения (битрейт по ratio, CC > 0)
    [METHOD_RATIO] = function(prev, curr, rate, cc_threshold, stats)
        return prev.ready ~= curr.on_air or
               prev.scrambled ~= curr.total.scrambled or
               (prev.cc_errors or 0) > 0 or
               (prev.pes_errors or 0) > 0 or
               ratio(prev.bitrate, curr.total.bitrate) > rate
    end,

    -- 3. Только изменение статуса On Air
    [METHOD_ON_AIR] = function(prev, curr, rate, cc_threshold, stats)
        return prev.ready ~= curr.on_air
    end,

    -- 4. Изменения с учетом порога CC
    [METHOD_CC_THRESHOLD] = function(prev, curr, rate, cc_threshold, stats)
        return prev.ready ~= curr.on_air or
               prev.scrambled ~= curr.total.scrambled or
               (prev.cc_errors or 0) > (cc_threshold or 0) or
               (prev.pes_errors or 0) > 0 or
               ratio(prev.bitrate, curr.total.bitrate) > rate
    end,

    -- 5. Игнорировать битрейт, только ошибки (CC > threshold, PES, Scrambled)
    [METHOD_ERROR_ONLY] = function(prev, curr, rate, cc_threshold, stats)
        return prev.ready ~= curr.on_air or
               prev.scrambled ~= curr.total.scrambled or
               (prev.cc_errors or 0) > (cc_threshold or 0) or
               (prev.pes_errors or 0) > 0
    end,

    -- 6. Только при падении битрейта (игнорировать рост)
    [METHOD_BITRATE_DROP] = function(prev, curr, rate, cc_threshold, stats)
        local is_drop = (prev.bitrate > curr.total.bitrate) and
                        (ratio(prev.bitrate, curr.total.bitrate) > rate)
        return prev.ready ~= curr.on_air or
               prev.scrambled ~= curr.total.scrambled or
               (prev.cc_errors or 0) > (cc_threshold or 0) or
               (prev.pes_errors or 0) > 0 or
               is_drop
    end,

    -- 7. Реакция на любую PES-ошибку (> 0), не дожидаясь порога Astra
    [METHOD_PES_STRICT] = function(prev, curr, rate, cc_threshold, stats)
        return prev.ready ~= curr.on_air or
               (prev.pes_errors or 0) > 0
    end,

    -- 8. Проверка ошибок только на видео-PID (игнорировать ошибки в аудио/телетексте)
    [METHOD_VIDEO_ONLY] = function(prev, curr, rate, cc_threshold, stats)
        if prev.ready ~= curr.on_air or prev.scrambled ~= curr.total.scrambled then
            return true
        end
        -- Проверяем ошибки только в видео-потоках из накопленной статистики
        if stats then
            for _, s in pairs(stats) do
                if s.type == "VIDEO" and (s.cc > 0 or s.pes > 0) then
                    return true
                end
            end
        end
        return ratio(prev.bitrate, curr.total.bitrate) > rate
    end
}

-- 5. Внутреннее состояние (Private State)
--- @class ChannelMonitor : BaseMonitor
--- @field private _display_name string Отображаемое имя монитора
--- @field private _input_instance any|nil Экземпляр входного потока (для IP мониторов)
--- @field private _channel_data table|nil Данные канала (Astra)
--- @field private _stream_json table Данные об источниках потока
--- @field private _stats table Статистика анализа по PID
--- @field private _stats_count number Текущее количество отслеживаемых PID
--- @field private _upstream any Объект апстрима
--- @field private _last_active_id number|nil ID последнего активного входа
--- @field private _cached_source table|nil Кэшированные данные текущего источника
--- @field private _astra_conf table|nil Рабочая конфигурация для Astra
local ChannelMonitor = setmetatable({}, BaseMonitor)
ChannelMonitor.__index = ChannelMonitor

-- ===========================================================================
-- Внутренние функции (Private/Protected)
-- ===========================================================================

--- Возвращает закэшированные данные об источнике
--- @private
--- @return table Данные об источнике
function ChannelMonitor:_get_cached_source()
    local active_id = self._channel_data and self._channel_data.active_input_id or 1
    if active_id ~= self._last_active_id then
        self._last_active_id = active_id
        self._cached_source = self._stream_json[active_id] or DEFAULT_SOURCE_TEMPLATE
    end
    return self._cached_source
end

--- Обработка ошибок потока
--- @private
--- @param data table Данные ошибки
function ChannelMonitor:_process_error_data(data)
    local r = self:get_table_from_pool("report_error")
    Utils.init_report(r, "Channel", self._name)
    r.display_name = self._display_name
    r.monitor = self._config.monitor
    r.error = data.error
    r.timestamp = os_time()
    self:publish(r, "error", true)
end

--- Обработчик данных от анализатора Astra (горячий путь)
--- @private
--- @param data table Данные от анализатора
function ChannelMonitor:_on_astra_data(data)
    if type(data) ~= "table" then return end

    if data.error then
        self:_process_error_data(data)
        return
    end

    if data.psi then
        self:_process_psi_data(data)
        return
    end

    if data.analyze then
        self:_process_analyze_data(data)
    end

    if data.total then
        self:_process_total_data(data)
    end
end

--- Обработка PSI данных.
--- Переопределяет базовый метод для извлечения статистики PID.
--- @protected
--- @param data table Данные PSI
function ChannelMonitor:_process_psi_data(data)
    -- Вызываем базовую логику сохранения в кэш
    BaseMonitor._process_psi_data(self, data)

    local table_id = data.psi and data.psi:upper()
    if table_id == "PMT" and type(data.streams) == "table" then
        for _, stream in ipairs(data.streams) do
            local pid = stream.pid
            if pid then
                local type_name = stream.type_name or "UNKNOWN"
                local stats = self._stats[pid]
                if not stats then
                    -- Лимит на количество отслеживаемых PID
                    if self._stats_count >= PID_LIMIT then
                        self:_clear_stats()
                        Logger.warn(COMPONENT_NAME,
                            "[%s] Достигнут лимит статистики PID при обработке PSI, очистка статистики",
                            tostring(self._name))
                    end

                    -- Статическое создание таблицы вместо пула
                    stats = {
                        type = type_name,
                        cc = 0,
                        pes = 0,
                        sc = 0
                    }

                    self._stats[pid] = stats
                    self._stats_count = self._stats_count + 1
                else
                    stats.type = type_name
                end
            end
        end
    end
end

--- Обработка данных анализа (статистика по PID)
--- @private
--- @param data table Данные анализа
function ChannelMonitor:_process_analyze_data(data)
    local conf = self._astra_conf or self._config
    if not conf.analyze or type(data.analyze) ~= "table" then return end

    for _, pid_data in ipairs(data.analyze) do
        local pid = pid_data.pid
        if pid then
            local cc = pid_data.cc_error or 0
            local pes = pid_data.pes_error or 0
            local sc = pid_data.sc_error or 0

            if cc > 0 or pes > 0 or sc > 0 then
                local stats = self._stats[pid]
                if not stats then
                    -- Лимит на количество отслеживаемых PID для предотвращения утечек памяти
                    if self._stats_count >= PID_LIMIT then
                        self:_clear_stats()
                        Logger.warn(COMPONENT_NAME, "[%s] Достигнут лимит статистики PID, очистка статистики",
                            tostring(self._name))
                    end

                    -- Статическое создание таблицы вместо пула
                    stats = {
                        type = "UNKNOWN",
                        cc = cc,
                        pes = pes,
                        sc = sc
                    }

                    self._stats[pid] = stats
                    self._stats_count = self._stats_count + 1
                else
                    -- Защита от переполнения
                    stats.cc = (stats.cc + cc) > MAX_COUNTER and MAX_COUNTER or (stats.cc + cc)
                    stats.pes = (stats.pes + pes) > MAX_COUNTER and MAX_COUNTER or (stats.pes + pes)
                    stats.sc = (stats.sc + sc) > MAX_COUNTER and MAX_COUNTER or (stats.sc + sc)
                end
            end
        end
    end
end

--- Обработка суммарных данных потока
--- @private
--- @param data table Суммарные данные
function ChannelMonitor:_process_total_data(data)
    local total = data.total
    if not total then return end

    local master = self._current_status_table
    local cc_inc = total.cc_errors or 0
    local pes_inc = total.pes_errors or 0

    -- Накапливаем ошибки в основной таблице статуса
    master.cc_errors = (master.cc_errors or 0) + cc_inc
    master.pes_errors = (master.pes_errors or 0) + pes_inc

    -- Защита от переполнения счетчиков
    if master.cc_errors > MAX_ERROR_COUNT then master.cc_errors = MAX_ERROR_COUNT end
    if master.pes_errors > MAX_ERROR_COUNT then master.pes_errors = MAX_ERROR_COUNT end

    local active_id = self._channel_data and self._channel_data.active_input_id or 1
    local conf = self._astra_conf or self._config

    -- Оптимизированная проверка: сначала интервал, затем force или тяжелое условие
    if self:_should_send(conf.time_check) and
       (active_id ~= self._last_active_id or self:_is_force() or
        self._current_method(master, data, conf.rate, conf.cc_threshold, self._stats))
    then
        self:_reset_force_timer()

        -- Обновление состояния
        local source = self:_get_cached_source()
        master.status = data.on_air
        master.ready = data.on_air
        master.scrambled = total.scrambled
        master.bitrate = total.bitrate or 0
        master.stream = source.stream
        master.format = source.format
        master.addr = source.addr
        master.timestamp = os_time()

        self._last_active_id = active_id

        -- Сбрасываем кэш JSON, так как данные изменились.
        self:_clear_json_cache()

        -- Создаем таблицу для Push-уведомления из пула через быстрое копирование
        local r = self:get_table_from_pool("report_channel")
        Utils.init_report(r, "Channel", self._name)
        r.display_name = self._display_name
        r.monitor = self._config.monitor

        -- Оптимизация: прямое копирование полей (горячий путь)
        r.status = master.status
        r.bitrate = master.bitrate
        r.cc_errors = master.cc_errors
        r.pes_errors = master.pes_errors
        r.scrambled = master.scrambled
        r.ready = master.ready
        r.stream = master.stream
        r.format = master.format
        r.addr = master.addr
        r.timestamp = master.timestamp

        -- Сбрасываем счетчики ошибок после отправки отчета
        master.cc_errors = 0
        master.pes_errors = 0

        -- Публикуем таблицу с передачей горячего кэша
        self:publish(r, "channels", true)
    end
end

--- Очищает статистику анализа
--- @private
function ChannelMonitor:_clear_stats()
    -- Больше не возвращаем в пул, так как таблицы статические
    self._stats = {}
    self._stats_count = 0
end

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- Создает новый экземпляр ChannelMonitor
--- @param config table Конфигурация монитора
--- @param channel_data table|nil Данные канала (необязательно)
--- @return ChannelMonitor|nil Экземпляр монитора или nil
function ChannelMonitor.new(config, channel_data)
    if not config or type(config) ~= "table" then
        Logger.error(COMPONENT_NAME, "new: конфигурация обязательна и должна быть таблицей")
        return nil
    end

    if not config.monitor or type(config.monitor) ~= "string" then
        Logger.error(COMPONENT_NAME, "new: адрес монитора обязателен в конфигурации")
        return nil
    end

    if not config.upstream then
        Logger.error(COMPONENT_NAME, "new: параметр upstream обязателен в конфигурации")
        return nil
    end

    local self = setmetatable(BaseMonitor.new(config, COMPONENT_NAME, "channel_", COMPARISON_METHODS), ChannelMonitor)

    -- 1. Данные канала и идентификация
    self._channel_data = type(channel_data) == "table" and channel_data or nil
    self._name = config.name or (self._channel_data and self._channel_data.name) or config.monitor
    self._display_name = config.display_name or (self._channel_data and self._channel_data.display_name) or self._name

    -- 2. Рабочая конфигурация (инициализируется при старте)
    self._astra_conf = nil

    -- 3. Унифицированная инициализация конфигурации
    self:_init_config(config, {
        "rate",
        "time_check",
        "method_comparison",
        "cc_threshold",
        "analyze",
        "cc_limit",
        "bitrate_limit",
        "join_pid"
    })

    -- 4. Состояние мониторинга и статистика
    self:_init_status_table("Channel")
    local master = self._current_status_table
    master.display_name = self._display_name
    master.monitor = self._config.monitor
    master.cc_errors = 0
    master.pes_errors = 0
    master.bitrate = 0
    master.ready = false
    master.scrambled = false

    self._stats = {}
    self._stats_count = 0

    -- 5. Источники и апстрим
    self._stream_json = config.stream_json or {}
    self._upstream = config.upstream
    self._input_instance = nil
    self._last_active_id = nil
    self._cached_source = nil

    return self
end

--- Запускает мониторинг
--- @return any|nil Экземпляр анализатора Astra или nil
function ChannelMonitor:start()
    if self._state == BaseMonitor.STATE.RUNNING then
        Logger.warn(COMPONENT_NAME, "[%s] Монитор уже запущен", tostring(self._name))
        return self._instance
    end

    -- Создаем рабочую копию конфигурации (эталон self._config остается неизменным)
    self._astra_conf = Utils.table_copy(self._config)

    if not self._current_method then
        Logger.error(COMPONENT_NAME, "[%s] start: некорректный метод сравнения %s",
            self._name, tostring(self._astra_conf.method_comparison))
        return nil
    end

    if not self._upstream or type(self._upstream.stream) ~= "function" then
        Logger.error(COMPONENT_NAME, "[%s] start: upstream некорректен или отсутствует метод stream()",
            tostring(self._name))
        return nil
    end

    local stream_data = self._upstream:stream()
    if not stream_data then
        Logger.error(COMPONENT_NAME, "[%s] start: upstream:stream() вернул nil", tostring(self._name))
        return nil
    end

    self._instance = analyze({
        upstream = stream_data,
        name = "_" .. self._name,
        cc_limit = self._astra_conf.cc_limit,
        bitrate_limit = self._astra_conf.bitrate_limit,
        join_pid = self._astra_conf.join_pid,
        callback = function(data)
            -- Защита от вызова после destroy или во время очистки
            if not self._active or not self._instance then return end

            local ok, err = pcall(self._on_astra_data, self, data)
            if not ok then
                -- В экстремальных условиях логируем только критические ошибки
                if self._active then
                    Logger.error(COMPONENT_NAME, "[%s] Ошибка в callback: %s",
                        tostring(self._name), tostring(err))
                end
            end
        end
    })

    if not self._instance then
        Logger.error(COMPONENT_NAME, "[%s] start: analyze вернул nil", self._name)
        return nil
    end

    self._state = BaseMonitor.STATE.RUNNING
    self._active = true

    return self._instance
end

--- Устанавливает экземпляр входного потока
--- @param instance any Экземпляр входа
function ChannelMonitor:set_input_instance(instance)
    self._input_instance = instance
end

--- Возвращает экземпляр входного потока
--- @return any|nil Экземпляр входа
function ChannelMonitor:get_input_instance()
    return self._input_instance
end

--- Возвращает статистику анализа по PID
--- @return table Статистика по PID
function ChannelMonitor:get_stats()
    local stats = {}
    if self._stats then
        for k, v in pairs(self._stats) do
            stats[tostring(k)] = v
        end
    end
    return stats
end

--- Очищает статистику анализа (публичный метод)
function ChannelMonitor:clear_stats()
    self:_clear_stats()
end

--- Проверяет функциональное здоровье канала (битрейт и скремблирование)
--- @return boolean|nil is_healthy
function ChannelMonitor:check_infrastructure_health()
    if self._state ~= BaseMonitor.STATE.RUNNING then return nil end

    local master = self._current_status_table
    if not master then return false end

    -- 1. Проверка Bitrate (No Data)
    if (master.bitrate or 0) == 0 then return false end

    -- 2. Проверка Scrambled (CAS Error)
    if master.scrambled then return false end

    return true
end

--- Специфическая очистка ресурсов канала.
--- @protected
function ChannelMonitor:_on_destroy()
    self:_clear_stats()

    if self._input_instance then
        -- kill_input самостоятельно очищает callback и ресурсы
        kill_input(self._input_instance)
    end

    self._input_instance = nil
    self._channel_data = nil
    self._stream_json = nil
    self._stats = nil
    self._stats_count = nil
    self._upstream = nil
    self._last_active_id = nil
    self._cached_source = nil
    self._display_name = nil
    self._astra_conf = nil

    -- Очистка пулов таблиц, связанных с этим монитором
    if self._table_pool then
        self._table_pool.drain("report_channel", 5)
        self._table_pool.drain("report_error", 2)
    end
end

--- Вызывается при обновлении конфигурации.
--- Синхронизирует рабочую конфигурацию и параметры в работающем экземпляре анализатора Astra.
--- @protected
--- @param key string Ключ параметра
--- @param value any Новое значение
function ChannelMonitor:_on_config_updated(key, value)
    -- Вызываем базовый метод для синхронизации метода сравнения
    BaseMonitor._on_config_updated(self, key, value)

    -- Если рабочая копия еще не создана (до start), мы ничего не делаем.
    if not self._astra_conf then return end

    -- Синхронизируем рабочую копию
    self._astra_conf[key] = value

    -- Обновление параметров в работающем экземпляре анализатора Astra
    if self._instance and type(self._instance.__options) == "table" then
        local opts = self._instance.__options
        if key == "cc_limit" then opts.cc_limit = value end
        if key == "bitrate_limit" then opts.bitrate_limit = value end
        if key == "join_pid" then opts.join_pid = value end
    end
end

-- ===========================================================================
-- Инициализация модуля
-- ===========================================================================

-- Регистрация пулов при загрузке модуля
local tp = ModuleManager.get_module("table_pool")
if tp then
    -- Используем стандартную очистку TablePool для всех типов,
    -- так как она теперь поддерживает автоматический возврат вложенных таблиц.
    tp.register_type("report_channel")
    tp.register_type("report_error")
    tp.register_type("pid_stats")
end

-- ===========================================================================
-- Инициализация модуля
-- ===========================================================================

return ChannelMonitor
