-- ===========================================================================
-- Структура таблицы monitor
-- ===========================================================================
-- instance = {
--     name -- Название канала в сообщений о статусе
--     upstream -- функция вызова потока
--     monitor_type -- на основай какого объекта будет создан монитор, только для make_stream
--     monitor -- адрес мониторинга
--     rate -- погрешность сравнения битрейда (0.001 to 0.3, default 0.035)
--     time_check -- время до сравнения данных для отправки обновления информаций (0 to 300, default 0). Раз в 300 происходит принудельное сравнение.
--     analyze -- расширенная информация о ошибках потока (boolean, default false)
--     method_comparison -- метод сравнения состояния потока (1 to 4, default 3)
-- }

-- ===========================================================================
-- Кэширование локальных функций для производительности
-- ===========================================================================

local type = type
local tostring = tostring
local tonumber = tonumber
local ipairs = ipairs
local math_max = math.max
local math_min = math.min
local string_lower = string.lower
local table_insert = table.insert
local table_remove = table.remove
local log_info = log.info
local log_error = log.error
local json_encode = json.encode
local analyze = analyze

local table_copy = table.copy -- Объявлена в модуле base.lua
local string_split = string.split -- Объявлена в модуле base.lua
local ratio = ratio -- Объявлена в модуле utils.lua
local check = check

-- ===========================================================================
-- Константы и конфигурация
-- ===========================================================================

local DEFAULT_RATE = 0.035
local DEFAULT_TIME_CHECK = 0
local DEFAULT_ANALYZE = false
local DEFAULT_METHOD_COMPARISON = 3
local MONITOR_LIMIT = 50
local FORCE_SEND = 300

