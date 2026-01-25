-- ===========================================================================
-- Модуль `config.monitor_config`
--
-- Централизованное хранилище конфигурации системы мониторинга.
-- Содержит параметры логирования, сетевые настройки, лимиты ресурсов
-- и правила валидации для мониторов.
-- ===========================================================================

-- 1. Стандартные Lua функции
local io_open = _G.io.open
local os_time = _G.os.time
local pairs = _G.pairs
local pcall = _G.pcall
local tostring = _G.tostring
local type = _G.type
local string_format = _G.string.format

-- 2. Функции из ModuleManager.get_module()
local ModuleManager = _G.ModuleManager

-- 3. Глобальные зависимости Astra
-- (Глобальные зависимости загружаются динамически в _load_from_file)

-- 4. Константы и конфигурации
local COMPONENT_NAME = "MonitorConfig"
local CONFIG_PATH = "/opt/astra/lib-monitor/config.json"
local GLOBAL_CONFIG_PATH = "/opt/config.json"

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
local _state = {
    cache = {},
    cache_ttl = 60,
    cache_timestamp = 0
}

--- @class MonitorConfig
local MonitorConfig = {}

-- ===========================================================================
-- Конфигурация по умолчанию (Сгруппированная)
-- ===========================================================================

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

-- Секции конфигурации
MonitorConfig.Logger = {
    LogLevel = "INFO",
    LogFormat = "TEXT",
    LogBatchEnabled = false,
    LogBufferSize = 0,
    MaxLogQueueSize = 200,
    MaxLogComponents = 100,
}

MonitorConfig.Network = {
    MaxPayloadSize = 1024 * 1024, -- 1MB
    CorsAllowOrigin = "*",
    HttpTimeout = 10,
    RateLimitWindow = 60,
    RateLimitMaxRequests = 100,
    MaxRetryQueueSize = 500,
    MaxRetries = 5,
    RetryDelay = 5,
    MaxRouteCacheSize = 1000,
}

MonitorConfig.Monitor = {
    ChannelMonitorLimit = 200,
    DvbMonitorLimit = 20,
    MaxMonitorNameLength = 64,
    MinRate = 0.001,
    MaxRate = 0.3,
    MinTimeCheck = 0,
    MaxTimeCheck = 300,
    MinMethodComparison = 1,
    MaxMethodComparison = 8,
    ChannelCcThreshold = 1,
    ForceSendInterval = 300,
}

MonitorConfig.System = {
    GcPause = 100,
    GcStepMul = 500,
    MemoryLimitMb = 50,
    SchedulerInterval = 1,
    CpuThreshold = 90,
    RamThresholdPct = 80,
    FdThreshold = 800,
    HysteresisFactor = 0.95,
    NetworkCheckInterval = 30,
    ConfigRefreshInterval = 10,
    AdaptiveTickThresholdCpu = 50,
    AdaptiveTickThresholdRam = 70,
    TickIntervalNormal = 5,
    TickIntervalFast = 1,
    RareMetricInterval = 5,
    MaxCpuJump = 50,
    MaxRamJumpPct = 20,
    CpuMovingAverageWindow = 5,
    ResourceMonitorEnabled = true,
}

MonitorConfig.Recovery = {
    AutoRecoverEnabled = false,
    AutoRecoverInterval = 300,
    MaxRecoveryAttempts = 3,
    RecoveryCooldown = 3600,
}

MonitorConfig.Event = {
    LvcTtl = 3600,
    MaxLvcSize = 1000,
    MaxQueueSize = 1000,
    EventBatchLimit = 100,
    MaxBatchLimit = 1000,
}

MonitorConfig.Batch = {
    BatchEnabled = false,
    BatchFlushInterval = 0.5,
    BatchMaxSize = 50,
    DefaultBatchMode = "single",
}

MonitorConfig.Pool = {
    MaxPoolSize = 100,
    PoolLimits = {},
    PoolDebug = false,
    PoolAdaptiveThreshold = 0.2,
    PoolAdaptiveStep = 0.25,
    PoolMinLimit = 10,
    PoolMaintenanceInterval = 300,
    MaxCacheSize = {
        wildcard = 1000,
        filter_engine = 500,
        subscription_routes = 1000
    },
}

