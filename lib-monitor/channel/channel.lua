-- ===========================================================================
-- Кэширование локальных функций для производительности
-- ===========================================================================

local type = type
local tostring = tostring
local tonumber = tonumber
local ipairs = ipairs
local math_max = math_max
local math_min = math.min
local string_lower = string.lower
local table_insert = table_insert
local table_remove = table_remove
local json_encode = json.encode

local Logger = require "utils.logger"
local log_info = Logger.info
local log_error = Logger.error

local COMPONENT_NAME = "Channel"

local table_copy = table.copy
local string_split = string.split
local check = check

local ChannelMonitor = require "channel.channel_monitor"
local MonitorManager = require "monitor_manager"

-- ===========================================================================
-- Константы и конфигурация
-- ===========================================================================

local MONITOR_LIMIT = 50

-- Константы для валидации параметров монитора
local MIN_RATE = 0.001
local MAX_RATE = 0.3
local MIN_TIME_CHECK = 0
local MAX_TIME_CHECK = 300
local MIN_METHOD_COMPARISON = 1
local MAX_METHOD_COMPARISON = 4

-- Константы для типов мониторов
local MONITOR_TYPE_INPUT = "input"
local MONITOR_TYPE_OUTPUT = "output"
local MONITOR_TYPE_IP = "ip"

-- ===========================================================================
-- Основные функции модуля
-- ===========================================================================

local monitor_manager = MonitorManager:new()

--- Возвращает список всех активных мониторов.
-- @return table monitor_list Таблица со списком активных мониторов.
function get_list_monitor()
    return monitor_manager:get_all_monitors()
end

--- Обновляет параметры существующего монитора канала.
-- @param string name Имя монитора, который нужно обновить.
-- @param table params Таблица с новыми параметрами. Поддерживаемые параметры:
--   - rate (number, optional): Новое значение погрешности сравнения битрейта (от 0.001 до 0.3).
--   - time_check (number, optional): Новый интервал проверки данных (от 0 до 300).
--   - analyze (boolean, optional): Включить/отключить расширенную информацию об ошибках потока.
--   - method_comparison (number, optional): Новый метод сравнения состояния потока (от 1 до 4).
-- @return boolean true, если параметры успешно обновлены, иначе false.
function update_monitor_parameters(name, params)
    if not name or type(name) ~= 'string' then
        log_error(COMPONENT_NAME, "Invalid name: expected string, got " .. type(name) .. ".")
        return false
    end
    if not params or type(params) ~= 'table' then
        log_error(COMPONENT_NAME, "Invalid parameters for '" .. name .. "': expected table, got " .. type(params) .. ".")
        return false
    end

    -- Находим монитор по имени
    local monitor_data = find_monitor(name)
    if not monitor_data then
        log_error(COMPONENT_NAME, "Monitor not found for name: " .. tostring(name))
        return false
    end

    -- Обновляем только переданные параметры с валидацией
    if params.rate ~= nil and check(type(params.rate) == 'number' and params.rate >= MIN_RATE and params.rate <= MAX_RATE, "params.rate must be between " .. tostring(MIN_RATE) .. " and " .. tostring(MAX_RATE)) then
        monitor_data.instance.rate = params.rate
    end
    if params.time_check ~= nil and check(type(params.time_check) == 'number' and params.time_check >= MIN_TIME_CHECK and params.time_check <= MAX_TIME_CHECK, "params.time_check must be between " .. tostring(MIN_TIME_CHECK) .. " and " .. tostring(MAX_TIME_CHECK)) then
        monitor_data.instance.time_check = params.time_check
    end
    if params.analyze ~= nil and check(type(params.analyze) == 'boolean', "params.analyze must be boolean") then
        monitor_data.instance.analyze = params.analyze
    end
    if params.method_comparison ~= nil and check(type(params.method_comparison) == 'number' and params.method_comparison >= MIN_METHOD_COMPARISON and params.method_comparison <= MAX_METHOD_COMPARISON, "params.method_comparison must be between " .. tostring(MIN_METHOD_COMPARISON) .. " and " .. tostring(MAX_METHOD_COMPARISON)) then
        monitor_data.instance.method_comparison = params.method_comparison
    end

    log_info(COMPONENT_NAME, "Parameters updated successfully for monitor: " .. name)

    return true
end

--- Создает новый монитор канала.
-- @param table config Таблица конфигурации для нового монитора.
-- @param table channel_data (optional) Таблица с данными канала или его имя (string).
-- @return userdata monitor Экземпляр монитора, если успешно создан, иначе false.
function make_monitor(config, channel_data)
    if #monitor_manager:get_all_monitors() > MONITOR_LIMIT then 
        log_error(COMPONENT_NAME, "Monitor list overflow. Cannot create more than " .. MONITOR_LIMIT .. " monitors.")
        return false
    end

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
    
    local monitor = ChannelMonitor:new(config, ch_data)
    local instance = monitor:start()

    if instance then
        monitor_manager:add_monitor(monitor.name, monitor)
        log_info(COMPONENT_NAME, "Channel monitor '" .. monitor.name .. "' created and added successfully.")
        return instance
    else
        log_error(COMPONENT_NAME, "ChannelMonitor:start returned nil for monitor '" .. (config.name or "unknown") .. "'.")
        return false        
    end
end

