-- ===========================================================================
-- Модуль `utils.wildcard`
--
-- Оптимизированный движок сопоставления масок (wildcards).
-- Предварительно компилирует маски в функции для ускорения маршрутизации.
-- ===========================================================================

-- 1. Стандартные Lua функции
local type = type

--- @class Wildcard
local Wildcard = {}

--- Компилирует маску в функцию сопоставления.
--- @param pattern string Маска (например, "channel:*", "adapter:1", "*")
--- @return function Функция вида function(name) -> boolean
function Wildcard.compile(pattern)
    if not pattern or type(pattern) ~= "string" then
        return function() return false end
    end

    -- Полное совпадение или любая строка
    if pattern == "*" then
        return function() return true end
    end

    -- Если маска не содержит спецсимволов, используем прямое сравнение строк
    if not pattern:find("*") then
        return function(name)
            return pattern == name
        end
    end

    -- Оптимизация: Быстрая проверка префикса для масок вида "prefix:*"
    if pattern:match("^[^%*]+%*$") then
        local prefix = pattern:sub(1, -2)
        return function(name)
            if not name or type(name) ~= "string" then return false end
            return name:sub(1, #prefix) == prefix
        end
    end

    -- Превращаем маску в регулярное выражение Lua
    -- Экранируем спецсимволы Lua и заменяем * на .*
    local regex = pattern:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1"):gsub("%*", ".*")
    local final_regex = "^" .. regex .. "$"

    return function(name)
        if not name or type(name) ~= "string" then return false end
        return name:match(final_regex) ~= nil
    end
end

return Wildcard
