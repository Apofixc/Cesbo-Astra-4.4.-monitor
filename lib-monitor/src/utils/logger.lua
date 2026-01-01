-- 1. Стандартные Lua функции
local select = select
local string_format = string.format
local tostring = tostring
local type = type

-- 2. Функции из ModuleManager.get_module()
local MonitorConfig = ModuleManager.get_module("monitor_config")

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

-- 5. Инициализация объектов из загруженных модулей
--- @class Logger
local Logger = {}

local function get_current_level()
    -- Динамически получаем конфиг через ModuleManager, чтобы всегда иметь актуальные настройки
    local config = ModuleManager.get_module("monitor_config")
    local level_name = config and config.LogLevel or "INFO"
    return LOG_LEVELS[level_name] or LOG_LEVELS.INFO
end

local function should_log(level)
    return level >= get_current_level()
end

--- Логирует сообщение с уровнем INFO
--- @param component string Имя компонента
--- @param format_str string Форматная строка
--- @param ... any Аргументы для формата
function Logger.info(component, format_str, ...)
    if should_log(LOG_LEVELS.INFO) then
        local msg = (select("#", ...) > 0) and string_format(format_str, ...) or format_str
        log.info(string_format("[%s] %s", component, msg))
    end
end

--- Логирует сообщение с уровнем ERROR
--- @param component string Имя компонента
--- @param format_str string Форматная строка
--- @param ... any Аргументы для формата
function Logger.error(component, format_str, ...)
    if should_log(LOG_LEVELS.ERROR) then
        local msg = (select("#", ...) > 0) and string_format(format_str, ...) or format_str
        log.error(string_format("[%s] %s", component, msg))
    end
end

--- Логирует сообщение с уровнем DEBUG
--- @param component string Имя компонента
--- @param format_str string Форматная строка
--- @param ... any Аргументы для формата
function Logger.debug(component, format_str, ...)
    if should_log(LOG_LEVELS.DEBUG) then
        local msg = (select("#", ...) > 0) and string_format(format_str, ...) or format_str
        log.info(string_format("[DEBUG][%s] %s", component, msg))
    end
end

--- Логирует сообщение с уровнем WARN
--- @param component string Имя компонента
--- @param format_str string Форматная строка
--- @param ... any Аргументы для формата
function Logger.warn(component, format_str, ...)
    if should_log(LOG_LEVELS.WARN) then
        local msg = (select("#", ...) > 0) and string_format(format_str, ...) or format_str
        log.info(string_format("[WARN][%s] %s", component, msg))
    end
end

return Logger
