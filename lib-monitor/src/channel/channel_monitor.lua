-- 1. Стандартные Lua функции
local ipairs = ipairs
local pairs = pairs
local setmetatable = setmetatable
local tostring = tostring
local type = type

-- 2. Функции из ModuleManager.get_module()
local HttpSubscriber = ModuleManager.get_module("http_subscriber")
local Logger = ModuleManager.get_module("logger")
local Utils = ModuleManager.get_module("utils")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local analyze = ModuleManager.get_global_dependency("analyze")
local kill_input = ModuleManager.get_global_dependency("kill_input")
local json_encode = ModuleManager.get_global_dependency("json.encode")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ChannelMonitor"
local DEFAULT_SOURCE_TEMPLATE = { format = "Unknown", addr = "Unknown", stream = "Unknown" }
local FORCE_SEND_INTERVAL = 300

-- Методы сравнения
local METHOD_ALWAYS = 1
local METHOD_STRICT = 2
local METHOD_RATIO = 3
local METHOD_ON_AIR = 4

-- 5. Инициализация объектов из загруженных модулей
local log_error = Logger.error
local ratio = Utils.ratio
local table_copy = Utils.table_copy
local validate_monitor_param = Utils.validate_monitor_param

--- @class ChannelMonitor
--- @field name string Технический идентификатор монитора
--- @field display_name string Отображаемое имя монитора
--- @field input_instance any|nil Экземпляр входного потока (для IP мониторов)
--- @field private _active boolean Флаг активности монитора
--- @field private _config table Конфигурация монитора
--- @field private _channel_data table|nil Данные канала (Astra)
--- @field private _stream_json table Данные об источниках потока
--- @field private _status table Текущий статус ошибок (CC/PES)
--- @field private _analyze_stats table Статистика анализа по PID
--- @field private _monitor_instance any Экземпляр анализатора Astra
--- @field private _force_timer number Таймер принудительной отправки статуса
--- @field private _check_timer number Таймер интервала проверки
--- @field private _upstream any Объект апстрима
--- @field private _json_status_cache string|nil Кэш последнего отправленного JSON
--- @field private _last_active_id number|nil ID последнего активного входа
--- @field private _cached_source table|nil Кэшированные данные текущего источника
--- @field private _status_template_cache table|nil Кэш базового шаблона статуса
--- @field private _psi_hash_cache table Кэш хэшей PSI таблиц
local ChannelMonitor = {}
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
        if prev.cc_errors > 1000 or prev.pes_errors > 1000 then
            prev.cc_errors = 0
            prev.pes_errors = 0
        end
        return prev.ready ~= curr.on_air
    end
}

--- Вспомогательная функция для установки параметра конфигурации
--- @param param_name string Имя параметра
--- @param value any Значение
--- @return boolean Статус выполнения
function ChannelMonitor:_set_config_param(param_name, value)
    local result = validate_monitor_param(param_name, value)
    if result == nil then
        return false
    end
    local key = param_name:gsub("channel_", "")
    self._config[key] = result
    return true
end

--- Создает новый экземпляр ChannelMonitor
--- @param config table Конфигурация монитора
--- @param channel_data table|nil Данные канала (необязательно)
--- @return ChannelMonitor|nil Экземпляр монитора или nil
function ChannelMonitor.new(config, channel_data)
    if not config or type(config) ~= "table" then
        log_error(COMPONENT_NAME, "new: config is required and must be a table")
        return nil
    end

    if not config.monitor or type(config.monitor) ~= "string" then
        log_error(COMPONENT_NAME, "new: monitor address is required in config")
        return nil
    end

    if not config.upstream then
        log_error(COMPONENT_NAME, "new: upstream is required in config")
        return nil
    end

    local self = setmetatable({}, ChannelMonitor)
    self._config = config
    self._channel_data = type(channel_data) == "table" and channel_data or nil

    -- Инициализация имен с учетом возможного отсутствия channel_data
    self.name = config.name or (self._channel_data and self._channel_data.name) or config.monitor
    self.display_name = config.display_name or (self._channel_data and self._channel_data.display_name) or self.name

    -- Валидация и установка параметров (валидатор сам вернет default при необходимости)
    self:_set_config_param("channel_rate", config.rate)
    self:_set_config_param("channel_time_check", config.time_check)
    self:_set_config_param("channel_method_comparison", config.method_comparison)
    self:_set_config_param("channel_analyze", config.analyze)
    self:_set_config_param("channel_cc_limit", config.cc_limit)
    self:_set_config_param("channel_bitrate_limit", config.bitrate_limit)
    self:_set_config_param("channel_rate_stat", config.rate_stat)
    self:_set_config_param("channel_join_pid", config.join_pid)

    self._stream_json = config.stream_json or {}
    self._upstream = config.upstream
    self._force_timer = 0
    self._check_timer = 0
    self._json_status_cache = nil
    self._last_active_id = nil
    self._cached_source = nil
    self._status_template_cache = nil
    self._psi_hash_cache = {}
    self._status = {
        cc_errors = 0,
        pes_errors = 0,
        bitrate = 0,
        ready = false,
        scrambled = false,
    }
    self._analyze_stats = {}
    self._active = true

    return self
