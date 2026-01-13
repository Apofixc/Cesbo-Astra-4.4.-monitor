-- ===========================================================================
-- Модуль `utils.table_pool`
--
-- Пул таблиц для оптимизации работы с памятью и снижения нагрузки на GC.
-- Реализует автоматический рекурсивный возврат вложенных объектов в их пулы.
-- ===========================================================================

-- 1. Стандартные Lua функции
local next = next
local type = type
local pcall = pcall
local getmetatable = getmetatable
local setmetatable = setmetatable
local collectgarbage = collectgarbage

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local MonitorConfig = ModuleManager.get_module("monitor_config")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "TablePool"
local DEFAULT_MAX_POOL_SIZE = (MonitorConfig and MonitorConfig.MaxPoolSize) or 100
local MAX_DEPTH = 10 -- Защита от слишком глубокой рекурсии

--- @class TablePool
local TablePool = {}

-- Внутренние хранилища
local pools = {}    -- Таблицы пулов: type -> { t1, t2, ... }
local cleaners = {} -- Кастомные функции очистки: type -> function
local limits = {}   -- Лимиты размеров: type -> number
local stats = {}    -- Статистика использования: type -> { hits, misses, created }

-- Режим отладки для проверки чистоты возвращаемых таблиц
local debug_mode = (MonitorConfig and MonitorConfig.PoolDebug) or false

-- Статический кэш для защиты от циклических ссылок (избегаем аллокаций в горячем цикле)
local visited_cache = {}
local visited_count = 0

--- Включает или выключает режим отладки
--- @param enabled boolean
function TablePool.set_debug(enabled)
    debug_mode = enabled
end

--- Очищает кэш посещенных объектов
local function clear_visited_cache()
    for k in next, visited_cache do
        visited_cache[k] = nil
    end
end

--- Внутренняя рекурсивная функция очистки таблицы.
--- Реализует автоматический возврат вложенных таблиц в их родные пулы.
--- @param t table Таблица для очистки
--- @param deep boolean Флаг глубокой очистки (рекурсия по обычным таблицам)
--- @param depth number Текущая глубина рекурсии
local function do_clear_table(t, deep, depth)
    for k, v in next, t do
        if k ~= "__pool_type" then
            if type(v) == "table" and not visited_cache[v] then
                local v_pool_type = v.__pool_type
                if v_pool_type then
                    -- Автоматический возврат вложенного объекта в его пул
                    TablePool.release(v, v_pool_type, deep, depth + 1)
                elseif deep and depth < MAX_DEPTH then
                    -- Рекурсивная очистка обычной вложенной таблицы
                    visited_cache[v] = true
                    do_clear_table(v, true, depth + 1)
                end
            end
            t[k] = nil
        end
    end
end

