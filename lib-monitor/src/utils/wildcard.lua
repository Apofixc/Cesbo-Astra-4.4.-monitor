-- ===========================================================================
-- Модуль `utils.wildcard`
--
-- Оптимизированный движок сопоставления масок (wildcards).
-- Предварительно компилирует маски в функции для ускорения маршрутизации.
-- Поддерживает символы `*` (любое количество символов) и `?` (один символ).
-- ===========================================================================

-- 1. Стандартные Lua функции
local type = _G.type
local string_find = _G.string.find
local string_match = _G.string.match
local string_sub = _G.string.sub
local string_gsub = _G.string.gsub
local string_gmatch = _G.string.gmatch

-- 2. Функции из ModuleManager.get_module()
-- (Модуль не использует другие модули библиотеки)

-- 3. Глобальные зависимости Astra
-- (Модуль не использует внешние зависимости Astra)

-- 4. Константы и конфигурации
--- Максимальный размер кэша скомпилированных функций
local MAX_CACHE_SIZE = 1000

-- 5. Инициализация объектов и внутреннее состояние
--- @class WildcardState
--- @field compile_cache table<string, function> Кэш скомпилированных функций
--- @field cache_size number Текущее количество элементов в кэше
local state = {
    compile_cache = {},
    cache_size = 0,
}

--- @class Wildcard
local Wildcard = {}

-- ===========================================================================
-- Внутренние функции (Private)
-- ===========================================================================

--- Создает матчер для любого значения (маска "*")
--- @private
--- @return function Функция-матчер
local function _create_any_matcher()
    return function(name)
        return name ~= nil
    end
end

--- Создает матчер для точного совпадения строк
--- @private
--- @param pattern string Маска
--- @return function Функция-матчер
local function _create_exact_matcher(pattern)
    return function(name)
        return pattern == name
    end
end

--- Создает матчер для проверки префикса (маска "prefix:*")
--- @private
--- @param pattern string Маска
--- @return function Функция-матчер
local function _create_prefix_matcher(pattern)
    local prefix = string_sub(pattern, 1, -2)
    return function(name)
        if not name or type(name) ~= "string" then return false end
        return string_find(name, prefix, 1, true) == 1
    end
end

--- Создает матчер для проверки суффикса (маска "*:suffix")
--- @private
--- @param pattern string Маска
--- @return function Функция-матчер
local function _create_suffix_matcher(pattern)
    local suffix = string_sub(pattern, 2)
    local suffix_len = #suffix
    return function(name)
        if not name or type(name) ~= "string" then return false end
        return string_find(name, suffix, -suffix_len, true) ~= nil
    end
end

--- Создает матчер для проверки вхождения (маска "*middle*")
--- @private
--- @param pattern string Маска
--- @return function Функция-матчер
local function _create_middle_matcher(pattern)
    local middle = string_sub(pattern, 2, -2)
    return function(name)
        if not name or type(name) ~= "string" then return false end
        return string_find(name, middle, 1, true) ~= nil
    end
end

