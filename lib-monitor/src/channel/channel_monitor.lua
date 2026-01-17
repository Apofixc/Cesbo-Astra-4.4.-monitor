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
local METHOD_STRICT = 2
local METHOD_RATIO = 3
local METHOD_ON_AIR = 4

-- 5. Внутреннее состояние (Private State)
--- @class ChannelMonitor : BaseMonitor
--- @field private _display_name string Отображаемое имя монитора
--- @field private _input_instance any|nil Экземпляр входного потока (для IP мониторов)
--- @field private _channel_data table|nil Данные канала (Astra)
--- @field private _stream_json table Данные об источниках потока
--- @field private _status table Текущий статус ошибок (CC/PES)
--- @field private _stats table Статистика анализа по PID
--- @field private _stats_count number Текущее количество отслеживаемых PID
--- @field private _upstream any Объект апстрима
--- @field private _last_active_id number|nil ID последнего активного входа
--- @field private _cached_source table|nil Кэшированные данные текущего источника
--- @field private _current_status_table table Таблица для Pull-запросов
local ChannelMonitor = setmetatable({}, BaseMonitor)
ChannelMonitor.__index = ChannelMonitor

local ratio = Utils.ratio

-- Методы сравнения
local COMPARISON_METHODS = {
    [METHOD_ALWAYS] = function(prev, curr, rate)
        return true
    end,
    [METHOD_STRICT] = function(prev, curr, rate)
        return prev.ready ~= curr.on_air or
               prev.scrambled ~= curr.total.scrambled or
               prev.cc_errors > 0 or
               prev.pes_errors > 0 or
               prev.bitrate ~= curr.total.bitrate
    end,
    [METHOD_RATIO] = function(prev, curr, rate)
        return prev.ready ~= curr.on_air or
               prev.scrambled ~= curr.total.scrambled or
               prev.cc_errors > 0 or
               prev.pes_errors > 0 or
               ratio(prev.bitrate, curr.total.bitrate) > rate
    end,
    [METHOD_ON_AIR] = function(prev, curr, rate)
        return prev.ready ~= curr.on_air
    end
}

-- ===========================================================================
-- Внутренние функции (Private)
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
        self:_process_psi_data_internal(data)
        return
    end

    if data.analyze then
        self:_process_analyze_data(data)
    end

    if data.total then
        self:_process_total_data(data)
    end
end

--- Обработка PSI данных
--- @private
--- @param data table Данные PSI
function ChannelMonitor:_process_psi_data_internal(data)
    -- Сохраняем таблицу в базовое хранилище
    self:_process_psi_data(data)

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
    if not self._config.analyze or type(data.analyze) ~= "table" then return end

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
                    -- Если лимит превышен, сбрасываем статистику для очистки места
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

    local status = self._status
    local cc_inc = total.cc_errors or 0
    local pes_inc = total.pes_errors or 0

    status.cc_errors = status.cc_errors + cc_inc
    status.pes_errors = status.pes_errors + pes_inc

    -- Защита от переполнения счетчиков
    if status.cc_errors > MAX_ERROR_COUNT then status.cc_errors = MAX_ERROR_COUNT end
    if status.pes_errors > MAX_ERROR_COUNT then status.pes_errors = MAX_ERROR_COUNT end

    local active_id = self._channel_data and self._channel_data.active_input_id or 1

    -- Оптимизированная проверка: сначала интервал, затем force или тяжелое условие
    if self:_should_send(self._config.time_check) and
       (active_id ~= self._last_active_id or self:_is_force() or
        self._current_method(status, data, self._config.rate))
    then
        self:_reset_force_timer()

        -- Обновляем Master State (таблица для Pull-запросов)
        self:_build_status_table(self._current_status_table, data)

        -- Сбрасываем кэш JSON, так как данные изменились.
        -- Новый кэш будет сгенерирован лениво при первом запросе (Pull или Push).
        self:_clear_json_cache()

        -- Создаем таблицу для Push-уведомления из пула через быстрое копирование
        local r = self:get_table_from_pool("report_channel")
        Utils.init_report(r, "Channel", self._name)
        r.display_name = self._display_name
        r.monitor = self._config.monitor

        -- Копируем данные из Master State
        Utils.table_merge(r, self._current_status_table)

        -- Публикуем таблицу с передачей горячего кэша
        self:publish(r, "channels", true)

        -- Обновление состояния для следующего сравнения
        status.ready = data.on_air
        status.scrambled = data.total.scrambled
        status.bitrate = data.total.bitrate or 0
        status.cc_errors = 0
        status.pes_errors = 0
        self._last_active_id = active_id
    end
