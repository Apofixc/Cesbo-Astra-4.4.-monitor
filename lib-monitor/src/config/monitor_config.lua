-- ===========================================================================
-- Модуль `config.monitor_config`
--
-- Централизованное хранилище конфигурации системы мониторинга.
-- Содержит параметры логирования, сетевые настройки, лимиты ресурсов
-- и правила валидации для мониторов.
-- ===========================================================================

-- 1. Стандартные Lua функции
local os_time = _G.os.time
local pairs = _G.pairs
local pcall = _G.pcall
local tostring = _G.tostring
local type = _G.type
local string_format = _G.string.format

-- 2. Функции из ModuleManager.get_module()
local ModuleManager = _G.ModuleManager
local Logger = nil -- Кэшируется при первом обращении
local EventDispatcher = nil -- Кэшируется при первом обращении

-- 3. Глобальные зависимости Astra
local json_load = ModuleManager.get_global_dependency("json.load")
local json_save = ModuleManager.get_global_dependency("json.save")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "MonitorConfig"
local CONFIG_PATH = "/opt/astra/lib-monitor/config.json"

--- @class ValidationRule
--- @field type string Тип данных ("number"|"boolean"|"string"|"table")
--- @field min number|nil Минимальное значение (для чисел)
--- @field max number|nil Максимальное значение (для чисел)
--- @field enum table<string, boolean>|nil Список допустимых значений (для строк)
--- @field default any Значение по умолчанию

-- 5. Внутреннее состояние (Private State)

--- @class MonitorConfigState
--- @field cache table<string, any> Кэш вычисляемых значений
--- @field cache_ttl number Время жизни кэша (сек)
--- @field cache_timestamp number Время последнего обновления кэша
--- @field environment_cache string|nil Кэш окружения
local _state = {
    cache = {},
    cache_ttl = 60,
    cache_timestamp = 0,
    environment_cache = nil
}

--- @class MonitorConfig
local MonitorConfig = {}

-- ===========================================================================
-- Схема валидации и значения по умолчанию (Единый источник правды)
-- ===========================================================================

