-- ===========================================================================
-- ChannelMonitor Class
-- ===========================================================================

local type = type
local tostring = tostring
local ipairs = ipairs
local math_max = math.max
local table_insert = table.insert
local log_info = log.info
local log_error = log.error
local json_encode = json.encode
local analyze = analyze

local get_server_name = get_server_name
local send_monitor = send_monitor
local get_stream = get_stream
local find_dvb_conf = find_dvb_conf
local parse_url = parse_url
local init_input = init_input
local kill_input = kill_input
local check = check
local ratio = ratio

local Logger = require "utils.logger"
local log_info = Logger.info
local log_error = Logger.error

local COMPONENT_NAME = "ChannelMonitor"

-- Методы сравнения для монитора канала
local channel_monitor_method_comparison = {
    [1] = function(prev, curr, rate) -- по таймеру
        return true
    end,
    [2] = function(prev, curr, rate) -- по любому изменению параметров
        if prev.ready ~= curr.on_air or 
            prev.scrambled ~= curr.total.scrambled or 
            prev.cc_errors > 0 or 
            prev.pes_errors > 0 or 
            prev.bitrate ~= curr.total.bitrate then
                return true
        end
        return false
    end,
    [3] = function(prev, curr, rate) -- по любому изменению параметров, с учетом погрешности
        if prev.ready ~= curr.on_air or 
            prev.scrambled ~= curr.total.scrambled or 
            prev.cc_errors > 0 or 
            prev.pes_errors > 0 or 
            ratio(prev.bitrate, curr.total.bitrate) > rate then
                return true
        end
        return false
    end,
    [4] = function(prev, curr, rate) -- по изменению доступности канала (добавлена для использования в связке telegraf + telegram bot)
        if prev.cc_errors > 1000 or prev.pes_errors > 1000 then -- "Сброс счетчиков ошибок для предотвращения накопления"
            prev.cc_errors = 0
            prev.pes_errors = 0
        end

        if prev.ready ~= curr.on_air then
                return true
        end
        return false
    end
}

local ChannelMonitor = {}
ChannelMonitor.__index = ChannelMonitor

--- Конструктор для ChannelMonitor.
-- @param table config Таблица конфигурации для нового монитора.
-- @param table channel_data Таблица с данными канала или его имя (string).
-- @return ChannelMonitor Новый экземпляр ChannelMonitor.
function ChannelMonitor:new(config, channel_data)
    local self = setmetatable({}, ChannelMonitor)
    self.config = config
    self.channel_data = channel_data

    self.config.rate = self.config.rate or 0.035
    self.config.time_check = self.config.time_check or 0
    self.config.analyze = self.config.analyze or false
    self.config.method_comparison = self.config.method_comparison or 3

    self.name = self.channel_data and self.channel_data.name or self.config.name
    self.stream_json = config.stream_json or {} -- Принимаем stream_json из config
    self.psi_data_cache = {}
    self.json_status_cache = nil
    self.input_instance = nil -- Для init_input

    -- self:init_stream_json() -- Удаляем вызов, так как stream_json теперь передается
    -- self:init_upstream() -- Удаляем вызов, так как upstream теперь передается

    self.time = 0
    self.force_timer = 0
    self.status = self:create_status_template()
    self.status.ready = false
    self.status.scrambled = true
    self.status.bitrate = 0
    self.status.cc_errors = 0
    self.status.pes_errors = 0

    log_info(COMPONENT_NAME, "New ChannelMonitor instance created for channel: " .. self.name)
    return self
end

--- Возвращает актуальный source.
function ChannelMonitor:get_cached_source()
    local active_id = self.channel_data and self.channel_data.active_input_id or 1
    if active_id ~= self.last_active_id then 
        self.last_active_id = active_id
        local input_index = math_max(1, active_id)
        self.cached_source = self.stream_json[input_index] or {format = "Unknown", addr = "Unknown", stream = "Unknown"}
    end
    return self.cached_source
end

--- Создает шаблон статуса.
function ChannelMonitor:create_status_template()
    local source = self:get_cached_source()
    return {
        type = "Channel",
        server = get_server_name(),
        channel = self.name,
        output = self.config.monitor,
        stream = source.stream,
        format = source.format,
        addr = source.addr
    }
end

