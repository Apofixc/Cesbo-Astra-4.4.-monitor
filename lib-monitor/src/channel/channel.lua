-- 1. Стандартные Lua функции
local type = type
local tostring = tostring
local ipairs = ipairs
local string_lower = string.lower

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local Utils = ModuleManager.get_module("utils")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local ChannelMonitor = ModuleManager.get_module("channel_monitor")
local ChannelStorage = ModuleManager.get_module("channel_storage")
local Adapter = ModuleManager.get_module("adapter")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local find_channel = ModuleManager.get_global_dependency("find_channel")
local make_channel = ModuleManager.get_global_dependency("make_channel")
local kill_channel = ModuleManager.get_global_dependency("kill_channel")
local init_input = ModuleManager.get_global_dependency("init_input")
local kill_input = ModuleManager.get_global_dependency("kill_input")
local parse_url = ModuleManager.get_global_dependency("parse_url")
local string_split = ModuleManager.get_global_dependency("string.split")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "Channel"

-- 5. Инициализация объектов из загруженных модулей
--- @class Channel
local Channel = {}

--- Вспомогательная функция для подготовки stream_json
local function prepare_stream_json(ch_data)
    local stream_json = {}
    if not ch_data or not ch_data.input then return stream_json end

    for key, input in ipairs(ch_data.input) do
        local cfg = {format = input.config.format}
        if input.config.format == "dvb" then
            cfg.addr = input.config.addr
            local success_ad, adap_conf = find_dvb_conf(input.config.addr)
            cfg.stream = success_ad and adap_conf and adap_conf.source or "dvb"      
        elseif input.config.format == "udp" or input.config.format == "rtp" then
            cfg.addr = (input.config.localaddr or "") .. "@" .. (input.config.addr or "") .. ":" .. (input.config.port or "")
            cfg.stream = Utils.get_stream_name(input.config.addr)
        elseif input.config.format == "http" then
            cfg.addr = (input.config.host or "") .. ":" .. (input.config.port or "") .. (input.config.path or "")
            cfg.stream = Utils.get_stream_name(input.config.host)
        elseif input.config.format == "file" then
            cfg.addr = input.config.filename
            cfg.stream = "file"
        end
        stream_json[key] = cfg
    end
    return stream_json
end

--- Создает новый монитор канала
--- @param config table Конфигурация монитора
--- @param channel_data table|string Данные канала или имя
--- @return boolean success
--- @return any monitor_instance или nil
function make_monitor(config, channel_data)
    if ChannelStorage.count() >= (MonitorConfig.ChannelMonitorLimit or 50) then
        Logger.error(COMPONENT_NAME, "make_monitor: monitor limit reached")
        return false, nil
    end

    local ch_data = type(channel_data) == "table" and channel_data or find_channel(tostring(channel_data))
    local name = (ch_data and ch_data.name) or (type(channel_data) == "string" and channel_data) or config.name

    if ChannelStorage.find(name) then
        Logger.error(COMPONENT_NAME, "make_monitor: Monitor '%s' already exists", name)
        return false, nil
    end

    local stream_json = prepare_stream_json(ch_data)
    if #stream_json == 0 then
        stream_json[1] = {format = "Unknown", addr = "Unknown", stream = "Unknown"}
    end

    local success_new, monitor = ChannelMonitor.new(name, config, stream_json)
    if not success_new then
        return false, nil
    end
    
    local upstream = config.upstream
    local input_instance = nil

    if not upstream then
        local url_cfg = parse_url(config.monitor)
        if not url_cfg then
            Logger.error(COMPONENT_NAME, "make_monitor: invalid monitor address '%s'", config.monitor)
            return false, nil
        end
        url_cfg.name = name
        input_instance = init_input(url_cfg)
        if not input_instance then
            Logger.error(COMPONENT_NAME, "make_monitor: init_input failed")
            return false, nil
        end
        upstream = input_instance.tail
    end

    if monitor:start(upstream) then
        monitor.input_instance = input_instance
        ChannelStorage.register(name, monitor)
        return true, monitor.monitor_instance
    else
        if input_instance then kill_input(input_instance) end
        Logger.error(COMPONENT_NAME, "make_monitor: failed to start monitor")
        return false, nil
    end
end

--- Останавливает монитор
--- @param name string Имя монитора
--- @return boolean success
function kill_monitor(name)
    local monitor = ChannelStorage.find(name)
    if not monitor then return false end

    monitor:stop()
    if monitor.input_instance then
        kill_input(monitor.input_instance)
    end

    ChannelStorage.unregister(name)
    return true
end

--- Создает поток и монитор для него
--- @param conf table Конфигурация потока
--- @return boolean success
--- @return any monitor_instance или nil
function make_stream(conf)
    local channel_data = make_channel(conf)
    if not channel_data then
        Logger.error(COMPONENT_NAME, "make_stream: make_channel failed")
        return false, nil
    end

    local monitor_name = (conf.monitor and conf.monitor.name) or conf.name
    local monitor_type = (conf.monitor and conf.monitor.monitor_type and string_lower(conf.monitor.monitor_type)) or "output"

    local upstream, monitor_target
    if monitor_type == "input" then
        local input_data = channel_data.input[1]
        upstream = input_data.input.tail
        local parts = string_split(conf.input[1], "#")
        monitor_target = parts[1] or conf.input[1]
    elseif monitor_type == "output" then
        upstream = channel_data.tail
        monitor_target = "output"
    else
        upstream = channel_data.tail
        monitor_target = "output"
    end

    local monitor_config = {
        name = monitor_name,
        upstream = upstream,
        monitor = monitor_target,
        rate = conf.monitor and conf.monitor.rate,
        time_check = conf.monitor and conf.monitor.time_check,
        analyze = conf.monitor and conf.monitor.analyze,
        method_comparison = conf.monitor and conf.monitor.method_comparison
    }

    local success, monitor_instance = make_monitor(monitor_config, channel_data)
    return success, monitor_instance
end

--- Останавливает поток и монитор
--- @param channel_data table
--- @return boolean success
function kill_stream(channel_data)
    if not channel_data or not channel_data.config then return false end
    local name = channel_data.config.name
    
    kill_monitor(name)
    kill_channel(channel_data)
    
    return true
end

--- Возвращает список мониторов
function get_list_monitor()
    return ChannelStorage.get_all()
end

--- Находит монитор
function find_monitor(name)
    return ChannelStorage.find(name)
end

--- Обновляет параметры
function update_monitor_parameters(name, params)
    local monitor = ChannelStorage.find(name)
    if monitor then
        return monitor:update_parameters(params)
    end
    return false
end

-- Экспорт в таблицу модуля для ModuleManager
Channel.make_monitor = make_monitor
Channel.kill_monitor = kill_monitor
Channel.make_stream = make_stream
Channel.kill_stream = kill_stream
Channel.get_list_monitor = get_list_monitor
Channel.find_monitor = find_monitor
Channel.update_monitor_parameters = update_monitor_parameters

return Channel