--- Создает матчер для сложных масок с множественными сегментами (только "*")
--- Например: "prefix*middle*suffix"
--- Оптимизировано: использование локальных переменных для ускорения цикла.
--- @private
--- @param pattern string Маска
--- @return function Функция-матчер
local function _create_segments_matcher(pattern)
    local segments = {}
    local segment_lens = {}
    for seg in string_gmatch(pattern, "[^*]+") do
        segments[#segments + 1] = seg
        segment_lens[#segment_lens + 1] = #seg
    end

    local num_segments = #segments
    if num_segments == 0 then -- Только звезды
        return _create_any_matcher()
    end

    local first_is_star = string_sub(pattern, 1, 1) == "*"
    local last_is_star = string_sub(pattern, -1, -1) == "*"

    local start_idx = first_is_star and 1 or 2
    local end_idx = last_is_star and num_segments or num_segments - 1
    local first_seg = segments[1]
    local first_seg_len = segment_lens[1]
    local last_seg = segments[num_segments]
    local last_seg_len = segment_lens[num_segments]

    -- Кэшируем функции для Fast Path
    local find = string_find

    return function(name)
        if not name or type(name) ~= "string" then return false end
        local pos = 1

        -- 1. Проверка первого сегмента (если маска не начинается со звезды)
        if not first_is_star then
            if find(name, first_seg, 1, true) ~= 1 then return false end
            pos = first_seg_len + 1
        end

        -- 2. Проверка промежуточных сегментов (поиск по порядку)
        for i = start_idx, end_idx do
            local s, e = find(name, segments[i], pos, true)
            if not s then return false end
            pos = e + 1
        end

        -- 3. Проверка последнего сегмента (если маска не заканчивается звездой)
        if not last_is_star and num_segments > (first_is_star and 0 or 1) then
            local s = find(name, last_seg, -last_seg_len, true)
            if not s or (s + last_seg_len - 1) ~= #name then return false end
        end

        return true
    end
end

--- Создает универсальный матчер на основе регулярных выражений Lua
--- Используется как fallback для масок с "?" или сложной комбинацией "*"
--- @private
--- @param pattern string Маска
--- @return function Функция-матчер
local function _create_regex_matcher(pattern)
    -- Экранируем магические символы Lua, кроме * и ?
    local regex = string_gsub(pattern, "%%", "%%%%")
    regex = string_gsub(regex, "([%^%$%(%)%.%[%]%+%-%?])", function(c)
        if c == "?" then return "." end
        return "%%" .. c
    end)
    -- Заменяем * на .* для regex
    regex = string_gsub(regex, "%*", ".*")
    local final_regex = "^" .. regex .. "$"

    return function(name)
        if not name or type(name) ~= "string" then return false end
        return string_match(name, final_regex) ~= nil
    end
end

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- Компилирует маску в функцию сопоставления.
--- Поддерживает оптимизированные пути для частых случаев (префиксы, суффиксы, сегменты).
--- @param pattern string Маска (например, "channel:*", "adapter:1", "*", "a?c")
--- @return function Функция вида function(name: string) -> boolean
function Wildcard.compile(pattern)
    if not pattern or type(pattern) ~= "string" then
        return function() return false end
    end

    -- Проверка кэша
    local cached = state.compile_cache[pattern]
    if cached then return cached end

    local matcher

    -- Определение стратегии компиляции
    if pattern == "*" then
        -- 1. Любая строка (Оптимизировано: константная функция)
        matcher = _create_any_matcher()
    elseif not string_find(pattern, "[%*%?]") then
        -- 2. Прямое сравнение (нет спецсимволов)
        matcher = _create_exact_matcher(pattern)
    elseif string_match(pattern, "^[^%*%?]+%*$") then
        -- 3. Оптимизация: Префикс "prefix:*"
        matcher = _create_prefix_matcher(pattern)
    elseif string_match(pattern, "^%*[^%*%?]+$") then
        -- 4. Оптимизация: Суффикс "*:suffix"
        matcher = _create_suffix_matcher(pattern)
    elseif string_match(pattern, "^%*[^%*%?]+%*$") then
        -- 5. Оптимизация: Вхождение "*middle*"
        matcher = _create_middle_matcher(pattern)
    elseif not string_find(pattern, "?", 1, true) then
        -- 6. Оптимизация: Множественные сегменты (только *)
        matcher = _create_segments_matcher(pattern)
    else
        -- 7. Общий случай: Регулярное выражение Lua (поддержка ?)
        matcher = _create_regex_matcher(pattern)
    end

    -- Управление кэшем (очистка при переполнении)
    if state.cache_size >= MAX_CACHE_SIZE then
        state.compile_cache = {}
        state.cache_size = 0
    end

    state.compile_cache[pattern] = matcher
    state.cache_size = state.cache_size + 1

    return matcher
end

return Wildcard
