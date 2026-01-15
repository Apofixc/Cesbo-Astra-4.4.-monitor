-- ===========================================================================
-- Модуль `utils.table_pool`
--
-- Пул таблиц для оптимизации работы с памятью и снижения нагрузки на GC.
-- Реализует автоматический рекурсивный возврат вложенных объектов в их пулы.
-- ===========================================================================

-- 1. Стандартные Lua функции
local next = _G.next
local type = _G.type
local pcall = _G.pcall
local math_floor = _G.math.floor
local math_max = _G.math.max
local getmetatable = _G.getmetatable
local setmetatable = _G.setmetatable
local collectgarbage = _G.collectgarbage

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local Scheduler = ModuleManager.get_module("core.scheduler")

-- 3. Глобальные зависимости Astra
-- (Модуль не использует внешние зависимости Astra)

-- 4. Константы и конфигурации
local COMPONENT_NAME = "TablePool"

-- Настройки пула по умолчанию
local DEFAULT_MAX_POOL_SIZE = (MonitorConfig and MonitorConfig.MaxPoolSize) or 100
local MAX_DEPTH = 10 -- Защита от слишком глубокой рекурсии

-- Настройки адаптивности
local ADAPTIVE_THRESHOLD = (MonitorConfig and MonitorConfig.PoolAdaptiveThreshold) or 0.2
local ADAPTIVE_STEP = (MonitorConfig and MonitorConfig.PoolAdaptiveStep) or 0.25
local MIN_LIMIT = (MonitorConfig and MonitorConfig.PoolMinLimit) or 10
local MAINTENANCE_INTERVAL = (MonitorConfig and MonitorConfig.PoolMaintenanceInterval) or 300

-- 5. Инициализация объектов и внутреннее состояние
--- @class TablePoolState
--- @field pools table<string, table[]> Таблицы пулов: type -> { t1, t2, ... }
--- @field cleaners table<string, function> Кастомные функции очистки: type -> function
--- @field limits table<string, number> Лимиты размеров: type -> number
--- @field stats table<string, table> Статистика использования: type -> { hits, misses, created }
--- @field visited_cache table<table, boolean> Кэш для защиты от циклических ссылок
--- @field visited_count number Счетчик вложенности для очистки кэша
--- @field debug_mode boolean Режим отладки
local state = {
    pools = {},
    cleaners = {},
    limits = {},
    stats = {},
    visited_cache = {},
    visited_count = 0,
    debug_mode = (MonitorConfig and MonitorConfig.PoolDebug) or false,
}

--- @class TablePool
local TablePool = {}

-- ===========================================================================
-- Внутренние функции (Private)
-- ===========================================================================

--- Очищает кэш посещенных объектов
local function _clear_visited_cache()
    for k in next, state.visited_cache do
        state.visited_cache[k] = nil
    end
end

--- Внутренняя рекурсивная функция очистки таблицы.
--- Реализует автоматический возврат вложенных таблиц в их родные пулы.
--- @param t table Таблица для очистки
--- @param deep boolean|string Флаг глубокой очистки (рекурсия по обычным таблицам)
--- @param depth number Текущая глубина рекурсии
local function _do_clear_table(t, deep, depth)
    local default_child_pool = type(deep) == "string" and deep or nil

    for k, v in next, t do
        if k ~= "__pool_type" then
            if type(v) == "table" and not state.visited_cache[v] then
                local v_pool_type = v.__pool_type or default_child_pool
                if v_pool_type then
                    -- Автоматический возврат вложенного объекта в его пул
                    TablePool.release(v, v_pool_type, deep, depth + 1)
                elseif deep and depth < MAX_DEPTH then
                    -- Рекурсивная очистка обычной вложенной таблицы
                    state.visited_cache[v] = true
                    _do_clear_table(v, true, depth + 1)
                end
            end
            t[k] = nil
        end
    end
end

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- Включает или выключает режим отладки
--- @param enabled boolean Статус режима отладки
function TablePool.set_debug(enabled)
    state.debug_mode = enabled
end