end

--- Запускает мониторинг
--- @return any|nil Экземпляр монитора или nil
function ChannelMonitor:start()
    local comparison_method = COMPARISON_METHODS[self._config.method_comparison]
    if not comparison_method then
        log_error(COMPONENT_NAME, "[%s] start: Invalid comparison method %s", self.name, tostring(self._config.method_comparison))
        return nil
    end

    local stream_data = self._upstream:stream()
    if not stream_data then
        log_error(COMPONENT_NAME, "[%s] start: upstream:stream() returned nil", self.name)
        return nil
    end

    self._monitor_instance = analyze({
        upstream = stream_data,
        name = "_" .. self.name,
        cc_limit = self._config.cc_limit,
        bitrate_limit = self._config.bitrate_limit,
        rate_stat = self._config.rate_stat,
        join_pid = self._config.join_pid,
        callback = function(data)
            if not self or not self._active or not data then return end

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

            if data.total then
                self:process_total_data(data, comparison_method)
            end
        end
    })

    if not self._monitor_instance then
        log_error(COMPONENT_NAME, "[%s] start: analyze returned nil", self.name)
        return nil
    end

    return self._monitor_instance
end

--- Возвращает закэшированные данные об источнике
--- @return table Данные об источнике
function ChannelMonitor:get_cached_source()
    local active_id = self._channel_data and self._channel_data.active_input_id or 1
    if active_id ~= self._last_active_id then
        self._last_active_id = active_id
        local input_index = active_id > 0 and active_id or 1
        self._cached_source = self._stream_json[input_index] or DEFAULT_SOURCE_TEMPLATE
        -- Сбрасываем кэш шаблона при смене источника
        self._status_template_cache = nil
    end
    return self._cached_source
end

--- Создает или возвращает закэшированный базовый шаблон статуса
--- @return table Шаблон статуса
function ChannelMonitor:get_status_template()
    local source = self:get_cached_source()
    if self._status_template_cache then
        return self._status_template_cache
    end
    self._status_template_cache = {
        type = "Channel",
        server = Utils.get_server_name(),
        channel = self.name,
        display_name = self.display_name,
        monitor = self._config.monitor,
        stream = source.stream,
        format = source.format,
        addr = source.addr
    }
    return self._status_template_cache
end

--- Обработка ошибок потока
--- @param data table Данные ошибки
function ChannelMonitor:process_error_data(data)
    local content = table_copy(self:get_status_template())
    content.error = data.error
    HttpSubscriber.publish("error", json_encode(content))
end

--- Обработка PSI данных
--- @param data table Данные PSI
function ChannelMonitor:process_psi_data(data)
    if not self._psi_hash_cache then return end
    
    -- Оптимизация: проверяем только PMT или если данные действительно изменились
    -- Для PMT нам важно отслеживать изменения стримов
    local current_data_json = json_encode(data)
    if self._psi_hash_cache[data.psi] == current_data_json then
        return
    end
    self._psi_hash_cache[data.psi] = current_data_json

    if data.psi == "PMT" and data.streams then
        for _, stream in ipairs(data.streams) do
            local pid = stream.pid
            if pid then
                local type_name = stream.type_name or "UNKNOWN"
                local stats = self._analyze_stats[pid]
                if not stats then
                    self._analyze_stats[pid] = {
                        type = type_name,
                        cc = 0,
                        pes = 0,
                        sc = 0
                    }
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
    if not self._analyze_stats or not self._config.analyze then return end

    for _, pid_data in ipairs(data.analyze) do
        local pid = pid_data.pid
        if pid then
            local cc = pid_data.cc_error or 0
            local pes = pid_data.pes_error or 0
            local sc = pid_data.sc_error or 0

            if cc > 0 or pes > 0 or sc > 0 then
                local stats = self._analyze_stats[pid]
                if not stats then
                    stats = {
                        type = "UNKNOWN",
                        cc = 0,
                        pes = 0,
                        sc = 0
                    }
                    self._analyze_stats[pid] = stats
                end
                stats.cc = stats.cc + cc
                stats.pes = stats.pes + pes
                stats.sc = stats.sc + sc
            end
        end
    end
end

--- Обработка суммарных данных потока
--- @param data table Суммарные данные
--- @param comparison_method function Функция сравнения
function ChannelMonitor:process_total_data(data, comparison_method)
    local status = self._status
    status.cc_errors = status.cc_errors + (data.total.cc_errors or 0)
    status.pes_errors = status.pes_errors + (data.total.pes_errors or 0)

    self._force_timer = self._force_timer + 1
    if self._check_timer < (self._config.time_check or 0) then
        self._check_timer = self._check_timer + 1
        return
    end
    self._check_timer = 0

    if comparison_method(status, data, self._config.rate) or self._force_timer > FORCE_SEND_INTERVAL then
        self:update_status_and_publish(data)
        self._force_timer = 0
    end
