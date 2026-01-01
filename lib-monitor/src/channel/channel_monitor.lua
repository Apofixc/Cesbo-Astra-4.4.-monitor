-- 1. Стандартные Lua функции
local ipairs = ipairs
local pairs = pairs
local setmetatable = setmetatable
local tostring = tostring
local type = type

-- 2. Функции из ModuleManager.get_module()
local EventDispatcher = ModuleManager.get_module("event_dispatcher")
local Logger = ModuleManager.get_module("logger")
local Utils = ModuleManager.get_module("utils")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local analyze = ModuleManager.get_global_dependency("analyze")
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
local validate_monitor_param = Utils.validate_monitor_param

--- @class ChannelMonitor
--- @field name string Технический идентификатор монитора
--- @field display_name string Отображаемое имя монитора
--- @field config table Конфигурация монитора
--- @field channel_data table|nil Данные канала (Astra)
--- @field stream_json table Данные об источниках потока
--- @field status table Текущий статус ошибок (CC/PES)
--- @field psi_cache table Кэш PSI таблиц
--- @field analyze_stats table Статистика анализа по PID
--- @field monitor_instance any Экземпляр анализатора Astra
--- @field force_timer number Таймер принудительной отправки статуса
--- @field check_timer number Таймер интервала проверки
--- @field upstream any Объект апстрима
--- @field json_status_cache string|nil Кэш последнего отправленного JSON
--- @field last_active_id number|nil ID последнего активного входа
--- @field cached_source table|nil Кэшированные данные текущего источника
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
--- @param self ChannelMonitor
--- @param param_name string
--- @param value any
--- @return boolean success
local function set_config_param(self, param_name, value)
    local success, result = validate_monitor_param(param_name, value)
    if not success then
        log_error(COMPONENT_NAME, "[%s] Invalid parameter value for %s: %s", tostring(self.name), param_name, tostring(value))
        return false
    end
    local key = param_name:gsub("channel_", "")
    self.config[key] = result
    return true
end

--- Создает новый экземпляр ChannelMonitor
--- @param config table Конфигурация монитора
--- @param [channel_data] table|nil Данные канала (необязательно)
--- @return boolean success
--- @return ChannelMonitor|nil result
function ChannelMonitor.new(config, channel_data)
    if not config or type(config) ~= "table" then
        log_error(COMPONENT_NAME, "new: config is required and must be a table")
        return false, nil
    end

    if not config.monitor or type(config.monitor) ~= "string" then
        log_error(COMPONENT_NAME, "new: monitor address is required in config")
        return false, nil
    end

    if not config.upstream then
        log_error(COMPONENT_NAME, "new: upstream is required in config")
        return false, nil
    end

    local self = setmetatable({}, ChannelMonitor)
    self.config = config
    self.channel_data = type(channel_data) == "table" and channel_data or nil

    -- Инициализация имен с учетом возможного отсутствия channel_data
    self.name = config.name or (self.channel_data and self.channel_data.name) or config.monitor
    self.display_name = config.display_name or (self.channel_data and self.channel_data.display_name) or self.name

    -- Валидация и установка параметров
    set_config_param(self, "channel_rate", config.rate)
    set_config_param(self, "channel_time_check", config.time_check)
    set_config_param(self, "channel_method_comparison", config.method_comparison)
    set_config_param(self, "channel_analyze", config.analyze)

    self.stream_json = config.stream_json or {}
    self.upstream = config.upstream
    self.force_timer = 0
    self.check_timer = 0
    self.json_status_cache = nil
    self.last_active_id = nil
    self.cached_source = nil
    self.status = {
        cc_errors = 0,
        pes_errors = 0,
        bitrate = 0,
        ready = false,
        scrambled = false,
    }
    self.psi_cache = {}
    self.analyze_stats = {}

    return true, self
end

