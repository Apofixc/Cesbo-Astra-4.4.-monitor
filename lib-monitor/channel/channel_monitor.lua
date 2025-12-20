-- ===========================================================================
-- ChannelMonitor Class
-- ===========================================================================

-- ===========================================================================
-- ChannelMonitor Class
-- Модуль для мониторинга состояния отдельных каналов.
-- Отвечает за запуск анализа потока, обработку данных и отправку статусов.
-- ===========================================================================

-- Стандартные функции Lua
local type = type
local tostring = tostring
local ipairs = ipairs
local math_max = math.max
local table_insert = table.insert

-- Глобальные функции Astra (предполагается, что они доступны в глобальной области видимости)
local json_encode = json.encode
local analyze = analyze
local get_server_name = get_server_name
local send_monitor = send_monitor
local check = check
local ratio = ratio

-- Локальные модули
local Logger = require "utils.logger"
local log_info = Logger.info
local log_error = Logger.error

local COMPONENT_NAME = "ChannelMonitor" -- Имя компонента для логирования

--- Таблица методов сравнения для монитора канала.
-- Каждый метод определяет логику, по которой определяется, изменилось ли состояние канала
-- достаточно для отправки нового статуса.
local channel_monitor_method_comparison = {
    --- Метод 1: Сравнение по таймеру. Всегда возвращает true, что означает отправку статуса
    -- по истечении заданного интервала `time_check`.
    -- @param table prev Предыдущее состояние монитора.
    -- @param table curr Текущее состояние данных потока.
    -- @param number rate Погрешность сравнения битрейта (не используется в этом методе).
    -- @return boolean Всегда true.
    [1] = function(prev, curr, rate)
        return true
    end,

    --- Метод 2: Сравнение по любому изменению ключевых параметров.
    -- Возвращает true, если изменился статус готовности, скремблирования,
    -- есть ошибки CC/PES, или изменился битрейт.
    -- @param table prev Предыдущее состояние монитора.
    -- @param table curr Текущее состояние данных потока.
    -- @param number rate Погрешность сравнения битрейта (не используется в этом методе).
    -- @return boolean true, если обнаружено существенное изменение; false иначе.
    [2] = function(prev, curr, rate)
        if prev.ready ~= curr.on_air or
            prev.scrambled ~= curr.total.scrambled or
            prev.cc_errors > 0 or
            prev.pes_errors > 0 or
            prev.bitrate ~= curr.total.bitrate then
                return true
        end
        return false
    end,

    --- Метод 3: Сравнение по изменению параметров с учетом погрешности битрейта.
    -- Аналогичен Методу 2, но изменение битрейта учитывается с заданной погрешностью `rate`.
    -- @param table prev Предыдущее состояние монитора.
    -- @param table curr Текущее состояние данных потока.
    -- @param number rate Допустимая погрешность для сравнения битрейта.
    -- @return boolean true, если обнаружено существенное изменение; false иначе.
    [3] = function(prev, curr, rate)
        if prev.ready ~= curr.on_air or
            prev.scrambled ~= curr.total.scrambled or
            prev.cc_errors > 0 or
            prev.pes_errors > 0 or
            ratio(prev.bitrate, curr.total.bitrate) > rate then
                return true
        end
        return false
    end,

    --- Метод 4: Сравнение по изменению доступности канала.
    -- Используется для интеграции с внешними системами (например, Telegraf + Telegram bot).
    -- Сбрасывает счетчики ошибок, если они превышают пороговое значение, и проверяет
    -- только изменение статуса `on_air`.
    -- @param table prev Предыдущее состояние монитора.
    -- @param table curr Текущее состояние данных потока.
    -- @param number rate Погрешность сравнения битрейта (не используется в этом методе).
    -- @return boolean true, если изменился статус `on_air`; false иначе.
    [4] = function(prev, curr, rate)
        -- Сброс счетчиков ошибок для предотвращения накопления, если они слишком велики.
        if prev.cc_errors > 1000 or prev.pes_errors > 1000 then
            prev.cc_errors = 0
            prev.pes_errors = 0
        end

        if prev.ready ~= curr.on_air then
                return true
        end
        return false
    end
}

--- Шаблон для информации об источнике, используемый по умолчанию, если данные отсутствуют.
local DEFAULT_SOURCE_TEMPLATE = {format = "Unknown", addr = "Unknown", stream = "Unknown"}

local ChannelMonitor = {}
ChannelMonitor.__index = ChannelMonitor

