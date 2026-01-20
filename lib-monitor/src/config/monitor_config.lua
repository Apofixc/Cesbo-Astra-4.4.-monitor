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
-- Конфигурация по умолчанию
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

-- Логирование
MonitorConfig.LogLevel = "INFO"
MonitorConfig.LogFormat = "TEXT"
MonitorConfig.LogBatchEnabled = false
MonitorConfig.LogBufferSize = 0
MonitorConfig.MaxLogQueueSize = 200
MonitorConfig.MaxLogComponents = 100

-- Сеть и HTTP
MonitorConfig.MaxPayloadSize = 1024 * 1024 -- 1MB
MonitorConfig.CorsAllowOrigin = "*"
MonitorConfig.HttpTimeout = 10
MonitorConfig.RateLimitWindow = 60
MonitorConfig.RateLimitMaxRequests = 100
MonitorConfig.MaxRetryQueueSize = 500
MonitorConfig.MaxRetries = 5
MonitorConfig.RetryDelay = 5
MonitorConfig.MaxRouteCacheSize = 1000

-- Лимиты мониторов
MonitorConfig.ChannelMonitorLimit = 200
MonitorConfig.DvbMonitorLimit = 20
MonitorConfig.MaxMonitorNameLength = 64
MonitorConfig.MinRate = 0.001
MonitorConfig.MaxRate = 0.3
MonitorConfig.MinTimeCheck = 0
MonitorConfig.MaxTimeCheck = 300
MonitorConfig.MinMethodComparison = 1
MonitorConfig.MaxMethodComparison = 8
MonitorConfig.ChannelCcThreshold = 1
MonitorConfig.ForceSendInterval = 300

-- Системные ресурсы и GC
MonitorConfig.GcPause = 100
MonitorConfig.GcStepMul = 500
MonitorConfig.MemoryLimitMb = 50
MonitorConfig.SchedulerInterval = 1
MonitorConfig.CpuThreshold = 90
MonitorConfig.RamThresholdPct = 80
MonitorConfig.FdThreshold = 800
MonitorConfig.HysteresisFactor = 0.95
MonitorConfig.NetworkCheckInterval = 30
MonitorConfig.ConfigRefreshInterval = 10
MonitorConfig.AdaptiveTickThresholdCpu = 50
MonitorConfig.AdaptiveTickThresholdRam = 70
MonitorConfig.TickIntervalNormal = 5
MonitorConfig.TickIntervalFast = 1
MonitorConfig.RareMetricInterval = 5
MonitorConfig.MaxCpuJump = 50
MonitorConfig.MaxRamJumpPct = 20
MonitorConfig.CpuMovingAverageWindow = 5

-- Восстановление
MonitorConfig.AutoRecoverEnabled = false
MonitorConfig.AutoRecoverInterval = 300
MonitorConfig.MaxRecoveryAttempts = 3
MonitorConfig.RecoveryCooldown = 3600

-- События и LVC
MonitorConfig.LvcTtl = 3600
MonitorConfig.MaxLvcSize = 1000
MonitorConfig.MaxQueueSize = 1000
MonitorConfig.EventBatchLimit = 100
MonitorConfig.MaxBatchLimit = 1000

-- Пакетная отправка
MonitorConfig.BatchEnabled = false
MonitorConfig.BatchFlushInterval = 0.5
MonitorConfig.BatchMaxSize = 50
MonitorConfig.DefaultBatchMode = "single"

-- Пулы и кэши
MonitorConfig.MaxPoolSize = 100
MonitorConfig.PoolLimits = {}
MonitorConfig.PoolDebug = false
MonitorConfig.PoolAdaptiveThreshold = 0.2
MonitorConfig.PoolAdaptiveStep = 0.25
MonitorConfig.PoolMinLimit = 10
MonitorConfig.PoolMaintenanceInterval = 300
MonitorConfig.MaxCacheSize = {
    wildcard = 1000,
    filter_engine = 500,
    subscription_routes = 1000
}

-- Данные
MonitorConfig.PidStatsLimit = 100
MonitorConfig.MaxCounterValue = 1000000000
MonitorConfig.MaxErrorCount = 1000000
MonitorConfig.subscribers = {}