MonitorConfig.Watchdog = {
    WatchdogEnabled = false,
    WatchdogMaxRetries = 3,
    WatchdogInterval = 5,
    WatchdogThreshold = 15,
    WatchdogCasThreshold = 60,
}

MonitorConfig.Instance = {
    channel_rate = 0.035,
    channel_time_check = 0,
    channel_analyze = false,
    channel_method_comparison = 2,
    channel_cc_threshold = 1,
    channel_cc_limit = 0,
    channel_bitrate_limit = 0,
    channel_join_pid = false,
    dvb_time_check = 10,
    dvb_rate = 0.015,
    dvb_method_comparison = 2,
    dvb_analyze = true,
    channel_watchdog_enabled = false,
    channel_watchdog_timeout = 15,
    channel_watchdog_cas_timeout = 60,
}

-- Служебные данные
MonitorConfig.PidStatsLimit = 100
MonitorConfig.MaxCounterValue = 1000000000
MonitorConfig.MaxErrorCount = 1000000
MonitorConfig.subscribers = {}

-- ===========================================================================
-- Внутренние функции (Private/Protected)
-- ===========================================================================

--- Загружает конфигурацию из внешних JSON файлов.
--- Сначала загружается локальный конфиг библиотеки, затем накладывается глобальный конфиг Astra.
--- @private
local function _load_from_file()
    if not ModuleManager then return end
    local json_decode = ModuleManager.get_global_dependency("json.decode")
    if not json_decode then return end

    -- 1. Загрузка основного конфига библиотеки
    local f = io_open(CONFIG_PATH, "rb")
    if f then
        local content = f:read("*all")
        f:close()
        if content and content ~= "" then
            local success, data = pcall(json_decode, content)
            if success and type(data) == "table" then
                -- Маппинг плоского JSON на сгруппированную структуру
                for k, v in pairs(data) do
                    local found = false
                    for section_name, section in pairs(MonitorConfig) do
                        if type(section) == "table" and section_name ~= "ValidationSchema" and section_name ~= "STREAM" then
                            if section[k] ~= nil or (MonitorConfig.ValidationSchema[section_name] and MonitorConfig.ValidationSchema[section_name][k]) then
                                section[k] = v
                                found = true
                                break
                            end
                        end
                    end
                    -- Если не нашли в секциях, проверяем корень (для обратной совместимости или служебных полей)
                    if not found and MonitorConfig[k] ~= nil then
                        MonitorConfig[k] = v
                    end
                end
            end
        end
    end

    -- 2. Загрузка глобального конфига для Middleware (CORS и др.)
    local global_f = io_open(GLOBAL_CONFIG_PATH, "rb")
    if global_f then
        local content = global_f:read("*all")
        global_f:close()
        if content and content ~= "" then
            local success, data = pcall(json_decode, content)
            if success and type(data) == "table" then
                if data.cors_allow_origin then
                    MonitorConfig.Network.CorsAllowOrigin = data.cors_allow_origin
                end
            end
        end
    end