--- Запускает мониторинг канала.
-- @return userdata Экземпляр монитора, если успешно создан, иначе nil.
function ChannelMonitor:start()
    local comparison_method = channel_monitor_method_comparison[self.config.method_comparison]
    local self_ref = self -- Сохраняем ссылку на self для использования в замыкании

    self.monitor_instance = analyze({
        upstream = self.config.upstream:stream(),
        name = "_" .. self.name,
        callback = function(data)
            if data.error then
                local content = self_ref:create_status_template()
                content.error = data.error
                send_monitor(json_encode(content), "errors")
            elseif data.psi then
                local psi_key = data.psi
                if self_ref.psi_data_cache[psi_key] then
                    self_ref.psi_data_cache[psi_key] = nil
                end
                self_ref.psi_data_cache[psi_key] = json_encode(data) 
            elseif data.total then
               if self_ref.config.analyze and data.analyze and (data.total.cc_errors > 0 or data.total.pes_errors > 0) then
                    local content = self_ref:create_status_template()
                    content.analyze = {}
                    local has_errors = false
                    for _, pid_data in ipairs(data.analyze) do
                        if pid_data.cc_error > 0 or pid_data.pes_error > 0 or pid_data.sc_error > 0 then
                            table_insert(content.analyze, pid_data)
                            has_errors = true
                        end
                    end
                    if has_errors then
                        send_monitor(json_encode(content), "analyze")
                    end
                end

                self_ref.status.cc_errors = self_ref.status.cc_errors + (data.total.cc_errors or 0)
                self_ref.status.pes_errors = self_ref.status.pes_errors + (data.total.pes_errors or 0)

                self_ref.force_timer = self_ref.force_timer + 1
                if self_ref.time < self_ref.config.time_check then
                    self_ref.time = self_ref.time + 1
                    return
                end
                self_ref.time = 0

                if comparison_method(self_ref.status, data, self_ref.config.rate) or self_ref.force_timer > 300 then -- FORCE_SEND = 300
                    local source = self_ref:get_cached_source()
                    if source then
                        self_ref.status.stream = source.stream
                        self_ref.status.format = source.format
                        self_ref.status.addr = source.addr
                    end

                    self_ref.status.ready = data.on_air
                    self_ref.status.scrambled = data.total.scrambled
                    self_ref.status.bitrate = data.total.bitrate or 0
                    
                    local json_cache = json_encode(self_ref.status)
                    send_monitor(json_cache, "channels")

                    self_ref.json_status_cache = json_cache

                    self_ref.status.cc_errors = 0
                    self_ref.status.pes_errors = 0
                    self_ref.force_timer = 0
                end
            end
        end
    })

    if not self.monitor_instance then 
        log_error(COMPONENT_NAME, "analyze returned nil for channel '" .. self.name .. "'. Failed to start monitor.")
        return nil
    end

    log_info(COMPONENT_NAME, "Started monitor for channel: " .. self.name)
    return self.monitor_instance
end

--- Обновляет параметры мониторинга канала.
-- @param table params Таблица с новыми параметрами.
-- @return boolean true, если параметры успешно обновлены, иначе false.
function ChannelMonitor:update_parameters(params)
    if type(params) ~= 'table' then
        log_error(COMPONENT_NAME, "Invalid parameters for update_parameters: expected table, got " .. type(params) .. ".")
        return false
    end

    if params.rate ~= nil and check(type(params.rate) == 'number' and params.rate >= 0.001 and params.rate <= 0.3, "params.rate must be between 0.001 and 0.3") then
        self.config.rate = params.rate
    end
    if params.time_check ~= nil and check(type(params.time_check) == 'number' and params.time_check >= 0 and params.time_check <= 300, "params.time_check must be between 0 and 300") then
        self.config.time_check = params.time_check
    end
    if params.analyze ~= nil and check(type(params.analyze) == 'boolean', "params.analyze must be boolean") then
        self.config.analyze = params.analyze
    end
    if params.method_comparison ~= nil and check(type(params.method_comparison) == 'number' and params.method_comparison >= 1 and params.method_comparison <= 4, "params.method_comparison must be between 1 and 4") then
        self.config.method_comparison = params.method_comparison
    end

    log_info(COMPONENT_NAME, "Parameters updated successfully for monitor: " .. self.name)
    return true
end

--- Останавливает монитор.
function ChannelMonitor:kill()
    if self.input_instance then
        kill_input(self.input_instance)
        self.input_instance = nil
    end
    self.monitor_instance = nil
    self.config = nil
    self.channel_data = nil
    self.stream_json = nil
    self.psi_data_cache = nil
    self.json_status_cache = nil
    log_info(COMPONENT_NAME, "Monitor killed for channel: " .. self.name)
end

return ChannelMonitor