--- Регистрирует новый тип пула.
--- @param pool_type string Уникальное имя типа (например, "report")
--- @param cleaner? function|table Опциональная функция очистки или список ключей (схема)
--- @param max_size? number Максимальный размер пула (по умолчанию 100)
--- @param preallocate_count? number Количество таблиц для преаллокации
function TablePool.register_type(pool_type, cleaner, max_size, preallocate_count)
    if type(pool_type) ~= "string" or state.pools[pool_type] then return end

    -- Автоматический запуск обслуживания при первой регистрации пула
    if MonitorConfig and not MonitorConfig.PoolMaintenanceStarted and Scheduler then
        local s = Scheduler.get_instance()
        if s then
            s:add_task("table_pool_maintenance", function()
                TablePool.maintain()
            end, MAINTENANCE_INTERVAL)
            MonitorConfig.PoolMaintenanceStarted = true
            Logger.debug(COMPONENT_NAME,
                "Автоматическое обслуживание пулов запущено (интервал: %d сек)",
                MAINTENANCE_INTERVAL)
        end
    end

    state.pools[pool_type] = {}

    -- Если передана таблица ключей, создаем оптимизированный очиститель по схеме
    if type(cleaner) == "table" then
        local schema = cleaner
        cleaner = function(t, deep, depth)
            for i = 1, #schema do
                local k = schema[i]
                local v = t[k]
                if type(v) == "table" and not state.visited_cache[v] then
                    local v_pool_type = v.__pool_type
                    if v_pool_type then
                        TablePool.release(v, v_pool_type, deep, depth + 1)
                    elseif deep and depth < MAX_DEPTH then
                        state.visited_cache[v] = true
                        _do_clear_table(v, true, depth + 1)
                    end
                end
                t[k] = nil
            end
            -- В режиме отладки проверяем, не осталось ли лишних полей
            if state.debug_mode then
                for k in next, t do
                    if k ~= "__pool_type" and k ~= "__in_pool" then
                        Logger.error(COMPONENT_NAME,
                            "Схематичный очиститель '%s' пропустил поле: %s",
                            pool_type, tostring(k))
                        t[k] = nil
                    end
                end
            end
        end
    end

    state.cleaners[pool_type] = cleaner
    state.stats[pool_type] = { hits = 0, misses = 0, created = 0 }

    -- Приоритет лимита: конфиг -> аргумент -> значение по умолчанию
    local limit = max_size
    if MonitorConfig and MonitorConfig.PoolLimits then
        limit = MonitorConfig.PoolLimits[pool_type] or limit
    end
    state.limits[pool_type] = limit or DEFAULT_MAX_POOL_SIZE

    if type(preallocate_count) == "number" and preallocate_count > 0 then
        TablePool.preallocate(pool_type, preallocate_count)
    end
end

--- Публичный метод преаллокации таблиц.
--- @param pool_type string Тип пула
--- @param count number Количество таблиц
function TablePool.preallocate(pool_type, count)
    local pool = state.pools[pool_type]
    if not pool then return end

    local limit = state.limits[pool_type] or DEFAULT_MAX_POOL_SIZE
    local current = #pool
    if count > limit then count = limit end

    if current < count then
        local s = state.stats[pool_type]
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

--- Возвращает чистую таблицу из пула.
--- @param pool_type? string Тип пула (по умолчанию "generic")
--- @return table Свободная таблица
function TablePool.get(pool_type)
    pool_type = pool_type or "generic"
    local pool = state.pools[pool_type]
    if not pool then
        TablePool.register_type(pool_type)
        pool = state.pools[pool_type]
    end

    local size = #pool
    if size > 0 then
        local t = pool[size]
        pool[size] = nil

        t.__in_pool = nil -- Снимаем метку нахождения в пуле

        local s = state.stats[pool_type]
        if s then s.hits = s.hits + 1 end
        return t
    end

    -- Пул пуст, создаем новый объект
    local s = state.stats[pool_type]
    if s then
        s.misses = s.misses + 1
        s.created = s.created + 1
    end

    return { __pool_type = pool_type }
end

