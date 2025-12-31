-- ===========================================================================
-- Модуль `utils.logger`
--
-- Предоставляет централизованную систему логирования для системы мониторинга.
-- Включает функции для вывода логов с различными уровнями детализации
-- (DEBUG, INFO, WARN, ERROR) и управляет текущим уровнем логирования.
-- ===========================================================================

-- 1. Стандартные Lua функции
local type = type
local string_format = string.format
local os_date = os.date
local io_write, io_stderr = io.write, io.stderr

-- 2. Функции из ModuleManager.get_module()
-- Нет функций из ModuleManager.get_module() в этом модуле

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Нет глобальных зависимостей Astra в этом модуле

-- 4. Константы и конфигурации
local LOG_LEVELS = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4,
    NONE = 5,
}
local COMPONENT_NAME = "Logger"

-- 5. Инициализация объектов из загруженных модулей
--- @class Logger
local Logger = {}
Logger.__index = Logger
--- @type number
local current_log_level

-- Временная функция для получения MonitorConfig, пока ModuleManager не загружен
local function get_monitor_config_log_level()
    local success, MonitorConfig = pcall(ModuleManager.get_module, "config.monitor_config")
    if success and MonitorConfig and MonitorConfig.LogLevel then
        return MonitorConfig.LogLevel
    end
    return "INFO" -- Значение по умолчанию, если MonitorConfig недоступен
end

-- Инициализация уровня логирования с проверкой на nil и тип
local initial_log_level_name = get_monitor_config_log_level()
if initial_log_level_name and type(initial_log_level_name) == "string" then
    current_log_level = LOG_LEVELS[initial_log_level_name:upper()] or LOG_LEVELS.INFO
else
    current_log_level = LOG_LEVELS.INFO
end

--- Устанавливает глобальный уровень логирования для всех сообщений.
--- Сообщения с уровнем ниже установленного не будут выводиться.
--- @param level_name string Имя уровня логирования (например, "DEBUG", "INFO", "WARN", "ERROR", "NONE").
function Logger.set_log_level(level_name)
    if not level_name or type(level_name) ~= "string" then
        io_stderr(format_message("ERROR", COMPONENT_NAME, "Invalid log level name: expected string, got %s.", type(level_name)) .. "\n")
        return
    end
    local level = LOG_LEVELS[level_name:upper()]
    if level then
        current_log_level = level
        io_write(format_message("INFO", COMPONENT_NAME, "Log level set to: %s", level_name:upper()) .. "\n")
    else
        io_stderr(format_message("ERROR", COMPONENT_NAME, "Invalid log level: %s. Available levels: DEBUG, INFO, WARN, ERROR, NONE.", level_name) .. "\n")
    end
end

--- Возвращает текущий установленный уровень логирования.
--- @return number Числовое значение текущего уровня логирования.
function Logger.get_log_level()
    return current_log_level
end

--- Внутренняя функция для форматирования сообщения лога.
--- Добавляет временную метку, уровень лога и имя компонента к сообщению.
--- @param level string Уровень лога (например, "INFO", "ERROR").
--- @param component string Имя компонента или модуля, откуда было вызвано логирование.
--- @param format_str string Форматная строка для сообщения.
--- @param ... any Переменное количество аргументов для форматной строки.
--- @return string Полностью отформатированное сообщение лога.
local function format_message(level, component, format_str, ...)
    local timestamp = os_date("%Y-%m-%d %H:%M:%S")
    -- Безопасный вызов string_format с проверкой аргументов
    local message = format_str
    local args = {...}
    
    if select('#', ...) > 0 then
        local success, result = pcall(string_format, format_str, ...)
        if success then
            message = result
        else
            -- Если форматирование не удалось, выводим исходную строку и аргументы
            message = string_format("%s [args: %s]", format_str, table.concat(args, ", "))
        end
    end
    
    return string_format("[%s] [%s] [%s] %s", timestamp, level, component, message)
end

--- Логирует сообщение на уровне DEBUG.
--- Сообщения DEBUG используются для детальной отладки и обычно отключаются в production.
--- @param component string Имя компонента, генерирующего лог.
--- @param format_str string Форматная строка для сообщения.
--- @param ... any Переменное количество аргументов для форматной строки.
function Logger.debug(component, format_str, ...)
    if current_log_level <= LOG_LEVELS.DEBUG then
        io_write(format_message("DEBUG", component, format_str, ...) .. "\n")
    end
end

--- Логирует сообщение на уровне INFO.
--- Информационные сообщения о нормальной работе приложения.
--- @param component string Имя компонента, генерирующего лог.
--- @param format_str string Форматная строка для сообщения.
--- @param ... any Переменное количество аргументов для форматной строки.
function Logger.info(component, format_str, ...)
    if current_log_level <= LOG_LEVELS.INFO then
        io_write(format_message("INFO", component, format_str, ...) .. "\n")
    end
end

--- Логирует сообщение на уровне WARN.
--- Предупреждающие сообщения о потенциальных проблемах, которые не блокируют работу.
--- @param component string Имя компонента, генерирующего лог.
--- @param format_str string Форматная строка для сообщения.
--- @param ... any Переменное количество аргументов для форматной строки.
function Logger.warn(component, format_str, ...)
    if current_log_level <= LOG_LEVELS.WARN then
        io_write(format_message("WARN", component, format_str, ...) .. "\n")
    end
end

--- Логирует сообщение на уровне ERROR.
--- Сообщения об ошибках, которые требуют внимания и могут указывать на сбои.
--- Выводится в `io.stderr`.
--- @param component string Имя компонента, генерирующего лог.
--- @param format_str string Форматная строка для сообщения.
--- @param ... any Переменное количество аргументов для форматной строки.
function Logger.error(component, format_str, ...)
    if current_log_level <= LOG_LEVELS.ERROR then
        io_stderr:write(format_message("ERROR", component, format_str, ...) .. "\n")
    end
end

return Logger
