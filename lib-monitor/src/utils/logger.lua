-- 1. Стандартные Lua функции
local ipairs = ipairs
local os_time = os.time
local pcall = pcall
local select = select
local string_format = string.format
local table_insert = table.insert
local table_remove = table.remove
local tostring = tostring
local unpack = table.unpack

-- 2. Функции из ModuleManager.get_module()
-- local MonitorConfig = ModuleManager.get_module("monitor_config") -- Загружается динамически в get_current_level

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local log = ModuleManager.get_global_dependency("log")
local json_encode = ModuleManager.get_global_dependency("json.encode")

-- 4. Константы и конфигурации
local LOG_LEVELS = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4,
    NONE = 5
}

-- Внутреннее состояние для контекстного хранения ошибок
local last_errors = {}
local context_stack = {}
local current_context_id = nil
local context_counter = 0

-- Кэширование уровня логирования и конфига
local cached_log_level = nil
local cached_log_format = nil
local last_config_check = 0
local CONFIG_REFRESH_INTERVAL = 5 -- секунд

-- 5. Инициализация объектов из загруженных модулей

--- Возвращает модуль конфигурации (ленивая загрузка для избежания циклических зависимостей)
--- @return MonitorConfig|nil
local function get_monitor_config()
    local success, config = pcall(function()
        return ModuleManager.get_module("monitor_config")
    end)
    return (success and config and type(config) == "table") and config or nil
end

--- @class Logger
--- @field private last_errors table<string, string> Хранилище последних ошибок по контекстам
--- @field private context_stack table<number, string> Стек контекстов
--- @field private current_context_id string|nil Текущий идентификатор контекста
--- @field _context_buffer table<string, table> Буфер логов для диагностики
--- @field _buffer_size number Максимальный размер буфера
local Logger = {}

-- Буфер логов для диагностики
Logger._context_buffer = {}
Logger._buffer_size = 1000

--- Обновляет кэшированный уровень логирования
function Logger.refresh_log_level()
    local config = get_monitor_config()
    local level_name = config and config.LogLevel or "INFO"
    cached_log_level = LOG_LEVELS[level_name] or LOG_LEVELS.INFO
end

local function refresh_cache_if_needed()
    local now = os_time()
    if not cached_log_level or (now - last_config_check) > CONFIG_REFRESH_INTERVAL then
        local config = get_monitor_config()
        if config then
            cached_log_level = LOG_LEVELS[config.LogLevel] or LOG_LEVELS.INFO
            cached_log_format = config.LogFormat
        else
            cached_log_level = cached_log_level or LOG_LEVELS.INFO
            cached_log_format = cached_log_format or "TEXT"
        end
        last_config_check = now
    end
end

local function get_current_level()
    refresh_cache_if_needed()
    return cached_log_level
end

local function should_log(level)
    return level >= get_current_level()
end

--- Добавляет запись в кольцевой буфер логов
--- @param level string Уровень лога
--- @param component string Имя компонента
--- @param message string Текст сообщения
--- @param context_id? string ID контекста
function Logger.buffer_log(level, component, message, context_id)
    if not Logger._context_buffer[component] then
        Logger._context_buffer[component] = {}
    end
    
    local buffer = Logger._context_buffer[component]
    local entry = {
        timestamp = os_time(),
        level = level,
        message = message,
        context_id = context_id
    }
    
    table_insert(buffer, entry)
    
    -- Ограничение размера буфера (FIFO)
    if #buffer > Logger._buffer_size then
        table_remove(buffer, 1)
    end
end

--- Возвращает содержимое буфера логов
--- @param component string Имя компонента
--- @param limit? number Лимит записей
--- @return table Список записей
function Logger.get_buffer(component, limit)
    local buffer = Logger._context_buffer[component]
    if not buffer then return {} end
    
    if limit and #buffer > limit then
        local result = {}
        for i = #buffer - limit + 1, #buffer do
            table_insert(result, buffer[i])
        end
        return result
    end
    
    return buffer
