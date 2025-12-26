-- ===========================================================================
-- ChannelMonitor Class
-- ===========================================================================

-- ===========================================================================
-- ChannelMonitor Class
-- Модуль для мониторинга состояния отдельных каналов.
-- Отвечает за запуск анализа потока, обработку данных и отправку статусов.
-- ===========================================================================

-- Стандартные функции Lua
local type       = type
local tostring   = tostring
local ipairs     = ipairs
local math_max   = math.max
local table_insert = table.insert

local AstraAPI = require "src.api.astra_api"

local json_encode     = AstraAPI.json_encode
local analyze         = AstraAPI.analyze

local Utils           = require "src.utils.utils"
local get_server_name = Utils.get_server_name
local send_monitor    = Utils.send_monitor
local ratio           = Utils.ratio
local validate_monitor_param = Utils.validate_monitor_param

local Logger = require "src.utils.logger"
local log_info           = Logger.info
local log_error          = Logger.error
local MonitorConfig      = require "src.config.monitor_config"

local COMPONENT_NAME = "ChannelMonitor"

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
        return prev.ready ~= curr.on_air or
               prev.scrambled ~= curr.total.scrambled or
               prev.cc_errors > 0 or
               prev.pes_errors > 0 or
               prev.bitrate ~= curr.total.bitrate
    end,

    --- Метод 3: Сравнение по изменению параметров с учетом погрешности битрейта.
    -- Аналогичен Методу 2, но изменение битрейта учитывается с заданной погрешностью `rate`.
    -- @param table prev Предыдущее состояние монитора.
    -- @param table curr Текущее состояние данных потока.
    -- @param number rate Допустимая погрешность для сравнения битрейта.
    -- @return boolean true, если обнаружено существенное изменение; false иначе.
    [3] = function(prev, curr, rate)
        return prev.ready ~= curr.on_air or
               prev.scrambled ~= curr.total.scrambled or
               prev.cc_errors > 0 or
               prev.pes_errors > 0 or
               ratio(prev.bitrate, curr.total.bitrate) > rate
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

        return prev.ready ~= curr.on_air
    end
}

--- Шаблон для информации об источнике, используемый по умолчанию, если данные отсутствуют.
local DEFAULT_SOURCE_TEMPLATE = {format = "Unknown", addr = "Unknown", stream = "Unknown"}

local ChannelMonitor = {}
ChannelMonitor.__index = ChannelMonitor

--- Вспомогательная функция для валидации и установки параметра конфигурации.
-- @param table self Объект ChannelMonitor.
-- @param string param_name Имя параметра (например, "channel_rate").
-- @param any value Значение для установки.
-- @return boolean true, если параметр успешно установлен; nil и сообщение об ошибке в случае ошибки.
local function set_config_param(self, param_name, value)
    local updated_value, err = validate_monitor_param(param_name, value)
    if err then
        log_error(COMPONENT_NAME, "Failed to validate '%s' parameter: %s", param_name, err)
        return nil, err
    end
    -- Извлекаем фактическое имя параметра из "channel_param_name"
    local config_key = param_name:gsub("channel_", "")
    self.config[config_key] = updated_value
    return true
end

