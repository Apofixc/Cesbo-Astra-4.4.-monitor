-- ===========================================================================
-- Модуль `utils.filter_engine`
--
-- Высокопроизводительный движок фильтрации событий с поддержкой JIT-компиляции,
-- сложных логических групп и фильтров по длительности (Duration).
-- ===========================================================================

-- 1. Стандартные Lua функции
local type = _G.type
local pairs = _G.pairs
local ipairs = _G.ipairs
local pcall = _G.pcall
local load = _G.load
local tostring = tostring
local string_format = _G.string.format
local string_match = _G.string.match
local string_find = _G.string.find
local table_concat = _G.table.concat
local table_insert = _G.table.insert
local os_time = _G.os.time

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")

-- 3. Глобальные зависимости Astra
-- (Модуль не использует внешние зависимости Astra)

-- 4. Константы и конфигурации
local COMPONENT_NAME = "FilterEngine"
local MAX_CACHE_SIZE = 500 -- Увеличенный размер кэша для сложных систем

-- 5. Инициализация объектов и внутреннее состояние
--- @class FilterEngineState
--- @field script_cache table<string, function> Кэш скомпилированных скриптов
--- @field script_cache_count number Текущее количество скриптов в кэше
--- @field accessor_cache table<string, function> Кэш функций-аксессоров
--- @field accessor_cache_count number Текущее количество аксессоров в кэше
--- @field duration_state table<string, table<string, number>> Состояние фильтров по длительности
local state = {
    script_cache = {},
    script_cache_count = 0,
    accessor_cache = {},
    accessor_cache_count = 0,
    duration_state = {},
}

--- @class FilterEngine
local FilterEngine = {}

--- @type table<string, function> Операторы сравнения для интерпретируемого режима
local OPERATORS = {
    eq = function(a, b) return a == b end,
    ne = function(a, b) return a ~= b end,
    gt = function(a, b) return (type(a) == "number" and type(b) == "number") and a > b end,
    ge = function(a, b) return (type(a) == "number" and type(b) == "number") and a >= b end,
    lt = function(a, b) return (type(a) == "number" and type(b) == "number") and a < b end,
    le = function(a, b) return (type(a) == "number" and type(b) == "number") and a <= b end,
    contains = function(a, b) return (type(a) == "string" and type(b) == "string") and string_find(a, b, 1, true) ~= nil end,
    matches = function(a, b) return (type(a) == "string" and type(b) == "string") and string_match(a, b) ~= nil end,
    ["in"] = function(a, b)
        if type(b) == "table" then
            for _, v in pairs(b) do if v == a then return true end end
        elseif type(b) == "string" then
            return string_find(b, tostring(a), 1, true) ~= nil
        end
        return false
    end,
}

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- Компилирует строковый путь в функцию-аксессор для быстрого доступа к данным
--- @param path string Путь к полю через точку (например, "total.bitrate")
--- @return function Функция-аксессор: function(data) return value end
function FilterEngine.compile_accessor(path)
    if not path or path == "" then
        return function(d) return d end
    end

    local accessor = state.accessor_cache[path]
    if accessor then return accessor end

    if state.accessor_cache_count >= MAX_CACHE_SIZE then
        state.accessor_cache = {}
        state.accessor_cache_count = 0
    end

    local parts = {}
    for part in path:gmatch("[^%.]+") do
        table_insert(parts, part)
    end

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

    state.accessor_cache[path] = accessor
    state.accessor_cache_count = state.accessor_cache_count + 1
    return accessor
end

--- Очищает состояние фильтров для указанной подписки
--- @param sub_id string ID подписки
function FilterEngine.clear_state(sub_id)
    if sub_id and state.duration_state[sub_id] then
        state.duration_state[sub_id] = nil
    end
end

-- ===========================================================================
-- Внутренние функции (Private)
-- ===========================================================================