end

--- Внутренняя функция для записи лога
--- @private
local function write_log(level_name, component, format_str, ...)
    local level = LOG_LEVELS[level_name]
    local is_error = (level_name == "ERROR")
    
    if not should_log(level) and not (is_error and current_context_id) then
        return
    end

    local msg = (select("#", ...) > 0) and string_format(format_str, ...) or format_str
    
    if is_error and current_context_id then
        last_errors[current_context_id] = msg
        for _, id in ipairs(context_stack) do
            last_errors[id] = msg
        end
    end

    -- Буферизация (если включена в конфиге)
    local config = get_monitor_config()
    if config and config.LogBufferSize and config.LogBufferSize > 0 then
        Logger._buffer_size = config.LogBufferSize
        Logger.buffer_log(level_name, component, msg, current_context_id)
    end

    if should_log(level) then
        local use_json = (cached_log_format == "JSON")

        if use_json and json_encode then
            local log_data = {
                timestamp = os_time(),
                level = level_name,
                component = component,
                message = msg,
                context_id = current_context_id
            }
            local ok, json_str = pcall(json_encode, log_data)
            if ok then
                msg = json_str
            end
        else
            msg = string_format("[%s] %s", component, msg)
        end

        local lower_level = level_name:lower()
        if log and log[lower_level] then
            log[lower_level](msg)
        else
            print(string_format("[%s] %s", level_name, msg))
        end
    end
end

--- Логирует сообщение с уровнем INFO
--- @param component string Имя компонента
--- @param format_str string Форматная строка
--- @param ... any Аргументы для формата
function Logger.info(component, format_str, ...)
    write_log("INFO", component, format_str, ...)
end

--- Логирует сообщение с уровнем ERROR и сохраняет в контекст, если он активен
--- @param component string Имя компонента
--- @param format_str string Форматная строка
--- @param ... any Аргументы для формата
function Logger.error(component, format_str, ...)
    write_log("ERROR", component, format_str, ...)
end

--- Логирует сообщение с уровнем DEBUG
--- @param component string Имя компонента
--- @param format_str string Форматная строка
--- @param ... any Аргументы для формата
function Logger.debug(component, format_str, ...)
    write_log("DEBUG", component, format_str, ...)
end

--- Логирует сообщение с уровнем WARN
--- @param component string Имя компонента
--- @param format_str string Форматная строка
--- @param ... any Аргументы для формата
function Logger.warn(component, format_str, ...)
    write_log("WARN", component, format_str, ...)
end

--- Выполняет функцию в контексте отслеживания ошибок
--- @param func function Функция для выполнения
--- @param ... any Аргументы функции
--- @return boolean success Статус выполнения
--- @return any|string|nil result_or_error Данные, nil или сообщение об ошибке (для HTTP-функций)
--- @return any ... Дополнительные результаты
function Logger.with_error(func, ...)
    context_counter = context_counter + 1
    local context_id = tostring(context_counter) -- Уникальный ID для этого вызова
    
    if current_context_id then
        table_insert(context_stack, current_context_id)
    end
    current_context_id = context_id
    
    local results = { pcall(func, ...) }
    
    -- Восстанавливаем контекст
    current_context_id = table_remove(context_stack)
    
    local ok = results[1]
    if not ok then
        -- Ошибка выполнения (crash)
        local err = results[2]
        Logger.error("Logger", "Runtime error: %s", tostring(err))
        last_errors[context_id] = nil
        return false, tostring(err)
    end
    
    -- Успешное выполнение функции, проверяем результат
    local success = results[2]
    if not success then
        -- Извлекаем ошибку, которая была сохранена для ЭТОГО контекста
        local err = last_errors[context_id] or "Unknown error"
        last_errors[context_id] = nil
        return false, err
    end
    
    -- Успех
    last_errors[context_id] = nil
    return unpack(results, 2)
end

return Logger
