-- ===========================================================================
-- Модуль централизованного логирования для системы мониторинга.
-- Предоставляет функции для вывода логов с различными уровнями детализации
-- (DEBUG, INFO, WARN, ERROR) и управляет текущим уровнем логирования.
-- ===========================================================================

local Logger = {}
Logger.__index = Logger

--- Таблица, определяющая уровни логирования и их числовые значения.
-- Используется для фильтрации сообщений в зависимости от текущего уровня логирования.
local LOG_LEVELS = {
    DEBUG = 1, -- Отладочные сообщения, наиболее подробные.
    INFO = 2,  -- Информационные сообщения о ходе выполнения программы.
    WARN = 3,  -- Предупреждения о потенциальных проблемах.
    ERROR = 4, -- Сообщения об ошибках, которые могут повлиять на работу программы.
    NONE = 5,  -- Отключить все логи.
}

local MonitorConfig = require "config.monitor_config"

--- Текущий активный уровень логирования.
-- Инициализируется значением из `MonitorConfig.LogLevel` (приведенным к верхнему регистру)
-- или `LOG_LEVELS.INFO` по умолчанию, если значение не определено или некорректно.
local current_log_level = LOG_LEVELS[MonitorConfig.LogLevel:upper()] or LOG_LEVELS.INFO

--- Устанавливает глобальный уровень логирования для всех сообщений.
-- Сообщения с уровнем ниже установленного не будут выводиться.
-- @param string level_name Имя уровня логирования (например, "DEBUG", "INFO", "WARN", "ERROR", "NONE").
function Logger.set_log_level(level_name)
    local level = LOG_LEVELS[level_name:upper()]
    if level then
        current_log_level = level
        print("Log level set to: " .. level_name:upper())
    else
        print("Invalid log level: " .. level_name .. ". Available levels: DEBUG, INFO, WARN, ERROR, NONE.")
    end
end

--- Возвращает текущий установленный уровень логирования.
-- @return number Числовое значение текущего уровня логирования.
function Logger.get_log_level()
    return current_log_level
end

--- Внутренняя функция для форматирования сообщения лога.
-- Добавляет временную метку, уровень лога и имя компонента к сообщению.
-- @param string level Уровень лога (например, "INFO", "ERROR").
-- @param string component Имя компонента или модуля, откуда было вызвано логирование.
-- @param string format_str Форматная строка для сообщения.
-- @param ... Переменное количество аргументов для форматной строки.
-- @return string Полностью отформатированное сообщение лога.
local function format_message(level, component, format_str, ...)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local message = string.format(format_str, ...)
    return string.format("[%s] [%s] [%s] %s", timestamp, level, component, message)
end

--- Логирует сообщение на уровне DEBUG.
-- Сообщения DEBUG используются для детальной отладки и обычно отключаются в production.
-- @param string component Имя компонента, генерирующего лог.
-- @param string format_str Форматная строка для сообщения.
-- @param ... Переменное количество аргументов для форматной строки.
function Logger.debug(component, format_str, ...)
    if current_log_level <= LOG_LEVELS.DEBUG then
        io.write(format_message("DEBUG", component, format_str, ...) .. "\n")
    end
end

--- Логирует сообщение на уровне INFO.
-- Информационные сообщения о нормальной работе приложения.
-- @param string component Имя компонента, генерирующего лог.
-- @param string format_str Форматная строка для сообщения.
-- @param ... Переменное количество аргументов для форматной строки.
function Logger.info(component, format_str, ...)
    if current_log_level <= LOG_LEVELS.INFO then
        io.write(format_message("INFO", component, format_str, ...) .. "\n")
    end
end

--- Логирует сообщение на уровне WARN.
-- Предупреждающие сообщения о потенциальных проблемах, которые не блокируют работу.
-- @param string component Имя компонента, генерирующего лог.
-- @param string format_str Форматная строка для сообщения.
-- @param ... Переменное количество аргументов для форматной строки.
function Logger.warn(component, format_str, ...)
    if current_log_level <= LOG_LEVELS.WARN then
        io.write(format_message("WARN", component, format_str, ...) .. "\n")
    end
end

--- Логирует сообщение на уровне ERROR.
-- Сообщения об ошибках, которые требуют внимания и могут указывать на сбои.
-- Выводится в `io.stderr`.
-- @param string component Имя компонента, генерирующего лог.
-- @param string format_str Форматная строка для сообщения.
-- @param ... Переменное количество аргументов для форматной строки.
function Logger.error(component, format_str, ...)
    if current_log_level <= LOG_LEVELS.ERROR then
        io.stderr:write(format_message("ERROR", component, format_str, ...) .. "\n")
    end
end

return Logger
