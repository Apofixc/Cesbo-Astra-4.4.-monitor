-- 1. Стандартные Lua функции
local ipairs = ipairs
local string_lower = string.lower
local tostring = tostring
local type = type
local string_format = string.format

-- 2. Функции из ModuleManager.get_module()
local ChannelMonitor = ModuleManager.get_module("channel_monitor")
local ChannelRepository = ModuleManager.get_module("channel_repository")
local Logger = ModuleManager.get_module("logger")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local Utils = ModuleManager.get_module("utils")
local DvbRepository = ModuleManager.get_module("dvb_repository")

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

--- Таблица обработчиков типов мониторов
local monitor_type_handlers = {
    [MONITOR_TYPE_INPUT] = function(conf, channel_data)
        local input_data = channel_data.input[1]
        if not input_data then
            Logger.error(COMPONENT_NAME, "Отсутствуют входные данные для типа монитора 'input' в потоке '%s'.", conf.name)
            return nil
        end

        local upstream = input_data.input.tail
        
        -- Формируем информативное имя монитора для входа
        local monitor_target = "Input: Unknown"
        if input_data.config then
            local fmt = input_data.config.format or "Unknown"
            local addr = "Unknown"
            
            if fmt == "dvb" then
                addr = input_data.config.addr or "Unknown"
            elseif fmt == "udp" or fmt == "rtp" then
                addr = (input_data.config.addr or "0.0.0.0") .. ":" .. (input_data.config.port or "0")
            elseif fmt == "http" then
                addr = (input_data.config.host or "localhost") .. ":" .. (input_data.config.port or "80")
            elseif fmt == "file" then
                addr = input_data.config.filename or "Unknown"
            end
            
            monitor_target = string_format("Input: %s (%s)", fmt:upper(), addr)
        end

        return { upstream = upstream, monitor_target = monitor_target }
    end,
    [MONITOR_TYPE_OUTPUT] = function(conf, channel_data)
        local upstream = channel_data.tail
        local monitor_target = "Output: Channel"
        return { upstream = upstream, monitor_target = monitor_target }
    end,
    [MONITOR_TYPE_IP] = function(conf, channel_data)
        if not channel_data.output or #channel_data.output == 0 then
            Logger.error(COMPONENT_NAME, "Отсутствует channel_data.output для IP-монитора в потоке '%s'.", conf.name)
            return nil
        end

        local key = 1
        for index, output in ipairs(channel_data.output) do
            if output.config and output.config.monitor then
                key = index
                break
            end
        end

        local output_url = conf.output and conf.output[key]
        if not output_url then
            Logger.error(COMPONENT_NAME, "Отсутствует URL вывода для ключа %d в потоке '%s'.", key, conf.name)
            return nil
        end

        local split_result = string_split(output_url, "#")
        local addr = type(split_result) == "table" and split_result[1] or output_url
        local monitor_target = string_format("Output: IP (%s)", addr)

        Logger.info(COMPONENT_NAME, "Используется ключ вывода %d для IP-монитора в потоке '%s'.", key, conf.name)

        -- Для IP-монитора upstream должен быть получен из channel_data.output[key].tail
        local upstream = channel_data.output[key] and channel_data.output[key].tail
        return { upstream = upstream, monitor_target = monitor_target }
    end,
}

--- Таблица обработчиков форматов входных данных
local format_handlers = {
    dvb = function(config)
        local cfg = { format = config.format, addr = config.addr }
        local tuner = DvbRepository:find(config.addr)
        local status = tuner and tuner:get_full_status()
        cfg.stream = status and status.source or "dvb"
        return cfg
    end,
    udp = function(config)
        local cfg = { format = config.format }
        local localaddr = config.localaddr or ""
        if localaddr ~= "" then
            cfg.addr = localaddr .. "@" .. config.addr .. ":" .. config.port
        else
            cfg.addr = config.addr .. ":" .. config.port
        end
        cfg.stream = Utils.get_stream_name(config.addr) or "unknown_stream"
        return cfg
    end,
    rtp = function(config)
        local cfg = { format = config.format }
        local localaddr = config.localaddr or ""
        if localaddr ~= "" then
            cfg.addr = localaddr .. "@" .. config.addr .. ":" .. config.port
        else
            cfg.addr = config.addr .. ":" .. config.port
        end
        cfg.stream = Utils.get_stream_name(config.addr) or "unknown_stream"
        return cfg
    end,
    http = function(config)
        local cfg = { format = config.format }
        cfg.addr = config.host .. ":" .. config.port .. config.path
        cfg.stream = Utils.get_stream_name(config.host) or "unknown_stream"
        return cfg
    end,
    file = function(config)
        local cfg = {format = config.format, addr = config.filename, stream = "file"}
        return cfg
    end,
}

