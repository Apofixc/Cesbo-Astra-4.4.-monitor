-- 1. Стандартные Lua функции
local ipairs = ipairs
local pairs = pairs
local os_time = os.time
local setmetatable = setmetatable
local tostring = tostring
local type = type
local collectgarbage = collectgarbage
local pcall = pcall

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local Utils = ModuleManager.get_module("utils")
local BaseMonitor = ModuleManager.get_module("core.base_monitor")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local analyze = ModuleManager.get_global_dependency("analyze")
local kill_input = ModuleManager.get_global_dependency("kill_input")
local json_encode = ModuleManager.get_global_dependency("json.encode")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ChannelMonitor"
local DEFAULT_SOURCE_TEMPLATE = { format = "Unknown", addr = "Unknown", stream = "Unknown" }
local MAX_COUNTER = 1000000000
local MAX_ERROR_COUNT = 1000000

-- Методы сравнения
local METHOD_ALWAYS = 1
local METHOD_STRICT = 2
local METHOD_RATIO = 3
local METHOD_ON_AIR = 4

-- 5. Инициализация объектов из загруженных модулей
local ratio = Utils.ratio

--- @class ChannelMonitor : BaseMonitor
--- @field private _display_name string Отображаемое имя монитора
--- @field private _input_instance any|nil Экземпляр входного потока (для IP мониторов)
--- @field private _channel_data table|nil Данные канала (Astra)
--- @field private _stream_json table Данные об источниках потока
--- @field private _status table Текущий статус ошибок (CC/PES)
--- @field private _stats table Статистика анализа по PID
--- @field private _stats_count number Текущее количество отслеживаемых PID
--- @field private _rate_stat table|nil Статистика битрейта (если включено rate_stat)
--- @field private _upstream any Объект апстрима
--- @field private _last_active_id number|nil ID последнего активного входа
--- @field private _cached_source table|nil Кэшированные данные текущего источника
local ChannelMonitor = setmetatable({}, BaseMonitor)
ChannelMonitor.__index = ChannelMonitor

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
        Logger.error(COMPONENT_NAME, "new: upstream обязателен в конфигурации")
        return nil
    end

    local self = setmetatable(BaseMonitor.new(config, COMPONENT_NAME), ChannelMonitor)
    self._channel_data = type(channel_data) == "table" and channel_data or nil

    -- Инициализация имен с учетом возможного отсутствия channel_data
    self._name = config.name or (self._channel_data and self._channel_data.name) or config.monitor
    self._display_name = config.display_name or (self._channel_data and self._channel_data.display_name) or self._name

    -- Валидация и установка параметров
    if not self:_set_config_param("channel_rate", config.rate, "channel_") then return nil end
    if not self:_set_config_param("channel_time_check", config.time_check, "channel_") then return nil end
    if not self:_set_config_param("channel_method_comparison", config.method_comparison, "channel_") then return nil end
    if not self:_set_config_param("channel_analyze", config.analyze, "channel_") then return nil end
    if not self:_set_config_param("channel_cc_limit", config.cc_limit, "channel_") then return nil end
    if not self:_set_config_param("channel_bitrate_limit", config.bitrate_limit, "channel_") then return nil end
    if not self:_set_config_param("channel_rate_stat", config.rate_stat, "channel_") then return nil end
    if not self:_set_config_param("channel_join_pid", config.join_pid, "channel_") then return nil end

    self._stream_json = config.stream_json or {}
    self._upstream = config.upstream
    self._last_active_id = nil
    self._cached_source = nil
    
    -- Таблица для Pull-запросов (всегда актуальное состояние)
    self._current_status_table = {}
    Utils.init_report(self._current_status_table, "Channel", self._name)
    self._current_status_table.display_name = self._display_name
    self._current_status_table.monitor = self._config.monitor

    self._status = {
        cc_errors = 0,
        pes_errors = 0,
        bitrate = 0,
        ready = false,
        scrambled = false,
    }
    self._stats = {}
    self._stats_count = 0
    self._rate_stat = nil
    self._current_method = COMPARISON_METHODS[self._config.method_comparison]

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
        Logger.error(COMPONENT_NAME, "[%s] start: Некорректный метод сравнения %s", self._name, tostring(self._config.method_comparison))
        return nil
    end

    if not self._upstream or type(self._upstream.stream) ~= "function" then
        Logger.error(COMPONENT_NAME, "[%s] start: upstream некорректен или отсутствует метод stream()", tostring(self._name))
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
            if not self or not self._active or not data then return end

            local ok, err = pcall(function()
                if data.error then
                    self:process_error_data(data)
                    return
                end

                if data.psi then
                    self:process_psi_data(data)
                    return
                end

                if data.analyze then
                    self:process_analyze_data(data)
                end

                if data.rate_stat then
                    self._rate_stat = data.rate_stat
                    self:process_rate_stat_data(data.rate_stat)
                end

                if data.total then
                    self:process_total_data(data)
                end
            end)

            if not ok then
                Logger.error(COMPONENT_NAME, "[%s] Callback error: %s", tostring(self._name), tostring(err))
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

--- Возвращает закэшированные данные об источнике
--- @return table Данные об источнике
function ChannelMonitor:get_cached_source()
    local active_id = self._channel_data and self._channel_data.active_input_id or 1
    if active_id ~= self._last_active_id then
        self._last_active_id = active_id
        self._cached_source = self._stream_json[active_id] or DEFAULT_SOURCE_TEMPLATE
    end
    return self._cached_source
