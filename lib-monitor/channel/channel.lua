-- ===========================================================================
-- Модуль `channel.channel`
--
-- Этот модуль предназначен для управления каналами и их мониторингом в системе Astra.
-- Он предоставляет функции для создания, обновления, поиска и удаления каналов,
-- а также для управления связанными с ними мониторами.
--
-- Основные функции включают:
-- - Получение списка всех активных мониторов каналов.
-- - Обновление параметров существующего монитора канала.
-- - Создание и регистрация нового монитора канала.
-- - Поиск монитора канала по имени.
-- - Остановка и удаление монитора канала.
-- - Создание и запуск потока с мониторингом.
-- - Остановка потока и связанного с ним монитора.
-- ===========================================================================

-- Стандартные функции Lua
local type = type
local tostring = tostring
local ipairs = ipairs
local math_max = math.max
local string_lower = string.lower
local table_insert = table_insert

-- Локальные модули
local Logger = require "utils.logger"
local log_info = Logger.info
local log_error = Logger.error

local COMPONENT_NAME = "Channel" -- Имя компонента для логирования

-- Глобальные функции Astra (предполагается, что они доступны в глобальной области видимости)
local table_copy = table.copy
local string_split = string.split
local check = check
local find_channel = find_channel -- Предполагаем, что find_channel является глобальной функцией
local make_channel = make_channel -- Предполагаем, что make_channel является глобальной функцией
local kill_channel = kill_channel -- Предполагаем, что kill_channel является глобальной функцией
local get_stream = get_stream     -- Предполагаем, что get_stream является глобальной функцией

-- Модули мониторинга
local ChannelMonitor = require "channel.channel_monitor"
local ChannelMonitorManager = require "dispatcher.channel_monitor_manager"
local find_dvb_conf = require "adapters.adapter".find_dvb_conf
-- parse_url и init_input теперь используются внутри MonitorManager, поэтому их можно удалить отсюда
-- local parse_url = parse_url
-- local init_input = init_input

-- ===========================================================================
-- Константы и конфигурация
-- ===========================================================================

local MonitorConfig = require "config.monitor_config"

-- Константы для валидации параметров монитора
local MONITOR_LIMIT = MonitorConfig.MonitorLimit
local MIN_RATE = MonitorConfig.MinRate
local MAX_RATE = MonitorConfig.MaxRate
local MIN_TIME_CHECK = MonitorConfig.MinTimeCheck
local MAX_TIME_CHECK = MonitorConfig.MaxTimeCheck
local MIN_METHOD_COMPARISON = MonitorConfig.MinMethodComparison
local MAX_METHOD_COMPARISON = MonitorConfig.MaxMethodComparison

-- Константы для типов мониторов
local MONITOR_TYPE_INPUT = "input"
local MONITOR_TYPE_OUTPUT = "output"
local MONITOR_TYPE_IP = "ip"

-- ===========================================================================
-- Основные функции модуля
-- ===========================================================================

local channel_monitor_manager = ChannelMonitorManager:new()

--- Возвращает список всех активных мониторов каналов.
-- Эта функция запрашивает у `ChannelMonitorManager` список всех зарегистрированных
-- и активных мониторов каналов.
-- @return table monitor_list Таблица со списком активных мониторов.
function get_list_monitor()
    return channel_monitor_manager:get_all_monitors()
end

--- Обновляет параметры существующего монитора канала.
-- Обновляет параметры существующего монитора канала, идентифицируемого по имени.
-- @param string name Имя монитора, который нужно обновить.
-- @param table params Таблица с новыми параметрами. Поддерживаемые параметры:
--   - rate (number, optional): Новое значение погрешности сравнения битрейта (от 0.001 до 0.3).
--   - time_check (number, optional): Новый интервал проверки данных (от 0 до 300).
--   - analyze (boolean, optional): Включить/отключить расширенную информацию об ошибках потока.
--   - method_comparison (number, optional): Новый метод сравнения состояния потока (от 1 до 4).
-- @return boolean true, если параметры успешно обновлены, иначе `false`.
function update_monitor_parameters(name, params)
    if not name or type(name) ~= 'string' then
        log_error(COMPONENT_NAME, "Invalid name: expected string, got " .. type(name) .. ".")
        return false
    end
    if not params or type(params) ~= 'table' then
        log_error(COMPONENT_NAME, "Invalid parameters for '" .. name .. "': expected table, got " .. type(params) .. ".")
        return false
    end

    -- Делегируем обновление параметров менеджеру каналов
    local success = channel_monitor_manager:update_monitor_parameters(name, params)
    if success then
        log_info(COMPONENT_NAME, "Parameters updated successfully for monitor: %s", name)
    else
        log_error(COMPONENT_NAME, "Failed to update parameters for monitor: %s", name)
    end
    return success
