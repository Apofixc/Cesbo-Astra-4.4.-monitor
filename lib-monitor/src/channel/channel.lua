-- ===========================================================================
-- Модуль `channel.channel`
--
-- Высокоуровневый API для управления жизненным циклом каналов Astra
-- и их мониторингом. Обеспечивает автоматическую привязку мониторов к потокам.
-- ===========================================================================

-- 1. Стандартные Lua функции
local ipairs = _G.ipairs
local pcall = _G.pcall
local string_format = _G.string.format
local string_lower = _G.string.lower
local tostring = _G.tostring
local type = _G.type

-- 2. Функции из ModuleManager.get_module()
local ChannelMonitor = ModuleManager.get_module("channel_monitor")
local ChannelRepository = ModuleManager.get_module("channel_repository")
local DvbRepository = ModuleManager.get_module("dvb_repository")
local Logger = ModuleManager.get_module("logger")
local Utils = ModuleManager.get_module("utils")

-- 3. Глобальные зависимости Astra
local find_channel = ModuleManager.get_global_dependency("find_channel")
local init_input = ModuleManager.get_global_dependency("init_input")
local kill_channel = ModuleManager.get_global_dependency("kill_channel")
local kill_input = ModuleManager.get_global_dependency("kill_input")
local make_channel = ModuleManager.get_global_dependency("make_channel")
local parse_url = ModuleManager.get_global_dependency("parse_url")
local string_split = ModuleManager.get_global_dependency("string.split")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "Channel"

local MONITOR_TYPES = {
    INPUT = "input",
    OUTPUT = "output",
    IP = "ip"
}

--- Локальная конфигурация модуля (значения по умолчанию)
local _m_config = {
    ChannelMonitorLimit = 200,
}

-- 5. Внутреннее состояние (Private State)

--- @class ChannelState
--- @field restart_configs table<string, table[]> Хранилище конфигураций для перезапуска

-- ===========================================================================
-- Внутренние функции (Private/Protected)
-- ===========================================================================

--- Обработчики форматов сетевых адресов
--- @param config table Конфигурация входа
--- @return table Сформированные данные для stream_json
local function _network_format_handler(config)
    local cfg = { format = config.format }
    local localaddr = config.localaddr or ""
    local host = config.addr or config.host or "0.0.0.0"

    if localaddr ~= "" then
        cfg.addr = localaddr .. "@" .. host .. ":" .. (config.port or "0")
    else
        cfg.addr = host .. ":" .. (config.port or "0")
    end

    cfg.stream = Utils.get_stream_name(host) or "unknown_stream"
    return cfg
end

--- Таблица функций для обработки различных форматов входных данных
local _format_handlers = {
    dvb = function(config)
        local cfg = { format = config.format, addr = config.addr }
        local tuner = DvbRepository:find(config.addr)
        local status = tuner and tuner:get_status_table()
        cfg.stream = status and status.source or "dvb"
        return cfg
    end,
    udp = _network_format_handler,
    rtp = _network_format_handler,
    http = function(config)
        local cfg = { format = config.format }
        cfg.addr = (config.host or "localhost") .. ":" .. (config.port or "80") .. (config.path or "/")
        cfg.stream = Utils.get_stream_name(config.host) or "unknown_stream"
        return cfg
    end,
    file = function(config)
        return { format = config.format, addr = config.filename, stream = "file" }
    end,
}

--- Таблица обработчиков типов мониторов
local _monitor_type_handlers = {
    [MONITOR_TYPES.INPUT] = function(conf, channel_data)
        local input_data = channel_data.input and channel_data.input[1]
        if not input_data then
            Logger.error(COMPONENT_NAME, "Отсутствуют входные данные для типа 'input' в потоке '%s'.", conf.name)
            return nil
        end

        local upstream = input_data.input and input_data.input.tail
        local monitor_target = "Input: Unknown"

        if type(input_data.config) == "table" then
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

    [MONITOR_TYPES.OUTPUT] = function(conf, channel_data)
        return { upstream = channel_data.tail, monitor_target = "Output: Channel" }
    end,

    [MONITOR_TYPES.IP] = function(conf, channel_data)
        if type(channel_data.output) ~= "table" or #channel_data.output == 0 then
            Logger.error(COMPONENT_NAME, "Отсутствует channel_data.output для IP-монитора в '%s'.", conf.name)
            return nil
        end

        local key = 1
        for index, output in ipairs(channel_data.output) do
            local cfg = output.config
            if type(cfg) == "userdata" then
                local ok, opts = pcall(function(u) return u.__options end, cfg)
                if ok and type(opts) == "table" and opts.monitor then
                    key = index
                    break
                end
            elseif type(cfg) == "table" and cfg.monitor then
                key = index
                break
            end
        end

        local output_url = conf.output and conf.output[key]
        if not output_url then
            Logger.error(COMPONENT_NAME, "Отсутствует URL вывода для ключа %d в '%s'.", key, conf.name)
            return nil
        end

        local split_result = string_split(output_url, "#")
        local addr = type(split_result) == "table" and split_result[1] or output_url
        local monitor_target = string_format("Output: IP (%s)", addr)

        return {
            upstream = channel_data.output[key] and channel_data.output[key].tail,
            monitor_target = monitor_target
        }
    end,
}