--- Вспомогательная функция для подготовки stream_json
--- @param ch_data table|nil Данные канала
--- @param monitor_url string|nil URL монитора для режима fallback
local function prepare_stream_json(ch_data, monitor_url)
    local stream_json = {}
    
    -- Если есть данные канала, формируем из них
    if ch_data and ch_data.input then
        for key, input in ipairs(ch_data.input) do
            local format = input.config.format or "Unknown"
            local handler = format_handlers[format]
            if handler then
                stream_json[key] = handler(input.config)
            else
                stream_json[key] = {format = format, addr = "Unknown", stream = "Unknown"}
            end
        end
    end

    -- Если данных канала нет, но есть URL монитора (режим analyze.lua)
    if #stream_json == 0 and monitor_url then
        local url_cfg = parse_url(monitor_url)
        if url_cfg then
            local format = url_cfg.format or "Unknown"
            local handler = format_handlers[format]
            if handler then
                stream_json[1] = handler(url_cfg)
            else
                stream_json[1] = {format = format, addr = monitor_url, stream = "analyze"}
            end
        end
    end

    -- Заглушка, если ничего не удалось определить
    if #stream_json == 0 then
        stream_json[1] = {format = "Unknown", addr = "Unknown", stream = "Unknown"}
    end

    return stream_json
end

--- Создает новый монитор канала
--- @param config table Конфигурация монитора
--- @return ChannelMonitor|nil Экземпляр монитора или nil
local function make_monitor(config)
    if ChannelRepository:count() >= (MonitorConfig.ChannelMonitorLimit or 50) then
        Logger.error(COMPONENT_NAME, "make_monitor: monitor limit reached")
        return nil
    end

    local name = config.name
    if not name then
        Logger.error(COMPONENT_NAME, "make_monitor: monitor name is required")
        return nil
    end

    if ChannelRepository:find(name) then
        Logger.error(COMPONENT_NAME, "make_monitor: Monitor '%s' already exists", name)
        return nil
    end

    if not Utils.validate_monitor_name(name) then
        Logger.error(COMPONENT_NAME, "make_monitor: Invalid monitor name '%s'", tostring(name))
        return nil
    end

    local ch_data = find_channel(name)
    local stream_json = prepare_stream_json(ch_data, config.monitor)

    local upstream = config.upstream
    local input_instance = nil

    if not upstream then
        local is_handled = false
        if ch_data then
            local monitor_type = (config.monitor_type and string_lower(config.monitor_type)) or MONITOR_TYPE_OUTPUT
            local handler = monitor_type_handlers[monitor_type]
            if handler then
                local handler_result = handler(config, ch_data)
                if handler_result then
                    upstream = handler_result.upstream
                    if not config.monitor then
                        config.monitor = handler_result.monitor_target
                    end
                    is_handled = true
                end
            end
        end

        -- Если upstream не задан и не был обработан хендлером (канал не найден или хендлер не сработал)
        if not is_handled and not upstream then
            local url_cfg = parse_url(config.monitor)
            if not url_cfg then
                Logger.error(COMPONENT_NAME, "make_monitor: invalid monitor address '%s'", tostring(config.monitor))
                return nil
            end
            url_cfg.name = name
            input_instance = init_input(url_cfg)
            if not input_instance then
                Logger.error(COMPONENT_NAME, "make_monitor: init_input failed")
                return nil
            end
            upstream = input_instance.tail
        end
    end

    config.name = name
    config.stream_json = stream_json
    config.upstream = upstream

    local monitor = ChannelMonitor.new(config, ch_data)
    if not monitor then
        if input_instance then kill_input(input_instance) end
        Logger.error(COMPONENT_NAME, "make_monitor: failed to create ChannelMonitor instance for '%s'", name)
        return nil
    end

    local monitor_instance = monitor:start()
    if monitor_instance then
        monitor:set_input_instance(input_instance)
        ChannelRepository:register(name, monitor)
        Logger.info(COMPONENT_NAME, "Monitor '%s' successfully started", name)
        return monitor_instance
    else
        if input_instance then kill_input(input_instance) end
        Logger.error(COMPONENT_NAME, "make_monitor: failed to start monitor for '%s'", name)
        return nil
    end
end

