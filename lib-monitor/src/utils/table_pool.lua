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
local Utils = ModuleManager.get_module("utils")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "TablePool"
local MonitorConfig = ModuleManager.get_module("monitor_config")
local MAX_POOL_SIZE = (MonitorConfig and MonitorConfig.MaxPoolSize) or 100 -- Максимальное количество таблиц в пуле одного типа

--- @class TablePool
--- @field private pools table<string, table<number, table>> Хранилище пулов по типам
local TablePool = {}

local pools = {}

--- Преаллокация таблиц в пуле
--- @param pool_type string Тип пула
--- @param count number Количество таблиц
function TablePool.preallocate(pool_type, count)
    local pool = pools[pool_type]
    if not pool then
        pool = {}
        pools[pool_type] = pool
    end

    local current = #pool
    if current < count then
        for _ = 1, (count - current) do
            table.insert(pool, {})
        end
    end
end

--- Очищает таблицу рекурсивно
--- @param t table Таблица для очистки
--- @param deep boolean|nil Флаг глубокой очистки
--- @param visited table|nil Защита от циклических ссылок
local function clear_table(t, deep, visited)
    if type(t) ~= "table" then return end
    visited = visited or {}
    if visited[t] then return end
    visited[t] = true

    for k, v in pairs(t) do
        if deep and type(v) == "table" then
            clear_table(v, true, visited)
        end
        t[k] = nil
    end
end

--- Рекурсивно возвращает вложенные таблицы в пул
--- @param t table Таблица, содержащая вложенные таблицы
--- @param item_pool_type string Тип пула для вложенных таблиц
local function release_nested(t, item_pool_type)
    if type(t) ~= "table" then return end
    for k, v in pairs(t) do
        if type(v) == "table" then
            TablePool.release(v, item_pool_type)
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
--- @param deep_or_nested boolean|string|nil Флаг глубокой очистки (boolean) или тип пула для вложенных таблиц (string)
function TablePool.release(t, pool_type, deep_or_nested)
    if type(t) ~= "table" then return end

    pool_type = pool_type or "generic"
    local pool = pools[pool_type]
    if not pool then
        pool = {}
        pools[pool_type] = pool
    end

    if #pool < MAX_POOL_SIZE then
        -- Оптимизация: Быстрая очистка для известных типов
        if pool_type == "event" then
            t.id = nil
            t.type = nil
            t.data = nil
            t.priority = nil
            t.timestamp = nil
            t.source = nil
            t.source_monitor = nil
            t.is_table = nil
            t.json_cache = nil
        elseif pool_type == "pid_stats" then
            t.type = nil
            t.cc = nil
            t.pes = nil
            t.sc = nil
        elseif pool_type == "log_entry" then
            t.timestamp = nil
            t.level = nil
            t.message = nil
            t.context_id = nil
            t.msg = nil
        elseif pool_type == "retry_item" then
            t.config = nil
            t.data = nil
            t.type = nil
            t.retries = nil
            t.time = nil
        elseif pool_type == "lvc_wrapper" then
            t.data = nil
            t.timestamp = nil
        elseif pool_type == "report" and type(deep_or_nested) ~= "string" then
            -- Для отчетов используем глубокую очистку, так как они могут содержать вложенные данные
            -- Но если передан тип вложенного пула, идем в общую логику release_nested
            clear_table(t, true)
        elseif pool_type == "lvc_entry" or pool_type == "lvc_sub" or pool_type == "generic" or pool_type == "batch_queue" then
            if Utils and Utils.table_clear then
                Utils.table_clear(t)
            else
                for k in pairs(t) do t[k] = nil end
            end
        else
            if type(deep_or_nested) == "string" then
                release_nested(t, deep_or_nested)
            else
                clear_table(t, deep_or_nested)
            end
        end
        table_insert(pool, t)
    end
end

--- Полностью очищает все пулы таблиц.
--- Используется для освобождения памяти при достижении лимитов.
function TablePool.clear_all()
    for name, pool in pairs(pools) do
        for i = 1, #pool do
            pool[i] = nil
        end
        pools[name] = {}
    end
    -- Согласно astra-api-usage.md: ручное управление памятью обязательно
    collectgarbage()
    Logger.debug(COMPONENT_NAME, "Все пулы таблиц очищены")
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