-- Watchdog
MonitorConfig.WatchdogEnabled = false
MonitorConfig.WatchdogMaxRetries = 3
MonitorConfig.WatchdogInterval = 5
MonitorConfig.WatchdogThreshold = 15
MonitorConfig.WatchdogCasThreshold = 60

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

    -- 0. Инициализация значений по умолчанию из схемы (если они еще не установлены)
    if MonitorConfig.ValidationSchema then
        for key, rule in pairs(MonitorConfig.ValidationSchema) do
            if MonitorConfig[key] == nil and rule.default ~= nil then
                MonitorConfig[key] = rule.default
            end
        end
    end

    -- 1. Загрузка основного конфига библиотеки
    local f = io_open(CONFIG_PATH, "rb")
    if f then
        local content = f:read("*all")
        f:close()
        if content and content ~= "" then
            local success, data = pcall(json_decode, content)
            if success and type(data) == "table" then
                for k, v in pairs(data) do
                    -- Обновляем ключи, которые есть в схеме или уже в конфиге
                    if MonitorConfig[k] ~= nil or (MonitorConfig.ValidationSchema and MonitorConfig.ValidationSchema[k]) then
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
                    MonitorConfig.CorsAllowOrigin = data.cors_allow_origin
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

    for key, rule in pairs(schema) do
        local value = MonitorConfig[key]
        -- Пропускаем параметры, которые предназначены только для экземпляров мониторов
        -- (они начинаются с channel_ или dvb_ и отсутствуют в глобальном MonitorConfig)
        if value ~= nil then
            if type(value) ~= rule.type then
                return false, string.format("Parameter '%s' must be a %s, got %s", key, rule.type, type(value))
            end

            if rule.type == "number" then
                if rule.min and value < rule.min then
                    return false, string.format("Parameter '%s' is too small (min: %s)", key, tostring(rule.min))
                end
                if rule.max and value > rule.max then
                    return false, string.format("Parameter '%s' is too large (max: %s)", key, tostring(rule.max))
                end
            elseif rule.type == "string" and rule.enum then
                if not rule.enum[value] then
                    return false, string.format("Invalid value for '%s': %s", key, tostring(value))
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
--- @param params table Таблица новых параметров
--- @return boolean success Статус выполнения
--- @return string|nil error_message Сообщение об ошибке
function MonitorConfig.update(params)
    if type(params) ~= "table" then return false, "Параметры должны быть таблицей" end

    local schema = MonitorConfig.ValidationSchema
    if not schema then return false, "Схема валидации отсутствует" end

    -- 1. Предварительная валидация всех параметров
    for key, value in pairs(params) do
        local rule = schema[key]
        if rule then
            if type(value) ~= rule.type then
                return false, string.format("Параметр '%s' должен быть %s, получено %s", key, rule.type, type(value))
            end
            if rule.type == "number" then
                if rule.min and value < rule.min then
                    return false, string.format("Параметр '%s' слишком мал (min: %s)", key, tostring(rule.min))
                end
                if rule.max and value > rule.max then
                    return false, string.format("Параметр '%s' слишком велик (max: %s)", key, tostring(rule.max))
                end
            elseif rule.type == "string" and rule.enum then
                if not rule.enum[value] then
                    return false, string.format("Недопустимое значение для '%s': %s", key, tostring(value))
                end
            end
        end
    end

    -- 2. Применение параметров
    for key, value in pairs(params) do
        if schema[key] then
            MonitorConfig[key] = value
        end
    end

    -- 3. Уведомление зависимых модулей об изменениях
    local Logger = ModuleManager.get_module("logger")
    if Logger and Logger.refresh_log_level then
        Logger.refresh_log_level()
    end

    -- Обновление настроек в репозиториях
    local ChannelRepository = ModuleManager.get_module("channel_repository")
    if ChannelRepository and ChannelRepository.update_settings then
        ChannelRepository:update_settings(params)
    end

    local DvbRepository = ModuleManager.get_module("dvb_repository")
    if DvbRepository and DvbRepository.update_settings then
        DvbRepository:update_settings(params)
    end

    _state.cache = {} -- Сброс кэша
    Logger.info(COMPONENT_NAME, "Конфигурация обновлена через API")
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
    for k, v in pairs(MonitorConfig) do
        if k ~= "ValidationSchema" and type(v) ~= "function" then
            data_to_save[k] = v
        end
    end

    local ok, content = pcall(json_encode, data_to_save)
    if not ok then return false end

    local f = io_open(CONFIG_PATH, "w")
    if not f then return false end

    f:write(content)
    f:close()
    return true
end

-- [ Схема валидации для параметров мониторов ]