MonitorConfig.ValidationSchema = {
    Logger = {
        LogLevel = {
            type = "string",
            enum = {DEBUG=true, INFO=true, WARN=true, ERROR=true, NONE=true},
            default = "INFO"
        },
        LogFormat = { type = "string", enum = {TEXT=true, JSON=true}, default = "TEXT" },
        LogBatchEnabled = { type = "boolean", default = false },
        LogBufferSize = { type = "number", min = 0, max = 1024 * 1024, default = 0 },
        MaxLogQueueSize = { type = "number", min = 1, max = 10000, default = 200 },
        MaxLogComponents = { type = "number", min = 1, max = 1000, default = 100 },
    },
    Network = {
        MaxPayloadSize = { type = "number", min = 1024, max = 10 * 1024 * 1024, default = 1024 * 1024 },
        CorsAllowOrigin = { type = "string", default = "*" },
        HttpTimeout = { type = "number", min = 1, max = 300, default = 10 },
        RateLimitWindow = { type = "number", min = 1, max = 3600, default = 60 },
        RateLimitMaxRequests = { type = "number", min = 1, max = 10000, default = 100 },
        MaxRetryQueueSize = { type = "number", min = 1, max = 10000, default = 500 },
        MaxRetries = { type = "number", min = 0, max = 100, default = 5 },
        RetryDelay = { type = "number", min = 1, max = 3600, default = 5 },
        MaxRouteCacheSize = { type = "number", min = 1, max = 10000, default = 1000 },
    },
    Monitor = {
        ChannelMonitorLimit = { type = "number", min = 1, max = 1000, default = 200 },
        DvbMonitorLimit = { type = "number", min = 1, max = 100, default = 20 },
        MaxMonitorNameLength = { type = "number", min = 1, max = 256, default = 64 },
        -- MinRate = { type = "number", min = 0.0001, max = 1, default = 0.001 },
        -- MaxRate = { type = "number", min = 0.001, max = 1, default = 0.3 },
        -- MinTimeCheck = { type = "number", min = 0, max = 3600, default = 0 },
        -- MaxTimeCheck = { type = "number", min = 1, max = 3600, default = 300 },
        -- MinMethodComparison = { type = "number", min = 1, max = 10, default = 1 },
        -- MaxMethodComparison = { type = "number", min = 1, max = 10, default = 8 },
        -- ChannelCcThreshold = { type = "number", min = 0, max = 65535, default = 1 },
        ForceSendInterval = { type = "number", min = 1, max = 3600, default = 300 },
        -- PidStatsLimit = { type = "number", min = 1, max = 8192, default = 100 },
        -- MaxCounterValue = { type = "number", min = 1, max = 1000000000000, default = 1000000000 },
        -- MaxErrorCount = { type = "number", min = 1, max = 1000000000, default = 1000000 },
    },
    System = {
        GcPause = { type = "number", min = 10, max = 1000, default = 100 },
        GcStepMul = { type = "number", min = 10, max = 1000, default = 500 },
        SchedulerInterval = { type = "number", min = 0.1, max = 60, default = 1 },
        CpuThreshold = { type = "number", min = 1, max = 100, default = 90 },
        RamThresholdPct = { type = "number", min = 1, max = 100, default = 80 },
        FdThreshold = { type = "number", min = 1, max = 10000, default = 800 },
        HysteresisFactor = { type = "number", min = 0.5, max = 0.99, default = 0.95 },
        NetworkCheckInterval = { type = "number", min = 1, max = 3600, default = 30 },
        ConfigRefreshInterval = { type = "number", min = 1, max = 3600, default = 10 },
        AdaptiveTickThresholdCpu = { type = "number", min = 1, max = 100, default = 50 },
        AdaptiveTickThresholdRam = { type = "number", min = 1, max = 100, default = 70 },
        TickIntervalNormal = { type = "number", min = 0.1, max = 60, default = 5 },
        TickIntervalFast = { type = "number", min = 0.1, max = 60, default = 1 },
        RareMetricInterval = { type = "number", min = 1, max = 3600, default = 5 },
        MaxCpuJump = { type = "number", min = 1, max = 100, default = 50 },
        MaxRamJumpPct = { type = "number", min = 1, max = 100, default = 20 },
        CpuMovingAverageWindow = { type = "number", min = 1, max = 100, default = 5 },
        ResourceMonitorEnabled = { type = "boolean", default = true },
    },
    Recovery = {
        AutoRecoverEnabled = { type = "boolean", default = false },
        AutoRecoverInterval = { type = "number", min = 1, max = 3600, default = 300 },
        MaxRecoveryAttempts = { type = "number", min = 1, max = 100, default = 3 },
        RecoveryCooldown = { type = "number", min = 1, max = 86400, default = 3600 },
    },
    Event = {
        LvcTtl = { type = "number", min = 1, max = 86400, default = 3600 },
        MaxLvcSize = { type = "number", min = 1, max = 10000, default = 1000 },
        MaxQueueSize = { type = "number", min = 1, max = 10000, default = 1000 },
        EventBatchLimit = { type = "number", min = 1, max = 1000, default = 100 },
        MaxBatchLimit = { type = "number", min = 1, max = 10000, default = 1000 },
    },
    Batch = {
        BatchEnabled = { type = "boolean", default = true },
        BatchFlushInterval = { type = "number", min = 0.01, max = 60, default = 0.5 },
        BatchMaxSize = { type = "number", min = 1, max = 1000, default = 50 },
        DefaultBatchMode = { type = "string", enum = {single=true, array=true}, default = "single" },
    },
    Pool = {
        MaxPoolSize = { type = "number", min = 1, max = 10000, default = 100 },
        PoolDebug = { type = "boolean", default = false },
        PoolAdaptiveThreshold = { type = "number", min = 0.01, max = 1, default = 0.2 },
        PoolAdaptiveStep = { type = "number", min = 0.01, max = 1, default = 0.25 },
        PoolMinLimit = { type = "number", min = 1, max = 1000, default = 10 },
        PoolMaintenanceInterval = { type = "number", min = 1, max = 3600, default = 300 },
        MemoryLimitMb = { type = "number", min = 1, max = 1024, default = 50 },
    },
    Watchdog = {
        WatchdogEnabled = { type = "boolean", default = false },
        WatchdogMaxRetries = { type = "number", min = 1, max = 100, default = 3 },
        WatchdogInterval = { type = "number", min = 1, max = 3600, default = 5 },
        WatchdogThreshold = { type = "number", min = 1, max = 3600, default = 15 },
        WatchdogCasThreshold = { type = "number", min = 1, max = 3600, default = 60 },
    },
    Instance = {
        channel_rate = { type = "number", min = 0.0001, max = 1, default = 0.035 },
        channel_time_check = { type = "number", min = 0, max = 3600, default = 0 },
        channel_analyze = { type = "boolean", default = false },
        channel_method_comparison = { type = "number", min = 1, max = 8, default = 2 },
        channel_cc_threshold = { type = "number", min = 0, max = 65535, default = 1 },
        channel_cc_limit = { type = "number", min = 0, max = 65535, default = 0 },
        channel_bitrate_limit = { type = "number", min = 0, max = 100000000, default = 0 },
        channel_join_pid = { type = "boolean", default = false },
        dvb_time_check = { type = "number", min = 0, max = 3600, default = 10 },
        dvb_rate = { type = "number", min = 0.0001, max = 1, default = 0.015 },
        dvb_method_comparison = { type = "number", min = 1, max = 7, default = 2 },
        dvb_analyze = { type = "boolean", default = true },
        channel_watchdog_enabled = { type = "boolean", default = false },
        channel_watchdog_timeout = { type = "number", min = 1, max = 3600, default = 15 },
        channel_watchdog_cas_timeout = { type = "number", min = 1, max = 3600, default = 60 },
        MaxCounterValue = { type = "number", default = 1000000000 },
        MaxErrorCount = { type = "number", default = 1000000 },
        PidStatsLimit = { type = "number", default = 100 },
    }
}

