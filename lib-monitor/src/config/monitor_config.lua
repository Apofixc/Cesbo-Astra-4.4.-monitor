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
MonitorConfig.MaxMethodComparison = 4
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
MonitorConfig.BatchEnabled = true
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
-- Внутренние функции (Private)
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
                for k, v in pairs(data) do
                    -- Обновляем только существующие ключи для защиты от мусора в JSON
                    if MonitorConfig[k] ~= nil then
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
    -- 1. Логирование
    if type(MonitorConfig.LogLevel) ~= "string" then return false, "LogLevel must be a string" end
    local valid_levels = {DEBUG=true, INFO=true, WARN=true, ERROR=true, NONE=true}
    if not valid_levels[MonitorConfig.LogLevel] then
        return false, "Invalid LogLevel: " .. tostring(MonitorConfig.LogLevel)
    end

    if type(MonitorConfig.LogFormat) ~= "string" then return false, "LogFormat must be a string" end
    if type(MonitorConfig.LogBufferSize) ~= "number" or MonitorConfig.LogBufferSize < 0 then
        return false, "LogBufferSize must be a non-negative number"
    end

    -- 2. Сеть и HTTP
    if type(MonitorConfig.HttpTimeout) ~= "number" or MonitorConfig.HttpTimeout <= 0 then
        return false, "HttpTimeout must be a positive number"
    end
    if type(MonitorConfig.MaxRetries) ~= "number" or MonitorConfig.MaxRetries < 0 then
        return false, "MaxRetries must be a non-negative number"
    end

    -- 3. Лимиты мониторов
    if type(MonitorConfig.ChannelMonitorLimit) ~= "number" or MonitorConfig.ChannelMonitorLimit <= 0 then
        return false, "ChannelMonitorLimit must be a positive number"
    end
    if type(MonitorConfig.DvbMonitorLimit) ~= "number" or MonitorConfig.DvbMonitorLimit <= 0 then
        return false, "DvbMonitorLimit must be a positive number"
    end

    -- 4. Системные ресурсы
    if type(MonitorConfig.CpuThreshold) ~= "number" or MonitorConfig.CpuThreshold <= 0 or MonitorConfig.CpuThreshold > 100 then
        return false, "CpuThreshold must be between 1 and 100"
    end
    if type(MonitorConfig.RamThresholdPct) ~= "number" or MonitorConfig.RamThresholdPct <= 0 or MonitorConfig.RamThresholdPct > 100 then
        return false, "RamThresholdPct must be between 1 and 100"
    end
    if type(MonitorConfig.MemoryLimitMb) ~= "number" or MonitorConfig.MemoryLimitMb <= 0 then
        return false, "MemoryLimitMb must be a positive number"
    end

    if type(MonitorConfig.AdaptiveTickThresholdCpu) ~= "number" then return false, "AdaptiveTickThresholdCpu must be a number" end
    if type(MonitorConfig.AdaptiveTickThresholdRam) ~= "number" then return false, "AdaptiveTickThresholdRam must be a number" end
    if type(MonitorConfig.TickIntervalNormal) ~= "number" then return false, "TickIntervalNormal must be a number" end
    if type(MonitorConfig.TickIntervalFast) ~= "number" then return false, "TickIntervalFast must be a number" end
    if type(MonitorConfig.RareMetricInterval) ~= "number" then return false, "RareMetricInterval must be a number" end
    if type(MonitorConfig.MaxCpuJump) ~= "number" then return false, "MaxCpuJump must be a number" end
    if type(MonitorConfig.MaxRamJumpPct) ~= "number" then return false, "MaxRamJumpPct must be a number" end

    -- 5. Пакетная отправка
    if type(MonitorConfig.BatchMaxSize) ~= "number" or MonitorConfig.BatchMaxSize <= 0 then
        return false, "BatchMaxSize must be a positive number"
    end
    local valid_batch_modes = {single=true, array=true}
    if not valid_batch_modes[MonitorConfig.DefaultBatchMode] then
        return false, "Invalid DefaultBatchMode: " .. tostring(MonitorConfig.DefaultBatchMode)
    end

    -- 6. Пулы
    if type(MonitorConfig.PoolAdaptiveThreshold) ~= "number" then return false, "PoolAdaptiveThreshold must be a number" end
    if type(MonitorConfig.PoolAdaptiveStep) ~= "number" then return false, "PoolAdaptiveStep must be a number" end
    if type(MonitorConfig.PoolMinLimit) ~= "number" then return false, "PoolMinLimit must be a number" end
    if type(MonitorConfig.PoolMaintenanceInterval) ~= "number" then return false, "PoolMaintenanceInterval must be a number" end

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

-- [ Схема валидации для параметров мониторов ]

--- Схема валидации для параметров мониторов.
--- Используется в BaseMonitor для проверки входящих настроек конкретных экземпляров.
--- @type table<string, ValidationRule>
MonitorConfig.ValidationSchema = {
    channel_rate = {
        type = "number",
        min = MonitorConfig.MinRate,
        max = MonitorConfig.MaxRate,
        default = 0.035
    },
    channel_time_check = {
        type = "number",
        min = MonitorConfig.MinTimeCheck,
        max = MonitorConfig.MaxTimeCheck,
        default = 0
    },
    channel_analyze = {
        type = "boolean",
        default = false
    },
    channel_method_comparison = {
        type = "number",
        min = MonitorConfig.MinMethodComparison,
        max = MonitorConfig.MaxMethodComparison,
        default = 3
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
        max = 1000000,
        default = 0
    },
    channel_rate_stat = {
        type = "boolean",
        default = false
    },
    channel_join_pid = {
        type = "boolean",
        default = false
    },
    dvb_time_check = {
        type = "number",
        min = MonitorConfig.MinTimeCheck,
        max = MonitorConfig.MaxTimeCheck,
        default = 10
    },
    dvb_rate = {
        type = "number",
        min = 0.001,
        max = 1,
        default = 0.015
    },
    dvb_method_comparison = {
        type = "number",
        min = 1,
        max = 3,
        default = 3
    },
    dvb_analyze = {
        type = "boolean",
        default = true
    },
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

return MonitorConfig
