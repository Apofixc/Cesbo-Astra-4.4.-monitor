-- ===========================================================================
-- Модуль `channel.channel`
--
-- Предназначен для управления каналами и их мониторингом в системе Astra.
-- Предоставляет функции для создания, обновления, поиска и удаления каналов,
-- а также для управления связанными с ними мониторами.
--
-- Основные функции:
-- - `get_list_monitor()`: Получает список всех активных мониторов каналов.
-- - `update_monitor_parameters(name, params)`: Обновляет параметры существующего монитора канала.
-- - `make_monitor(monitor_config_table, channel_data_obj)`: Создает и регистрирует новый монитор канала.
-- - `find_monitor(name)`: Ищет монитор канала по имени.
-- - `kill_monitor(monitor_obj)`: Останавливает и удаляет монитор канала.
-- - `make_stream(conf)`: Создает и запускает поток с мониторингом.
-- - `kill_stream(channel_data)`: Останавливает поток и связанный с ним монитор.
-- ===========================================================================

-- 1. Стандартные Lua функции
local type, tostring, ipairs = type, tostring, ipairs
local math_max = math.max
local string_lower = string.lower
local table_insert = table.insert

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("utils.logger")
local log_info = Logger.info
local log_error = Logger.error
local log_debug = Logger.debug
local Utils = ModuleManager.get_module("utils.utils")
local ChannelMonitor = ModuleManager.get_module("channel.channel_monitor")
local ChannelMonitorDispatcher = ModuleManager.get_module("dispatchers.channel_monitor_dispatcher")
local Adapter = ModuleManager.get_module("adapters.adapter")
local MonitorConfig = ModuleManager.get_module("config.monitor_config")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local string_split = ModuleManager.get_global_dependency("string.split")
local find_channel = ModuleManager.get_global_dependency("find_channel")
local make_channel = ModuleManager.get_global_dependency("make_channel")
local kill_channel = ModuleManager.get_global_dependency("kill_channel")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "Channel"
local MONITOR_TYPE_INPUT = "input"
local MONITOR_TYPE_OUTPUT = "output"
local MONITOR_TYPE_IP = "ip"