end

--- Обновляет статус и публикует его
--- @param data table Данные потока
function ChannelMonitor:update_status_and_publish(data)
    -- Оптимизация: проверяем изменения до создания копии таблицы и json_encode
    local on_air = data.on_air
    local scrambled = data.total.scrambled
    local bitrate = data.total.bitrate or 0
    local cc = self._status.cc_errors
    local pes = self._status.pes_errors

    -- Если данные не изменились по сравнению с кэшем (и это не принудительная отправка по таймеру),
    -- то можно пропустить публикацию. Но так как мы сюда попадаем уже после проверки comparison_method,
    -- мы проверяем только против последнего отправленного JSON.
    
    local status = table_copy(self:get_status_template())
    status.ready = on_air
    status.scrambled = scrambled
    status.bitrate = bitrate
    status.cc_errors = cc
    status.pes_errors = pes

    local current_json = json_encode(status)
    if current_json ~= self._json_status_cache then
        HttpSubscriber.publish("channels", current_json)
        self._json_status_cache = current_json
    end

    -- Обновление состояния для следующего сравнения
    self._status.ready = data.on_air
    self._status.scrambled = data.total.scrambled
    self._status.bitrate = data.total.bitrate or 0
    -- Сброс счетчиков ошибок
    self._status.cc_errors = 0
    self._status.pes_errors = 0
end

--- Возвращает закэшированные PSI данные (в формате JSON)
--- @param table_name string|nil Имя таблицы (например, "PMT"). Если nil, вернет весь кэш.
--- @return string|table|nil Данные PSI (JSON строка или таблица JSON строк) или nil
function ChannelMonitor:get_psi(table_name)
    if not self._psi_hash_cache then return nil end
    if table_name then
        return self._psi_hash_cache[table_name]
    end
    return self._psi_hash_cache
end

--- Возвращает статистику анализа по PID
--- @return table Статистика по PID
function ChannelMonitor:get_analyze_stats()
    return self._analyze_stats or {}
end

--- Очищает статистику анализа
function ChannelMonitor:clear_analyze_stats()
    self._analyze_stats = {}
end

--- Возвращает кэш последнего отправленного JSON статуса
--- @return string|nil JSON статус
function ChannelMonitor:get_json_status_cache()
    return self._json_status_cache
end

--- Приостанавливает мониторинг
function ChannelMonitor:pause()
    self._active = false
    Logger.info(COMPONENT_NAME, "[%s] Monitoring paused", tostring(self.name))
end

--- Возобновляет мониторинг
--- @return boolean Статус выполнения
function ChannelMonitor:resume()
    if self._status == nil then
        Logger.error(COMPONENT_NAME, "[%s] Cannot resume: monitor already stopped", tostring(self.name))
        return false
    end
    self._active = true
    Logger.info(COMPONENT_NAME, "[%s] Monitoring resumed", tostring(self.name))
    return true
end

--- Останавливает мониторинг и очищает ресурсы
function ChannelMonitor:stop()
    self._active = false

    if self._monitor_instance then
        if type(self._monitor_instance.close) == "function" then
            self._monitor_instance:close()
        end
        self._monitor_instance = nil
    end

    if self.input_instance then
        kill_input(self.input_instance)
        self.input_instance = nil
    end

    -- Очистка кэшей и данных
    self._psi_hash_cache = nil
    self._analyze_stats = nil
    self._status = nil
    self._config = nil
    self._channel_data = nil
    self._stream_json = nil
    self._upstream = nil
    self._cached_source = nil
    self._status_template_cache = nil
    self._json_status_cache = nil

    -- Обнуление идентификаторов
    self.name = nil
    self.display_name = nil
    self._force_timer = nil
    self._check_timer = nil
    self._last_active_id = nil
end

--- Обновляет параметры монитора
--- @param params table Таблица новых параметров
--- @return boolean Статус выполнения
function ChannelMonitor:update_parameters(params)
    if not params or type(params) ~= "table" then
        log_error(COMPONENT_NAME, "[%s] update_parameters: params must be a table", tostring(self.name))
        return false
    end

    local param_map = {
        rate = "channel_rate",
        time_check = "channel_time_check",
        method_comparison = "channel_method_comparison",
        analyze = "channel_analyze"
    }

    local has_errors = false
    for key, config_name in pairs(param_map) do
        if params[key] ~= nil then
            if not self:_set_config_param(config_name, params[key]) then
                has_errors = true
            end
        end
    end

    if has_errors then
        log_error(COMPONENT_NAME, "[%s] update_parameters: some parameters failed to update", tostring(self.name))
        return false
    end

    return true
end

return ChannelMonitor