--- Находит монитор по его имени.
-- @param string name Имя монитора для поиска.
-- @return table monitor_data Таблица с данными монитора, если найден, иначе nil.
function find_monitor(name)
    return monitor_manager:get_monitor(name)
end

--- Останавливает и удаляет монитор.
-- @param table monitor_obj Объект монитора, который нужно остановить.
-- @return table config Копия конфигурации остановленного монитора, если успешно, иначе false.
function kill_monitor(monitor_obj)
    if not monitor_obj then
        log_error(COMPONENT_NAME, "Attempted to kill a nil monitor object.")
        return false
    end

    local config = table_copy(monitor_obj.config)
    monitor_manager:remove_monitor(monitor_obj.name)

    -- collectgarbage("collect") -- Пересмотрено: принудительная сборка мусора может негативно сказаться на производительности.

    log_info(COMPONENT_NAME, "Monitor '" .. monitor_obj.name .. "' killed successfully.")
    return config
end

--- Создает и запускает поток с мониторингом.
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
-- @return userdata monitor Экземпляр монитора, если успешно создан, иначе false.
function make_stream(conf)  
    local channel_data = make_channel(conf)
    if not channel_data then 
        log_error(COMPONENT_NAME, "Failed to create channel data for stream '" .. (conf.name or "unknown") .. "'.")
        return false
    end

    if not check(type(conf) == 'table', "[make_stream] Invalid conf table.") then
        log_error(COMPONENT_NAME, "Invalid conf table.")
        return false
    end
    if not check(conf.name and type(conf.name) == 'string', "[make_stream] conf.name is required and must be a string.") then
        log_error(COMPONENT_NAME, "conf.name is required and must be a string.")
        return false
    end
    if not check(conf.input and type(conf.input) == 'table', "[make_stream] conf.input is required and must be a table.") then
        log_error(COMPONENT_NAME, "conf.input is required and must be a table.")
        return false
    end
    if not check(conf.output and type(conf.output) == 'table', "[make_stream] conf.output is required and must be a table.") then
        log_error(COMPONENT_NAME, "conf.output is required and must be a table.")
        return false
    end

    local monitor_name = (conf.monitor and type(conf.monitor) == 'table' and type(conf.monitor.name) == "string" and conf.monitor.name) or conf.name
    local monitor_type = (conf.monitor and type(conf.monitor) == 'table' and type(conf.monitor.monitor_type) == "string" and string_lower(conf.monitor.monitor_type)) or MONITOR_TYPE_OUTPUT

    local upstream, monitor_target
    if monitor_type == MONITOR_TYPE_INPUT then
        local input_data = channel_data.input[1]
        if not input_data then
            log_error(COMPONENT_NAME, "Input data is missing for input monitor type in stream '" .. conf.name .. "'.")
            return false
        end
        upstream = input_data.input.tail

        local split_result = string_split(conf.input[1], "#")
        monitor_target = type(split_result) == 'table' and split_result[1] or conf.input[1]
    elseif monitor_type == MONITOR_TYPE_OUTPUT then
        upstream = channel_data.tail
        monitor_target = MONITOR_TYPE_OUTPUT
    elseif monitor_type == MONITOR_TYPE_IP then
        if not channel_data.output or #channel_data.output == 0 then
            log_error(COMPONENT_NAME, "channel_data.output is missing for ip monitor in stream '" .. conf.name .. "'.")
            return false
        end

        local key = 1
        for index, output in ipairs(channel_data.output) do
            if output.config and output.config.monitor then
                key = index
                break
            end
        end

        local split_result = string_split(conf.output[key], "#")
        monitor_target = type(split_result) == 'table' and split_result[1] or conf.output[key]
        
        log_info(COMPONENT_NAME, "Using output key " .. key .. " for IP monitor in stream '" .. conf.name .. "'.")
    else
        log_error(COMPONENT_NAME, "Invalid monitor_type: '" .. tostring(monitor_type) .. "' for stream '" .. conf.name .. "'.")
        return false
    end

    local instance = {
        name = monitor_name,
        upstream = upstream,
        monitor = monitor_target,
        rate = conf.monitor and conf.monitor.rate,
        time_check = conf.monitor and conf.monitor.time_check,
        analyze = conf.monitor and conf.monitor.analyze,
        method_comparison = conf.monitor and conf.monitor.method_comparison     
    }

    log_info(COMPONENT_NAME, "Attempting to create monitor for stream '" .. conf.name .. "'.")
    return make_monitor(instance, channel_data)
end

--- Останавливает поток и связанный с ним монитор.
-- @param table channel_data Таблица с данными канала, который нужно остановить.
-- @return table config Копия конфигурации остановленного канала, если успешно, иначе nil.
function kill_stream(channel_data)
    if not channel_data or not channel_data.config or not channel_data.config.name then 
        log_error(COMPONENT_NAME, "Invalid channel_data or config provided to kill_stream.")
        return nil 
    end

    local monitor_name = channel_data.config.name
    local monitor_data = find_monitor(monitor_name)

    if monitor_data then
        kill_monitor(monitor_data)
        log_info(COMPONENT_NAME, "Monitor '" .. monitor_name .. "' was killed as part of stream shutdown.")
    else
        log_info(COMPONENT_NAME, "No monitor found for stream '" .. monitor_name .. "'.")
    end

    local config = table_copy(channel_data.config)
    kill_channel(channel_data)

    log_info(COMPONENT_NAME, "Stream '" .. config.name .. "' shutdown successfully.")

    return config
end
