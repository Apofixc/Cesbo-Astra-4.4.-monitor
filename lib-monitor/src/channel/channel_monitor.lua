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
local FORCE_SEND_INTERVAL = 300

--- @class ChannelMonitor
--- @field private name string
--- @field private config table
--- @field private channel_data table
--- @field private stream_json table
--- @field private status table
--- @field private psi_cache table
--- @field private pid_types table
--- @field private analyze_stats table
--- @field private monitor_instance any
--- @field private force_timer number
--- @field private check_timer number
--- @field private upstream any
local ChannelMonitor = {}
ChannelMonitor.__index = ChannelMonitor

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
               Utils.ratio(prev.bitrate, curr.total.bitrate) > rate
    end,
    [4] = function(prev, curr, rate)
        if prev.cc_errors > 1000 or prev.pes_errors > 1000 then
            prev.cc_errors = 0
            prev.pes_errors = 0
        end
        return prev.ready ~= curr.on_air
    end
}

--- Валидирует конфигурацию монитора
--- @param config table
--- @return boolean success
local function validate_config(config)
    if not config or type(config) ~= "table" then
        Logger.error(COMPONENT_NAME, "validate_config: config must be a table")
        return false
    end

    if not config.monitor or type(config.monitor) ~= "string" then
        Logger.error(COMPONENT_NAME, "validate_config: monitor address is required")
        return false
    end

    local schema = MonitorConfig and MonitorConfig.ValidationSchema or {}
    
    local function validate_param(param_name, schema_key)
        local s = schema[schema_key]
        if not s then return end
        
        local val = config[param_name]
        if val == nil then
            config[param_name] = s.default
        elseif type(val) ~= s.type or (s.min and val < s.min) or (s.max and val > s.max) then
            Logger.warn(COMPONENT_NAME, "Parameter '%s' is invalid (value: %s). Using default: %s", param_name, tostring(val), tostring(s.default))
            config[param_name] = s.default
        end
    end

    validate_param("rate", "channel_rate")
    validate_param("time_check", "channel_time_check")
    validate_param("method_comparison", "channel_method_comparison")
    validate_param("analyze", "channel_analyze")

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

    if not validate_config(config) then
        return false, nil
    end

    local upstream = config.upstream
    if not upstream then
        Logger.error(COMPONENT_NAME, "new: upstream is required in config")
        return false, nil
    end

    local self = setmetatable({}, ChannelMonitor)
    self.name = config.name or channel_data.name
    self.config = config
    self.channel_data = channel_data
    self.stream_json = config.stream_json or {}
    self.upstream = upstream
    self.force_timer = 0
    self.check_timer = 0
    self.status = {
        type = "Channel",
        server = Utils.get_server_name(),
        channel = self.name,
        output = config.monitor,
        ready = false,
        scrambled = true,
        bitrate = 0,
        cc_errors = 0,
        pes_errors = 0
    }
    self.psi_cache = {}
    self.pid_types = {}
    self.analyze_stats = {}
    return true, self
end

--- Публикует данные мониторинга через EventDispatcher
--- @param content string JSON данные
--- @param event_type string Тип события
function ChannelMonitor:publish(content, event_type)
    EventDispatcher.publish(event_type, content)
end

--- Запускает мониторинг
--- @return boolean success
function ChannelMonitor:start()
    self.monitor_instance = analyze({
        upstream = self.upstream:stream(),
        name = "_" .. self.name,
        callback = function(data) self:on_data(data) end
    })

    if not self.monitor_instance then
        Logger.error(COMPONENT_NAME, "start: analyze returned nil")
        return false
    end

    return true
end

function ChannelMonitor:get_cached_source()
    -- local active_id = self.channel_data and self.channel_data.active_input_id or 1
    -- if active_id ~= self.last_active_id then 
    --     self.last_active_id = active_id
    --     local input_index = math_max(1, active_id)
    --     self.cached_source = self.stream_json[input_index] or DEFAULT_SOURCE_TEMPLATE
    -- end
    -- return self.cached_source
end

--- Обработка данных от analyze
--- @param data table
function ChannelMonitor:on_data(data)
    if data.error then
        local content = Utils.table_copy(self.status)
        content.error = data.error
        self:publish(json_encode(content), "error")
    elseif data.psi then
        self:process_psi_data(data)
    elseif data.total then
        self:process_total_data(data)
    end
