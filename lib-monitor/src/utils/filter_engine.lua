-- ===========================================================================
-- Модуль `utils.filter_engine`
--
-- Реализует логику фильтрации событий. Поддерживает простые сравнения,
-- операторы (gt, lt, matches) и выполнение Lua-выражений.
-- ===========================================================================

-- 1. Стандартные Lua функции
local type = type
local pairs = pairs
local pcall = pcall
local loadstring = loadstring or load
local tostring = tostring

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "FilterEngine"

--- @class FilterEngine
local FilterEngine = {}

--- Получает значение из таблицы по вложенному пути (например, "total.bitrate")
--- @private
local function get_nested_value(data, path)
    if not path or path == "" then return data end
    local current = data
    for part in path:gmatch("[^%.]+") do
        if type(current) ~= "table" then return nil end
        current = current[part]
    end
    return current
end

--- Операторы сравнения
local OPERATORS = {
    eq = function(a, b) return a == b end,
    ne = function(a, b) return a ~= b end,
    gt = function(a, b) return (type(a) == "number" and type(b) == "number") and a > b end,
    ge = function(a, b) return (type(a) == "number" and type(b) == "number") and a >= b end,
    lt = function(a, b) return (type(a) == "number" and type(b) == "number") and a < b end,
    le = function(a, b) return (type(a) == "number" and type(b) == "number") and a <= b end,
    contains = function(a, b) return (type(a) == "string" and type(b) == "string") and a:find(b, 1, true) ~= nil end,
    matches = function(a, b) return (type(a) == "string" and type(b) == "string") and a:match(b) ~= nil end,
}

--- Проверяет соответствие данных условию
--- @private
local function check_condition(data, condition)
    if not condition.field then return true end
    
    local value = get_nested_value(data, condition.field)
    local op = condition.op or "eq"
    local target = condition.value

    local func = OPERATORS[op]
    if func then
        return func(value, target)
    end
    
    return false
end

--- Проверяет данные события на соответствие фильтрам
--- @param data table Данные события
--- @param filters table Схема фильтров
--- @return boolean Результат проверки
function FilterEngine.match(data, filters)
    if not filters or next(filters) == nil then return true end

    -- 1. Проверка Lua-скрипта (максимальная гибкость)
    if filters.script and type(filters.script) == "string" then
        local env = { data = data, type = type, tostring = tostring }
        local func, err = loadstring(filters.script)
        if func then
            setfenv(func, env)
            local ok, res = pcall(func)
            if ok then return res == true end
            Logger.error(COMPONENT_NAME, "Ошибка выполнения скрипта фильтра: %s", tostring(res))
        else
            Logger.error(COMPONENT_NAME, "Ошибка компиляции скрипта фильтра: %s", tostring(err))
        end
        return false
    end

    -- 2. Проверка условий (conditions)
    if filters.conditions and type(filters.conditions) == "table" then
        local logic = filters.logic or "and"
        
        if logic == "and" then
            for _, cond in pairs(filters.conditions) do
                if not check_condition(data, cond) then return false end
            end
            return true
        elseif logic == "or" then
            for _, cond in pairs(filters.conditions) do
                if check_condition(data, cond) then return true end
            end
            return false
        end
    end

    -- 3. Простая фильтрация по полям (обратная совместимость)
    for key, val in pairs(filters) do
        if key ~= "conditions" and key ~= "logic" and key ~= "script" then
            if data[key] ~= val then return false end
        end
    end

    return true
end

return FilterEngine
