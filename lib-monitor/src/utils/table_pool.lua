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
local collectgarbage = collectgarbage

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local Utils = ModuleManager.get_module("utils")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "TablePool"
local MonitorConfig = ModuleManager.get_module("monitor_config")
local DEFAULT_MAX_POOL_SIZE = (MonitorConfig and MonitorConfig.MaxPoolSize) or 100

--- @class TablePool
--- @field private pools table<string, table<number, table>> Хранилище пулов по типам
--- @field private cleaners table<string, function> Функции очистки для типов
--- @field private limits table<string, number> Индивидуальные лимиты для типов
--- @field private stats table<string, table> Статистика (hits, misses)
local TablePool = {}

local pools = {}
local cleaners = {}
local limits = {}
local stats = {}

--- Инициализирует структуру статистики для типа
--- @param pool_type string
local function init_stats(pool_type)
    if not stats[pool_type] then
        stats[pool_type] = { hits = 0, misses = 0, created = 0 }
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

-- Регистрация стандартных очистителей
cleaners["event"] = function(t)
    t.id = nil
    t.type = nil
    t.data = nil
    t.priority = nil
    t.timestamp = nil
    t.source = nil
    t.source_monitor = nil
    t.is_table = nil
    t.json_cache = nil
end

cleaners["pid_stats"] = function(t)
    t.type = nil
    t.cc = nil
    t.pes = nil
    t.sc = nil
end

cleaners["log_entry"] = function(t)
    t.timestamp = nil
    t.level = nil
    t.message = nil
    t.context_id = nil
    t.msg = nil
end

cleaners["retry_item"] = function(t)
    t.config = nil
    t.data = nil
    t.type = nil
    t.retries = nil
    t.time = nil
end

cleaners["lvc_wrapper"] = function(t)
    t.data = nil
    t.timestamp = nil
end

cleaners["report"] = function(t)
    clear_table(t, true)
end

local function generic_cleaner(t)
    if Utils and Utils.table_clear then
        Utils.table_clear(t)
    else
        for k in pairs(t) do t[k] = nil end
    end
end

cleaners["lvc_entry"] = generic_cleaner
cleaners["lvc_sub"] = generic_cleaner
cleaners["generic"] = generic_cleaner
cleaners["batch_queue"] = generic_cleaner

--- Регистрирует новый тип пула с кастомным очистителем и лимитом
--- @param pool_type string Тип пула
--- @param cleaner function Функция очистки таблицы
--- @param max_size number|nil Максимальный размер пула
function TablePool.register_type(pool_type, cleaner, max_size)
    if type(pool_type) ~= "string" then return end
    if type(cleaner) == "function" then
        cleaners[pool_type] = cleaner
    end
    if type(max_size) == "number" then
        limits[pool_type] = max_size
    end
    if not pools[pool_type] then
        pools[pool_type] = {}
    end
    init_stats(pool_type)
end

--- Преаллокация таблиц в пуле
--- @param pool_type string Тип пула
--- @param count number Количество таблиц
function TablePool.preallocate(pool_type, count)
    local pool = pools[pool_type]
    if not pool then
        pool = {}
        pools[pool_type] = pool
    end
    init_stats(pool_type)

    local current = #pool
    if current < count then
        for _ = 1, (count - current) do
            local t = {}
            t.__in_pool = pool_type -- Помечаем для O(1) проверки
            table_insert(pool, t)
            stats[pool_type].created = stats[pool_type].created + 1
        end
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
    init_stats(pool_type)

    if #pool > 0 then
        local t = table_remove(pool)
        t.__in_pool = nil -- Снимаем метку
        stats[pool_type].hits = stats[pool_type].hits + 1
        return t
    end

    stats[pool_type].misses = stats[pool_type].misses + 1
    stats[pool_type].created = stats[pool_type].created + 1
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
    
    -- O(1) Защита от двойного высвобождения
    if t.__in_pool then
        if t.__in_pool == pool_type then
            Logger.warn(COMPONENT_NAME, "Попытка двойного высвобождения таблицы в пул '%s'", pool_type)
        else
            Logger.warn(COMPONENT_NAME, "Попытка высвобождения таблицы в пул '%s', хотя она уже в пуле '%s'", pool_type, t.__in_pool)
        end
        return
    end

    local pool = pools[pool_type]
    if not pool then
        pool = {}
        pools[pool_type] = pool
    end
    init_stats(pool_type)

    local limit = limits[pool_type] or DEFAULT_MAX_POOL_SIZE

    if #pool < limit then
        local cleaner = cleaners[pool_type]
        if cleaner then
            -- Если это отчет и передан тип вложенного пула, используем специальную логику
            if pool_type == "report" and type(deep_or_nested) == "string" then
                release_nested(t, deep_or_nested)
            else
                cleaner(t, deep_or_nested)
            end
        else
            -- Fallback логика
            if type(deep_or_nested) == "string" then
                release_nested(t, deep_or_nested)
            else
                clear_table(t, deep_or_nested)
            end
        end
        
        t.__in_pool = pool_type -- Ставим метку перед возвратом в пул
        table_insert(pool, t)
    end
end

--- Полностью очищает все пулы таблиц.
--- Используется для освобождения памяти при достижении лимитов.
function TablePool.clear_all()
    for name, pool in pairs(pools) do
        for i = 1, #pool do
            if pool[i] then
                pool[i].__in_pool = nil
                pool[i] = nil
            end
        end
        pools[name] = {}
    end
    -- Согласно astra-api-usage.md: ручное управление памятью обязательно
    collectgarbage()
    Logger.debug(COMPONENT_NAME, "Все пулы таблиц очищены")
end

--- Возвращает статистику использования пулов
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