end

--- Очищает статистику анализа
--- @private
function ChannelMonitor:_clear_stats()
    -- Больше не возвращаем в пул, так как таблицы статические
    self._stats = {}
    self._stats_count = 0
end

--- Внутренний метод для сборки таблицы полного статуса.
--- @private
--- @param t table Целевая таблица для заполнения
--- @param data table|nil Текущие данные (если есть)
--- @return table Таблица статуса
function ChannelMonitor:_build_status_table(t, data)
    local source = self:_get_cached_source()
    local status = self._status or {}

    -- Добавить проверку на nil для всех полей
    local ready = (data and data.on_air) or (status.ready or false)
    local bitrate = (data and data.total and data.total.bitrate) or (status.bitrate or 0)
    local scrambled = (data and data.total and data.total.scrambled) or (status.scrambled or false)
    local cc = status.cc_errors or 0
    local pes = status.pes_errors or 0
    local rate_stat = data and data.rate_stat or nil

    -- Защита от nil
    t.status = ready
    t.bitrate = bitrate or 0
    t.cc_errors = cc
    t.pes_errors = pes
    t.scrambled = scrambled
    t.ready = ready
    t.rate_stat = rate_stat
    t.stream = source and source.stream or "Unknown"
    t.format = source and source.format or "Unknown"
    t.addr = source and source.addr or "Unknown"
    t.timestamp = os_time()

    return t
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

    local self = setmetatable(BaseMonitor.new(config, COMPONENT_NAME), ChannelMonitor)

    -- 1. Данные канала и идентификация
    self._channel_data = type(channel_data) == "table" and channel_data or nil
    self._name = config.name or (self._channel_data and self._channel_data.name) or config.monitor
    self._display_name = config.display_name or (self._channel_data and self._channel_data.display_name) or self._name

    -- 2. Валидация и установка параметров конфигурации
    if not self:_set_config_param("channel_rate", config.rate, "channel_") then return nil end
    if not self:_set_config_param("channel_time_check", config.time_check, "channel_") then return nil end
    if not self:_set_config_param("channel_method_comparison", config.method_comparison, "channel_") then return nil end
    if not self:_set_config_param("channel_analyze", config.analyze, "channel_") then return nil end
    if not self:_set_config_param("channel_cc_limit", config.cc_limit, "channel_") then return nil end
    if not self:_set_config_param("channel_bitrate_limit", config.bitrate_limit, "channel_") then return nil end
    if not self:_set_config_param("channel_rate_stat", config.rate_stat, "channel_") then return nil end
    if not self:_set_config_param("channel_join_pid", config.join_pid, "channel_") then return nil end

    -- 3. Состояние мониторинга и статистика
    self._status = {
        cc_errors = 0,
        pes_errors = 0,
        bitrate = 0,
        ready = false,
        scrambled = false,
    }
    self._stats = {}
    self._stats_count = 0
    self._current_method = COMPARISON_METHODS[self._config.method_comparison]

    -- 4. Источники и апстрим
    self._stream_json = config.stream_json or {}
    self._upstream = config.upstream
    self._input_instance = nil
    self._last_active_id = nil
    self._cached_source = nil

    -- 5. Таблица для Pull-запросов (всегда актуальное состояние)
    self._current_status_table = {}
    Utils.init_report(self._current_status_table, "Channel", self._name)
    self._current_status_table.display_name = self._display_name
    self._current_status_table.monitor = self._config.monitor

    return self
end

--- Запускает мониторинг
--- @return any|nil Экземпляр анализатора Astra или nil
function ChannelMonitor:start()
    if self._state == BaseMonitor.STATE.RUNNING then
        Logger.warn(COMPONENT_NAME, "[%s] Монитор уже запущен", tostring(self._name))
        return self._instance
    end

    if not self._current_method then
        Logger.error(COMPONENT_NAME, "[%s] start: некорректный метод сравнения %s",
            self._name, tostring(self._config.method_comparison))
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
        cc_limit = self._config.cc_limit,
        bitrate_limit = self._config.bitrate_limit,
        rate_stat = self._config.rate_stat,
        join_pid = self._config.join_pid,
        callback = function(data)
            -- Защита от вызова после destroy или во время очистки
            if not self._active or not self._instance then return end
            
            local ok, err = pcall(self._on_astra_data, self, data)
            if not ok then
                -- В экстремальных условиях логируем только критические ошибки
                if self._active then
                    Logger.error(COMPONENT_NAME, "[%s] Ошибка в callback: %s", tostring(self._name), tostring(err))
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