--- Схема валидации для параметров мониторов.
--- Используется в BaseMonitor для проверки входящих настроек конкретных экземпляров,
--- а также в MonitorConfig.validate() для проверки глобальных настроек.
--- @type table<string, ValidationRule>
MonitorConfig.ValidationSchema = {
    -- 1. Логирование
    LogLevel = {
        type = "string",
        enum = {DEBUG=true, INFO=true, WARN=true, ERROR=true, NONE=true},
        default = "INFO"
    },
    LogFormat = {
        type = "string",
        enum = {TEXT=true, JSON=true},
        default = "TEXT"
    },
    LogBatchEnabled = {
        type = "boolean",
        default = false
    },
    LogBufferSize = {
        type = "number",
        min = 0,
        max = 1024 * 1024,
        default = 0
    },
    MaxLogQueueSize = {
        type = "number",
        min = 1,
        max = 10000,
        default = 200
    },
    MaxLogComponents = {
        type = "number",
        min = 1,
        max = 1000,
        default = 100
    },

    -- 2. Сеть и HTTP
    MaxPayloadSize = {
        type = "number",
        min = 1024,
        max = 10 * 1024 * 1024,
        default = 1024 * 1024
    },
    CorsAllowOrigin = {
        type = "string",
        default = "*"
    },
    HttpTimeout = {
        type = "number",
        min = 1,
        max = 300,
        default = 10
    },
    RateLimitWindow = {
        type = "number",
        min = 1,
        max = 3600,
        default = 60
    },
    RateLimitMaxRequests = {
        type = "number",
        min = 1,
        max = 10000,
        default = 100
    },
    MaxRetryQueueSize = {
        type = "number",
        min = 1,
        max = 10000,
        default = 500
    },
    MaxRetries = {
        type = "number",
        min = 0,
        max = 100,
        default = 5
    },
    RetryDelay = {
        type = "number",
        min = 1,
        max = 3600,
        default = 5
    },
    MaxRouteCacheSize = {
        type = "number",
        min = 1,
        max = 10000,
        default = 1000
    },

    -- 3. Лимиты мониторов
    ChannelMonitorLimit = {
        type = "number",
        min = 1,
        max = 1000,
        default = 200
    },
    DvbMonitorLimit = {
        type = "number",
        min = 1,
        max = 100,
        default = 20
    },
    MaxMonitorNameLength = {
        type = "number",
        min = 1,
        max = 256,
        default = 64
    },
    MinRate = {
        type = "number",
        min = 0.0001,
        max = 1,
        default = 0.001
    },
    MaxRate = {
        type = "number",
        min = 0.001,
        max = 1,
        default = 0.3
    },
    MinTimeCheck = {
        type = "number",
        min = 0,
        max = 3600,
        default = 0
    },
    MaxTimeCheck = {
        type = "number",
        min = 1,
        max = 3600,
        default = 300
    },
    MinMethodComparison = {
        type = "number",
        min = 1,
        max = 10,
        default = 1
    },
    MaxMethodComparison = {
        type = "number",
        min = 1,
        max = 10,
        default = 8
    },
    ChannelCcThreshold = {
        type = "number",
        min = 0,
        max = 65535,
        default = 1
    },
    ForceSendInterval = {
        type = "number",
        min = 1,
        max = 3600,
        default = 300
    },

    -- 4. Системные ресурсы и GC
    GcPause = {
        type = "number",
        min = 10,
        max = 1000,
        default = 100
    },
    GcStepMul = {
        type = "number",
        min = 10,
        max = 1000,
        default = 500
    },
    MemoryLimitMb = {
        type = "number",
        min = 1,
        max = 1024,
        default = 50
    },
    SchedulerInterval = {
        type = "number",
        min = 0.1,
        max = 60,
        default = 1
    },
    CpuThreshold = {
        type = "number",
        min = 1,
        max = 100,
        default = 90
    },
    RamThresholdPct = {
        type = "number",
        min = 1,
        max = 100,
        default = 80
    },
    FdThreshold = {
        type = "number",
        min = 1,
        max = 10000,
        default = 800
    },
    HysteresisFactor = {
        type = "number",
        min = 0.5,
        max = 0.99,
        default = 0.95
    },
    NetworkCheckInterval = {
        type = "number",
        min = 1,
        max = 3600,
        default = 30
    },
    ConfigRefreshInterval = {
        type = "number",
        min = 1,
        max = 3600,
        default = 10
    },
    AdaptiveTickThresholdCpu = {
        type = "number",
        min = 1,
        max = 100,
        default = 50
    },
    AdaptiveTickThresholdRam = {
        type = "number",
        min = 1,
        max = 100,
        default = 70
    },
    TickIntervalNormal = {
        type = "number",
        min = 0.1,
        max = 60,
        default = 5
    },
    TickIntervalFast = {
        type = "number",
        min = 0.1,
        max = 60,
        default = 1
    },
    RareMetricInterval = {
        type = "number",
        min = 1,
        max = 3600,
        default = 5
    },
    MaxCpuJump = {
        type = "number",
        min = 1,
        max = 100,
        default = 50
    },
    MaxRamJumpPct = {
        type = "number",
        min = 1,
        max = 100,
        default = 20
    },
    CpuMovingAverageWindow = {
        type = "number",
        min = 1,
        max = 100,
        default = 5
    },

    -- 5. Восстановление
    AutoRecoverEnabled = {
        type = "boolean",
        default = false
    },
    AutoRecoverInterval = {
        type = "number",
        min = 1,
        max = 3600,
        default = 300
    },
    MaxRecoveryAttempts = {
        type = "number",
        min = 1,
        max = 100,
        default = 3
    },
    RecoveryCooldown = {
        type = "number",
        min = 1,
        max = 86400,
        default = 3600
    },

    -- 6. События и LVC
    LvcTtl = {
        type = "number",
        min = 1,
        max = 86400,
        default = 3600
    },
    MaxLvcSize = {
        type = "number",
        min = 1,
        max = 10000,
        default = 1000
    },
    MaxQueueSize = {
        type = "number",
        min = 1,
        max = 10000,
        default = 1000
    },
    EventBatchLimit = {
        type = "number",
        min = 1,
        max = 1000,
        default = 100
    },
    MaxBatchLimit = {
        type = "number",
        min = 1,
        max = 10000,
        default = 1000
    },

    -- 7. Пакетная отправка
    BatchEnabled = {
        type = "boolean",
        default = true
    },
    BatchFlushInterval = {
        type = "number",
        min = 0.01,
        max = 60,
        default = 0.5
    },
    BatchMaxSize = {
        type = "number",
        min = 1,
        max = 1000,
        default = 50
    },
    DefaultBatchMode = {
        type = "string",
        enum = {single=true, array=true},
        default = "single"
    },

    -- 8. Пулы и кэши
    MaxPoolSize = {
        type = "number",
        min = 1,
        max = 10000,
        default = 100
    },
    PoolDebug = {
        type = "boolean",
        default = false
    },
    PoolAdaptiveThreshold = {
        type = "number",
        min = 0.01,
        max = 1,
        default = 0.2
    },
    PoolAdaptiveStep = {
        type = "number",
        min = 0.01,
        max = 1,
        default = 0.25
    },
    PoolMinLimit = {
        type = "number",
        min = 1,
        max = 1000,
        default = 10
    },
    PoolMaintenanceInterval = {
        type = "number",
        min = 1,
        max = 3600,
        default = 300
    },

    -- 9. Данные
    PidStatsLimit = {
        type = "number",
        min = 1,
        max = 8192,
        default = 100
    },
    MaxCounterValue = {
        type = "number",
        min = 1,
        max = 1000000000000,
        default = 1000000000
    },
    MaxErrorCount = {
        type = "number",
        min = 1,
        max = 1000000000,
        default = 1000000
    },

    -- 10. Watchdog
    WatchdogEnabled = {
        type = "boolean",
        default = false
    },
    WatchdogMaxRetries = {
        type = "number",
        min = 1,
        max = 100,
        default = 3
    },
    WatchdogInterval = {
        type = "number",
        min = 1,
        max = 3600,
        default = 5
    },
    WatchdogThreshold = {
        type = "number",
        min = 1,
        max = 3600,
        default = 15
    },
    WatchdogCasThreshold = {
        type = "number",
        min = 1,
        max = 3600,
        default = 60
    },

    -- 11. Параметры экземпляров (Instance Parameters)
    channel_rate = {
        type = "number",
        min = 0.0001,
        max = 1,
        default = 0.035
    },
    channel_time_check = {
        type = "number",
        min = 0,
        max = 3600,
        default = 0
    },
    channel_analyze = {
        type = "boolean",
        default = false
    },
    channel_method_comparison = {
        type = "number",
        min = 1,
        max = 8,
        default = 2
    },
    channel_cc_threshold = {
        type = "number",
        min = 0,
        max = 65535,
        default = 1
    },
    channel_cc_limit = {
        type = "number",
        min = 0,
        max = 65535,
        default = 0
    },
    channel_bitrate_limit = {
        type = "number",
        min = 0,
        max = 100000000,
        default = 0
    },
    channel_join_pid = {
        type = "boolean",
        default = false
    },
    dvb_time_check = {
        type = "number",
        min = 0,
        max = 3600,
        default = 10
    },
    dvb_rate = {
        type = "number",
        min = 0.0001,
        max = 1,
        default = 0.015
    },
    dvb_method_comparison = {
        type = "number",
        min = 1,
        max = 7,
        default = 2
    },
    dvb_analyze = {
        type = "boolean",
        default = true
    },
    channel_watchdog_enabled = {
        type = "boolean",
        default = false
    },
    channel_watchdog_timeout = {
        type = "number",
        min = 1,
        max = 3600,
        default = 15
    },
    channel_watchdog_cas_timeout = {
        type = "number",
        min = 1,
        max = 3600,
        default = 60
    }
}

-- ===========================================================================
-- Инициализация модуля
-- ===========================================================================

-- Первичная загрузка из файлов
_load_from_file()

-- Автоматическая настройка уровней логирования для режима разработки
if MonitorConfig.is_development() then
    MonitorConfig.ExtraDebug = true
    MonitorConfig.LogLevel = "DEBUG"
end

return MonitorConfig