--- Вспомогательная функция для подготовки stream_json
--- @param ch_data table|nil Данные канала Astra
--- @param monitor_url string|nil URL монитора для режима прямого анализа
--- @return table Список метаданных источников
local function _prepare_stream_json(ch_data, monitor_url)
    local stream_json = {}

    if ch_data and type(ch_data.input) == "table" then
        for key, input in ipairs(ch_data.input) do
            local config = type(input) == "table" and input.config
            local format = (type(config) == "table" and config.format) or "Unknown"
            local handler = _format_handlers[format]
            if handler then
                stream_json[key] = handler(config)
            else
                stream_json[key] = { format = format, addr = "Unknown", stream = "Unknown" }
            end
        end
    end

    if #stream_json == 0 and monitor_url then
        local url_cfg = parse_url(monitor_url)
        if url_cfg then
            local format = url_cfg.format or "Unknown"
            local handler = _format_handlers[format]
            if handler then
                stream_json[1] = handler(url_cfg)
            else
                stream_json[1] = { format = format, addr = monitor_url, stream = "analyze" }
            end
        end
    end

    if #stream_json == 0 then
        stream_json[1] = { format = "Unknown", addr = "Unknown", stream = "Unknown" }
    end

    return stream_json
end

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- @class Channel
local Channel = {}

--- Инициализирует подписку на обновление конфигурации
function Channel.init_config_subscription()
    local success, EventDispatcher = pcall(ModuleManager.get_module, "core.event_dispatcher")
    if success and EventDispatcher then
        local instance = EventDispatcher.get_instance()
        instance:subscribe("config:updated:monitor", function(new_config)
            if new_config.ChannelMonitorLimit then
                _m_config.ChannelMonitorLimit = new_config.ChannelMonitorLimit
                Logger.debug(COMPONENT_NAME, "Лимит мониторов каналов обновлен: %d", _m_config.ChannelMonitorLimit)
            end
        end)
    end
end

--- Создает новый монитор канала
--- @param config table Конфигурация монитора
--- @return any|nil Экземпляр монитора Astra или nil при ошибке
function Channel.make_monitor(config)
    local limit = _m_config.ChannelMonitorLimit

    if ChannelRepository:count() >= limit then
        Logger.error(COMPONENT_NAME, "make_monitor: лимит мониторов исчерпан (%d)", limit)
        return nil
    end

    local name = config.name
    if not name then
        Logger.error(COMPONENT_NAME, "make_monitor: имя монитора обязательно")
        return nil
    end

    if ChannelRepository:find(name) then
        Logger.error(COMPONENT_NAME, "make_monitor: монитор '%s' уже существует", name)
        return nil
    end

    if not Utils.validate_monitor_name(name) then
        Logger.error(COMPONENT_NAME, "make_monitor: некорректное имя монитора '%s'", tostring(name))
        return nil
    end

    local ch_data = find_channel(name)
    local stream_json = _prepare_stream_json(ch_data, config.monitor)

    local upstream = config.upstream
    local input_instance = nil

    if not upstream then
        local is_handled = false
        if ch_data then
            local monitor_type = (config.monitor_type and string_lower(config.monitor_type)) or MONITOR_TYPES.OUTPUT
            local handler = _monitor_type_handlers[monitor_type]
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

        if not is_handled and not upstream then
            local url_cfg = parse_url(config.monitor)
            if not url_cfg then
                Logger.error(COMPONENT_NAME, "make_monitor: некорректный адрес монитора '%s'", tostring(config.monitor))
                return nil
            end
            url_cfg.name = name
            input_instance = init_input(url_cfg)
            if not input_instance then
                Logger.error(COMPONENT_NAME, "make_monitor: ошибка init_input")
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
        Logger.error(COMPONENT_NAME, "make_monitor: ошибка создания ChannelMonitor для '%s'", name)
        return nil
    end

    local monitor_instance = monitor:start()
    if monitor_instance then
        monitor:set_input_instance(input_instance)
        ChannelRepository:register(name, monitor, ChannelMonitor)
        Logger.info(COMPONENT_NAME, "Монитор '%s' успешно запущен", name)
        return monitor_instance
    else
        if input_instance then kill_input(input_instance) end
        Logger.error(COMPONENT_NAME, "make_monitor: не удалось запустить монитор для '%s'", name)
        return nil
    end