-- Имена потоков
MonitorConfig.STREAM = {
    ["127.0.0.1"] = "Узда",
    ["127.0.0.2"] = "Дружный",
    ["127.0.0.3"] = "Старобин",
    ["127.0.0.4"] = "Октябрьский",
    ["127.0.0.5"] = "Червень",
    ["127.0.0.6"] = "Mediatech",
    ["127.0.0.7"] = "PlayOut",
    ["127.0.0.8"] = "BeCloud",
    ["127.0.0.9"] = "WikiLink",
}

-- Служебные данные
MonitorConfig.subscribers = {}

-- ===========================================================================
-- Внутренние функции (Private/Protected)
-- ===========================================================================

--- Возвращает модуль Logger (ленивая загрузка)
--- @private
--- @return Logger|nil
local function _get_logger()
    if Logger then return Logger end
    Logger = ModuleManager.get_module("logger")
    return Logger
end

--- Инициализирует структуру конфигурации значениями по умолчанию из схемы.
--- @private
local function _init_defaults()
    for section_name, section_rules in pairs(MonitorConfig.ValidationSchema) do
        MonitorConfig[section_name] = {}
        for key, rule in pairs(section_rules) do
            MonitorConfig[section_name][key] = rule.default
        end
    end
end

--- Загружает конфигурацию из внешних JSON файлов.
--- Сначала загружается локальный конфиг библиотеки, затем накладывается глобальный конфиг Astra.
--- @private
local function _load_from_file()
    local log = _get_logger()
    if not json_load then
        if log then log.error(COMPONENT_NAME, "json.load недоступен для загрузки конфигурации") end
        return
    end

    -- 1. Загрузка основного конфига библиотеки
    local success, data = pcall(json_load, CONFIG_PATH)
    if success and type(data) == "table" then
        -- Маппинг сгруппированного JSON на структуру MonitorConfig
        for section_name, section_data in pairs(data) do
            if MonitorConfig.ValidationSchema[section_name] and type(section_data) == "table" then
                for key, value in pairs(section_data) do
                    if MonitorConfig.ValidationSchema[section_name][key] then
                        MonitorConfig[section_name][key] = value
                    else
                        if log then log.warning(COMPONENT_NAME, "Неизвестный ключ конфигурации в секции ", section_name, " в ", CONFIG_PATH, ": ", key) end
                    end
                end
            else
                if log then log.warning(COMPONENT_NAME, "Неизвестная секция конфигурации в ", CONFIG_PATH, ": ", section_name) end
            end
        end
    elseif success and data == nil then
        if log then log.info(COMPONENT_NAME, "Файл конфигурации не найден или пуст: ", CONFIG_PATH) end
    else
        if log then log.error(COMPONENT_NAME, "Ошибка загрузки или парсинга JSON в ", CONFIG_PATH, ": ", data) end
    end

