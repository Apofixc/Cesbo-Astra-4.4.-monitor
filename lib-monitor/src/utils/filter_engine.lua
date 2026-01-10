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
local accessor_cache = {}
local accessor_cache_count = 0
local MAX_CACHE_SIZE = 100

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

--- Компилирует строковый путь в функцию-аксессор для быстрого доступа к данным.
--- @param path string Путь к полю через точку (например, "total.bitrate")
--- @return function Функция-аксессор: function(data) return value end
function FilterEngine.compile_accessor(path)
    if not path or path == "" then
        return function(d) return d end
    end

    local accessor = accessor_cache[path]
    if accessor then return accessor end

    -- Очистка кэша при переполнении (O(1) проверка)
    if accessor_cache_count >= MAX_CACHE_SIZE then
        accessor_cache = {}
        accessor_cache_count = 0
    end

    local parts = {}
    for part in path:gmatch("[^%.]+") do
        parts[#parts + 1] = part
    end

    -- Генерация функции-аксессора
    if #parts == 1 then
        local key = parts[1]
        accessor = function(d)
            return (type(d) == "table") and d[key] or nil
        end
    elseif #parts == 2 then
        local k1, k2 = parts[1], parts[2]
        accessor = function(d)
            if type(d) ~= "table" then return nil end
            local v1 = d[k1]
            return (type(v1) == "table") and v1[k2] or nil
        end
    else
        accessor = function(d)
            local current = d
            for i = 1, #parts do
                if type(current) ~= "table" then return nil end
                current = current[parts[i]]
            end
            return current
        end
    end

    accessor_cache[path] = accessor
    accessor_cache_count = accessor_cache_count + 1
    return accessor
end

--- Проверяет соответствие данных конкретному условию с учетом оператора и длительности.
--- @param data table Данные события
--- @param condition table Параметры условия (field, op, value, duration, accessor)
--- @param sub_id string|nil ID подписки (для отслеживания длительности)
--- @param cond_idx number Индекс условия в списке
--- @return boolean Результат проверки
local function check_condition(data, condition, sub_id, cond_idx)
    if type(data) ~= "table" then return false end
    if not condition.field then return true end

    local value
    if condition.accessor then
        value = condition.accessor(data)
    else
        -- Fallback для обратной совместимости или если аксессор не скомпилирован
        local accessor = FilterEngine.compile_accessor(condition.field)
        condition.accessor = accessor
        value = accessor(data)
    end

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

--- Генерирует Lua-код для проверки набора условий.
--- @private
--- @param filters table Схема фильтров
--- @return string|nil Lua-код функции
local function generate_filter_code(filters)
    if not filters.conditions or #filters.conditions == 0 then return nil end

    local logic = filters.logic or "and"
    local code_parts = {}

    for i, cond in ipairs(filters.conditions) do
        local op = cond.op or "eq"
        local field = cond.field
        local target = cond.value

        -- Формируем выражение для одного условия
        local expr
        if op == "eq" then
            expr = string.format("(data.%s == %s)", field,
                type(target) == "string" and string.format("%q", target) or tostring(target))
        elseif op == "ne" then
            expr = string.format("(data.%s ~= %s)", field,
                type(target) == "string" and string.format("%q", target) or tostring(target))
        elseif op == "gt" then
            expr = string.format("(type(data.%s) == 'number' and data.%s > %s)", field, field, tostring(target))
        elseif op == "lt" then
            expr = string.format("(type(data.%s) == 'number' and data.%s < %s)", field, field, tostring(target))
        elseif op == "contains" then
            expr = string.format("(type(data.%s) == 'string' and data.%s:find(%q, 1, true) ~= nil)",
                field, field, tostring(target))
        end

        if expr then
            table.insert(code_parts, expr)
        end
    end

    if #code_parts == 0 then return nil end

    local joiner = (logic == "or") and " or " or " and "
    return "return function(data) return " .. table.concat(code_parts, joiner) .. " end"
end

--- Проверяет данные события на соответствие набору фильтров.
--- Поддерживает Fast Path (если фильтры пусты), Lua-скрипты и логические группы условий.
--- @param data table Данные события
--- @param filters table Схема фильтров
--- @param sub_id string|nil ID подписки для отслеживания состояний
--- @return boolean Результат проверки
function FilterEngine.match(data, filters, sub_id)
    if not filters or next(filters) == nil then return true end

    -- Оптимизация: JIT-компиляция условий в функцию
    if filters.conditions and not filters.script and not filters._compiled_func then
        -- Если есть условия с длительностью, JIT не используем (нужно состояние)
        local has_duration = false
        for _, c in ipairs(filters.conditions) do
            if c.duration and c.duration > 0 then has_duration = true; break end
        end

        if not has_duration then
            local code = generate_filter_code(filters)
            if code then
                local factory, _ = load(code, "=(filter_jit)", "t", { type = type, table = table })
                if factory then
                    local ok, func = pcall(factory)
                    if ok and type(func) == "function" then
                        filters._compiled_func = func
                    end
                end
            end
        end
    end

    if filters._compiled_func then
        local ok, res = pcall(filters._compiled_func, data)
        return ok and res == true
    end

    -- 1. Проверка Lua-скрипта
    if filters.script and type(filters.script) == "string" then
        local func = script_cache[filters.script]
        if not func then
            -- Очистка кэша при переполнении
            if #script_cache > MAX_CACHE_SIZE then script_cache = {} end

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