--- Возвращает актуальные данные в виде таблицы (сырые данные).
--- @return table|nil Таблица данных
function ChannelMonitor:get_status_table()
    return self._current_status_table
end

--- Останавливает мониторинг и уничтожает объект.
--- Освобождает все ресурсы и возвращает оригинальную конфигурацию.
--- @param force boolean Принудительная остановка
--- @return table|nil Оригинальная конфигурация при успехе, иначе nil
function ChannelMonitor:destroy(force)
    if self._state ~= BaseMonitor.STATE.RUNNING then
        return nil
    end

    -- 0. Немедленная остановка обработки (предохранитель для callback)
    self._active = false

    local original_config = self._config and Utils.table_copy(self._config) or nil

    -- 1. Очистка специфических ресурсов
    self:_clear_stats()

    if self._instance then
        -- 1. Сначала обнуляем ссылку на инстанс в объекте Lua
        local inst = self._instance
        self._instance = nil

        -- 2. Очищаем callback во внутренней таблице параметров Astra ОБЯЗАТЕЛЬНО
        if type(inst.__options) == "table" then
            inst.__options.callback = nil
        end

        -- 3. Физическое закрытие инстанса Astra
        if inst.close then
            pcall(inst.close, inst)
        end
    end

    if self._input_instance then
        -- kill_input самостоятельно очищает callback и ресурсы
        kill_input(self._input_instance)
    end

    -- 2. Обнуление специфических полей
    self._input_instance = nil
    self._channel_data = nil
    self._stream_json = nil
    self._status = nil
    self._stats = nil
    self._stats_count = nil
    self._upstream = nil
    self._last_active_id = nil
    self._cached_source = nil
    self._display_name = nil
    self._current_status_table = nil

    -- 3. Базовая очистка и смена состояния
    BaseMonitor.destroy(self)

    Logger.debug(COMPONENT_NAME, "Объект монитора уничтожен")
    return original_config
end

--- Обновляет параметры монитора
--- @param params table Таблица новых параметров
--- @return boolean Статус выполнения
function ChannelMonitor:update_parameters(params)
    if not params or type(params) ~= "table" then
        Logger.error(COMPONENT_NAME, "[%s] update_parameters: параметры должны быть таблицей", tostring(self._name))
        return false
    end

    local param_map = {
        rate = "channel_rate",
        time_check = "channel_time_check",
        method_comparison = "channel_method_comparison",
        analyze = "channel_analyze",
        cc_limit = "channel_cc_limit",
        bitrate_limit = "channel_bitrate_limit",
        rate_stat = "channel_rate_stat",
        join_pid = "channel_join_pid"
    }

    local has_errors = false
    for key, config_name in pairs(param_map) do
        if params[key] ~= nil then
            if not self:_set_config_param(config_name, params[key], "channel_") then
                has_errors = true
            end
        end
    end

    -- Обновляем прямую ссылку на метод для callback
    if params.method_comparison ~= nil then
        self._current_method = COMPARISON_METHODS[self._config.method_comparison]
    end

    -- Обновление параметров в работающем экземпляре анализатора Astra
    if self._instance and type(self._instance.__options) == "table" then
        local opts = self._instance.__options
        if params.cc_limit ~= nil then opts.cc_limit = self._config.cc_limit end
        if params.bitrate_limit ~= nil then opts.bitrate_limit = self._config.bitrate_limit end
        if params.rate_stat ~= nil then opts.rate_stat = self._config.rate_stat end
        if params.join_pid ~= nil then opts.join_pid = self._config.join_pid end
    end

    if has_errors then
        Logger.error(COMPONENT_NAME, "[%s] update_parameters: не удалось обновить некоторые параметры",
            tostring(self._name))
        return false
    end

    return true
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

return ChannelMonitor