end

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- Перезагружает конфигурацию из файлов и выполняет валидацию.
--- @return boolean success Статус успеха
--- @return string|nil error_message Сообщение об ошибке при неудаче
function MonitorConfig.reload()
    _init_defaults()
    _load_from_file()
    _state.cache = {} -- Сброс кэша при перезагрузке
    _state.environment_cache = nil -- Сброс кэша окружения при перезагрузке

    -- Автоматическая настройка уровней логирования для режима разработки
    if MonitorConfig.is_development() then
        MonitorConfig.Logger.LogLevel = "DEBUG"
    end

    return MonitorConfig.validate()
end

--- Валидирует текущую конфигурацию на соответствие типам и диапазонам.
--- @return boolean success Статус валидности
--- @return string|nil error_message Описание первой найденной ошибки
function MonitorConfig.validate()
    local schema = MonitorConfig.ValidationSchema
    if not schema then return true end

    for section_name, section_rules in pairs(schema) do
        local section = MonitorConfig[section_name]
        if type(section) == "table" then
            for key, rule in pairs(section_rules) do
                local value = section[key]
                if value ~= nil then
                    if type(value) ~= rule.type then
                        return false, string_format(
                            "Parameter '%s.%s' must be a %s, got %s",
                            section_name, key, rule.type, type(value)
                        )
                    end

                    if rule.type == "number" then
                        if rule.min and value < rule.min then
                            return false, string_format(
                                "Parameter '%s.%s' is too small (min: %s)",
                                section_name, key, tostring(rule.min)
                            )
                        end
                        if rule.max and value > rule.max then
                            return false, string_format(
                                "Parameter '%s.%s' is too large (max: %s)",
                                section_name, key, tostring(rule.max)
                            )
                        end
                    elseif rule.type == "string" and rule.enum then
                        if not rule.enum[value] then
                            return false, string_format(
                                "Invalid value for '%s.%s': %s",
                                section_name, key, tostring(value)
                            )
                        end
                    end
                end
            end
        end
    end

    return true
end

--- Возвращает значение из кэша или генерирует новое, если кэш просрочен.
--- @param key string Уникальный ключ кэша
--- @param generator function Функция для генерации значения при промахе
--- @return any Значение из кэша или сгенерированное
function MonitorConfig.get_cached(key, generator)
    local now = os_time()
    if _state.cache_timestamp + _state.cache_ttl < now then
        _state.cache = {}
        _state.cache_timestamp = now
    end

    if _state.cache[key] == nil then
        _state.cache[key] = generator()
    end

    return _state.cache[key]
end

--- Возвращает человекочитаемое имя потока по его IP-адресу.
--- Использует кэширование для оптимизации частых вызовов.
--- @param ip string IP-адрес
--- @return string Имя потока или исходный IP
function MonitorConfig.get_stream_name_cached(ip)
    return MonitorConfig.get_cached("stream_" .. ip, function()
        return MonitorConfig.STREAM[ip] or ip
    end)
end

--- Определяет текущее окружение системы на основе файла /opt/astra/environment.
--- Результат кэшируется.
--- @return string "development" или "production"
function MonitorConfig.get_environment()
    if _state.environment_cache then
        return _state.environment_cache
    end

    local env_file = io_open("/opt/astra/environment", "r")
    if env_file then
        local content = env_file:read("*all")
        env_file:close()
        if content then
            _state.environment_cache = content:gsub("%s+", ""):lower()
            return _state.environment_cache
        end
    end
    _state.environment_cache = "production"
    return _state.environment_cache
end

--- Проверяет, запущена ли система в режиме разработки.
--- @return boolean true если разработка
function MonitorConfig.is_development()
    return MonitorConfig.get_environment() == "development"
end

