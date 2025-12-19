-- ===========================================================================
-- Модуль централизованного логирования
-- ===========================================================================

local Logger = {}
Logger.__index = Logger

-- Уровни логирования
local LOG_LEVELS = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4,
    NONE = 5, -- Отключить все логи
}

-- Текущий уровень логирования (по умолчанию INFO)
local current_log_level = LOG_LEVELS.INFO

--- Устанавливает текущий уровень логирования.
-- @param string level_name Имя уровня логирования (DEBUG, INFO, WARN, ERROR, NONE).
function Logger.set_log_level(level_name)
    local level = LOG_LEVELS[level_name:upper()]
    if level then
        current_log_level = level
        print("Log level set to: " .. level_name:upper())
    else
        print("Invalid log level: " .. level_name .. ". Available levels: DEBUG, INFO, WARN, ERROR, NONE.")
    end
end

--- Получает текущий уровень логирования.
-- @return number Текущий уровень логирования.
function Logger.get_log_level()
    return current_log_level
end

--- Форматирует сообщение лога.
-- @param string level Уровень лога (например, "INFO").
-- @param string message Сообщение лога.
-- @param string component Компонент, из которого пришло сообщение (например, "MonitorManager").
-- @return string Отформатированное сообщение.
local function format_message(level, message, component)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    return string.format("[%s] [%s] [%s] %s", timestamp, level, component, message)
end

--- Логирует сообщение на уровне DEBUG.
-- @param string component Компонент, из которого пришло сообщение.
-- @param string message Сообщение лога.
function Logger.debug(component, message)
    if current_log_level <= LOG_LEVELS.DEBUG then
        print(format_message("DEBUG", message, component))
    end
end

--- Логирует сообщение на уровне INFO.
-- @param string component Компонент, из которого пришло сообщение.
-- @param string message Сообщение лога.
function Logger.info(component, message)
    if current_log_level <= LOG_LEVELS.INFO then
        print(format_message("INFO", message, component))
    end
end

--- Логирует сообщение на уровне WARN.
-- @param string component Компонент, из которого пришло сообщение.
-- @param string message Сообщение лога.
function Logger.warn(component, message)
    if current_log_level <= LOG_LEVELS.WARN then
        print(format_message("WARN", message, component))
    end
end

--- Логирует сообщение на уровне ERROR.
-- @param string component Компонент, из которого пришло сообщение.
-- @param string message Сообщение лога.
function Logger.error(component, message)
    if current_log_level <= LOG_LEVELS.ERROR then
        io.stderr:write(format_message("ERROR", message, component) .. "\n")
    end
end

return Logger