end

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- Перезагружает конфигурацию из файлов и выполняет валидацию.
--- @return boolean success Статус успеха
--- @return string|nil error_message Сообщение об ошибке при неудаче
function MonitorConfig.reload()
    _load_from_file()
    _state.cache = {} -- Сброс кэша при перезагрузке
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
                        return false, string_format("Parameter '%s.%s' must be a %s, got %s", section_name, key, rule.type, type(value))
                    end

                    if rule.type == "number" then
                        if rule.min and value < rule.min then
                            return false, string_format("Parameter '%s.%s' is too small (min: %s)", section_name, key, tostring(rule.min))
                        end
                        if rule.max and value > rule.max then
                            return false, string_format("Parameter '%s.%s' is too large (max: %s)", section_name, key, tostring(rule.max))
                        end
                    elseif rule.type == "string" and rule.enum then
                        if not rule.enum[value] then
                            return false, string_format("Invalid value for '%s.%s': %s", section_name, key, tostring(value))
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
--- @return string "development" или "production"
function MonitorConfig.get_environment()
    local env_file = io_open("/opt/astra/environment", "r")
    if env_file then
        local content = env_file:read("*all")
        env_file:close()
        if content then
            return content:gsub("%s+", ""):lower()
        end
    end
    return "production"
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
                    if type(sub_v) ~= rule.type then
                        return false, string_format("Параметр '%s.%s' должен быть %s, получено %s", k, sub_k, rule.type, type(sub_v))
                    end
                    MonitorConfig[k][sub_k] = sub_v
                    updated_sections[k] = true
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
                    MonitorConfig[section_name][k] = v
                    updated_sections[section_name] = true
                    break
                end
            end
        end
    end

    -- 2. Рассылка событий об обновлении секций
    if _G.EventDispatcher then
        for section_name in pairs(updated_sections) do
            _G.EventDispatcher:emit_safe("config:updated:" .. section_name:lower(), MonitorConfig[section_name])
        end
    end

    _state.cache = {} -- Сброс кэша
    
    local Logger = ModuleManager.get_module("logger")
    if Logger and Logger.info then
        Logger.info(COMPONENT_NAME, "Конфигурация обновлена через API")
    end
    
    return true
end

--- Сохраняет текущую конфигурацию в JSON файл.
--- Исключает служебные поля, такие как ValidationSchema и функции.
--- @return boolean success Статус выполнения
function MonitorConfig.save()
    if not ModuleManager then return false end
    local json_encode = ModuleManager.get_global_dependency("json.encode")
    if not json_encode then return false end

    local data_to_save = {}
    -- Сохраняем в плоском виде для совместимости с существующими конфигами
    for section_name, section in pairs(MonitorConfig) do
        if type(section) == "table" and section_name ~= "ValidationSchema" and section_name ~= "STREAM" then
            for k, v in pairs(section) do
                data_to_save[k] = v
            end
        end
    end
    
    -- Добавляем служебные поля из корня
    data_to_save.PidStatsLimit = MonitorConfig.PidStatsLimit
    data_to_save.MaxCounterValue = MonitorConfig.MaxCounterValue
    data_to_save.MaxErrorCount = MonitorConfig.MaxErrorCount

    local ok, content = pcall(json_encode, data_to_save)
    if not ok then return false end

    local f = io_open(CONFIG_PATH, "w")
    if not f then return false end

    f:write(content)
    f:close()
    return true
end

-- ===========================================================================
-- Схема валидации (Сгруппированная)
-- ===========================================================================

MonitorConfig.ValidationSchema = {
    Logger = {
        LogLevel = { type = "string", enum = {DEBUG=true, INFO=true, WARN=true, ERROR=true, NONE=true}, default = "INFO" },
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
        MinRate = { type = "number", min = 0.0001, max = 1, default = 0.001 },
        MaxRate = { type = "number", min = 0.001, max = 1, default = 0.3 },
        MinTimeCheck = { type = "number", min = 0, max = 3600, default = 0 },
        MaxTimeCheck = { type = "number", min = 1, max = 3600, default = 300 },
        MinMethodComparison = { type = "number", min = 1, max = 10, default = 1 },
        MaxMethodComparison = { type = "number", min = 1, max = 10, default = 8 },
        ChannelCcThreshold = { type = "number", min = 0, max = 65535, default = 1 },
        ForceSendInterval = { type = "number", min = 1, max = 3600, default = 300 },
    },
    System = {
        GcPause = { type = "number", min = 10, max = 1000, default = 100 },
        GcStepMul = { type = "number", min = 10, max = 1000, default = 500 },
        MemoryLimitMb = { type = "number", min = 1, max = 1024, default = 50 },
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
    }
}

-- ===========================================================================
-- Инициализация модуля
-- ===========================================================================

-- Первичная загрузка из файлов
_load_from_file()

-- Автоматическая настройка уровней логирования для режима разработки
if MonitorConfig.is_development() then
    MonitorConfig.Logger.LogLevel = "DEBUG"
end

return MonitorConfig