--- Обновляет параметры конфигурации в рантайме.
--- @param params table Таблица новых параметров (может быть плоской или сгруппированной)
--- @return boolean success Статус выполнения
--- @return string|nil error_message Сообщение об ошибке
function MonitorConfig.update(params)
    if type(params) ~= "table" then return false, "Параметры должны быть таблицей" end

    local schema = MonitorConfig.ValidationSchema
    if not schema then return false, "Схема валидации отсутствует" end

    local updated_sections = {}

    -- 1. Валидация и применение
    for k, v in pairs(params) do
        if type(v) == "table" and schema[k] then
            -- Сгруппированные параметры
            for sub_k, sub_v in pairs(v) do
                local rule = schema[k][sub_k]
                if rule then
                    -- Полная валидация по правилу
                    if type(sub_v) ~= rule.type then
                        return false, string_format(
                            "Параметр '%s.%s' должен быть %s, получено %s",
                            k, sub_k, rule.type, type(sub_v)
                        )
                    end
                    if rule.type == "number" then
                        if rule.min and sub_v < rule.min then
                            return false, string_format("Параметр '%s.%s' слишком мал (min: %s)",
                                k, sub_k, tostring(rule.min))
                        end
                        if rule.max and sub_v > rule.max then
                            return false, string_format("Параметр '%s.%s' слишком велик (max: %s)",
                                k, sub_k, tostring(rule.max))
                        end
                    elseif rule.type == "string" and rule.enum then
                        if not rule.enum[sub_v] then
                            return false, string_format("Недопустимое значение для '%s.%s': %s",
                                k, sub_k, tostring(sub_v))
                        end
                    end
                    updated_sections[k] = true
                    MonitorConfig[k][sub_k] = sub_v
                end
            end
        else
            -- Плоские параметры (поиск по секциям)
            for section_name, section_rules in pairs(schema) do
                local rule = section_rules[k]
                if rule then
                    if type(v) ~= rule.type then
                        return false, string_format("Параметр '%s' должен быть %s, получено %s", k, rule.type, type(v))
                    end
                    if rule.type == "number" then
                        if rule.min and v < rule.min then
                            return false, string_format("Параметр '%s' слишком мал (min: %s)",
                                k, tostring(rule.min))
                        end
                        if rule.max and v > rule.max then
                            return false, string_format("Параметр '%s' слишком велик (max: %s)",
                                k, tostring(rule.max))
                        end
                    elseif rule.type == "string" and rule.enum then
                        if not rule.enum[v] then
                            return false, string_format("Недопустимое значение для '%s': %s",
                                k, tostring(v))
                        end
                    end
                    updated_sections[section_name] = true
                    MonitorConfig[section_name][k] = v
                    break
                end
            end
        end
    end

    if not EventDispatcher then
        EventDispatcher = ModuleManager.get_module("core.event_dispatcher")
    end

    -- 2. Рассылка событий об обновлении секций
    if EventDispatcher then
        for section_name in pairs(updated_sections) do
            EventDispatcher:emit_safe("config:updated:" .. section_name:lower(), MonitorConfig[section_name])
        end
    end

    _state.cache = {} -- Сброс кэша

    local log = _get_logger()
    if log and log.info then
        log.info(COMPONENT_NAME, "Конфигурация обновлена через API")
    end

    return true
end

--- Сохраняет текущую конфигурацию в JSON файл.
--- Исключает служебные поля, такие как ValidationSchema и функции.
--- @return boolean success Статус выполнения
function MonitorConfig.save()
    local log = _get_logger()
    if not json_save then
        if log then log.error(COMPONENT_NAME, "json.save недоступен для сохранения конфигурации") end
        return false
    end

    local data_to_save = {}
    -- Сохраняем в сгруппированном виде
    for section_name, section_rules in pairs(MonitorConfig.ValidationSchema) do
        local section = MonitorConfig[section_name]
        if type(section) == "table" then
            data_to_save[section_name] = {} -- Создаем таблицу для секции
            for k, v in pairs(section) do
                -- Сохраняем только те ключи, которые есть в схеме валидации
                if section_rules[k] then
                    data_to_save[section_name][k] = v -- Присваиваем вложенной таблице секции
                end
            end
        end
    end

    local ok, err = pcall(json_save, CONFIG_PATH, data_to_save)
    if not ok then
        if log then log.error(COMPONENT_NAME, "Ошибка сохранения конфигурации в файл: ", CONFIG_PATH, " Ошибка: ", err) end
        return false
    end

    if log then log.info(COMPONENT_NAME, "Конфигурация успешно сохранена в ", CONFIG_PATH) end
    return true
end

-- ===========================================================================
-- Инициализация модуля
-- ===========================================================================

-- Первичная загрузка из файлов и настройка окружения
MonitorConfig.reload()

return MonitorConfig