--- Запускает мониторинг
--- @return boolean success
function ChannelMonitor:start()
    local comparison_method = COMPARISON_METHODS[self.config.method_comparison]
    if not comparison_method then
        log_error(COMPONENT_NAME, "[%s] start: Invalid comparison method %s", self.name, tostring(self.config.method_comparison))
        return false
    end

    local stream_data = self.upstream:stream()
    if not stream_data then
        log_error(COMPONENT_NAME, "[%s] start: upstream:stream() returned nil", self.name)
        return false
    end

    self.monitor_instance = analyze({
        upstream = stream_data,
        name = "_" .. self.name,
        callback = function(data)
            if not data then return end

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

    if not self.monitor_instance then
        log_error(COMPONENT_NAME, "[%s] start: analyze returned nil", self.name)
        return false
    end

    return true
end

--- Возвращает закэшированные данные об источнике
--- @return table source Данные об источнике
function ChannelMonitor:get_cached_source()
    local active_id = self.channel_data and self.channel_data.active_input_id or 1
    if active_id ~= self.last_active_id then
        self.last_active_id = active_id
        local input_index = active_id > 0 and active_id or 1
        self.cached_source = self.stream_json[input_index] or DEFAULT_SOURCE_TEMPLATE
    end
    return self.cached_source
end

--- Создает базовый шаблон статуса
--- @return table template Шаблон статуса
function ChannelMonitor:create_status_template()
    local source = self:get_cached_source()
    return {
        type = "Channel",
        server = Utils.get_server_name(),
        channel = self.name,
        display_name = self.display_name,
        output = self.config.monitor,
        stream = source.stream,
        format = source.format,
        addr = source.addr
    }
end

--- Обработка ошибок потока
--- @param data table Данные ошибки
function ChannelMonitor:process_error_data(data)
    local content = self:create_status_template()
    content.error = data.error
    EventDispatcher.publish("error", json_encode(content))
end

--- Обработка PSI данных
--- @param data table Данные PSI
function ChannelMonitor:process_psi_data(data)
    if not data or not data.psi then return end
    self.psi_cache[data.psi] = data

    if data.psi == "PMT" and data.streams then
        for _, stream in ipairs(data.streams) do
            local pid = stream.pid
            if pid then
                local type_name = stream.type_name or "UNKNOWN"
                local stats = self.analyze_stats[pid]
                if not stats then
                    self.analyze_stats[pid] = {
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
    if not self.config or not self.config.analyze or not data.analyze then return end

    for _, pid_data in ipairs(data.analyze) do
        local pid = pid_data.pid
        if pid then
            local cc = pid_data.cc_error or 0
            local pes = pid_data.pes_error or 0
            local sc = pid_data.sc_error or 0

            if cc > 0 or pes > 0 or sc > 0 then
                local stats = self.analyze_stats[pid]
                if not stats then
                    stats = {
                        type = "UNKNOWN",
                        cc = 0,
                        pes = 0,
                        sc = 0
                    }
                    self.analyze_stats[pid] = stats
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
    local status = self.status
    status.cc_errors = status.cc_errors + (data.total.cc_errors or 0)
    status.pes_errors = status.pes_errors + (data.total.pes_errors or 0)

    self.force_timer = self.force_timer + 1
    if self.check_timer < (self.config.time_check or 0) then
        self.check_timer = self.check_timer + 1
        return
    end
    self.check_timer = 0

    if comparison_method(status, data, self.config.rate) or self.force_timer > FORCE_SEND_INTERVAL then
        self:update_status_and_publish(data)
        self.force_timer = 0
    end
end

--- Обновляет статус и публикует его
--- @param data table Данные потока
function ChannelMonitor:update_status_and_publish(data)
    local status = self:create_status_template()

    status.ready = data.on_air
    status.scrambled = data.total.scrambled
    status.bitrate = data.total.bitrate or 0
    status.cc_errors = self.status.cc_errors
    status.pes_errors = self.status.pes_errors

    local current_json = json_encode(status)
    if current_json ~= self.json_status_cache then
        EventDispatcher.publish("channels", current_json)
        self.json_status_cache = current_json
    end

    -- Обновление состояния для следующего сравнения
    self.status.ready = data.on_air
    self.status.scrambled = data.total.scrambled
    self.status.bitrate = data.total.bitrate or 0
    -- Сброс счетчиков ошибок
    self.status.cc_errors = 0
    self.status.pes_errors = 0
end

--- Возвращает закэшированные PSI данные
--- @param table_name string Имя таблицы (например, "PMT"). Если nil, вернет весь кэш.
--- @return table|nil psi Данные PSI или nil
function ChannelMonitor:get_psi(table_name)
    if table_name then
        return self.psi_cache[table_name]
    end
    return self.psi_cache
end

--- Возвращает статистику анализа по PID
--- @return table stats Статистика по PID
function ChannelMonitor:get_analyze_stats()
    return self.analyze_stats
end

--- Очищает статистику анализа
function ChannelMonitor:clear_analyze_stats()
    self.analyze_stats = {}
end

--- Возвращает кэш последнего отправленного JSON статуса
--- @return string|nil cache JSON статус
function ChannelMonitor:get_json_status_cache()
    return self.json_status_cache
end

--- Останавливает мониторинг и очищает ресурсы
--- @return boolean success
function ChannelMonitor:destroy()
    if self.monitor_instance then
        if type(self.monitor_instance) == "table" and self.monitor_instance.stop then
            self.monitor_instance:stop()
        end
        self.monitor_instance = nil
    end

    -- Очистка кэшей и данных
    self.psi_cache = nil
    self.analyze_stats = nil
    self.status = nil
    self.config = nil
    self.channel_data = nil
    self.stream_json = nil
    self.upstream = nil
    self.cached_source = nil
    self.json_status_cache = nil

    -- Обнуление идентификаторов
    self.name = nil
    self.display_name = nil
    self.force_timer = nil
    self.check_timer = nil
    self.last_active_id = nil

    return true
end

--- Обновляет параметры монитора
--- @param params table Таблица новых параметров
--- @return boolean success
--- @return string|nil error_message
function ChannelMonitor:update_parameters(params)
    if not params or type(params) ~= "table" then
        return false, "params must be a table"
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
            if not set_config_param(self, config_name, params[key]) then
                has_errors = true
            end
        end
    end

    if has_errors then
        return false, "Some parameters failed to update"
    end

    return true
end

return ChannelMonitor
