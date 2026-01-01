-- 1. Стандартные Lua функции
local type = type
local pairs = pairs
local ipairs = ipairs
local table_insert = table.insert
local setmetatable = setmetatable

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local Utils = ModuleManager.get_module("utils")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local EventDispatcher = ModuleManager.get_module("event_dispatcher")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local analyze = ModuleManager.get_global_dependency("analyze")
local json_encode = ModuleManager.get_global_dependency("json.encode")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ChannelMonitor"
local DEFAULT_SOURCE_TEMPLATE = {format = "Unknown", addr = "Unknown", stream = "Unknown"}
local FORCE_SEND_INTERVAL = 300

--- @class ChannelMonitor
--- @field name string
--- @field display_name string
--- @field config table
--- @field channel_data table
--- @field stream_json table
--- @field status table
--- @field psi_cache table
--- @field analyze_stats table
--- @field monitor_instance any
--- @field force_timer number
--- @field check_timer number
--- @field upstream any
--- @field json_status_cache string|nil
--- @field last_active_id number|nil
--- @field cached_source table|nil
local ChannelMonitor = {}
ChannelMonitor.__index = ChannelMonitor

local ratio = Utils.ratio
local validate_monitor_param = Utils.validate_monitor_param

-- Методы сравнения
local COMPARISON_METHODS = {
    [1] = function(prev, curr, rate) return true end,
    [2] = function(prev, curr, rate)
        return prev.ready ~= curr.on_air or 
               prev.scrambled ~= curr.total.scrambled or 
               prev.cc_errors > 0 or 
               prev.pes_errors > 0 or 
               prev.bitrate ~= curr.total.bitrate
    end,
    [3] = function(prev, curr, rate)
        return prev.ready ~= curr.on_air or 
               prev.scrambled ~= curr.total.scrambled or 
               prev.cc_errors > 0 or 
               prev.pes_errors > 0 or 
               ratio(prev.bitrate, curr.total.bitrate) > rate
    end,
    [4] = function(prev, curr, rate)
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
local function set_config_param(self, param_name, value)
    local success, result = validate_monitor_param(param_name, value)
    if not success then return false end
    local key = param_name:gsub("channel_", "")
    self.config[key] = result
    return true
end

--- Создает новый экземпляр ChannelMonitor
--- @param config table Конфигурация монитора
--- @param channel_data table Данные канала
--- @return boolean success
--- @return ChannelMonitor|nil
function ChannelMonitor.new(config, channel_data)
    if not config or type(config) ~= "table" then
        Logger.error(COMPONENT_NAME, "new: config is required")
        return false, nil
    end

    if not channel_data or type(channel_data) ~= "table" then
        Logger.error(COMPONENT_NAME, "new: channel_data is required")
        return false, nil
    end

    local self = setmetatable({}, ChannelMonitor)
    self.config = config
    self.channel_data = channel_data

    -- Валидация и установка параметров по умолчанию
    set_config_param(self, "channel_rate", config.rate)
    set_config_param(self, "channel_time_check", config.time_check)
    set_config_param(self, "channel_method_comparison", config.method_comparison)
    set_config_param(self, "channel_analyze", config.analyze)

    if not config.monitor or type(config.monitor) ~= "string" then
        Logger.error(COMPONENT_NAME, "new: monitor address is required")
        return false, nil
    end

    local upstream = config.upstream
    if not upstream then
        Logger.error(COMPONENT_NAME, "new: upstream is required in config")
        return false, nil
    end

    self.name = config.name or channel_data.name
    self.display_name = config.display_name or self.name
    self.stream_json = config.stream_json or {}
    self.upstream = upstream
    self.force_timer = 0
    self.check_timer = 0
    self.json_status_cache = nil
    self.last_active_id = nil
    self.cached_source = nil
    self.status = {
        cc_errors = 0,
        pes_errors = 0
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
        Logger.error(COMPONENT_NAME, "start: Invalid comparison method %s", tostring(self.config.method_comparison))
        return false
    end

    self.monitor_instance = analyze({
        upstream = self.upstream:stream(),
        name = "_" .. self.name,
        callback = function(data)
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
        Logger.error(COMPONENT_NAME, "start: analyze returned nil")
        return false
    end

    return true
end

--- Возвращает закэшированные данные об источнике
--- @return table
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
--- @return table
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
--- @param data table
function ChannelMonitor:process_error_data(data)
    Logger.error(COMPONENT_NAME, "[%s] Stream error: %s", self.name, tostring(data.error))

    local content = self:create_status_template()
    content.error = data.error
    EventDispatcher.publish("error", json_encode(content))
end

--- Обработка PSI данных
--- @param data table
function ChannelMonitor:process_psi_data(data)
    self.psi_cache[data.psi] = data
end

--- Обработка данных анализа (статистика по PID)
--- @param data table
function ChannelMonitor:process_analyze_data(data)
    if not self.config.analyze then return end

    for _, pid_data in ipairs(data.analyze) do
        local pid = pid_data.pid
        local cc = pid_data.cc_error or 0
        local pes = pid_data.pes_error or 0
        local sc = pid_data.sc_error or 0

        if pid and (cc > 0 or pes > 0 or sc > 0) then
            if not self.analyze_stats[pid] then
                self.analyze_stats[pid] = {
                    type = self:get_pid_description(pid),
                    cc = cc,
                    pes = pes,
                    sc = sc
                }
            else
                local stats = self.analyze_stats[pid]
                stats.cc = stats.cc + cc
                stats.pes = stats.pes + pes
                stats.sc = stats.sc + sc
            end
        end
    end
end

--- Обработка суммарных данных потока
--- @param data table
--- @param comparison_method function
function ChannelMonitor:process_total_data(data, comparison_method)
    self.status.cc_errors = self.status.cc_errors + (data.total.cc_errors or 0)
    self.status.pes_errors = self.status.pes_errors + (data.total.pes_errors or 0)

    self.force_timer = self.force_timer + 1
    if self.check_timer < (self.config.time_check or 0) then
        self.check_timer = self.check_timer + 1
        return
    end
    self.check_timer = 0

    if comparison_method(self.status, data, self.config.rate) or self.force_timer > FORCE_SEND_INTERVAL then
        self:update_status_and_publish(data)
        self.force_timer = 0
    end
end

--- Обновляет статус и публикует его
--- @param data table
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

    -- Сброс данных
    self.status.cc_errors = 0
    self.status.pes_errors = 0
end

--- Возвращает закэшированные PSI данные
--- @param table_name string|nil Имя таблицы (например, "PMT"). Если nil, вернет весь кэш.
--- @return table|nil
function ChannelMonitor:get_psi(table_name)
    if table_name then
        return self.psi_cache[table_name]
    end
    return self.psi_cache
end

--- Возвращает статистику анализа по PID
--- @return table
function ChannelMonitor:get_analyze_stats()
    return self.analyze_stats
end

--- Очищает статистику анализа
function ChannelMonitor:clear_analyze_stats()
    self.analyze_stats = {}
end

--- Возвращает кэш последнего отправленного JSON статуса
--- @return string|nil
function ChannelMonitor:get_json_status_cache()
    return self.json_status_cache
end

--- Возвращает описание назначения PID
--- @param pid number
--- @return string
function ChannelMonitor:get_pid_description(pid)
    local pmt = self.psi_cache["PMT"]
    if not pmt and self.channel_data and self.channel_data.get_psi then
        pmt = self.channel_data:get_psi("PMT")
    end

    if pmt and pmt.streams then
        for _, stream in ipairs(pmt.streams) do
            if stream.pid == pid then
                return stream.type_name or "UNKNOWN"
            end
        end
    end
    return "UNKNOWN"
end

--- Останавливает мониторинг и очищает ресурсы
function ChannelMonitor:kill()
    if self.monitor_instance then
        self.monitor_instance = nil
    end
    self.name = nil
    self.display_name = nil
    self.config = nil
    self.channel_data = nil
    self.stream_json = nil
    self.upstream = nil
    self.status = nil
    self.psi_cache = nil
    self.analyze_stats = nil
    self.force_timer = nil
    self.check_timer = nil
    self.json_status_cache = nil
end

--- Обновляет параметры монитора
--- @param params table
--- @return boolean success
function ChannelMonitor:update_parameters(params)
    if not params or type(params) ~= "table" then return false end

    if params.rate ~= nil then
        set_config_param(self, "channel_rate", params.rate)
    end
    
    if params.time_check ~= nil then
        set_config_param(self, "channel_time_check", params.time_check)
    end

    if params.method_comparison ~= nil then
        set_config_param(self, "channel_method_comparison", params.method_comparison)
    end

    if params.analyze ~= nil then
        set_config_param(self, "channel_analyze", params.analyze)
    end

    return true
end

return ChannelMonitor
