-- ===========================================================================
-- Модуль `config.monitor_config`
--
-- Содержит настраиваемые параметры, которые определяют поведение различных
-- компонентов системы мониторинга, таких как логирование и параметры
-- мониторов каналов.
-- ===========================================================================

-- 1. Стандартные Lua функции
local os_time = os.time
local pairs = pairs
local type = type
local tostring = tostring
local pcall = pcall
local io_open = io.open

-- 2. Функции из ModuleManager.get_module()
local ModuleManager = _G.ModuleManager

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Глобальные зависимости будут получены динамически при загрузке конфига

-- 4. Константы и конфигурации
local CONFIG_PATH = "/opt/astra/lib-monitor/config.json"

--- @class ValidationRule
--- @field type string Тип данных ("number"|"boolean"|"string")
--- @field min number|nil Минимальное значение (для чисел)
--- @field max number|nil Максимальное значение (для чисел)
--- @field default any Значение по умолчанию

--- @class MonitorConfig
--- @field STREAM table<string, string> Карта имен потоков по их IP-адресам
--- @field LogLevel string Уровень логирования ("DEBUG"|"INFO"|"WARN"|"ERROR"|"NONE")
--- @field LogFormat string Формат логирования ("TEXT"|"JSON")
--- @field MaxPayloadSize number Максимальный размер полезной нагрузки HTTP
--- @field CorsAllowOrigin string Настройки CORS
--- @field ChannelMonitorLimit number Максимальное количество одновременно активных мониторов каналов
--- @field DvbMonitorLimit number Максимальное количество одновременно активных DVB-мониторов
--- @field MaxMonitorNameLength number Максимальная длина имени монитора
--- @field MinRate number Минимальное допустимое значение погрешности
--- @field MaxRate number Максимальное допустимое значение погрешности
--- @field MinTimeCheck number Минимальный интервал между проверками
--- @field MaxTimeCheck number Максимальный интервал между проверками
--- @field MinMethodComparison number Минимальное значение для метода сравнения
--- @field MaxMethodComparison number Максимальное значение для метода сравнения
--- @field HttpTimeout number Таймаут HTTP-запросов
--- @field LogBufferSize number Размер буфера логов (0 - выключено)
--- @field ExtraDebug boolean Флаг расширенной отладки (для dev-окружения)
--- @field GcPause number Параметр GC setpause (по умолчанию 100)
--- @field GcStepMul number Параметр GC setstepmul (по умолчанию 500)
--- @field SchedulerInterval number Интервал тика планировщика в секундах
--- @field subscribers table<string, table[]> Список подписчиков
--- @field ValidationSchema table<string, ValidationRule> Схема валидации для параметров мониторов
local MonitorConfig = {}

-- Внутреннее состояние кэша
MonitorConfig._cache = {}
MonitorConfig._cache_ttl = 60 -- секунд
MonitorConfig._cache_timestamp = 0

-- Значения по умолчанию
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
MonitorConfig.LogLevel = "INFO"
MonitorConfig.LogFormat = "TEXT"
MonitorConfig.MaxPayloadSize = 1024 * 1024 -- 1MB
MonitorConfig.CorsAllowOrigin = "*"
MonitorConfig.ChannelMonitorLimit = 200
MonitorConfig.DvbMonitorLimit = 20
MonitorConfig.MaxMonitorNameLength = 64
MonitorConfig.MinRate = 0.001
MonitorConfig.MaxRate = 0.3
MonitorConfig.MinTimeCheck = 0
MonitorConfig.MaxTimeCheck = 300
MonitorConfig.MinMethodComparison = 1
MonitorConfig.MaxMethodComparison = 4
MonitorConfig.HttpTimeout = 10
MonitorConfig.RateLimitWindow = 60 -- секунд
MonitorConfig.RateLimitMaxRequests = 100 -- запросов на окно
MonitorConfig.ForceSendInterval = 300
MonitorConfig.LogBufferSize = 0 -- По умолчанию выключено
MonitorConfig.ExtraDebug = false
MonitorConfig.GcPause = 100
MonitorConfig.GcStepMul = 500
MonitorConfig.SchedulerInterval = 1
MonitorConfig.subscribers = {}

