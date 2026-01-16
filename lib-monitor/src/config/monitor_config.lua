-- ===========================================================================
-- Модуль `config.monitor_config`
--
-- Централизованное хранилище конфигурации системы мониторинга.
-- Содержит параметры логирования, сетевые настройки, лимиты ресурсов
-- и правила валидации для мониторов.
-- ===========================================================================

-- [ 1. Стандартные Lua функции ]
local os_time = _G.os.time
local pairs = _G.pairs
local type = _G.type
local tostring = _G.tostring
local pcall = _G.pcall
local io_open = _G.io.open

-- [ 2. Функции из ModuleManager ]
local ModuleManager = _G.ModuleManager

-- [ 3. Константы ]
local CONFIG_PATH = "/opt/astra/lib-monitor/config.json"
local GLOBAL_CONFIG_PATH = "/opt/config.json"

--- @class ValidationRule
--- @field type string Тип данных ("number"|"boolean"|"string"|"table")
--- @field min number|nil Минимальное значение (для чисел)
--- @field max number|nil Максимальное значение (для чисел)
--- @field default any Значение по умолчанию

--- @class MonitorConfig
--- @field STREAM table<string, string> Карта имен потоков по их IP-адресам
--- @field LogLevel string Уровень логирования ("DEBUG"|"INFO"|"WARN"|"ERROR"|"NONE")
--- @field LogFormat string Формат логирования ("TEXT"|"JSON")
--- @field LogBatchEnabled boolean Включить пакетное логирование
--- @field LogBufferSize number Размер буфера логов (0 - выключено)
--- @field MaxPayloadSize number Максимальный размер полезной нагрузки HTTP
--- @field CorsAllowOrigin string Настройки CORS
--- @field HttpTimeout number Таймаут HTTP-запросов
--- @field ChannelMonitorLimit number Максимальное количество одновременно активных мониторов каналов
--- @field DvbMonitorLimit number Максимальное количество одновременно активных DVB-мониторов
--- @field MaxMonitorNameLength number Максимальная длина имени монитора
--- @field MinRate number Минимальное допустимое значение погрешности
--- @field MaxRate number Максимальное допустимое значение погрешности
--- @field MinTimeCheck number Минимальный интервал между проверками
--- @field MaxTimeCheck number Максимальный интервал между проверками
--- @field MinMethodComparison number Минимальное значение для метода сравнения
--- @field MaxMethodComparison number Максимальное значение для метода сравнения
--- @field ExtraDebug boolean Флаг расширенной отладки
--- @field GcPause number Параметр GC setpause (по умолчанию 100)
--- @field GcStepMul number Параметр GC setstepmul (по умолчанию 500)
--- @field SchedulerInterval number Интервал тика планировщика в секундах
--- @field MemoryLimitMb number Лимит памяти для адаптивного GC (МБ)
--- @field AutoRecoverEnabled boolean Включить автономное восстановление
--- @field AutoRecoverInterval number Интервал авто-восстановления (сек)
--- @field MaxRecoveryAttempts number Максимальное количество попыток восстановления
--- @field RecoveryCooldown number Время стабильной работы для сброса попыток (сек)
--- @field PidStatsLimit number Лимит отслеживаемых PID в ChannelMonitor
--- @field MaxCounterValue number Максимальное значение счетчиков
--- @field MaxErrorCount number Максимальное значение ошибок
--- @field LvcTtl number TTL для Last Value Cache в секундах
--- @field MaxLvcSize number Максимальный размер LVC
--- @field MaxQueueSize number Максимальный размер очереди событий
--- @field EventBatchLimit number Лимит событий за один проход очереди
--- @field MaxBatchLimit number Максимальный лимит событий при высокой нагрузке
--- @field MaxRetryQueueSize number Лимит очереди повторов HTTP
--- @field MaxRetries number Максимальное количество попыток HTTP
--- @field RetryDelay number Базовая задержка повтора HTTP (сек)
--- @field BatchEnabled boolean Включить пакетную отправку событий
--- @field BatchFlushInterval number Интервал сброса буфера в секундах
--- @field BatchMaxSize number Максимальный размер пачки событий
--- @field DefaultBatchMode string Режим по умолчанию ("single" или "array")
--- @field MaxPoolSize number Максимальный размер пула таблиц
--- @field PoolLimits table<string, number> Индивидуальные лимиты для типов пулов
--- @field PoolDebug boolean Режим отладки пулов
--- @field CpuThreshold number Порог использования CPU (%)
--- @field RamThresholdPct number Порог использования RAM (%)
--- @field FdThreshold number Порог открытых файловых дескрипторов
--- @field HysteresisFactor number Коэффициент гистерезиса для событий
--- @field NetworkCheckInterval number Интервал проверки сети (сек)
--- @field ConfigRefreshInterval number Интервал обновления кэша конфига в модулях (сек)
--- @field AdaptiveTickThresholdCpu number Порог CPU для адаптивного интервала (%)
--- @field AdaptiveTickThresholdRam number Порог RAM для адаптивного интервала (%)
--- @field TickIntervalNormal number Обычный интервал опроса ресурсов (сек)
--- @field TickIntervalFast number Ускоренный интервал опроса ресурсов (сек)
--- @field RareMetricInterval number Интервал для редких метрик (FD, Threads)
--- @field MaxCpuJump number Максимальный скачок CPU за тик (%)
--- @field MaxRamJumpPct number Максимальный скачок RAM за тик (%)
--- @field CpuMovingAverageWindow number Окно скользящего среднего для CPU
--- @field MaxCacheSize table<string, number> Лимиты кэшей для разных модулей
--- @field subscribers table<string, table[]> Список подписчиков
--- @field ValidationSchema table<string, ValidationRule> Схема валидации параметров
local MonitorConfig = {}