--- Останавливает монитор
--- @param name string Имя монитора
--- @param force boolean|nil Принудительная остановка
--- @return table|nil Конфигурация монитора для восстановления или nil
local function kill_monitor(name, force)
    local config = ChannelRepository:unregister(name, force)
    if config then
        Logger.info(COMPONENT_NAME, "Monitor '%s' successfully killed", name)
        return type(config) == "table" and config or nil
    end
    return nil
end

--- Создает поток и монитор для него
--- @param conf table Конфигурация потока
--- @return any|nil Данные канала или nil
local function make_stream(conf)
    local channel_data = make_channel(conf)
    if not channel_data then
        Logger.error(COMPONENT_NAME, "make_stream: make_channel failed for '%s'", tostring(conf.name))
        return nil
    end

    local monitor_type = (conf.monitor and conf.monitor.monitor_type and string_lower(conf.monitor.monitor_type)) or MONITOR_TYPE_OUTPUT

    local handler = monitor_type_handlers[monitor_type]
    if not handler then
        Logger.error(COMPONENT_NAME, "make_stream: unknown monitor type '%s' for stream '%s'", monitor_type, conf.name)
        kill_channel(channel_data)
        return nil
    end

    local handler_result = handler(conf, channel_data)
    if not handler_result then
        kill_channel(channel_data)
        return nil
    end

    local monitor_config = {
        name = conf.name,
        display_name = conf.monitor and conf.monitor.display_name or conf.name,
        upstream = handler_result.upstream,
        monitor = handler_result.monitor_target,
        rate = conf.monitor and conf.monitor.rate,
        time_check = conf.monitor and conf.monitor.time_check,
        analyze = conf.monitor and conf.monitor.analyze,
        method_comparison = conf.monitor and conf.monitor.method_comparison,
        cc_limit = conf.monitor and conf.monitor.cc_limit,
        bitrate_limit = conf.monitor and conf.monitor.bitrate_limit,
        rate_stat = conf.monitor and conf.monitor.rate_stat,
        join_pid = conf.monitor and conf.monitor.join_pid
    }

    if not make_monitor(monitor_config) then
        Logger.error(COMPONENT_NAME, "make_stream: make_monitor failed for '%s', killing channel", conf.name)
        kill_channel(channel_data)
        return nil
    end

    return channel_data
end

--- Останавливает поток и монитор
--- @param channel_data table|string Данные канала или имя
--- @return table|nil Конфигурация потока для восстановления или nil
local function kill_stream(channel_data)
    local ch_data = type(channel_data) == "table" and channel_data or find_channel(tostring(channel_data))
    if not ch_data or not ch_data.config then
        Logger.error(COMPONENT_NAME, "kill_stream: invalid channel_data or channel not found")
        return nil
    end
    local name = ch_data.config.name
    
    if not kill_monitor(name) then
        Logger.warn(COMPONENT_NAME, "kill_stream: monitor '%s' was not active or failed to kill", name)
    end

    kill_channel(ch_data)
    
    Logger.info(COMPONENT_NAME, "Stream and monitor '%s' successfully killed", name)
    return ch_data.config
end

--- Возвращает список всех активных мониторов
--- @return table<string, ChannelMonitor> Список мониторов
local function get_list_monitor()
    return ChannelRepository:get_all()
end

--- Находит экземпляр монитора по его имени
--- @param name string Имя монитора
--- @return ChannelMonitor|nil Экземпляр монитора или nil
local function find_monitor(name)
    return ChannelRepository:find(name)
end

--- Обновляет параметры
--- @param name string Имя монитора
--- @param params table Новые параметры
--- @return boolean Статус выполнения
local function update_monitor_parameters(name, params)
    local monitor = ChannelRepository:find(name)
    if monitor then
        return monitor:update_parameters(params)
    end
    Logger.error(COMPONENT_NAME, "update_monitor_parameters: monitor '%s' not found", tostring(name))
    return false
end

--- Приостанавливает монитор
--- @param name string Имя монитора
--- @return boolean Статус выполнения
local function pause_monitor(name)
    local monitor = ChannelRepository:find(name)
    if monitor then
        return monitor:pause()
    end
    return false
end

--- Возобновляет монитор
--- @param name string Имя монитора
--- @return boolean Статус выполнения
local function resume_monitor(name)
    local monitor = ChannelRepository:find(name)
    if monitor then
        return monitor:resume()
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
Channel.pause_monitor = pause_monitor
Channel.resume_monitor = resume_monitor

return Channel
