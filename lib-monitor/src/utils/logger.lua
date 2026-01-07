-- 1. Стандартные Lua функции
local ipairs = ipairs
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

-- Кэширование уровня логирования
local cached_log_level = nil

-- 5. Инициализация объектов из загруженных модулей
--- @class Logger
--- @field private last_errors table<string, string> Хранилище последних ошибок по контекстам
--- @field private context_stack table<number, string> Стек контекстов
--- @field private current_context_id string|nil Текущий идентификатор контекста
local Logger = {}

--- Обновляет кэшированный уровень логирования
function Logger.refresh_log_level()
    -- Используем pcall для безопасного получения модуля, чтобы избежать проблем при инициализации
    local success, config = pcall(function() return ModuleManager.get_module("monitor_config") end)
    local level_name = (success and config and type(config) == "table") and config.LogLevel or "INFO"
    cached_log_level = LOG_LEVELS[level_name] or LOG_LEVELS.INFO
end

local function get_current_level()
    if not cached_log_level then
        Logger.refresh_log_level()
    end
    return cached_log_level
end

local function should_log(level)
    return level >= get_current_level()
end

--- Внутренняя функция для записи лога
--- @private
local function write_log(level_name, component, format_str, ...)
    local level = LOG_LEVELS[level_name]
    local msg = (select("#", ...) > 0) and string_format(format_str, ...) or format_str
    
    if level_name == "ERROR" and current_context_id then
        last_errors[current_context_id] = msg
        for _, id in ipairs(context_stack) do
            last_errors[id] = msg
        end
    end

    if should_log(level) then
        local lower_level = level_name:lower()
        if log and log[lower_level] then
            log[lower_level](string_format("[%s] %s", component, msg))
        else
            print(string_format("[%s][%s] %s", level_name, component, msg))
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
