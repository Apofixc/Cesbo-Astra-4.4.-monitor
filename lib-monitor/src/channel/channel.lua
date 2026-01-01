-- 1. Стандартные Lua функции
local ipairs = ipairs
local string_lower = string.lower
local tostring = tostring
local type = type

-- 2. Функции из ModuleManager.get_module()
local Adapter = ModuleManager.get_module("adapter")
local ChannelMonitor = ModuleManager.get_module("channel_monitor")
local ChannelStorage = ModuleManager.get_module("channel_storage")
local Logger = ModuleManager.get_module("logger")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local Utils = ModuleManager.get_module("utils")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local find_channel = ModuleManager.get_global_dependency("find_channel")
local init_input = ModuleManager.get_global_dependency("init_input")
local kill_channel = ModuleManager.get_global_dependency("kill_channel")
local kill_input = ModuleManager.get_global_dependency("kill_input")
local make_channel = ModuleManager.get_global_dependency("make_channel")
local parse_url = ModuleManager.get_global_dependency("parse_url")
local string_split = ModuleManager.get_global_dependency("string.split")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "Channel"
local MONITOR_TYPE_INPUT = "input"
local MONITOR_TYPE_OUTPUT = "output"
local MONITOR_TYPE_IP = "ip"

-- 5. Инициализация объектов из загруженных модулей
--- @class Channel
local Channel = {}

--- Псевдоним для получения имени стрима
local get_stream = Utils.get_stream_name

--- Таблица обработчиков форматов входных данных
local format_handlers = {
    dvb = function(config)
        local cfg = {format = config.format, addr = config.addr}
        local adap_conf = Adapter.find_dvb_conf(config.addr)
        cfg.stream = adap_conf and adap_conf.source or "dvb"
        return cfg
    end,
    udp = function(config)
        local cfg = {format = config.format}
        cfg.addr = config.localaddr .. "@" .. config.addr .. ":" .. config.port
        cfg.stream = get_stream(config.addr) or "unknown_stream"
        return cfg
    end,
    rtp = function(config)
        local cfg = {format = config.format}
        cfg.addr = config.localaddr .. "@" .. config.addr .. ":" .. config.port
        cfg.stream = get_stream(config.addr) or "unknown_stream"
        return cfg
    end,
    http = function(config)
        local cfg = {format = config.format}
        cfg.addr = config.host .. ":" .. config.port .. config.path
        cfg.stream = get_stream(config.host) or "unknown_stream"
        return cfg
    end,
    file = function(config)
        local cfg = {format = config.format, addr = config.filename, stream = "file"}
        return cfg
    end,
}

--- Вспомогательная функция для подготовки stream_json
local function prepare_stream_json(ch_data)
    local stream_json = {}
    if not ch_data or not ch_data.input then return stream_json end

    for key, input in ipairs(ch_data.input) do
        local handler = format_handlers[input.config.format]
        if handler then
            stream_json[key] = handler(input.config)
        else
            stream_json[key] = {format = input.config.format or "Unknown", addr = "Unknown", stream = "Unknown"}
        end
    end
    return stream_json
end

--- Создает новый монитор канала
--- @param config table Конфигурация монитора
--- @param channel_data table|string Данные канала или имя
--- @return boolean success Статус выполнения
--- @return any|nil result Экземпляр монитора или nil
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

    config.name = name
    config.stream_json = stream_json
    config.upstream = upstream

    local success_new, monitor = ChannelMonitor.new(config, ch_data)
    if not success_new then
        if input_instance then kill_input(input_instance) end
        Logger.error(COMPONENT_NAME, "make_monitor: failed to create ChannelMonitor instance for '%s'", name)
        return false, nil
    end

    local success_start, monitor_instance = monitor:start()
    if success_start then
        monitor.input_instance = input_instance
        ChannelStorage.register(name, monitor)
        Logger.info(COMPONENT_NAME, "Monitor '%s' successfully started", name)
        return true, monitor_instance
    else
        if input_instance then kill_input(input_instance) end
        Logger.error(COMPONENT_NAME, "make_monitor: failed to start monitor for '%s'", name)
        return false, nil
    end
end

--- Останавливает монитор
--- @param name string Имя монитора
--- @return boolean success Статус выполнения
--- @return table|nil result Конфигурация монитора для восстановления или nil
function kill_monitor(name)
    local monitor = ChannelStorage.find(name)
    if not monitor then
        Logger.debug(COMPONENT_NAME, "kill_monitor: monitor '%s' not found", tostring(name))
        return false, nil
    end

    -- Сохраняем конфигурацию перед удалением
    local config = monitor._config

    -- Очистка специфичных для Channel ресурсов перед удалением из хранилища
    if monitor.input_instance then
        kill_input(monitor.input_instance)
        monitor.input_instance = nil
    end

    -- ChannelStorage.unregister сам вызовет monitor:stop()
    local success = ChannelStorage.unregister(name)
    if success then
        Logger.info(COMPONENT_NAME, "Monitor '%s' successfully killed", name)
        return true, config
    end
    return false, nil
