-- ===========================================================================
-- Модуль `utils.table_pool`
--
-- Пул таблиц для оптимизации работы с памятью и снижения нагрузки на GC.
-- Позволяет переиспользовать таблицы для отчетов и событий.
-- ===========================================================================

-- 1. Стандартные Lua функции
local next = next
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

-- Кэш для ускорения доступа к пулам и статистике
local pool_cache = {}
local stats_cache = {}

--- Включает или выключает режим отладки для валидации чистоты таблиц
--- @param enabled boolean
function TablePool.set_debug(enabled)
    debug_mode = enabled
end

--- Инициализирует структуру статистики для типа
--- @param pool_type string
local function init_stats(pool_type)
    if not stats[pool_type] then
        local s = { hits = 0, misses = 0, created = 0 }
        stats[pool_type] = s
        stats_cache[pool_type] = s
    end
end

--- Очищает таблицу рекурсивно (оптимизированная версия)
--- @param t table Таблица для очистки
--- @param deep boolean|nil Флаг глубокой очистки
--- @param visited table|nil Защита от циклических ссылок
local function clear_table(t, deep, visited)
    local k = next(t)
    while k ~= nil do
        local v = t[k]
        if deep and type(v) == "table" then
            visited = visited or {}
            if not visited[v] then
                visited[v] = true
                clear_table(v, true, visited)
            end
        end
        t[k] = nil
        k = next(t)
    end
end

--- Рекурсивно возвращает вложенные таблицы в пул
--- @param t table Таблица, содержащая вложенные таблицы
--- @param item_pool_type string Тип пула для вложенных таблиц
local function release_nested(t, item_pool_type)
    if type(t) ~= "table" then return end
    local k = next(t)
    while k ~= nil do
        local v = t[k]
        if type(v) == "table" then
            TablePool.release(v, item_pool_type)
        end
        t[k] = nil
        k = next(t)
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
    
    local limit = max_size
    -- Переопределение лимита из конфигурации
    if MonitorConfig and MonitorConfig.PoolLimits and type(MonitorConfig.PoolLimits[pool_type]) == "number" then
        limit = MonitorConfig.PoolLimits[pool_type]
    end
    
    limits[pool_type] = limit or DEFAULT_MAX_POOL_SIZE
    
    if not pools[pool_type] then
        pools[pool_type] = {}
        pool_cache[pool_type] = pools[pool_type]
    end
    init_stats(pool_type)
end

-- Регистрация стандартных типов для оптимизации
TablePool.register_type("event", function(t)
    t.id = nil
    t.type = nil
    t.data = nil
    t.priority = nil
    t.timestamp = nil
    t.source = nil
    t.source_monitor = nil
    t.is_table = nil
    t.json_cache = nil
    t.pnr = nil
    t.on_air = nil
    t.value = nil
    t.message = nil
end)

TablePool.register_type("report", function(t, nested_type)
    if type(nested_type) == "string" then
        release_nested(t, nested_type)
    else
        clear_table(t)
    end
end)

--- Преаллокация таблиц в пуле
--- @param pool_type string Тип пула
--- @param count number Количество таблиц
function TablePool.preallocate(pool_type, count)
    local pool = pools[pool_type]
    if not pool then
        pool = {}
        pools[pool_type] = pool
        pool_cache[pool_type] = pool
    end
    init_stats(pool_type)

    local current = #pool
    if current < count then
        local s = stats_cache[pool_type]
        for _ = 1, (count - current) do
            local t = {}
            t.__in_pool = pool_type -- Помечаем для O(1) проверки
            pool[#pool + 1] = t
            s.created = s.created + 1
        end
    end
end

--- Возвращает таблицу из пула указанного типа.
--- Если пул пуст, создает новую таблицу.
--- @param pool_type? string [Тип пула (например, "report", "event"). По умолчанию "generic"]
--- @return table Свободная таблица
function TablePool.get(pool_type)
    pool_type = pool_type or "generic"
    local pool = pool_cache[pool_type]
    if not pool then
        pool = {}
        pools[pool_type] = pool
        pool_cache[pool_type] = pool
        init_stats(pool_type)
    end

    local size = #pool
    if size > 0 then
        local t = pool[size]
        pool[size] = nil
        t.__in_pool = nil -- Снимаем метку
        local s = stats_cache[pool_type]
        s.hits = s.hits + 1
        return t
    end

    local s = stats_cache[pool_type]
    if not s then
        init_stats(pool_type)
        s = stats_cache[pool_type]
    end
    s.misses = s.misses + 1
    s.created = s.created + 1
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

    local pool = pool_cache[pool_type]
    if not pool then
        pool = {}
        pools[pool_type] = pool
        pool_cache[pool_type] = pool
        init_stats(pool_type)
    end

    local limit = limits[pool_type] or DEFAULT_MAX_POOL_SIZE

    if #pool < limit then
        local cleaner = cleaners[pool_type]
        if cleaner then
            cleaner(t, deep_or_nested)
        else
            -- Fallback логика
            if type(deep_or_nested) == "string" then
                release_nested(t, deep_or_nested)
            else
                clear_table(t, deep_or_nested)
            end
        end
        
        t.__in_pool = pool_type -- Ставим метку перед возвратом в пул

        -- Валидация чистоты таблицы в режиме отладки
        if debug_mode then
            local k = next(t)
            while k ~= nil do
                if k ~= "__in_pool" then
                    Logger.error(COMPONENT_NAME, "Таблица типа '%s' возвращена в пул не полностью очищенной! Поле: %s", pool_type, tostring(k))
                    t[k] = nil -- Принудительная очистка в режиме отладки
                end
                k = next(t, k)
            end
        end

        pool[#pool + 1] = t
    end
end

--- Полностью очищает все пулы таблиц.
--- Используется для освобождения памяти при достижении лимитов.
function TablePool.clear_all()
    for name, pool in pairs(pools) do
        for i = 1, #pool do
            local t = pool[i]
            if t then
                t.__in_pool = nil
                pool[i] = nil
            end
        end
        pools[name] = {}
        pool_cache[name] = pools[name]
        
        -- Очистка статистики при полной очистке пулов для предотвращения утечек
        if stats[name] then
            stats[name].hits = 0
            stats[name].misses = 0
            stats[name].created = 0
        end
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