--- Валидирует текущую конфигурацию
--- @return boolean success, string|nil error_message
function MonitorConfig.validate()
    if type(MonitorConfig.LogLevel) ~= "string" then return false, "LogLevel must be a string" end
    local valid_levels = {DEBUG=true, INFO=true, WARN=true, ERROR=true, NONE=true}
    if not valid_levels[MonitorConfig.LogLevel] then
        return false, "Invalid LogLevel: " .. tostring(MonitorConfig.LogLevel)
    end

    if type(MonitorConfig.LogFormat) ~= "string" then return false, "LogFormat must be a string" end
    local valid_formats = {TEXT=true, JSON=true}
    if not valid_formats[MonitorConfig.LogFormat] then
        return false, "Invalid LogFormat: " .. tostring(MonitorConfig.LogFormat)
    end

    if type(MonitorConfig.MaxPayloadSize) ~= "number" then return false, "MaxPayloadSize must be a number" end
    if type(MonitorConfig.CorsAllowOrigin) ~= "string" then return false, "CorsAllowOrigin must be a string" end

    if type(MonitorConfig.ChannelMonitorLimit) ~= "number" then return false, "ChannelMonitorLimit must be a number" end
    if MonitorConfig.ChannelMonitorLimit <= 0 then
        return false, "ChannelMonitorLimit must be positive"
    end

    if type(MonitorConfig.DvbMonitorLimit) ~= "number" then return false, "DvbMonitorLimit must be a number" end
    if type(MonitorConfig.ForceSendInterval) ~= "number" then return false, "ForceSendInterval must be a number" end
    if type(MonitorConfig.LogBufferSize) ~= "number" then return false, "LogBufferSize must be a number" end

    return true
end

--- Возвращает значение из кэша или генерирует новое.
--- @param key string Уникальный ключ кэша
--- @param generator function Функция для генерации значения при промахе кэша
--- @return any Значение из кэша
function MonitorConfig.get_cached(key, generator)
    local now = os_time()
    if MonitorConfig._cache_timestamp + MonitorConfig._cache_ttl < now then
        MonitorConfig._cache = {} -- Очистка кэша по TTL
        MonitorConfig._cache_timestamp = now
    end

    if MonitorConfig._cache[key] == nil then
        MonitorConfig._cache[key] = generator()
    end

    return MonitorConfig._cache[key]
end

--- Возвращает имя потока по IP с использованием кэширования.
--- @param ip string IP-адрес потока
--- @return string Имя потока или IP
function MonitorConfig.get_stream_name_cached(ip)
    return MonitorConfig.get_cached("stream_" .. ip, function()
        return MonitorConfig.STREAM[ip] or ip
    end)
end

--- Возвращает текущее окружение системы.
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

--- Проверяет, является ли текущее окружение средой разработки.
--- @return boolean true если разработка, иначе false
function MonitorConfig.is_development()
    return MonitorConfig.get_environment() == "development"
end

--- Загружает конфигурацию из внешнего JSON файла
local function load_from_file()
    if not ModuleManager then return end
    local json_decode = ModuleManager.get_global_dependency("json.decode")
    if not json_decode then return end

    -- 1. Загрузка основного конфига библиотеки
    local f = io.open(CONFIG_PATH, "rb")
    if f then
        local content = f:read("*all")
        f:close()
        if content and content ~= "" then
            local success, data = pcall(json_decode, content)
            if success and type(data) == "table" then
                for k, v in pairs(data) do MonitorConfig[k] = v end
            end
        end
    end

    -- 2. Загрузка глобального конфига для Middleware (CORS и др.)
    local global_f = io.open("/opt/config.json", "rb")
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

--- Сохраняет текущую конфигурацию в JSON файл
--- @return boolean Статус выполнения
function MonitorConfig.save()
    if not ModuleManager then return false end
    local json_encode = ModuleManager.get_global_dependency("json.encode")
    if not json_encode then return false end

    -- Создаем копию для сохранения, исключая ValidationSchema
    local data_to_save = {}
    for k, v in pairs(MonitorConfig) do
        if k ~= "ValidationSchema" and type(v) ~= "function" then
            data_to_save[k] = v
        end
    end

    local ok, content = pcall(json_encode, data_to_save)
    if not ok then return false end

    local f = io.open(CONFIG_PATH, "w")
    if not f then return false end

    f:write(content)
    f:close()
    return true
end

-- Вызов загрузки при инициализации модуля
load_from_file()

-- Настройка окружения
if MonitorConfig.is_development() then
    MonitorConfig.ExtraDebug = true
    MonitorConfig.LogLevel = "DEBUG"
end

-- 5. Инициализация объектов из загруженных модулей
-- Нет объектов для инициализации в этом модуле

--- Схема валидации для параметров мониторов.
--- Определяет правила валидации, значения по умолчанию и типы для каждого параметра.
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