--- Внутренняя функция преаллокации таблиц.
--- @param pool_type string Тип пула
--- @param count number Количество таблиц
local function do_preallocate(pool_type, count)
    local pool = pools[pool_type]
    if not pool then return end
    local limit = limits[pool_type] or DEFAULT_MAX_POOL_SIZE
    local current = #pool
    if count > limit then count = limit end

    if current < count then
        local s = stats[pool_type]
        for _ = 1, (count - current) do
            local t = {
                __in_pool = pool_type,
                __pool_type = pool_type
            }
            pool[#pool + 1] = t
            if s then s.created = s.created + 1 end
        end
    end
end

--- Регистрирует новый тип пула.
--- @param pool_type string Уникальное имя типа (например, "report")
--- @param cleaner? function Опциональная функция кастомной очистки
--- @param max_size? number Максимальный размер пула (по умолчанию 100)
--- @param preallocate_count? number Количество таблиц для преаллокации
function TablePool.register_type(pool_type, cleaner, max_size, preallocate_count)
    if type(pool_type) ~= "string" or pools[pool_type] then return end

    pools[pool_type] = {}
    cleaners[pool_type] = cleaner
    stats[pool_type] = { hits = 0, misses = 0, created = 0 }

    -- Приоритет лимита: конфиг -> аргумент -> значение по умолчанию
    local limit = max_size
    if MonitorConfig and MonitorConfig.PoolLimits then
        limit = MonitorConfig.PoolLimits[pool_type] or limit
    end
    limits[pool_type] = limit or DEFAULT_MAX_POOL_SIZE

    if type(preallocate_count) == "number" and preallocate_count > 0 then
        do_preallocate(pool_type, preallocate_count)
    end
end

--- Возвращает чистую таблицу из пула.
--- @param pool_type? string Тип пула (по умолчанию "generic")
--- @return table Свободная таблица
function TablePool.get(pool_type)
    pool_type = pool_type or "generic"
    local pool = pools[pool_type]
    if not pool then
        TablePool.register_type(pool_type)
        pool = pools[pool_type]
    end

    local size = #pool
    if size > 0 then
        local t = pool[size]
        pool[size] = nil

        t.__in_pool = nil -- Снимаем метку нахождения в пуле

        local s = stats[pool_type]
        if s then s.hits = s.hits + 1 end
        return t
    end

    -- Пул пуст, создаем новый объект
    local s = stats[pool_type]
    if s then
        s.misses = s.misses + 1
        s.created = s.created + 1
    end

    return { __pool_type = pool_type }
end

--- Возвращает таблицу в пул для повторного использования.
--- @param t table Таблица для возврата
--- @param pool_type? string Тип пула (если nil, берется из объекта)
--- @param deep? boolean Флаг глубокой очистки (рекурсивный возврат вложенных таблиц)
--- @param _depth? number Внутренний параметр глубины рекурсии
function TablePool.release(t, pool_type, deep, _depth)
    if type(t) ~= "table" or visited_cache[t] then return end

    local depth = _depth or 0
    if depth == 0 then visited_count = visited_count + 1 end

    -- Определяем целевой пул
    pool_type = pool_type or t.__pool_type or "generic"

    -- Защита от двойного возврата (O(1))
    if t.__in_pool then
        Logger.warn(COMPONENT_NAME, "Попытка двойного освобождения таблицы в пул '%s'", pool_type)
        if depth == 0 then
            visited_count = visited_count - 1
            if visited_count == 0 then clear_visited_cache() end
        end
        return
    end

    local pool = pools[pool_type]
    if not pool then
        TablePool.register_type(pool_type)
        pool = pools[pool_type]
    end

    visited_cache[t] = true

    -- Выполняем очистку в защищенном режиме
    local ok, err = pcall(function()
        local cleaner = cleaners[pool_type]
        if cleaner then
            cleaner(t, deep)
        elseif depth < MAX_DEPTH then
            do_clear_table(t, deep == true, depth)
        end

        if getmetatable(t) then setmetatable(t, nil) end

        local limit = limits[pool_type]
        if #pool < limit then
            t.__in_pool = pool_type

            if debug_mode then
                for k in next, t do
                    if k ~= "__in_pool" and k ~= "__pool_type" then
                        Logger.error(COMPONENT_NAME, "Таблица '%s' возвращена грязной! Поле: %s", pool_type, tostring(k))
                        t[k] = nil
                    end
                end
            end

            pool[#pool + 1] = t
        end
    end)
    if not ok then
        Logger.error(COMPONENT_NAME, "Ошибка при освобождении таблицы в пул '%s': %s", pool_type, tostring(err))
    end

    if depth == 0 then
        visited_count = visited_count - 1
        if visited_count == 0 then clear_visited_cache() end
    end
end

--- Полностью очищает все пулы и вызывает сборщик мусора.
function TablePool.clear_all()
    for name, pool in pairs(pools) do
        for i = 1, #pool do
            local t = pool[i]
            if t then t.__in_pool = nil end
            pool[i] = nil
        end

        local s = stats[name]
        if s then
            s.hits = 0
            s.misses = 0
            s.created = 0
        end
    end

    collectgarbage()
    Logger.debug(COMPONENT_NAME, "Все пулы таблиц очищены")
end

--- Возвращает статистику использования пулов.
--- @return table Статистика (тип -> данные)
function TablePool.get_stats()
    local result = {}
    for name, pool in pairs(pools) do
        local s = stats[name] or { hits = 0, misses = 0, created = 0 }
        result[name] = {
            size = #pool,
            hits = s.hits,
            misses = s.misses,
            created = s.created,
            limit = limits[name] or DEFAULT_MAX_POOL_SIZE
        }
    end
    return result
end

return TablePool