end

local format_handlers = {
    dvb = function(config)
        local cfg = {format = config.format, addr = config.addr}
        local adap_conf = find_dvb_conf(config.addr)
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

--- Создает JSON-представление потока на основе данных канала.
-- Эта функция обрабатывает входные данные канала и формирует соответствующий
-- JSON-объект, описывающий поток.
-- @param table ch_data Таблица с данными канала, содержащая информацию о входах.
-- @return table stream_json Таблица, представляющая JSON-объект потока, или пустая таблица в случае ошибки.
local function create_stream_json(ch_data)
    local stream_json = {}
    if ch_data and type(ch_data) == "table" then
        for key, input in ipairs(ch_data.input) do
            local cfg = {}
            local handler = format_handlers[input.config.format]
            if handler then
                cfg = handler(input.config)
            else
                log_error(COMPONENT_NAME, "Unknown or unsupported stream format: %s for entry %d. Cannot create stream JSON. Returning empty table.", tostring(format), key)
                return {} -- Возвращаем пустую таблицу, так как канал не может быть создан
            end
            table_insert(stream_json, cfg)
        end
    else
        table_insert(stream_json, {format = "Unknown", addr = "Unknown", stream = "Unknown"})
    end
    return stream_json
end

--- Создает и регистрирует новый монитор канала.
-- Эта функция подготавливает конфигурацию и данные канала, а затем делегирует
-- создание и регистрацию монитора `ChannelMonitorManager`.
-- @param table config Таблица конфигурации для нового монитора.
--   - name (string): Имя монитора.
--   - monitor (string): Адрес мониторинга.
--   - upstream (userdata, optional): Экземпляр upstream, если уже инициализирован.
--   - rate (number, optional): Погрешность сравнения битрейта.
--   - time_check (number, optional): Интервал проверки данных.
--   - analyze (boolean, optional): Включить/отключить расширенную информацию об ошибках.
--   - method_comparison (number, optional): Метод сравнения состояния потока.
-- @param table channel_data (optional) Таблица с данными канала или его имя (string).
-- @return userdata monitor Экземпляр монитора, если успешно создан, иначе `false`.
function make_monitor(config, channel_data)
    local ch_data = type(channel_data) == "table" and channel_data or find_channel(tostring(channel_data))

    if not check(type(config) == 'table', "[make_monitor] Invalid config table.") then
        log_error(COMPONENT_NAME, "Invalid config table.")
        return false
    end
    if not check(config.name and type(config.name) == 'string', "[make_monitor] config.name required") then
        log_error(COMPONENT_NAME, "config.name is required and must be a string.")
        return false
    end
    if not check(config.monitor and type(config.monitor) == 'string', "[make_monitor] config.monitor required") then
        log_error(COMPONENT_NAME, "config.monitor is required and must be a string.")
        return false
    end
    
    config.stream_json = create_stream_json(ch_data)

    -- Делегируем создание и регистрацию монитора ChannelMonitorManager
    return channel_monitor_manager:create_and_register_channel_monitor(config, ch_data)
end

--- Находит монитор по его имени.
-- Ищет зарегистрированный монитор канала по его имени.
-- @param string name Имя монитора для поиска.
-- @return table monitor_data Таблица с данными монитора, если найден, иначе `nil`.
function find_monitor(name)
    return channel_monitor_manager:get_monitor(name)
end

--- Останавливает и удаляет монитор.
-- Останавливает работу указанного монитора и удаляет его из `ChannelMonitorManager`.
-- @param table monitor_obj Объект монитора, который нужно остановить.
-- @return table config Копия конфигурации остановленного монитора, если успешно, иначе `false`.
function kill_monitor(monitor_obj)
    if not monitor_obj then
        log_error(COMPONENT_NAME, "Attempted to kill a nil monitor object.")
        return false
    end

    local config = table_copy(monitor_obj.config)
    channel_monitor_manager:remove_monitor(monitor_obj.name)

    log_info(COMPONENT_NAME, "Monitor '%s' killed successfully.", monitor_obj.name)
    return config
end

--- Таблица обработчиков для определения upstream и monitor_target по типу монитора.
-- Эти обработчики используются функцией `make_stream` для определения
-- источника (`upstream`) и цели мониторинга (`monitor_target`) в зависимости от
-- типа монитора (input, output, ip).
local monitor_type_handlers = {
    [MONITOR_TYPE_INPUT] = function(conf, channel_data)
        local input_data = channel_data.input[1]
        if not input_data then
            log_error(COMPONENT_NAME, "Input data is missing for input monitor type in stream '%s'.", conf.name)
            return nil, nil
        end
        local upstream = input_data.input.tail
        local split_result = string_split(conf.input[1], "#")
        local monitor_target = type(split_result) == 'table' and split_result[1] or conf.input[1]
        return upstream, monitor_target
    end,
    [MONITOR_TYPE_OUTPUT] = function(conf, channel_data)
        local upstream = channel_data.tail
        local monitor_target = MONITOR_TYPE_OUTPUT
        return upstream, monitor_target
    end,
    [MONITOR_TYPE_IP] = function(conf, channel_data)
        if not channel_data.output or #channel_data.output == 0 then
            log_error(COMPONENT_NAME, "channel_data.output is missing for ip monitor in stream '%s'.", conf.name)
            return nil, nil
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
        
        log_info(COMPONENT_NAME, "Using output key %d for IP monitor in stream '%s'.", key, conf.name)
        return nil, monitor_target -- upstream не используется для IP-монитора
    end,
}

--- Создает и запускает поток с мониторингом.
-- Эта функция создает канал с помощью `make_channel`, затем определяет тип монитора
-- (input, output, ip) и соответствующие `upstream` и `monitor_target`.
-- После этого она создает и регистрирует монитор канала через `ChannelMonitorManager`.
-- @param table conf Таблица конфигурации потока, содержащая:
--   - name (string): Имя потока.
--   - input (table): Конфигурация входных данных.
--   - output (table): Конфигурация выходных данных.
--   - monitor (table, optional): Конфигурация монитора, содержащая:
--     - name (string, optional): Имя монитора (по умолчанию совпадает с именем потока).
--     - monitor_type (string, optional): Тип монитора ("input", "output", "ip", по умолчанию "output").
--     - rate (number, optional): Погрешность сравнения битрейта.
--     - time_check (number, optional): Время до сравнения данных.
--     - analyze (boolean, optional): Включить/отключить расширенную информацию об ошибках.
--     - method_comparison (number, optional): Метод сравнения состояния потока.
-- @return userdata monitor Экземпляр монитора, если успешно создан, иначе `false`.
function make_stream(conf)  
    local channel_data = make_channel(conf)
    if not channel_data then 
        log_error(COMPONENT_NAME, "Failed to create channel data for stream '%s'.", (conf.name or "unknown"))
        return false
    end

    local monitor_name = (conf.monitor and type(conf.monitor) == 'table' and type(conf.monitor.name) == "string" and conf.monitor.name) or conf.name
    local monitor_type = (conf.monitor and type(conf.monitor) == 'table' and type(conf.monitor.monitor_type) == "string" and string_lower(conf.monitor.monitor_type)) or MONITOR_TYPE_OUTPUT

    local upstream, monitor_target
    local handler = monitor_type_handlers[monitor_type]
    if handler then
        upstream, monitor_target = handler(conf, channel_data)
    else
        log_error(COMPONENT_NAME, "Invalid monitor_type: '%s' for stream '%s'.", tostring(monitor_type), conf.name)
        return false
    end

    if not monitor_target then
        log_error(COMPONENT_NAME, "Failed to determine monitor target for stream '%s'.", conf.name)
        return false
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

    log_info(COMPONENT_NAME, "Attempting to create monitor for stream '%s'.", conf.name)
    -- Делегируем создание и регистрацию монитора ChannelMonitorManager
    return channel_monitor_manager:create_and_register_channel_monitor(monitor_config, channel_data)
end

--- Останавливает поток и связанный с ним монитор.
-- Эта функция останавливает работу канала с помощью `kill_channel` и, если
-- существует связанный монитор, останавливает и удаляет его через `kill_monitor`.
-- @param table channel_data Таблица с данными канала, который нужно остановить.
-- @return table config Копия конфигурации остановленного канала, если успешно, иначе `nil`.
function kill_stream(channel_data)
    if not channel_data or not channel_data.config or not channel_data.config.name then 
        log_error(COMPONENT_NAME, "Invalid channel_data or config provided to kill_stream.")
        return nil 
    end

    local monitor_name = channel_data.config.name
    local monitor_data = find_monitor(monitor_name)

    if monitor_data then
        kill_monitor(monitor_data)
        log_info(COMPONENT_NAME, "Monitor '%s' was killed as part of stream shutdown.", monitor_name)
    else
        log_info(COMPONENT_NAME, "No monitor found for stream '%s'.", monitor_name)
    end

    local config = table_copy(channel_data.config)
    kill_channel(channel_data)

    log_info(COMPONENT_NAME, "Stream '%s' shutdown successfully.", config.name)

    return config
end