--- Создает новый экземпляр ChannelMonitor.
-- Инициализирует монитор с предоставленной конфигурацией и данными канала,
-- устанавливает значения по умолчанию для отсутствующих параметров конфигурации
-- и подготавливает внутренние состояния для мониторинга.
-- @param table config Таблица конфигурации, содержащая параметры для монитора (например, `rate`, `time_check`, `analyze`, `method_comparison`).
-- @param table channel_data Таблица с данными о канале (например, `name`, `active_input_id`) или просто имя канала в виде строки.
-- @return ChannelMonitor Новый объект ChannelMonitor.
function ChannelMonitor:new(config, channel_data)
    local self = setmetatable({}, ChannelMonitor)
    self.config = config
    self.channel_data = channel_data

    -- Установка значений по умолчанию для параметров конфигурации, если они не заданы
    set_config_param(self, "channel_rate", config.rate)
    set_config_param(self, "channel_time_check", config.time_check)
    set_config_param(self, "channel_analyze", config.analyze)
    set_config_param(self, "channel_method_comparison", config.method_comparison)

    self.name = self.channel_data and self.channel_data.name or self.config.name
    self.stream_json = config.stream_json or {}
    self.psi_data_cache = {}
    self.json_status_cache = nil
    self.input_instance = nil

    self.time = 0
    self.force_timer = 0
    self.status = self:create_status_template()
    self.status.ready = false
    self.status.scrambled = true
    self.status.bitrate = 0
    self.status.cc_errors = 0
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
-- @return userdata Экземпляр монитора Astra, если успешно запущен; `nil` и сообщение об ошибке в случае ошибки.
function ChannelMonitor:start()
    local comparison_method = channel_monitor_method_comparison[self.config.method_comparison]
    if not comparison_method then
        local error_msg = "Invalid comparison method specified: " .. tostring(self.config.method_comparison)
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

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
                self_ref.psi_data_cache[psi_key] = json_encode(data)
            elseif data.total then
               if self_ref.config.analyze and data.analyze and (data.total.cc_errors > 0 or data.total.pes_errors > 0) then
                    local analyze_errors = {}
                    local has_errors = false
                    for _, pid_data in ipairs(data.analyze) do
                        if pid_data.cc_error > 0 or pid_data.pes_error > 0 or pid_data.sc_error > 0 then
                            table_insert(analyze_errors, pid_data)
                            has_errors = true
                        end
                    end
                    if has_errors then
                        local content = self_ref:create_status_template()
                        content.analyze = analyze_errors
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
        local error_msg = "analyze returned nil for channel '" .. self.name .. "'. Failed to start monitor."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    log_info(COMPONENT_NAME, "Started monitor for channel: " .. self.name)
    return self.monitor_instance, nil
end

--- Обновляет параметры конфигурации монитора канала.
-- Проверяет и применяет новые значения для `rate`, `time_check`, `analyze` и `method_comparison`,
-- если они предоставлены и валидны.
-- @param table params Таблица, содержащая новые параметры для обновления.
-- @return boolean true, если параметры успешно обновлены; `nil` и сообщение об ошибке, если `params` не является таблицей
-- или содержит невалидные значения.
function ChannelMonitor:update_parameters(params)
    if type(params) ~= 'table' then
        local error_msg = "Invalid parameters for update_parameters: expected table, got " .. type(params) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local success, err
    if params.rate ~= nil then
        success, err = set_config_param(self, "channel_rate", params.rate)
        if not success then return nil, err end
    end
    if params.time_check ~= nil then
        success, err = set_config_param(self, "channel_time_check", params.time_check)
        if not success then return nil, err end
    end
    if params.analyze ~= nil then
        success, err = set_config_param(self, "channel_analyze", params.analyze)
        if not success then return nil, err end
    end
    if params.method_comparison ~= nil then
        success, err = set_config_param(self, "channel_method_comparison", params.method_comparison)
        if not success then return nil, err end
    end

    log_info(COMPONENT_NAME, "Parameters updated successfully for monitor: " .. self.name)
    return true, nil
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
    
    local current_json_status = json_encode(self.status)
    if current_json_status ~= self.json_status_cache then
        send_monitor(current_json_status, "channels")
        self.json_status_cache = current_json_status
    end

    self.status.cc_errors = 0
    self.status.pes_errors = 0
end

--- Останавливает и очищает ресурсы, связанные с монитором канала.
-- Если существует `input_instance`, он будет остановлен.
-- Сбрасывает все внутренние ссылки для освобождения памяти.
function ChannelMonitor:kill()
    if self.input_instance then
        -- kill_input - это глобальная функция Astra
        _G.kill_input(self.input_instance)
        self.input_instance = nil
    end
    self.monitor_instance = nil
    self.config = nil
    self.channel_data = nil
    self.stream_json = nil
    self.psi_data_cache = nil
    self.json_status_cache = nil
    self.status = nil -- Очищаем статус
    log_info(COMPONENT_NAME, "Monitor killed for channel: " .. self.name)
end

--- Возвращает PSI-data.
-- @param table self Объект ChannelMonitor.
-- @return table Кэшированная PSI-data.
function ChannelMonitor:get_psi_data_cache()
    return self.psi_data_cache
end

--- Возвращает кэшированную JSON-строку статуса монитора.
-- @param table self Объект ChannelMonitor.
-- @return string Кэшированная JSON-строка статуса.
function ChannelMonitor:get_json_cache()
    return self.json_status_cache
end

return ChannelMonitor