end


--- Обработка ошибок потока
--- @param data table Данные ошибки
function ChannelMonitor:process_error_data(data)
    local r = self:get_table_from_pool("report")
    Utils.init_report(r, "Channel", self._name)
    r.display_name = self._display_name
    r.monitor = self._config.monitor
    r.error = data.error
    r.timestamp = os_time()
    self:publish(r, "error", true)
end

--- Обработка статистики битрейта
--- @param data table Данные статистики
function ChannelMonitor:process_rate_stat_data(data)
    local r = self:get_table_from_pool("report")
    Utils.init_report(r, "Channel", self._name)
    r.display_name = self._display_name
    r.monitor = self._config.monitor
    r.rate_stat = data
    r.timestamp = os_time()
    self:publish(r, "rate_stat", true)
end

--- Обработка PSI данных
--- @param data table Данные PSI
function ChannelMonitor:process_psi_data(data)
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
                    if self._stats_count >= 100 then
                        self:clear_stats()
                        Logger.warn(COMPONENT_NAME, "[%s] PID stats limit reached during PSI processing, clearing stats", tostring(self._name))
                    end

                    self._stats[pid] = {
                        type = type_name,
                        cc = 0,
                        pes = 0,
                        sc = 0
                    }
                    self._stats_count = self._stats_count + 1
                else
                    stats.type = type_name
                end
            end
        end
    end
end

--- Обработка данных анализа (статистика по PID)
--- @param data table Данные анализа
function ChannelMonitor:process_analyze_data(data)
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
                    if self._stats_count >= 100 then
                        self:clear_stats()
                        Logger.warn(COMPONENT_NAME, "[%s] PID stats limit reached, clearing stats", tostring(self._name))
                    end
                    
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
--- @param data table Суммарные данные
function ChannelMonitor:process_total_data(data)
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
       (active_id ~= self._last_active_id or self._force_timer >= self._force_interval or self._current_method(status, data, self._config.rate)) 
    then
        self:_reset_force_timer()
        self:_clear_json_cache()
        
        -- Обновляем таблицу для Pull-запросов
        self:_build_status_table(self._current_status_table, data)
        
        -- Создаем таблицу для Push-уведомления из пула
        local r = self:get_table_from_pool("report")
        Utils.init_report(r, "Channel", self._name)
        r.display_name = self._display_name
        r.monitor = self._config.monitor
        self:_build_status_table(r, data)

        -- Публикуем таблицу (EventDispatcher сам решит, когда делать encode)
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

--- Возвращает статистику битрейта (rate_stat)
--- @return table|nil Статистика битрейта
function ChannelMonitor:get_rate_stat()
    return self._rate_stat
end

--- Очищает статистику анализа
function ChannelMonitor:clear_stats()
    self._stats = {}
    self._stats_count = 0
    self._rate_stat = nil
end

--- Внутренний метод для сборки таблицы полного статуса.
--- @private
--- @param t table Целевая таблица для заполнения
--- @param data table|nil Текущие данные (если есть)
--- @return table Таблица статуса
function ChannelMonitor:_build_status_table(t, data)
    local source = self:get_cached_source()
    local status = self._status or {}
    
    -- Добавить проверку на nil для всех полей
    local ready = (data and data.on_air) or (status.ready or false)
    local bitrate = (data and data.total and data.total.bitrate) or (status.bitrate or 0)
    local scrambled = (data and data.total and data.total.scrambled) or (status.scrambled or false)
    local cc = status.cc_errors or 0
    local pes = status.pes_errors or 0

    -- Защита от nil
    t.status = ready
    t.bitrate = bitrate or 0
    t.cc_errors = cc
    t.pes_errors = pes
    t.scrambled = scrambled
    t.ready = ready
    t.stream = source and source.stream or "Unknown"
    t.format = source and source.format or "Unknown"
    t.addr = source and source.addr or "Unknown"
    t.timestamp = os_time()
    
    return t
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

    local original_config = self._config and Utils.table_copy(self._config) or nil

    self._active = false
    self._state = BaseMonitor.STATE.STOPPED

    if self._instance then
        -- Очищаем callback во внутренней таблице параметров Astra
        local opts = self._instance.__options
        if type(opts) == "table" then
            opts.callback = nil
        end

        -- Физическое закрытие инстанса Astra
        if self._instance.close then
            self._instance:close()
        end
        self._instance = nil
    end

    if self._input_instance then
        -- kill_input самостоятельно очищает callback и ресурсы
        kill_input(self._input_instance)
        self._input_instance = nil
    end

    -- Очистка кэшей и данных
    self:_clear_psi()
    self._stats = nil
    self._stats_count = nil
    self._status = nil
    self._config = nil
    self._channel_data = nil
    self._stream_json = nil
    self._upstream = nil
    self._cached_source = nil
    self._current_status_table = nil
    self._json_cache = nil
    self._current_method = nil

    -- Обнуление идентификаторов
    self._name = nil
    self._display_name = nil
    self._last_active_id = nil

    Logger.debug(COMPONENT_NAME, "Объект монитора уничтожен")
    collectgarbage()
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
        Logger.error(COMPONENT_NAME, "[%s] update_parameters: не удалось обновить некоторые параметры", tostring(self._name))
        return false
    end

    return true
end

return ChannelMonitor