local channel_monitor_method_comparison = {
    function(prev, curr, rate) -- по таймеру
        return true
    end,
    function(prev, curr, rate) -- по любому изменению параметров
        if prev.ready ~= curr.on_air or 
            prev.scrambled ~= curr.total.scrambled or 
            prev.cc_errors > 0 or 
            prev.pes_errors > 0 or 
            prev.bitrate ~= curr.total.bitrate then
                return true
        end

        return false
    end,
    function(prev, curr, rate) -- по любому изменению параметров, с учетом погрешности
        if prev.ready ~= curr.on_air or 
            prev.scrambled ~= curr.total.scrambled or 
            prev.cc_errors > 0 or 
            prev.pes_errors > 0 or 
            ratio(prev.bitrate, curr.total.bitrate) > rate then
                return true
        end

        return false
    end,
    function(prev, curr, rate) -- по изменению доступности канала (добавлена для использования в связке telegraf + telegram bot)
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

-- ===========================================================================
-- Основные функции модуля
-- ===========================================================================

local function create_monitor(monitor_data, channel_data)
    local instance = monitor_data.instance
    local stream_json = monitor_data.stream_json

    if not instance.name then
        log_error("[create_monitor] name is required")
        return nil
    end    

    local send = send_monitor
    
    local comparison = channel_monitor_method_comparison[instance.method_comparison]

    -- Кэш для source (инициализация)
    local cached_source = nil
    local last_active_id = nil
    -- Функция для получения актуального source
    local function get_cached_source()
        local active_id = channel_data and channel_data.active_input_id or 1
        if active_id ~= last_active_id then 
            last_active_id = active_id
            local input_index = math_max(1, active_id)
            cached_source = stream_json[input_index] or {format = "Unknown", addr = "Unknown", stream = "Unknown"}
        end
        return cached_source
    end

    local function create_template()
        local source = get_cached_source()
        return {
            type = "Channel",
            server = get_server_name(),
            channel = instance.name,
            output = instance.monitor, -- добавлен output для совместимости.
            stream = source.stream,
            format = source.format,
            addr = source.addr
        }
    end

    local time = 0  
    local force_timer = 0
    local status = create_template()
    status.ready = false
    status.scrambled = true
    status.bitrate = 0
    status.cc_errors = 0
    status.pes_errors = 0
    
    local monitor = analyze({
        upstream = instance.upstream:stream(),
        name = "_" .. instance.name,
        callback = function(data)
            if data.error then
                local content = create_template()
                content.error = data.error

                send(json_encode(content), "error")
            elseif data.psi then
                local psi_key = data.psi
                if monitor_data.psi_data_cache[psi_key] then
                    monitor_data.psi_data_cache[psi_key] = nil
                end
                    
                monitor_data.psi_data_cache[psi_key] = json_encode(data) 
            elseif data.total then
               if instance.analyze and data.analyze and (data.total.cc_errors > 0 or data.total.pes_errors > 0) then
                    local content = create_template()
                    content.analyze = {}
                    local has_errors = false
                    for _, pid_data in ipairs(data.analyze) do
                        if pid_data.cc_error > 0 or pid_data.pes_error > 0 or pid_data.sc_error > 0 then
                            table_insert(content.analyze, pid_data)
                            has_errors = true
                        end
                    end

                    if has_errors then  -- Отправляем только если есть ошибки (избегаем пустых JSON)
                        send(json_encode(content), "analyze")
                    end
                end

                -- Считаем общее количество ошибок между передачами данных
                status.cc_errors = status.cc_errors + (data.total.cc_errors or 0)
                status.pes_errors = status.pes_errors + (data.total.pes_errors or 0)

                force_timer = force_timer + 1
                if time < instance.time_check then
                    time = time + 1
                    return
                end
                time = 0

                if comparison(status, data, instance.rate) or force_timer > FORCE_SEND then
                    local source = get_cached_source()
                    if source then
                        status.stream = source.stream
                        status.format = source.format
                        status.addr = source.addr
                    end

                    status.ready = data.on_air
                    status.scrambled = data.total.scrambled
                    status.bitrate = data.total.bitrate or 0
                    
                    local json_cache = json_encode(status)
                    send(json_cache, "channels")

                    monitor_data.json_status_cache = json_cache

                    -- Обнуляем счетчик
                    status.cc_errors = 0
                    status.pes_errors = 0
                    force_timer = 0
                end
            end
        end
    })

    if not monitor then 
        log_error("[create_monitor] analyze returned nil")
        return nil
    end

    return monitor
end

local monitor_list = {}

function get_list_monitor()
    return monitor_list
end

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

function make_monitor(config, channel_data)
    if #monitor_list > MONITOR_LIMIT then 
        log_error("[make_monitor] monitor_list overflow")
        return false
    end

    local ch_data = type(channel_data) == "table" and channel_data or find_channel(tostring(channel_data))

    if not check(type(config) == 'table', "config must be a table") then return false end
    if not check(config.name and type(config.name) == 'string', "config.name required") then return false end
    if not check(config.monitor and type(config.monitor) == 'string', "config.monitor required") then return false end
    if not check(type(config.rate) == 'number' and config.rate >= 0.001 and config.rate <= 0.3, "config.rate must be between 0.001 and 0.3, default value was set: " .. DEFAULT_RATE) then config.rate = DEFAULT_RATE end
    if not check(type(config.time_check) == 'number' and config.time_check >= 0 and config.time_check <= 300, "config.time_check  must be between 0 and 300, default value was set: " .. DEFAULT_TIME_CHECK) then config.time_check = DEFAULT_TIME_CHECK end
    if not check(type(config.analyze) == 'boolean', "config.analyze must be boolean, default value was set: " .. tostring(DEFAULT_ANALYZE)) then config.analyze = DEFAULT_ANALYZE end
    if not check(type(config.method_comparison) == 'number' and config.method_comparison >= 1 and config.method_comparison <= 4, "config.method_comparison must be between 1 and 4, default value was set: " .. DEFAULT_METHOD_COMPARISON) then 
        config.method_comparison = DEFAULT_METHOD_COMPARISON end

    local name
    local stream_json = {}
    if ch_data then
        -- Создание stream_json — сериализация конфигурации input
        for key, input in ipairs(ch_data.input) do
            local cfg = {format = input.config.format}
            if input.config.format == "dvb" then
                cfg.addr = input.config.addr
                local adap_conf = find_dvb_conf(input.config.addr)
                cfg.stream = adap_conf and adap_conf.source or "dvb"      
            elseif input.config.format == "udp" or input.config.format == "rtp" then
                cfg.addr = input.config.localaddr .. "@" .. input.config.addr .. ":" .. input.config.port
                cfg.stream = get_stream(input.config.addr)
            elseif input.config.format == "http" then
                cfg.addr = input.config.host .. ":" .. input.config.port .. input.config.path
                cfg.stream = get_stream(input.config.host)
            elseif input.config.format == "file" then
                cfg.addr = input.config.filename
                cfg.stream = "file"
            end

            stream_json[key] = cfg
        end

        name = ch_data.name or config.name
    else
        table_insert(stream_json, {format = "Unknown", addr = "Unknown", stream = "Unknown"})
        name = type(channel_data) == "string" and channel_data or config.name
    end

    if find_monitor(name) then 
        log_error("[make_monitor] Monitor already exists") 
        return false
    end

    local monitor_data = {
        name = name,
        instance = config,
        stream_json = stream_json,
        psi_data_cache = {},
        json_status_cache = nil
    }

    if not config.upstream then
        local cfg = parse_url(config.monitor)

        if not cfg then
            log_error("[make_monitor] monitoring address does not exist.") 
            return false     
        end

        cfg.name = name

        monitor_data.input = init_input(cfg)
        if not monitor_data.input then
            log_error("[make_monitor] init_input returned nil, upstream is required")
            return false
        end

        config.upstream = monitor_data.input.tail
    end    

    monitor_data.monitor = create_monitor(monitor_data, ch_data)
    if monitor_data.monitor then
        table_insert(monitor_list, monitor_data)

        return monitor_data.monitor
    else
        log_error("[make_monitor] create_monitor returned nil")
        return false        
    end
end

function find_monitor(name)
    for _, monitor_data in ipairs(monitor_list) do
        if monitor_data.name == name then
            return monitor_data
        end
    end
    return nil
end

function kill_monitor(monitor_data)
    if not monitor_data then return false end

    -- Находим индекс в списке monitor_list
    local monitor_id = nil
    for index, data in ipairs(monitor_list) do
        if data == monitor_data then
            monitor_id = index
            break
        end
    end

    if not monitor_id then
        log_error("[kill_monitor] Monitor not in list")
        return false
    end

    local config = table_copy(monitor_data.instance)

    if monitor_data.input then
        kill_input(monitor_data.input)
        monitor_data.input = nil
    end

    -- Очистка связанных данных для предотвращения утечек памяти
    monitor_data.name = nil
    monitor_data.monitor = nil
    monitor_data.instance = nil
    monitor_data.psi_data_cache = nil 
    monitor_data.json_status_cache = nil

    for i = 1, #monitor_data.stream_json do
        monitor_data.stream_json[i] = nil
    end
    monitor_data.stream_json = nil

    table_remove(monitor_list, monitor_id)

    -- Мягкая сборка мусора для оптимизации памяти
    collectgarbage("collect")

    return config
end

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