end

--- Обработка PSI данных
--- @param data table
function ChannelMonitor:process_psi_data(data)
    if not data then return end

    local psi_type = data.psi and data.psi:upper()
    -- Кэшируем таблицу
    self.psi_cache[psi_type or data.psi] = data

    -- Если это PMT, обновляем типы PID
    if psi_type == "PMT" and data.streams then
        for _, stream in ipairs(data.streams) do
            if stream.pid then
                self.pid_types[stream.pid] = stream.type_name or "UNKNOWN"
            end
        end
    end

    self:publish(json_encode(data), "psi")
end

--- Обработка суммарных данных потока
--- @param data table
function ChannelMonitor:process_total_data(data)
    if self.config.analyze and data.analyze and (data.total.cc_errors > 0 or data.total.pes_errors > 0) then
        for _, pid_data in ipairs(data.analyze) do
            local pid = pid_data.pid
            local cc = pid_data.cc_error or 0
            local pes = pid_data.pes_error or 0
            local sc = pid_data.sc_error or 0
            
            if pid and (cc > 0 or pes > 0 or sc > 0) then
                if not self.analyze_stats[pid] then
                    self.analyze_stats[pid] = {
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

    self.status.cc_errors = self.status.cc_errors + (data.total.cc_errors or 0)
    self.status.pes_errors = self.status.pes_errors + (data.total.pes_errors or 0)

    self.force_timer = self.force_timer + 1
    if self.check_timer < (self.config.time_check or 0) then
        self.check_timer = self.check_timer + 1
        return
    end
    self.check_timer = 0

    local comparison = COMPARISON_METHODS[self.config.method_comparison or 3]
    if comparison(self.status, data, self.config.rate) or self.force_timer > FORCE_SEND_INTERVAL then
        self:update_status_and_publish(data)
    end
end

--- Обновляет статус и публикует его
--- @param data table
function ChannelMonitor:update_status_and_publish(data)
    local source = self.stream_json[1] or {format = "Unknown", addr = "Unknown", stream = "Unknown"}
    self.status.stream = source.stream
    self.status.format = source.format
    self.status.addr = source.addr

    self.status.ready = data.on_air
    self.status.scrambled = data.total.scrambled
    self.status.bitrate = data.total.bitrate or 0

    if self.config.analyze and next(self.analyze_stats) then
        local report = {}
        for pid, stats in pairs(self.analyze_stats) do
            report[pid] = {
                type = self.pid_types[pid] or "UNKNOWN",
                cc = stats.cc,
                pes = stats.pes,
                sc = stats.sc
            }
        end
        self.status.analyze = report
    else
        self.status.analyze = nil
    end
    
    self:publish(json_encode(self.status), "channels")

    -- Сброс данных
    self.status.cc_errors = 0
    self.status.pes_errors = 0
    self.analyze_stats = {}
    self.force_timer = 0
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

--- Возвращает описание назначения PID
--- @param pid number
--- @return string|nil
function ChannelMonitor:get_pid_description(pid)
    return self.pid_types[pid]
end

--- Останавливает мониторинг и очищает ресурсы
function ChannelMonitor:stop()
    if self.monitor_instance then
        self.monitor_instance = nil
    end
    self.name = nil
    self.config = nil
    self.channel_data = nil
    self.stream_json = nil
    self.upstream = nil
    self.status = nil
    self.psi_cache = nil
    self.pid_types = nil
    self.analyze_stats = nil
    self.force_timer = nil
    self.check_timer = nil
end

--- Обновляет параметры монитора
--- @param params table
--- @return boolean success
function ChannelMonitor:update_parameters(params)
    if not params or type(params) ~= "table" then return false end

    local schema = MonitorConfig and MonitorConfig.ValidationSchema or {}
    
    if params.rate ~= nil then
        local s = schema.channel_rate
        if type(params.rate) == "number" and params.rate >= s.min and params.rate <= s.max then
            self.config.rate = params.rate
        end
    end
    
    if params.time_check ~= nil then
        local s = schema.channel_time_check
        if type(params.time_check) == "number" and params.time_check >= s.min and params.time_check <= s.max then
            self.config.time_check = params.time_check
        end
    end

    return true
end

return ChannelMonitor