end

--- Таблица обработчиков типов мониторов
local monitor_type_handlers = {
    [MONITOR_TYPE_INPUT] = function(conf, channel_data)
        local input_data = channel_data.input[1]
        if not input_data then
            Logger.error(COMPONENT_NAME, string.format("Отсутствуют входные данные для типа монитора 'input' в потоке '%s'.", conf.name))
            return false, nil, nil
        end

        local upstream = input_data.input.tail
        local split_result = string_split(conf.input[1], "#")
        local monitor_target = type(split_result) == 'table' and split_result[1] or conf.input[1]

        return true, upstream, monitor_target
    end,
    [MONITOR_TYPE_OUTPUT] = function(conf, channel_data)
        local upstream = channel_data.tail
        local monitor_target = MONITOR_TYPE_OUTPUT
        return true, upstream, monitor_target
    end,
    [MONITOR_TYPE_IP] = function(conf, channel_data)
        if not channel_data.output or #channel_data.output == 0 then
            Logger.error(COMPONENT_NAME, string.format("Отсутствует channel_data.output для IP-монитора в потоке '%s'.", conf.name))
            return false, nil, nil
        end

        local key = 1
        for index, output in ipairs(channel_data.output) do
            if output.config and output.config.monitor then
                key = index
                break
            end
        end

        local split_result = string_split(conf.output[key], "#")
        local monitor_target = type(split_result) == 'table' and split_result[1] or conf.output[key]
        
        Logger.info(COMPONENT_NAME, "Используется ключ вывода %d для IP-монитора в потоке '%s'.", key, conf.name)
        return true, nil, monitor_target
    end,
}

--- Создает поток и монитор для него
--- @param conf table Конфигурация потока
--- @return boolean success Статус выполнения
--- @return any|nil result Экземпляр монитора или nil
function make_stream(conf)
    local channel_data = make_channel(conf)
    if not channel_data then
        Logger.error(COMPONENT_NAME, "make_stream: make_channel failed for '%s'", tostring(conf.name))
        return false, nil
    end

    local monitor_name = (conf.monitor and conf.monitor.name) or conf.name
    local monitor_type = (conf.monitor and conf.monitor.monitor_type and string_lower(conf.monitor.monitor_type)) or MONITOR_TYPE_OUTPUT

    local handler = monitor_type_handlers[monitor_type]
    if not handler then
        Logger.error(COMPONENT_NAME, "make_stream: unknown monitor type '%s' for stream '%s'", monitor_type, conf.name)
        kill_channel(channel_data)
        return false, nil
    end

    local success_handler, upstream, monitor_target = handler(conf, channel_data)
    if not success_handler then
        kill_channel(channel_data)
        return false, nil
    end

    local monitor_config = {
        name = monitor_name,
        display_name = conf.monitor and conf.monitor.display_name,
        upstream = upstream,
        monitor = monitor_target,
        rate = conf.monitor and conf.monitor.rate,
        time_check = conf.monitor and conf.monitor.time_check,
        analyze = conf.monitor and conf.monitor.analyze,
        method_comparison = conf.monitor and conf.monitor.method_comparison
    }

    local success, monitor_instance = make_monitor(monitor_config, channel_data)
    if not success then
        Logger.error(COMPONENT_NAME, "make_stream: make_monitor failed for '%s', killing channel", conf.name)
        kill_channel(channel_data)
        return false, nil
    end

    return true, monitor_instance
end

--- Останавливает поток и монитор
--- @param channel_data table Данные канала
--- @return boolean success Статус выполнения
--- @return table|nil result Конфигурация потока для восстановления или nil
function kill_stream(channel_data)
    if not channel_data or not channel_data.config then
        Logger.error(COMPONENT_NAME, "kill_stream: invalid channel_data")
        return false, nil
    end
    local name = channel_data.config.name
    local config = channel_data.config
    
    local success_monitor = kill_monitor(name)
    if not success_monitor then
        Logger.warn(COMPONENT_NAME, "kill_stream: monitor '%s' was not active or failed to kill", name)
    end

    local success_channel = kill_channel(channel_data)
    if not success_channel then
        Logger.error(COMPONENT_NAME, "kill_stream: failed to kill channel '%s'", name)
        return false, nil
    end
    
    Logger.info(COMPONENT_NAME, "Stream and monitor '%s' successfully killed", name)
    return true, config
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
--- @param name string Имя монитора
--- @param params table Новые параметры
--- @return boolean success Статус выполнения
--- @return nil result
function update_monitor_parameters(name, params)
    local monitor = ChannelStorage.find(name)
    if monitor then
        return monitor:update_parameters(params)
    end
    return false, nil
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