--- Создает новый экземпляр ChannelMonitor.
-- Инициализирует монитор с предоставленной конфигурацией и данными канала,
-- устанавливает значения по умолчанию для отсутствующих параметров конфигурации
-- и подготавливает внутренние состояния для мониторинга.
-- @param table config Таблица конфигурации, содержащая параметры для монитора (например, `rate`, `time_check`, `analyze`, `method_comparison`).
-- @param table channel_data Таблица с данными о канале (например, `name`, `active_input_id`) или просто имя канала в виде строки.
-- @return ChannelMonitor Новый объект ChannelMonitor.
function ChannelMonitor:new(config, channel_data)
    local self = setmetatable({}, ChannelMonitor)
    -- Таблица конфигурации, содержащая параметры для монитора (например, `rate`, `time_check`, `analyze`, `method_comparison`).
    self.config = config
    -- Таблица с данными о канале (например, `name`, `active_input_id`) или просто имя канала в виде строки.
    self.channel_data = channel_data

    -- Установка значений по умолчанию для параметров конфигурации, если они не заданы
    -- Допустимая погрешность для сравнения битрейта (например, 0.035 = 3.5%).
    self.config.rate = self.config.rate or 0.035
    -- Интервал проверки состояния канала в секундах.
    self.config.time_check = self.config.time_check or 0
    -- Флаг, указывающий, нужно ли выполнять детальный анализ потока.
    self.config.analyze = self.config.analyze or false
    -- Метод сравнения для определения изменений в параметрах канала.
    -- 1: Сравнение по таймеру.
    -- 2: Сравнение по любому изменению ключевых параметров.
    -- 3: Сравнение по изменению параметров с учетом погрешности битрейта.
    -- 4: Сравнение по изменению доступности канала.
    self.config.method_comparison = self.config.method_comparison or 3

    -- Имя канала/монитора, извлекается из channel_data или config.
    self.name = self.channel_data and self.channel_data.name or self.config.name
    -- JSON-данные потока из конфигурации.
    self.stream_json = config.stream_json or {}
    -- Кэш данных PSI (Program Specific Information).
    self.psi_data_cache = {}
    -- Кэш последнего отправленного JSON-статуса.
    self.json_status_cache = nil
    -- Экземпляр входного потока (если используется init_input).
    self.input_instance = nil

    -- Внутренний таймер для отсчета интервала проверки.
    self.time = 0
    -- Таймер для принудительной отправки статуса, если долго не было изменений.
    self.force_timer = 0
    -- Текущий статус монитора, инициализируется шаблоном.
    self.status = self:create_status_template()
    -- Готовность канала (true, если канал активен).
    self.status.ready = false
    -- Статус скремблирования (true, если канал скремблирован).
    self.status.scrambled = true
    -- Битрейт канала в кбит/с.
    self.status.bitrate = 0
    -- Счетчик ошибок Continuity Counter.
    self.status.cc_errors = 0
    -- Счетчик ошибок Packetized Elementary Stream.
    self.status.pes_errors = 0

    log_info(COMPONENT_NAME, "New ChannelMonitor instance created for channel: " .. self.name)
    return self
end

--- Возвращает кэшированную информацию об активном источнике канала.
-- Обновляет кэш, если `active_input_id` канала изменился.
-- @return table Таблица с информацией об активном источнике (`format`, `addr`, `stream`).
function ChannelMonitor:get_cached_source()
    local active_id = self.channel_data and self.channel_data.active_input_id or 1
    if active_id ~= self.last_active_id then 
        self.last_active_id = active_id
        local input_index = math_max(1, active_id)
        self.cached_source = self.stream_json[input_index] or DEFAULT_SOURCE_TEMPLATE
    end
    return self.cached_source
end

--- Создает базовый шаблон статуса для канала.
-- Включает общую информацию о канале, такую как тип, сервер, имя канала,
-- выходной поток и данные источника.
-- @return table Таблица, представляющая текущий статус канала.
function ChannelMonitor:create_status_template()
    local source = self:get_cached_source()
    return {
        type = "Channel",
        server = get_server_name(),
        channel = self.name,
        output = self.config.monitor,
        stream = source.stream,
        format = source.format,
        addr = source.addr
    }
end

