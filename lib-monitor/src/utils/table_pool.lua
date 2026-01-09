-- ===========================================================================
-- Модуль `utils.table_pool`
--
-- Пул таблиц для оптимизации работы с памятью и снижения нагрузки на GC.
-- Позволяет переиспользовать таблицы для отчетов и событий.
-- ===========================================================================

-- 1. Стандартные Lua функции
local pairs = pairs
local table_insert = table.insert
local table_remove = table.remove
local type = type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "TablePool"
local MAX_POOL_SIZE = 100 -- Максимальное количество таблиц в пуле одного типа

--- @class TablePool
--- @field private pools table<string, table<number, table>> Хранилище пулов по типам
local TablePool = {}

local pools = {}

--- Очищает таблицу рекурсивно
--- @param t table Таблица для очистки
--- @param deep boolean|nil Флаг глубокой очистки
local function clear_table(t, deep)
    for k, v in pairs(t) do
        if deep and type(v) == "table" then
            clear_table(v, true)
        end
        t[k] = nil
    end
end

--- Возвращает таблицу из пула указанного типа.
--- Если пул пуст, создает новую таблицу.
--- @param pool_type? string [Тип пула (например, "report", "event"). По умолчанию "generic"]
--- @return table Свободная таблица
function TablePool.get(pool_type)
    pool_type = pool_type or "generic"
    local pool = pools[pool_type]
    if not pool then
        pool = {}
        pools[pool_type] = pool
    end

    if #pool > 0 then
        return table_remove(pool)
    end

    return {}
end

--- Возвращает таблицу в пул для повторного использования.
--- Перед возвратом таблица полностью очищается.
--- @param t table Таблица для возврата
--- @param pool_type string|nil Тип пула. По умолчанию "generic"
--- @param deep boolean|nil Флаг глубокой очистки. По умолчанию false
function TablePool.release(t, pool_type, deep)
    if type(t) ~= "table" then return end
    
    pool_type = pool_type or "generic"
    local pool = pools[pool_type]
    if not pool then
        pool = {}
        pools[pool_type] = pool
    end

    if #pool < MAX_POOL_SIZE then
        clear_table(t, deep)
        table_insert(pool, t)
    end
end

--- Возвращает статистику использования пулов
--- @return table Статистика (тип -> количество свободных таблиц)
function TablePool.get_stats()
    local stats = {}
    for name, pool in pairs(pools) do
        stats[name] = #pool
    end
    return stats
end

return TablePool
