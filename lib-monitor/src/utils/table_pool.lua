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
local debug_mode = (MonitorConfig and MonitorConfig.PoolDebug) or false

--- Включает или выключает режим отладки для валидации чистоты таблиц
--- @param enabled boolean
function TablePool.set_debug(enabled)
    debug_mode = enabled
end

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

    -- Переопределение лимита из конфигурации
    if MonitorConfig and MonitorConfig.PoolLimits and type(MonitorConfig.PoolLimits[pool_type]) == "number" then
        limits[pool_type] = MonitorConfig.PoolLimits[pool_type]
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
            -- Fallback логика (теперь с предупреждением, так как регистрация обязательна)
            Logger.error(COMPONENT_NAME, "Тип пула '%s' не зарегистрирован! Используется медленная очистка.", pool_type)
            if type(deep_or_nested) == "string" then
                release_nested(t, deep_or_nested)
            else
                clear_table(t, deep_or_nested)
            end
        end
        
        t.__in_pool = pool_type -- Ставим метку перед возвратом в пул

        -- Валидация чистоты таблицы в режиме отладки
        if debug_mode then
            for k, v in pairs(t) do
                if k ~= "__in_pool" then
                    Logger.error(COMPONENT_NAME, "Таблица типа '%s' возвращена в пул не полностью очищенной! Поле: %s", pool_type, tostring(k))
                    t[k] = nil -- Принудительная очистка в режиме отладки
                end
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
