-- ===========================================================================
-- Модуль `utils.filter_engine`
--
-- Реализует логику фильтрации событий. Поддерживает простые сравнения,
-- операторы (gt, lt, matches), выполнение Lua-выражений и фильтры по длительности.
-- ===========================================================================

-- 1. Стандартные Lua функции
local type = type
local pairs = pairs
local pcall = pcall
local load = load
local tostring = tostring
local os_time = os.time

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "FilterEngine"

--- @class FilterEngine
--- @field private duration_state table<string, table<number, number>> Состояние фильтров по длительности
local FilterEngine = {}

-- Кэш для скомпилированных скриптов и путей
local script_cache = {}
local path_cache = {}

--- @type table<string, function> Операторы сравнения
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

-- Состояние для фильтров по длительности (Duration)
-- Структура: state[sub_id][condition_index] = { first_match_time }
local duration_state = {}

--- Извлекает значение из таблицы по вложенному пути (например, "total.bitrate").
--- @param data table Исходная таблица
--- @param path string|nil Путь к полю через точку
--- @return any|nil Значение поля или nil
local function get_nested_value(data, path)
    if not path or path == "" then return data end
    
    local parts = path_cache[path]
    if not parts then
        parts = {}
        for part in path:gmatch("[^%.]+") do
            parts[#parts + 1] = part
        end
        path_cache[path] = parts
    end

    local current = data
    for i = 1, #parts do
        if type(current) ~= "table" then return nil end
        current = current[parts[i]]
    end
    return current
end

--- Проверяет соответствие данных конкретному условию с учетом оператора и длительности.
--- @param data table Данные события
--- @param condition table Параметры условия (field, op, value, duration)
--- @param sub_id string|nil ID подписки (для отслеживания длительности)
--- @param cond_idx number Индекс условия в списке
--- @return boolean Результат проверки
local function check_condition(data, condition, sub_id, cond_idx)
    if not condition.field then return true end
    
    local value = get_nested_value(data, condition.field)
    local op = condition.op or "eq"
    local target = condition.value
    local duration = condition.duration -- в секундах

    local func = OPERATORS[op]
    local is_match = func and func(value, target) or false

    -- Обработка длительности (Duration)
    if duration and duration > 0 and sub_id then
        if not duration_state[sub_id] then duration_state[sub_id] = {} end
        local state = duration_state[sub_id]
        
        if is_match then
            if not state[cond_idx] then
                state[cond_idx] = os_time()
                return false -- Еще не прошло достаточно времени
            end
            if (os_time() - state[cond_idx]) >= duration then
                return true -- Условие выполняется дольше чем duration
            end
            return false
        else
            state[cond_idx] = nil -- Сброс, если условие перестало выполняться
            return false
        end
    end
    
    return is_match
end

--- Проверяет данные события на соответствие набору фильтров.
--- Поддерживает Fast Path (если фильтры пусты), Lua-скрипты и логические группы условий.
--- @param data table Данные события
--- @param filters table Схема фильтров
--- @param sub_id string|nil ID подписки для отслеживания состояний
--- @return boolean Результат проверки
function FilterEngine.match(data, filters, sub_id)
    if not filters or next(filters) == nil then return true end

    -- 1. Проверка Lua-скрипта
    if filters.script and type(filters.script) == "string" then
        local func = script_cache[filters.script]
        if not func then
            local env = { data = data, type = type, tostring = tostring, os_time = os_time }
            local err
            func, err = load(filters.script, "=(filter_script)", "t", env)
            if func then
                script_cache[filters.script] = func
            else
                Logger.error(COMPONENT_NAME, "Ошибка компиляции скрипта фильтра: %s", tostring(err))
                return false
            end
        end
        
        local ok, res = pcall(func)
        return ok and res == true
    end

    -- 2. Проверка условий (conditions)
    if filters.conditions and type(filters.conditions) == "table" then
        local logic = filters.logic or "and"
        if logic == "and" then
            for i, cond in pairs(filters.conditions) do
                if not check_condition(data, cond, sub_id, i) then return false end
            end
            return true
        elseif logic == "or" then
            for i, cond in pairs(filters.conditions) do
                if check_condition(data, cond, sub_id, i) then return true end
            end
            return false
        end
    end

    -- 3. Простая фильтрация
    for key, val in pairs(filters) do
        if key ~= "conditions" and key ~= "logic" and key ~= "script" then
            if data[key] ~= val then return false end
        end
    end

    return true
end

return FilterEngine