--- Проверяет соответствие данных конкретному условию (интерпретируемый режим)
--- @private
--- @param data table Данные события
--- @param condition table Параметры условия
--- @param sub_id string|nil ID подписки
--- @param cond_idx any Уникальный ключ условия
--- @return boolean Результат проверки
local function _check_condition(data, condition, sub_id, cond_idx)
    if type(data) ~= "table" then return false end
    
    -- Если это вложенная группа условий
    if condition.conditions then
        return FilterEngine.match(data, condition, sub_id)
    end

    if not condition.field then return true end

    local is_match
    if condition._compiled_cond then
        is_match = condition._compiled_cond(data)
    else
        local value
        if condition.accessor then
            value = condition.accessor(data)
        else
            local accessor = FilterEngine.compile_accessor(condition.field)
            condition.accessor = accessor
            value = accessor(data)
        end

        local op = condition.op or "eq"
        local target = condition.value
        local func = OPERATORS[op]
        is_match = func and func(value, target) or false
    end

    -- Обработка длительности
    local duration = condition.duration
    if duration and duration > 0 and sub_id then
        if not state.duration_state[sub_id] then state.duration_state[sub_id] = {} end
        local d_state = state.duration_state[sub_id]
        local key = tostring(cond_idx)

        if is_match then
            if not d_state[key] then
                d_state[key] = os_time()
                return false
            end
            return (os_time() - d_state[key]) >= duration
        else
            d_state[key] = nil
            return false
        end
    end

    return is_match
end