--- Возвращает таблицу в пул для повторного использования.
--- @param t table Таблица для возврата
--- @param pool_type? string Тип пула (если nil, берется из объекта)
--- @param deep? boolean|string Флаг глубокой очистки (рекурсивный возврат вложенных таблиц)
--- @param depth? number Внутренний параметр глубины рекурсии
function TablePool.release(t, pool_type, deep, depth)
    depth = depth or 0
    if type(t) ~= "table" or state.visited_cache[t] then return end
    if depth == 0 then state.visited_count = state.visited_count + 1 end

    -- Определяем целевой пул
    pool_type = pool_type or t.__pool_type or "generic"

    -- Защита от двойного возврата (O(1))
    if t.__in_pool then
        Logger.warn(COMPONENT_NAME,
            "Попытка двойного освобождения таблицы в пул '%s'", pool_type)
        if depth == 0 then
            state.visited_count = state.visited_count - 1
            if state.visited_count == 0 then _clear_visited_cache() end
        end
        return
    end

    local pool = state.pools[pool_type]
    if not pool then
        TablePool.register_type(pool_type)
        pool = state.pools[pool_type]
    end

    -- Оптимизация: если пул полон и не требуется глубокая очистка, выходим сразу
    local limit = state.limits[pool_type] or DEFAULT_MAX_POOL_SIZE
    if depth == 0 and #pool >= limit and not deep then
        state.visited_count = state.visited_count - 1
        if state.visited_count == 0 then _clear_visited_cache() end
        return
    end

    state.visited_cache[t] = true

    -- Выполняем очистку
    local cleaner = state.cleaners[pool_type]
    local is_deep = (deep == true or type(deep) == "string")
    if cleaner then
        -- Кастомные очистители запускаем в pcall для безопасности
        local ok, err = pcall(cleaner, t, is_deep, depth)
        if not ok then
            Logger.error(COMPONENT_NAME, "Ошибка в кастомном очистителе пула '%s': %s", pool_type, tostring(err))
        end
    elseif depth < MAX_DEPTH then
        -- Стандартная очистка (быстрее без pcall)
        _do_clear_table(t, is_deep, depth)
    end

    if getmetatable(t) then setmetatable(t, nil) end

    -- Обновляем метку типа (важно при миграции между пулами)
    t.__pool_type = pool_type

    if #pool < limit then
        t.__in_pool = pool_type

        if state.debug_mode then
            for k in next, t do
                if k ~= "__in_pool" and k ~= "__pool_type" then
                    Logger.error(COMPONENT_NAME, "Таблица '%s' возвращена грязной! Поле: %s", pool_type, tostring(k))
                    t[k] = nil
                end
            end
        end

        pool[#pool + 1] = t
    end

    if depth == 0 then
        state.visited_count = state.visited_count - 1
        if state.visited_count == 0 then _clear_visited_cache() end
    end
end

--- Полностью очищает все пулы и вызывает сборщик мусора.
function TablePool.clear_all()
    for name, pool in pairs(state.pools) do
        for i = 1, #pool do
            local t = pool[i]
            if t then t.__in_pool = nil end
            pool[i] = nil
        end

        local s = state.stats[name]
        if s then
            s.hits = 0
            s.misses = 0
            s.created = 0
        end
    end

    collectgarbage()
    Logger.debug(COMPONENT_NAME, "Все пулы таблиц очищены")
end

--- Выполняет обслуживание пулов: адаптивное изменение лимитов.
--- Рекомендуется вызывать периодически (например, раз в минуту).
function TablePool.maintain()
    for name, s in pairs(state.stats) do
        local total = s.hits + s.misses
        if total > 0 then
            local miss_rate = s.misses / total
            local current_limit = state.limits[name] or DEFAULT_MAX_POOL_SIZE

            if miss_rate > ADAPTIVE_THRESHOLD then
                -- Расширяем пул
                local new_limit = math_floor(current_limit * (1 + ADAPTIVE_STEP))
                state.limits[name] = new_limit
                Logger.debug(COMPONENT_NAME,
                    "Пул '%s' расширен: %d -> %d (miss rate: %.2f)",
                    name, current_limit, new_limit, miss_rate)
            elseif miss_rate < 0.05 then
                -- Сжимаем пул, если промахов почти нет
                local new_limit = math_max(MIN_LIMIT, math_floor(current_limit * (1 - ADAPTIVE_STEP)))
                if new_limit < current_limit then
                    state.limits[name] = new_limit
                    Logger.debug(COMPONENT_NAME, "Пул '%s' сжат: %d -> %d", name, current_limit, new_limit)
                end
            end

            -- Сброс статистики для следующего интервала
            s.hits = 0
            s.misses = 0
        end
    end
end

--- Возвращает статистику использования пулов.
--- @return table Статистика (тип -> данные)
function TablePool.get_stats()
    local result = {}
    for name, pool in pairs(state.pools) do
        local s = state.stats[name] or { hits = 0, misses = 0, created = 0 }
        result[name] = {
            size = #pool,
            hits = s.hits,
            misses = s.misses,
            created = s.created,
            limit = state.limits[name] or DEFAULT_MAX_POOL_SIZE
        }
    end
    return result
end

return TablePool
