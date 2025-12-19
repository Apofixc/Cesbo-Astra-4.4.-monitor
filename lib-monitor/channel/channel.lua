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
local log_info = log.info
local log_error = log.error
local json_encode = json.encode

local table_copy = table.copy
local string_split = string.split
local check = check

local ChannelMonitor = require "channel.channel_monitor"
local MonitorManager = require "monitor_manager"

-- ===========================================================================
-- Константы и конфигурация
-- ===========================================================================

local MONITOR_LIMIT = 50

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
    if not name or type(params) ~= 'table' then
        log_error("[update_monitor_parameters] name and params table are required")
        return false
    end

    -- Находим монитор по имени
    local monitor_data = find_monitor(name)
    if not monitor_data then
        log_error("[update_monitor_parameters] Monitor not found for name: " .. tostring(name))
        return false
    end

    -- Обновляем только переданные параметры с валидацией
    if params.rate ~= nil and check(type(params.rate) == 'number' and params.rate >= 0.001 and params.rate <= 0.3, "params.rate must be between 0.001 and 0.3") then
        monitor_data.instance.rate = params.rate
    end
    if params.time_check ~= nil and check(type(params.time_check) == 'number' and params.time_check >= 0 and params.time_check <= 300, "params.time_check must be between 0 and 300") then
        monitor_data.instance.time_check = params.time_check
    end
    if params.analyze ~= nil and check(type(params.analyze) == 'boolean', "params.analyze must be boolean") then
        monitor_data.instance.analyze = params.analyze
    end
    if params.method_comparison ~= nil and check(type(params.method_comparison) == 'number' and params.method_comparison >= 1 and params.method_comparison <= 4, "params.method_comparison must be between 1 and 4") then
        monitor_data.instance.method_comparison = params.method_comparison
    end

    log_info("[update_monitor_parameters] Parameters updated successfully for monitor: " .. name)

    return true
end

--- Создает новый монитор канала.
-- @param table config Таблица конфигурации для нового монитора.
-- @param table channel_data (optional) Таблица с данными канала или его имя (string).
-- @return userdata monitor Экземпляр монитора, если успешно создан, иначе false.
function make_monitor(config, channel_data)
    if #monitor_manager:get_all_monitors() > MONITOR_LIMIT then 
        log_error("[make_monitor] monitor_list overflow")
        return false
    end

    local ch_data = type(channel_data) == "table" and channel_data or find_channel(tostring(channel_data))

    if not check(type(config) == 'table', "config must be a table") then return false end
    if not check(config.name and type(config.name) == 'string', "config.name required") then return false end
    if not check(config.monitor and type(config.monitor) == 'string', "config.monitor required") then return false end
    
    local monitor = ChannelMonitor:new(config, ch_data)
    local instance = monitor:start()

    if instance then
        monitor_manager:add_monitor(monitor.name, monitor)
        return instance
    else
        log_error("[make_monitor] ChannelMonitor:start returned nil")
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
    if not monitor_obj then return false end

    local config = table_copy(monitor_obj.config)
    monitor_manager:remove_monitor(monitor_obj.name)

    collectgarbage("collect")

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
        log_error("[make_stream] channel_data is nil")
        return false
    end

    local monitor_name = (conf.monitor and type(conf.monitor.name) == "string" and conf.monitor.name) or conf.name
    local monitor_type = (conf.monitor and type(conf.monitor.monitor_type) == "string" and string_lower(conf.monitor.monitor_type)) or "output"

    local upstream, monitor_target
    if monitor_type == "input" then
        local input_data = channel_data.input[1]
        upstream = input_data.input.tail

        local split_result = string_split(conf.input[1], "#")
        monitor_target = type(split_result) == 'table' and split_result[1] or conf.input[1]
    elseif monitor_type == "output" then
        upstream = channel_data.tail
        monitor_target = "output"
    else
        monitor_type = "ip"

        if not channel_data.output or #channel_data.output == 0 then
            log_error("[make_stream] channel_data.output is missing for ip monitor")
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
        
        log_info("Using output key " .. key)
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

    return make_monitor(instance, channel_data)
end

--- Останавливает поток и связанный с ним монитор.
-- @param table channel_data Таблица с данными канала, который нужно остановить.
-- @return table config Копия конфигурации остановленного канала, если успешно, иначе nil.
function kill_stream(channel_data)
    if not channel_data or not channel_data.config or not channel_data.config.name then 
        log_error("[kill_stream] Invalid channel_data or config")
        return nil 
    end

    local monitor_data = find_monitor(channel_data.config.name)

    if monitor_data then
        kill_monitor(monitor_data)
        log_info("[kill_stream] Monitor was killed")
    end

    local config = table_copy(channel_data.config)
    kill_channel(channel_data)

    log_info("[kill_stream] Stream shutdown: " .. config.name)

    return config
end
