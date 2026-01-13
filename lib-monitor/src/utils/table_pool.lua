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

-- Кэши для ускорения доступа
local pool_cache = {}
local stats_cache = {}

-- Режим отладки для проверки чистоты возвращаемых таблиц
local debug_mode = (MonitorConfig and MonitorConfig.PoolDebug) or false

-- Статический кэш для защиты от циклических ссылок (избегаем аллокаций в горячем цикле)
local visited_cache = {}
local visited_depth = 0

--- Включает или выключает режим отладки
--- @param enabled boolean
function TablePool.set_debug(enabled)
    debug_mode = enabled
end

--- Инициализирует структуру статистики для типа пула
--- @param pool_type string
local function init_stats(pool_type)
    if not stats[pool_type] then
        local s = { hits = 0, misses = 0, created = 0 }
        stats[pool_type] = s
        stats_cache[pool_type] = s
    end
end

--- Очищает кэш посещенных объектов
local function clear_visited_cache()
    for k in next, visited_cache do
        visited_cache[k] = nil
    end
    visited_depth = 0
end

--- Внутренняя рекурсивная функция очистки таблицы.
--- Реализует автоматический возврат вложенных таблиц в их родные пулы.
--- @param t table Таблица для очистки
--- @param deep boolean Флаг глубокой очистки (рекурсия по обычным таблицам)
local function do_clear_table(t, deep)
    -- 1. Быстрая очистка массивной части (Lua 5.2+ оптимизация)
    local len = #t
    if len > 0 then
        for i = 1, len do
            local v = t[i]
            if type(v) == "table" then
                if v.__pool_type then
                    -- Автоматический возврат вложенного объекта в его пул
                    TablePool.release(v, v.__pool_type, deep)
                elseif deep and visited_depth < MAX_DEPTH then
                    -- Рекурсивная очистка обычной вложенной таблицы
                    if not visited_cache[v] then
                        visited_cache[v] = true
                        visited_depth = visited_depth + 1
                        do_clear_table(v, true)
                        visited_depth = visited_depth - 1
                    end
                end
            end
            t[i] = nil
        end
    end

    -- 2. Очистка хеш-части
    local k = next(t)
    while k ~= nil do
        -- Сохраняем следующий ключ заранее, так как текущий будет удален
        local next_k = next(t, k)
        
        if k ~= "__pool_type" then
            local v = t[k]
            if type(v) == "table" then
                if v.__pool_type then
                    -- Автоматический возврат вложенного объекта
                    TablePool.release(v, v.__pool_type, deep)
                elseif deep and visited_depth < MAX_DEPTH then
                    -- Рекурсивная очистка обычной таблицы
                    if not visited_cache[v] then
                        visited_cache[v] = true
                        visited_depth = visited_depth + 1
                        do_clear_table(v, true)
                        visited_depth = visited_depth - 1
                    end
                end
            end
            t[k] = nil
        end
        k = next_k
    end
end

--- Очищает таблицу перед возвратом в пул.
--- @param t table Таблица для очистки
--- @param deep boolean|nil Флаг глубокой очистки
local function clear_table(t, deep)
    visited_depth = 0
    local ok, err = pcall(do_clear_table, t, deep == true)
    
    -- Гарантированный сброс кэша посещений
    clear_visited_cache()
    
    if not ok then
        Logger.error(COMPONENT_NAME, "Ошибка при очистке таблицы: %s", tostring(err))
    end
end

--- Регистрирует новый тип пула.
--- @param pool_type string Уникальное имя типа (например, "report")
--- @param cleaner? function Опциональная функция кастомной очистки
--- @param max_size? number Максимальный размер пула (по умолчанию 100)
function TablePool.register_type(pool_type, cleaner, max_size)
    if type(pool_type) ~= "string" then return end
    
    if type(cleaner) == "function" then
        cleaners[pool_type] = cleaner
    end
    
    -- Приоритет лимита: конфиг -> аргумент -> значение по умолчанию
    local limit = max_size
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