--- Генерирует выражение для одного условия в JIT-коде
--- @private
--- @param cond table Условие
--- @param upvalues table Список внешних значений
--- @return string Lua-выражение
local function _generate_cond_expr(cond, upvalues)
    local op = cond.op or "eq"
    local field = cond.field
    local target = cond.value

    -- Генерация пути доступа
    local field_expr
    if field:find("%.") then
        local parts = {}
        local current = "data"
        local checks = {}
        for part in field:gmatch("[^%.]+") do
            current = string_format("%s[%q]", current, part)
            table_insert(parts, current)
        end
        for j = 1, #parts - 1 do
            table_insert(checks, string_format("type(%s) == 'table'", parts[j]))
        end
        field_expr = string_format("(%s and %s)", table_concat(checks, " and "), parts[#parts])
    else
        field_expr = string_format("data[%q]", field)
    end

    -- Оптимизация оператора 'in' через upvalues
    if op == "in" and type(target) == "table" then
        local lookup = {}
        for _, v in pairs(target) do lookup[v] = true end
        local uv_name = "uv" .. (#upvalues + 1)
        table_insert(upvalues, { name = uv_name, value = lookup })
        return string_format("(%s ~= nil and %s[%s] == true)", field_expr, uv_name, field_expr)
    end

    local target_val = type(target) == "string" and string_format("%q", target) or tostring(target)
    
    if op == "eq" then return string_format("(%s == %s)", field_expr, target_val)
    elseif op == "ne" then return string_format("(%s ~= %s)", field_expr, target_val)
    elseif op == "gt" then return string_format("(type(%s) == 'number' and %s > %s)", field_expr, field_expr, target_val)
    elseif op == "ge" then return string_format("(type(%s) == 'number' and %s >= %s)", field_expr, field_expr, target_val)
    elseif op == "lt" then return string_format("(type(%s) == 'number' and %s < %s)", field_expr, field_expr, target_val)
    elseif op == "le" then return string_format("(type(%s) == 'number' and %s <= %s)", field_expr, field_expr, target_val)
    elseif op == "contains" then
        return string_format("(type(%s) == 'string' and string_find(%s, %q, 1, true) ~= nil)", field_expr, field_expr, tostring(target))
    elseif op == "matches" then
        return string_format("(type(%s) == 'string' and string_match(%s, %q) ~= nil)", field_expr, field_expr, tostring(target))
    elseif op == "in" and type(target) == "string" then
        return string_format("(type(%s) ~= 'nil' and string_find(%q, tostring(%s), 1, true) ~= nil)", field_expr, target, field_expr)
    end

    return "false"
end

--- Рекурсивно генерирует Lua-код для фильтров
--- @private
--- @param filters table Схема фильтров
--- @param upvalues table Список внешних значений
--- @return string Lua-код
local function _generate_recursive(filters, upvalues)
    if not filters.conditions or #filters.conditions == 0 then return "true" end
    
    local parts = {}
    for _, cond in ipairs(filters.conditions) do
        if cond.conditions then
            table_insert(parts, "(" .. _generate_recursive(cond, upvalues) .. ")")
        else
            table_insert(parts, _generate_cond_expr(cond, upvalues))
        end
    end
    
    local joiner = (filters.logic == "or") and " or " or " and "
    return table_concat(parts, joiner)
end

--- Проверяет данные события на соответствие набору фильтров
--- @param data table Данные события
--- @param filters table Схема фильтров
--- @param sub_id string|nil ID подписки
--- @return boolean Результат проверки
function FilterEngine.match(data, filters, sub_id)
    if not filters or next(filters) == nil then return true end

    -- JIT-компиляция
    if filters.conditions and not filters.script and not filters._compiled_func then
        local has_duration = false
        local function check_dur(f)
            for _, c in ipairs(f.conditions) do
                if c.duration and c.duration > 0 then 
                    has_duration = true
                    -- Компилируем само условие для ускорения интерпретатора
                    if not c._compiled_cond then
                        local upvalues = {}
                        local expr = _generate_cond_expr(c, upvalues)
                        local uv_env = { 
                            type = type, tostring = tostring, 
                            string_find = string_find, string_match = string_match 
                        }
                        for _, uv in ipairs(upvalues) do uv_env[uv.name] = uv.value end
                        local code = string_format("return function(data) return %s end", expr)
                        local factory = load(code, "=(cond_jit)", "t", uv_env)
                        if factory then c._compiled_cond = factory() end
                    end
                end
                if c.conditions then check_dur(c) end
            end
        end
        check_dur(filters)

        if not has_duration then
            local upvalues = {}
            local expr = _generate_recursive(filters, upvalues)
            
            local uv_decl = {}
            local uv_env = { 
                type = type, tostring = tostring, 
                string_find = string_find, string_match = string_match 
            }
            for _, uv in ipairs(upvalues) do
                table_insert(uv_decl, uv.name)
                uv_env[uv.name] = uv.value
            end
            
            local code = string_format(
                "return function(data) return %s end",
                expr
            )
            
            local factory, err = load(code, "=(filter_jit)", "t", uv_env)
            if factory then
                local ok, func = pcall(factory)
                if ok and type(func) == "function" then
                    filters._compiled_func = func
                end
            else
                Logger.error(COMPONENT_NAME, "JIT Error: %s", tostring(err))
            end
        end
    end

    if filters._compiled_func then
        local ok, res = pcall(filters._compiled_func, data)
        return ok and res == true
    end

    -- Lua-скрипт
    if filters.script and type(filters.script) == "string" then
        local func = state.script_cache[filters.script]
        if not func then
            if state.script_cache_count >= MAX_CACHE_SIZE then
                state.script_cache = {}
                state.script_cache_count = 0
            end
            local env = { data = data, type = type, tostring = tostring, os_time = os_time, pairs = pairs, ipairs = ipairs }
            local err
            func, err = load(filters.script, "=(filter_script)", "t", env)
            if func then
                state.script_cache[filters.script] = func
                state.script_cache_count = state.script_cache_count + 1
            else
                Logger.error(COMPONENT_NAME, "Script Error: %s", tostring(err))
                return false
            end
        end
        local ok, res = pcall(func)
        return ok and res == true
    end

    -- Интерпретируемый режим (для Duration или Fallback)
    if filters.conditions then
        local logic = filters.logic or "and"
        if logic == "and" then
            for i, cond in ipairs(filters.conditions) do
                if not _check_condition(data, cond, sub_id, i) then return false end
            end
            return true
        else
            for i, cond in ipairs(filters.conditions) do
                if _check_condition(data, cond, sub_id, i) then return true end
            end
            return false
        end
    end

    -- Простая фильтрация по полям
    for key, val in pairs(filters) do
        if key ~= "conditions" and key ~= "logic" and key ~= "script" and not key:find("^_") then
            if data[key] ~= val then return false end
        end
    end

    return true
end

return FilterEngine
