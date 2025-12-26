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
local type         = type
local tostring     = tostring
local ipairs       = ipairs
local math_max     = math.max
local string_lower = string.lower
local table_insert = table.insert

-- Локальные модули
local Logger = require "src.utils.logger"
local log_info  = Logger.info
local log_error = Logger.error
local log_debug = Logger.debug

local COMPONENT_NAME = "Channel"

local Utils = require "src.utils.utils"
local shallow_table_copy   = Utils.shallow_table_copy
local AstraAPI = require "src.api.astra_api"

local string_split = AstraAPI.string_split
local find_channel = AstraAPI.find_channel
local make_channel = AstraAPI.make_channel
local kill_channel = AstraAPI.kill_channel
local get_stream   = Utils.get_stream

-- Модули мониторинга
local ChannelMonitor = require "src.channel.channel_monitor"
local ChannelMonitorDispatcher = require "src.dispatchers.channel_monitor_dispatcher"
local Adapter = require "src.adapters.adapter"

-- ===========================================================================
-- Константы и конфигурация
-- ===========================================================================

local MonitorConfig = require "src.config.monitor_config"

-- Константы для типов мониторов
local MONITOR_TYPE_INPUT  = "input"
local MONITOR_TYPE_OUTPUT = "output"
local MONITOR_TYPE_IP     = "ip"

-- ===========================================================================
-- Основные функции модуля
-- ===========================================================================

local channel_monitor_manager = ChannelMonitorDispatcher:new()

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
        local error_msg = "Invalid name: expected string, got " .. type(name) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if not params or type(params) ~= 'table' then
        local error_msg = "Invalid parameters for '" .. name .. "': expected table, got " .. type(params) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    -- Делегируем обновление параметров менеджеру каналов
    local success, err = channel_monitor_manager:update_monitor_parameters(name, params)
    if success then
        log_info(COMPONENT_NAME, "Parameters updated successfully for monitor: %s", name)
    else
        log_error(COMPONENT_NAME, "Failed to update parameters for monitor: %s. Error: %s", name, err or "unknown error")
    end
    return success, err
end

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

--- Создает JSON-представление потока на основе данных канала.
-- Эта функция обрабатывает входные данные канала и формирует соответствующий
-- JSON-объект, описывающий поток.
-- @param table channel_data_obj Таблица с данными канала, содержащая информацию о входах.
-- @return table stream_json_list Таблица, представляющая JSON-объект потока, или `nil` и сообщение об ошибке в случае ошибки.
local function create_stream_json_representation(channel_data_obj)
    local stream_json_list = {}
    if channel_data_obj and type(channel_data_obj) == "table" then
        for key, input_entry in ipairs(channel_data_obj.input) do
            local config_entry = {}
            local handler = format_handlers[input_entry.config.format]
            if handler then
                config_entry = handler(input_entry.config)
            else
                local error_msg = "Unknown or unsupported stream format: " .. tostring(input_entry.config.format) .. " for entry " .. key .. ". Cannot create stream JSON."
                log_error(COMPONENT_NAME, error_msg)
                return nil, error_msg
            end
            table_insert(stream_json_list, config_entry)
        end
    else
        local error_msg = "Invalid channel data provided. Expected table, got " .. type(channel_data_obj) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    return stream_json_list, nil
end

--- Создает и регистрирует новый монитор канала.
-- Эта функция подготавливает конфигурацию и данные канала, а затем делегирует
-- создание и регистрацию монитора `ChannelMonitorManager`.
-- @param table monitor_config_table Таблица конфигурации для нового монитора.
--   - name (string): Имя монитора.
--   - monitor (string): Адрес мониторинга.
--   - upstream (userdata, optional): Экземпляр upstream, если уже инициализирован.
--   - rate (number, optional): Погрешность сравнения битрейта.
--   - time_check (number, optional): Интервал проверки данных.
--   - analyze (boolean, optional): Включить/отключить расширенную информацию об ошибках.
--   - method_comparison (number, optional): Метод сравнения состояния потока.
-- @param table channel_data_obj (optional) Таблица с данными канала или его имя (string).
-- @return userdata monitor Экземпляр монитора, если успешно создан, иначе `nil` и сообщение об ошибке.
function make_monitor(monitor_config_table, channel_data_obj)
    local ch_data = type(channel_data_obj) == "table" and channel_data_obj or find_channel(tostring(channel_data_obj))

    if not (type(monitor_config_table) == 'table') then
        local error_msg = "Invalid config table. Expected table, got " .. type(monitor_config_table) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if not (monitor_config_table.name and type(monitor_config_table.name) == 'string') then
        local error_msg = "config.name is required and must be a string."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if not (monitor_config_table.monitor and type(monitor_config_table.monitor) == 'string') then
        local error_msg = "config.monitor is required and must be a string."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    
    local stream_json, err = create_stream_json_representation(ch_data)
    if err then
        log_error(COMPONENT_NAME, "Failed to create stream JSON: %s", err)
        return nil, err
    end
    monitor_config_table.stream_json = stream_json

    -- Делегируем создание и регистрацию монитора ChannelMonitorManager
    return channel_monitor_manager:create_and_register_channel_monitor(monitor_config_table, ch_data)
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
        local error_msg = "Attempted to kill a nil monitor object."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local config = shallow_table_copy(monitor_obj.config)
    local success, err = channel_monitor_manager:remove_monitor(monitor_obj.name)

    if success then
        log_info(COMPONENT_NAME, "Monitor '%s' killed successfully.", monitor_obj.name)
    else
        log_error(COMPONENT_NAME, "Failed to remove monitor '%s'. Error: %s", monitor_obj.name, err or "unknown error")
        return nil, err or "Failed to remove monitor"
    end
    return config, nil