--- Преаллокация таблиц для минимизации задержек при старте.
--- @param pool_type string Тип пула
--- @param count number Количество таблиц
function TablePool.preallocate(pool_type, count)
    if type(pool_type) ~= "string" or type(count) ~= "number" then return end
    
    local pool = pool_cache[pool_type]
    if not pool then
        TablePool.register_type(pool_type)
        pool = pool_cache[pool_type]
    end

    local limit = limits[pool_type] or DEFAULT_MAX_POOL_SIZE
    local current = #pool
    if count > limit then count = limit end
    
    if current < count then
        local s = stats_cache[pool_type]
        for _ = 1, (count - current) do
            local t = {}
            t.__in_pool = pool_type
            pool[#pool + 1] = t
            if s then s.created = s.created + 1 end
        end
    end
end

--- Возвращает чистую таблицу из пула.
--- @param pool_type? string Тип пула (по умолчанию "generic")
--- @return table Свободная таблица
function TablePool.get(pool_type)
    pool_type = pool_type or "generic"
    local pool = pool_cache[pool_type]
    
    -- Ленивая инициализация пула при первом обращении
    if not pool then
        TablePool.register_type(pool_type)
        pool = pool_cache[pool_type]
    end

    local size = #pool
    if size > 0 then
        local t = pool[size]
        pool[size] = nil
        
        t.__in_pool = nil          -- Снимаем метку нахождения в пуле
        t.__pool_type = pool_type  -- Сохраняем тип для авто-возврата
        
        local s = stats_cache[pool_type]
        if s then s.hits = s.hits + 1 end
        return t
    end

    -- Пул пуст, создаем новый объект
    local s = stats_cache[pool_type]
    if s then
        s.misses = s.misses + 1
        s.created = s.created + 1
    end
    
    local t = {}
    t.__pool_type = pool_type
    return t
end

--- Возвращает таблицу в пул для повторного использования.
--- @param t table Таблица для возврата
--- @param pool_type? string Тип пула (если nil, берется из объекта)
--- @param deep_or_nested? boolean|string Флаг глубокой очистки или тип вложенных таблиц (legacy)
function TablePool.release(t, pool_type, deep_or_nested)
    if type(t) ~= "table" then return end

    -- Определяем целевой пул
    pool_type = pool_type or t.__pool_type or "generic"
    
    -- Защита от двойного возврата (O(1))
    if t.__in_pool then
        Logger.warn(COMPONENT_NAME, "Попытка двойного высвобождения таблицы в пул '%s'", pool_type)
        return
    end

    local pool = pool_cache[pool_type]
    if not pool then
        TablePool.register_type(pool_type)
        pool = pool_cache[pool_type]
    end

    local limit = limits[pool_type] or DEFAULT_MAX_POOL_SIZE
    local pool_full = #pool >= limit

    -- Оптимизация: если пул полон и не требуется рекурсия, просто выбрасываем объект
    if pool_full and not deep_or_nested then
        return
    end

    -- Выполняем очистку
    local cleaner = cleaners[pool_type]
    if cleaner then
        -- Используем кастомный очиститель, если он есть
        cleaner(t, deep_or_nested)
    else
        -- Стандартная очистка с поддержкой авто-рекурсии
        clear_table(t, deep_or_nested)
    end

    -- Если в пуле есть место, сохраняем объект
    if not pool_full then
        t.__in_pool = pool_type

        -- Валидация чистоты в режиме отладки
        if debug_mode then
            local k = next(t)
            while k ~= nil do
                if k ~= "__in_pool" and k ~= "__pool_type" then
                    Logger.error(COMPONENT_NAME, "Таблица '%s' возвращена грязной! Поле: %s", pool_type, tostring(k))
                    t[k] = nil
                end
                k = next(t, k)
            end
        end

        pool[#pool + 1] = t
    end
end

--- Полностью очищает все пулы и вызывает сборщик мусора.
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
        
        if stats[name] then
            stats[name].hits = 0
            stats[name].misses = 0
            stats[name].created = 0
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