end

--- Останавливает монитор и освобождает ресурсы
--- @param name string Имя монитора
--- @return table|nil Конфигурация монитора для восстановления или nil
function Channel.kill_monitor(name)
    local config = ChannelRepository:unregister(name)
    if config then
        Logger.info(COMPONENT_NAME, "Монитор '%s' успешно остановлен", name)
        return type(config) == "table" and config or nil
    end
    return nil
end

--- Создает поток Astra и привязывает к нему монитор
--- @param conf table Конфигурация потока
--- @return table|nil Данные канала Astra или nil при ошибке
function Channel.make_stream(conf)
    local channel_data = make_channel(conf)
    if not channel_data then
        Logger.error(COMPONENT_NAME, "make_stream: ошибка make_channel для '%s'", tostring(conf.name))
        return nil
    end

    local monitor_type = MONITOR_TYPES.OUTPUT
    if type(conf.monitor) == "table" and conf.monitor.monitor_type then
        monitor_type = string_lower(conf.monitor.monitor_type)
    end

    local handler = _monitor_type_handlers[monitor_type]
    if not handler then
        Logger.error(COMPONENT_NAME, "make_stream: неизвестный тип монитора '%s' в '%s'", monitor_type, conf.name)
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
        join_pid = conf.monitor and conf.monitor.join_pid
    }

    if not Channel.make_monitor(monitor_config) then
        Logger.error(COMPONENT_NAME, "make_stream: ошибка make_monitor для '%s', удаляем канал", conf.name)
        kill_channel(channel_data)
        return nil
    end

    return channel_data
end

--- Останавливает поток и связанный с ним монитор
--- @param channel_data table|string Данные канала Astra или его имя
--- @return table|nil Конфигурация потока для восстановления или nil
function Channel.kill_stream(channel_data)
    local ch_data = type(channel_data) == "table" and channel_data or find_channel(tostring(channel_data))
    if not ch_data or type(ch_data) ~= "table" or not ch_data.config then
        Logger.error(COMPONENT_NAME, "kill_stream: некорректные данные канала или канал не найден")
        return nil
    end

    local name = ch_data.config.name
    if not Channel.kill_monitor(name) then
        Logger.warning(COMPONENT_NAME, "kill_stream: монитор '%s' не был активен", name)
    end

    kill_channel(ch_data)
    Logger.info(COMPONENT_NAME, "Поток и монитор '%s' успешно остановлены", name)

    return ch_data.config
end

--- Возвращает список всех активных мониторов
--- @return table<string, ChannelMonitor> Список мониторов
function Channel.get_list_monitor()
    return ChannelRepository:get_all()
end

--- Находит экземпляр монитора по его имени
--- @param name string Имя монитора
--- @return ChannelMonitor|nil Экземпляр монитора или nil
function Channel.find_monitor(name)
    return ChannelRepository:find(name)
end

--- Обновляет параметры работающего монитора
--- @param name string Имя монитора
--- @param params table Новые параметры
--- @return boolean Статус выполнения
function Channel.update_monitor_parameters(name, params)
    local monitor = ChannelRepository:find(name)
    if monitor then
        return monitor:update_parameters(params)
    end
    Logger.error(COMPONENT_NAME, "update_monitor_parameters: монитор '%s' не найден", tostring(name))
    return false
end

--- Приостанавливает анализ для монитора
--- @param name string Имя монитора
--- @return boolean Статус выполнения
function Channel.pause_monitor(name)
    local monitor = ChannelRepository:find(name)
    if monitor then
        monitor:pause()
        return true
    end
    return false
end

--- Возобновляет анализ для монитора
--- @param name string Имя монитора
--- @return boolean Статус выполнения
function Channel.resume_monitor(name)
    local monitor = ChannelRepository:find(name)
    if monitor then
        return monitor:resume()
    end
    return false
end

-- ===========================================================================
-- Инициализация модуля
-- ===========================================================================

return Channel
