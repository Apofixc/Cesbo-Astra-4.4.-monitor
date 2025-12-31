-- 1. Стандартные Lua функции
local type = type
local ipairs = ipairs
local table_insert = table.insert
local setmetatable = setmetatable

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local Utils = ModuleManager.get_module("utils")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local MonitorSettings = ModuleManager.get_module("monitor_settings")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local analyze = ModuleManager.get_global_dependency("analyze")
local json_encode = ModuleManager.get_global_dependency("json.encode")
local http_request = ModuleManager.get_global_dependency("http_request")
local astra_version = ModuleManager.get_global_dependency("astra.version")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ChannelMonitor"
local FORCE_SEND_INTERVAL = 300

--- @class ChannelMonitor
--- @field private name string
--- @field private config table
--- @field private stream_json table
--- @field private status table
--- @field private monitor_instance any
--- @field private force_timer number
--- @field private check_timer number
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
    
    -- Валидация rate
    local s_rate = schema.channel_rate
    if s_rate then
        if config.rate == nil then
            config.rate = s_rate.default
        elseif type(config.rate) ~= s_rate.type or config.rate < s_rate.min or config.rate > s_rate.max then
            Logger.warn(COMPONENT_NAME, "validate_config: invalid rate, using default")
            config.rate = s_rate.default
        end
    end

    -- Валидация time_check
    local s_tc = schema.channel_time_check
    if s_tc then
        if config.time_check == nil then
            config.time_check = s_tc.default
        elseif type(config.time_check) ~= s_tc.type or config.time_check < s_tc.min or config.time_check > s_tc.max then
            Logger.warn(COMPONENT_NAME, "validate_config: invalid time_check, using default")
            config.time_check = s_tc.default
        end
    end

    -- Валидация method_comparison
    local s_mc = schema.channel_method_comparison
    if s_mc then
        if config.method_comparison == nil then
            config.method_comparison = s_mc.default
        elseif type(config.method_comparison) ~= s_mc.type or config.method_comparison < s_mc.min or config.method_comparison > s_mc.max then
            Logger.warn(COMPONENT_NAME, "validate_config: invalid method_comparison, using default")
            config.method_comparison = s_mc.default
        end
    end

    return true
end

--- Создает новый экземпляр ChannelMonitor
--- @param name string Имя монитора
--- @param config table Конфигурация
--- @param stream_json table Данные о потоках
--- @return boolean success
--- @return ChannelMonitor|nil
function ChannelMonitor.new(name, config, stream_json)
    if not name or type(name) ~= "string" then
        Logger.error(COMPONENT_NAME, "new: name is required")
        return false, nil
    end

    if not validate_config(config) then
        return false, nil
    end

    local self = setmetatable({}, ChannelMonitor)
    self.name = name
    self.config = config
    self.stream_json = stream_json or {}
    self.force_timer = 0
    self.check_timer = 0
    self.status = {
        type = "Channel",
        server = Utils.get_server_name(),
        channel = name,
        output = config.monitor,
        ready = false,
        scrambled = true,
        bitrate = 0,
        cc_errors = 0,
        pes_errors = 0
    }
    return true, self
end

--- Отправляет данные мониторинга
--- @param content string JSON данные
--- @param feed string Тип фида
function ChannelMonitor:send(content, feed)
    local monit_addresses = MonitorSettings and MonitorSettings.MONIT_ADDRESS or {}
    local recipients = monit_addresses[feed]
    if not recipients then return end

    for _, addr in ipairs(recipients) do
        http_request({
            host = addr.host,
            path = addr.path,
            method = "POST",
            content = content,
            port = addr.port,
            headers = {
                "User-Agent: Astra v." .. (astra_version or "unknown"),
                "Host: " .. addr.host .. ":" .. addr.port,
                "Content-Type: application/json;charset=utf-8",
                "Content-Length: " .. #content,
                "Connection: close",
            },
            callback = function(s, r)
                if not s or (type(r) == "table" and r.code and r.code ~= 200) then
                    Logger.error(COMPONENT_NAME, "HTTP request failed for feed '%s': %s", feed, r and r.code or "unknown")
                end
            end
        })
    end
end

--- Запускает мониторинг
--- @param upstream any Поток для анализа
--- @return boolean success
function ChannelMonitor:start(upstream)
    if not upstream then
        Logger.error(COMPONENT_NAME, "start: upstream is required")
        return false
    end

    if self.monitor_instance then return true end

    self.monitor_instance = analyze({
        upstream = upstream,
        name = "_" .. self.name,
        callback = function(data) self:on_data(data) end
    })

    if not self.monitor_instance then
        Logger.error(COMPONENT_NAME, "start: analyze returned nil")
        return false
    end

    return true
end

--- Обработка данных от analyze
--- @param data table
function ChannelMonitor:on_data(data)
    if data.error then
        local content = Utils.table_copy(self.status)
        content.error = data.error
        self:send(json_encode(content), "error")
    elseif data.psi then
        self:send(json_encode(data), "psi")
    elseif data.total then
        self:process_total_data(data)
    end
end

--- Обработка суммарных данных потока
--- @param data table
function ChannelMonitor:process_total_data(data)
    if self.config.analyze and data.analyze and (data.total.cc_errors > 0 or data.total.pes_errors > 0) then
        local content = Utils.table_copy(self.status)
        content.analyze = {}
        local has_errors = false
        for _, pid_data in ipairs(data.analyze) do
            if pid_data.cc_error > 0 or pid_data.pes_error > 0 or pid_data.sc_error > 0 then
                table_insert(content.analyze, pid_data)
                has_errors = true
            end
        end
        if has_errors then
            self:send(json_encode(content), "analyze")
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
        self:update_status_and_send(data)
    end
end

--- Обновляет статус и отправляет его
--- @param data table
function ChannelMonitor:update_status_and_send(data)
    local source = self.stream_json[1] or {format = "Unknown", addr = "Unknown", stream = "Unknown"}
    self.status.stream = source.stream
    self.status.format = source.format
    self.status.addr = source.addr

    self.status.ready = data.on_air
    self.status.scrambled = data.total.scrambled
    self.status.bitrate = data.total.bitrate or 0
    
    self:send(json_encode(self.status), "channels")

    self.status.cc_errors = 0
    self.status.pes_errors = 0
    self.force_timer = 0
end

--- Останавливает мониторинг
function ChannelMonitor:stop()
    self.monitor_instance = nil
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