--- Запускает процесс мониторинга для канала.
-- Инициализирует функцию `analyze` Astra с колбэком для обработки входящих данных
-- потока (ошибки, PSI, общие данные). Обновляет внутреннее состояние монитора
-- и отправляет статусы при обнаружении изменений согласно выбранному методу сравнения.
-- @return userdata Экземпляр монитора Astra, если успешно запущен; nil в случае ошибки.
function ChannelMonitor:start()
    local comparison_method = channel_monitor_method_comparison[self.config.method_comparison]
    local self_ref = self -- Сохраняем ссылку на self для использования в замыкании

    self.monitor_instance = analyze({
        upstream = self.config.upstream:stream(),
        name = "_" .. self.name,
        callback = function(data)
            if data.error then
                local content = self_ref:create_status_template()
                content.error = data.error
                send_monitor(json_encode(content), "errors")
            elseif data.psi then
                local psi_key = data.psi
                if self_ref.psi_data_cache[psi_key] then
                    self_ref.psi_data_cache[psi_key] = nil
                end
                self_ref.psi_data_cache[psi_key] = json_encode(data) 
            elseif data.total then
               if self_ref.config.analyze and data.analyze and (data.total.cc_errors > 0 or data.total.pes_errors > 0) then
                    local content = self_ref:create_status_template()
                    content.analyze = {}
                    local has_errors = false
                    for _, pid_data in ipairs(data.analyze) do
                        if pid_data.cc_error > 0 or pid_data.pes_error > 0 or pid_data.sc_error > 0 then
                            table_insert(content.analyze, pid_data)
                            has_errors = true
                        end
                    end
                    if has_errors then
                        send_monitor(json_encode(content), "analyze")
                    end
                end

                self_ref.status.cc_errors = self_ref.status.cc_errors + (data.total.cc_errors or 0)
                self_ref.status.pes_errors = self_ref.status.pes_errors + (data.total.pes_errors or 0)

                self_ref.force_timer = self_ref.force_timer + 1
                if self_ref.time < self_ref.config.time_check then
                    self_ref.time = self_ref.time + 1
                    return
                end
                self_ref.time = 0

                -- Проверяем, нужно ли отправлять статус
                if comparison_method(self_ref.status, data, self_ref.config.rate) or self_ref.force_timer > 300 then -- FORCE_SEND = 300
                    self_ref:send_channel_status(data)
                    self_ref.force_timer = 0
                end
            end
        end
    })

    if not self.monitor_instance then 
        log_error(COMPONENT_NAME, "analyze returned nil for channel '" .. self.name .. "'. Failed to start monitor.")
        return nil
    end

    log_info(COMPONENT_NAME, "Started monitor for channel: " .. self.name)
    return self.monitor_instance
end

--- Обновляет параметры конфигурации монитора канала.
-- Проверяет и применяет новые значения для `rate`, `time_check`, `analyze` и `method_comparison`,
-- если они предоставлены и валидны.
-- @param table params Таблица, содержащая новые параметры для обновления.
-- @return boolean true, если параметры успешно обновлены; false, если `params` не является таблицей
-- или содержит невалидные значения.
function ChannelMonitor:update_parameters(params)
    if type(params) ~= 'table' then
        log_error(COMPONENT_NAME, "Invalid parameters for update_parameters: expected table, got " .. type(params) .. ".")
        return false
    end

    if params.rate ~= nil and check(type(params.rate) == 'number' and params.rate >= 0.001 and params.rate <= 0.3, "params.rate must be between 0.001 and 0.3") then
        self.config.rate = params.rate
    end
    if params.time_check ~= nil and check(type(params.time_check) == 'number' and params.time_check >= 0 and params.time_check <= 300, "params.time_check must be between 0 and 300") then
        self.config.time_check = params.time_check
    end
    if params.analyze ~= nil and check(type(params.analyze) == 'boolean', "params.analyze must be boolean") then
        self.config.analyze = params.analyze
    end
    if params.method_comparison ~= nil and check(type(params.method_comparison) == 'number' and params.method_comparison >= 1 and params.method_comparison <= 4, "params.method_comparison must be between 1 and 4") then
        self.config.method_comparison = params.method_comparison
    end

    log_info(COMPONENT_NAME, "Parameters updated successfully for monitor: " .. self.name)
    return true
end

--- Отправляет текущий статус канала.
-- Обновляет данные статуса на основе текущих данных потока и отправляет их
-- через `send_monitor`. Также обновляет кэш последнего отправленного статуса.
-- @param table data Текущие данные потока, полученные от `analyze`.
function ChannelMonitor:send_channel_status(data)
    local source = self:get_cached_source()
    if source then
        self.status.stream = source.stream
        self.status.format = source.format
        self.status.addr = source.addr
    end

    self.status.ready = data.on_air
    self.status.scrambled = data.total.scrambled
    self.status.bitrate = data.total.bitrate or 0
    
    local json_cache = json_encode(self.status)
    send_monitor(json_cache, "channels")

    self.json_status_cache = json_cache

    self.status.cc_errors = 0
    self.status.pes_errors = 0
end

--- Останавливает и очищает ресурсы, связанные с монитором канала.
-- Если существует `input_instance`, он будет остановлен.
-- Сбрасывает все внутренние ссылки для освобождения памяти.
function ChannelMonitor:kill()
    if self.input_instance then
        -- kill_input - это глобальная функция Astra
        kill_input(self.input_instance)
        self.input_instance = nil
    end
    self.monitor_instance = nil
    self.config = nil
    self.channel_data = nil
    self.stream_json = nil
    self.psi_data_cache = nil
    self.json_status_cache = nil
    log_info(COMPONENT_NAME, "Monitor killed for channel: " .. self.name)
end

return ChannelMonitor