-- [ 4. Внутреннее состояние ]

--- @class MonitorConfigState
--- @field cache table<string, any> Кэш вычисляемых значений
--- @field cache_ttl number Время жизни кэша (сек)
--- @field cache_timestamp number Время последнего обновления кэша
local _state = {
    cache = {},
    cache_ttl = 60,
    cache_timestamp = 0
}

-- [ 5. Конфигурация по умолчанию ]

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

-- [ 6. Внутренние функции ]

--- Загружает конфигурацию из внешних JSON файлов
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

-- [ 7. Публичное API ]

--- Перезагружает конфигурацию из файлов и выполняет валидацию
--- @return boolean success, string|nil error_message
function MonitorConfig.reload()
    _load_from_file()
    _state.cache = {} -- Сброс кэша при перезагрузке
    return MonitorConfig.validate()
end

--- Валидирует текущую конфигурацию
--- @return boolean success, string|nil error_message
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

    return true
end

--- Возвращает значение из кэша или генерирует новое
--- @param key string Уникальный ключ кэша
--- @param generator function Функция для генерации значения
--- @return any Значение
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

--- Возвращает имя потока по IP с использованием кэширования
--- @param ip string IP-адрес потока
--- @return string Имя потока или IP
function MonitorConfig.get_stream_name_cached(ip)
    return MonitorConfig.get_cached("stream_" .. ip, function()
        return MonitorConfig.STREAM[ip] or ip
    end)
end

--- Возвращает текущее окружение системы
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

--- Проверяет, является ли текущее окружение средой разработки
--- @return boolean
function MonitorConfig.is_development()
    return MonitorConfig.get_environment() == "development"
end

--- Сохраняет текущую конфигурацию в JSON файл
--- @return boolean Статус выполнения
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

-- [ 8. Инициализация ]

-- Вызов загрузки при инициализации модуля
_load_from_file()

-- Настройка окружения
if MonitorConfig.is_development() then
    MonitorConfig.ExtraDebug = true
    MonitorConfig.LogLevel = "DEBUG"
end

-- [ 9. Схема валидации ]

--- Схема валидации для параметров мониторов.
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
    }
}

return MonitorConfig