end

--- Таблица обработчиков для определения upstream и monitor_target по типу монитора.
-- Эти обработчики используются функцией `make_stream` для определения
-- источника (`upstream`) и цели мониторинга (`monitor_target`) в зависимости от
-- типа монитора (input, output, ip).
local monitor_type_handlers = {
    [MONITOR_TYPE_INPUT] = function(conf, channel_data)
        local input_data = channel_data.input[1]
        if not input_data then
            local error_msg = "Input data is missing for input monitor type in stream '" .. conf.name .. "'."
            log_error(COMPONENT_NAME, error_msg)
            return nil, nil, error_msg
        end
        local upstream = input_data.input.tail
        local split_result = string_split(conf.input[1], "#")
        local monitor_target = type(split_result) == 'table' and split_result[1] or conf.input[1]
        return upstream, monitor_target, nil
    end,
    [MONITOR_TYPE_OUTPUT] = function(conf, channel_data)
        local upstream = channel_data.tail
        local monitor_target = MONITOR_TYPE_OUTPUT
        return upstream, monitor_target, nil
    end,
    [MONITOR_TYPE_IP] = function(conf, channel_data)
        if not channel_data.output or #channel_data.output == 0 then
            local error_msg = "channel_data.output is missing for ip monitor in stream '" .. conf.name .. "'."
            log_error(COMPONENT_NAME, error_msg)
            return nil, nil, error_msg
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
        return nil, monitor_target, nil -- upstream не используется для IP-монитора
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
-- @return userdata monitor Экземпляр монитора, если успешно создан, иначе `nil` и сообщение об ошибке.
function make_stream(conf)
    local channel_data, err_channel = make_channel(conf)
    if not channel_data then 
        local error_msg = "Failed to create channel data for stream '" .. (conf.name or "unknown") .. "'. Error: " .. (err_channel or "unknown")
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local monitor_name = (conf.monitor and type(conf.monitor) == 'table' and type(conf.monitor.name) == "string" and conf.monitor.name) or conf.name
    local monitor_type = (conf.monitor and type(conf.monitor) == "table" and type(conf.monitor.monitor_type) == "string" and string_lower(conf.monitor.monitor_type)) or MONITOR_TYPE_OUTPUT

    local upstream, monitor_target, handler_err
    local handler = monitor_type_handlers[monitor_type]
    if handler then
        upstream, monitor_target, handler_err = handler(conf, channel_data)
    else
        local error_msg = "Invalid monitor_type: '" .. tostring(monitor_type) .. "' for stream '" .. conf.name .. "'."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    if handler_err then
        log_error(COMPONENT_NAME, "Error from monitor type handler for stream '%s': %s", conf.name, handler_err)
        return nil, handler_err
    end

    if not monitor_target then
        local error_msg = "Failed to determine monitor target for stream '" .. conf.name .. "'."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
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

    local stream_json, err = create_stream_json_representation(channel_data)
    if err then
        log_error(COMPONENT_NAME, "Failed to create stream JSON: %s", err)
        return nil, err
    end
    monitor_config.stream_json = stream_json

    log_info(COMPONENT_NAME, "Attempting to create monitor for stream '%s'.", conf.name)
    -- Делегируем создание и регистрацию монитора ChannelMonitorManager
    return channel_monitor_manager:create_and_register_channel_monitor(monitor_config, channel_data)
end

--- Останавливает поток и связанный с ним монитор.
-- Эта функция останавливает работу канала с помощью `kill_channel` и, если
-- существует связанный монитор, останавливает и удаляет его через `kill_monitor`.
-- @param table channel_data Таблица с данными канала, который нужно остановить.
-- @return table config Копия конфигурации остановленного канала, если успешно, иначе `nil` и сообщение об ошибке.
function kill_stream(channel_data)
    if not channel_data or not channel_data.config or not channel_data.config.name then 
        local error_msg = "Invalid channel_data or config provided to kill_stream."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local monitor_name = channel_data.config.name
    local monitor_data = find_monitor(monitor_name)

    if monitor_data then
        local success, err = kill_monitor(monitor_data)
        if success then
            log_info(COMPONENT_NAME, "Monitor '%s' was killed as part of stream shutdown.", monitor_name)
        else
            log_error(COMPONENT_NAME, "Failed to kill monitor '%s' as part of stream shutdown. Error: %s", monitor_name, err or "unknown error")
            return nil, err or "Failed to kill monitor during stream shutdown"
        end
    else
        log_info(COMPONENT_NAME, "No monitor found for stream '%s'.", monitor_name)
    end

    local config = shallow_table_copy(channel_data.config)
    kill_channel(channel_data) -- Предполагаем, что kill_channel всегда успешен или обрабатывает свои ошибки

    log_info(COMPONENT_NAME, "Stream '%s' shutdown successfully.", config.name)

    return config, nil
end