-- 5. Инициализация объектов из загруженных модулей
local channel_monitor_manager = ChannelMonitorDispatcher:new()
local shallow_table_copy = Utils.shallow_table_copy
local get_stream = Utils.get_stream

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
        local error_msg = "Неверное имя: ожидалась строка, получено: %s.", type(name)
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if not params or type(params) ~= 'table' then
        local error_msg = "Неверные параметры для '%s': ожидалась таблица, получено: %s.", name, type(params)
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    -- Делегируем обновление параметров менеджеру каналов
    local success, err = channel_monitor_manager:update_monitor_parameters(name, params)
    if success then
        log_info(COMPONENT_NAME, "Параметры успешно обновлены для монитора: %s.", name)
    else
        log_error(COMPONENT_NAME, "Не удалось обновить параметры для монитора: %s. Ошибка: %s.", name, err or "неизвестная ошибка")
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
                local error_msg = "Неизвестный или неподдерживаемый формат потока: %s для записи %s. Невозможно создать JSON потока.", tostring(input_entry.config.format), key
                log_error(COMPONENT_NAME, error_msg)
                return nil, error_msg
            end
            table_insert(stream_json_list, config_entry)
        end
    else
        local error_msg = "Предоставлены неверные данные канала. Ожидалась таблица, получено: %s.", type(channel_data_obj)
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
        local error_msg = "Неверная таблица конфигурации. Ожидалась таблица, получено: %s.", type(monitor_config_table)
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if not (monitor_config_table.name and type(monitor_config_table.name) == 'string') then
        local error_msg = "config.name является обязательным и должен быть строкой."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if not (monitor_config_table.monitor and type(monitor_config_table.monitor) == 'string') then
        local error_msg = "config.monitor является обязательным и должен быть строкой."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    
    local stream_json, err = create_stream_json_representation(ch_data)
    if err then
        log_error(COMPONENT_NAME, "Не удалось создать JSON потока: %s.", err)
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
        local error_msg = "Попытка остановить nil-объект монитора."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local config = shallow_table_copy(monitor_obj.config)
    local success, err = channel_monitor_manager:remove_monitor(monitor_obj.name)

    if success then
        log_info(COMPONENT_NAME, "Монитор '%s' успешно остановлен.", monitor_obj.name)
    else
        log_error(COMPONENT_NAME, "Не удалось удалить монитор '%s'. Ошибка: %s.", monitor_obj.name, err or "неизвестная ошибка")
        return nil, err or "Не удалось удалить монитор"
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
            local error_msg = "Отсутствуют входные данные для типа монитора 'input' в потоке '%s'.", conf.name
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
            local error_msg = "Отсутствует channel_data.output для IP-монитора в потоке '%s'.", conf.name
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
        
        log_info(COMPONENT_NAME, "Используется ключ вывода %d для IP-монитора в потоке '%s'.", key, conf.name)
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
        local error_msg = "Не удалось создать данные канала для потока '%s'. Ошибка: %s.", (conf.name or "unknown"), (err_channel or "unknown")
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local monitor_type = (conf.monitor and type(conf.monitor) == "table" and type(conf.monitor.monitor_type) == "string" and string_lower(conf.monitor.monitor_type)) or MONITOR_TYPE_OUTPUT

    local upstream, monitor_target, handler_err
    local handler = monitor_type_handlers[monitor_type]
    if handler then
        upstream, monitor_target, handler_err = handler(conf, channel_data)
    else
        local error_msg = "Неверный monitor_type: '%s' для потока '%s'.", tostring(monitor_type), conf.name
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    if handler_err then
        log_error(COMPONENT_NAME, "Ошибка от обработчика типа монитора для потока '%s': %s.", conf.name, handler_err)
        return nil, handler_err
    end

    if not monitor_target then
        local error_msg = "Не удалось определить цель монитора для потока '%s'.", conf.name
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local monitor_config = {
        name = conf.name,
        upstream = upstream,
        monitor = monitor_target,
        rate = conf.monitor and conf.monitor.rate,
        time_check = conf.monitor and conf.monitor.time_check,
        analyze = conf.monitor and conf.monitor.analyze,
        method_comparison = conf.monitor and conf.monitor.method_comparison     
    }

    local stream_json, err = create_stream_json_representation(channel_data)
    if err then
        log_error(COMPONENT_NAME, "Не удалось создать JSON потока: %s.", err)
        return nil, err
    end
    monitor_config.stream_json = stream_json

    log_info(COMPONENT_NAME, "Попытка создать монитор для потока '%s'.", conf.name)
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
        local error_msg = "Предоставлены неверные channel_data или config для kill_stream."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local monitor_name = channel_data.config.name
    local monitor_data = find_monitor(monitor_name)

    if monitor_data then
        local success, err = kill_monitor(monitor_data)
        if success then
            log_info(COMPONENT_NAME, "Монитор '%s' был остановлен в рамках завершения работы потока.", monitor_name)
        else
            log_error(COMPONENT_NAME, "Не удалось остановить монитор '%s' в рамках завершения работы потока. Ошибка: %s.", monitor_name, err or "неизвестная ошибка")
            return nil, err or "Не удалось остановить монитор во время завершения работы потока"
        end
    else
        log_info(COMPONENT_NAME, "Монитор для потока '%s' не найден.", monitor_name)
    end

    local config = shallow_table_copy(channel_data.config)
    kill_channel(channel_data) -- Предполагаем, что kill_channel всегда успешен или обрабатывает свои ошибки

    log_info(COMPONENT_NAME, "Поток '%s' успешно остановлен.", config.name)

    return config, nil
end
