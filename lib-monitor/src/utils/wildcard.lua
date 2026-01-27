-- ===========================================================================
-- Модуль `utils.wildcard`
--
-- Оптимизированный движок сопоставления масок (wildcards).
-- Предварительно компилирует маски в функции для ускорения маршрутизации.
-- Поддерживает символы `*` (любое количество символов) и `?` (один символ).
-- ===========================================================================

-- 1. Стандартные Lua функции
local type = _G.type
local pairs = _G.pairs
local ipairs = _G.ipairs
local table_insert = _G.table.insert
local string_find = _G.string.find
local string_match = _G.string.match
local string_sub = _G.string.sub
local string_gsub = _G.string.gsub
local string_gmatch = _G.string.gmatch

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local EventDispatcher = nil

-- 3. Глобальные зависимости Astra
-- (Модуль не использует внешние зависимости Astra)

-- 4. Константы и конфигурации
local COMPONENT_NAME = "Wildcard"

--- Локальная конфигурация модуля (значения по умолчанию)
local _m_config = {
    MaxCacheSize = {
        wildcard = 1000
    }
}

-- 5. Внутреннее состояние (Private State)
--- @class WildcardState
--- @field compile_cache table<string, function> Кэш скомпилированных функций
--- @field cache_size number Текущее количество элементов в кэше
--- @field decision_tree table|nil Дерево решений для множественного сопоставления
local state = {
    compile_cache = {},
    cache_size = 0,
    decision_tree = nil,
}

--- @class Wildcard
local Wildcard = {}

-- ===========================================================================
-- Внутренние функции (Private/Protected)
-- ===========================================================================

--- Инициализирует подписку на обновление конфигурации
function Wildcard.init_config_subscription()
    if not EventDispatcher then
        EventDispatcher = ModuleManager.get_module("core.event_dispatcher")
    end

    if EventDispatcher then
        local instance = EventDispatcher.get_instance()
        instance:subscribe("config:updated:pool", function(new_config)
            if new_config.MaxCacheSize and new_config.MaxCacheSize.wildcard then
                _m_config.MaxCacheSize.wildcard = new_config.MaxCacheSize.wildcard
                Logger.debug(COMPONENT_NAME, "Лимит кэша Wildcard обновлен: %d", _m_config.MaxCacheSize.wildcard)
            end
        end)
    end
end

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
--- Оптимизировано: читаемый цикл с использованием string.find.
--- @private
--- @param pattern string Маска
--- @return function Функция-матчер
local function _create_segments_matcher(pattern)
    local segments = {}
    for seg in string_gmatch(pattern, "[^*]+") do
        segments[#segments + 1] = seg
    end

    local num_segments = #segments
    if num_segments == 0 then return _create_any_matcher() end

    local first_is_star = string_sub(pattern, 1, 1) == "*"
    local last_is_star = string_sub(pattern, -1, -1) == "*"

    return function(name)
        if not name or type(name) ~= "string" then return false end
        local pos = 1

        for i = 1, num_segments do
            local seg = segments[i]
            if i == 1 and not first_is_star then
                -- Проверка префикса
                if string_find(name, seg, 1, true) ~= 1 then return false end
                pos = #seg + 1
            elseif i == num_segments and not last_is_star then
                -- Проверка суффикса
                local s = string_find(name, seg, -#seg, true)
                if not s or (s + #seg - 1) ~= #name then return false end
            else
                -- Поиск сегмента в середине
                local s, e = string_find(name, seg, pos, true)
                if not s then return false end
                pos = e + 1
            end
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

--- Очищает дерево решений. Вызывается при изменении набора подписок.
function Wildcard.clear_tree()
    state.decision_tree = nil
end

--- Сопоставляет имя события со всеми активными масками за один проход.
--- Реализует дерево решений (Decision Tree) для оптимизации маршрутизации.
--- @param name string Имя события
--- @param patterns table<string, any> Список активных паттернов (ключи - паттерны)
--- @return table Список совпавших паттернов
function Wildcard.match_multiple(name, patterns)
    -- Если паттернов мало, используем обычный перебор (Fast Path)
    local count = 0
    for _ in pairs(patterns) do count = count + 1 end

    if count < 5 then
        local result = {}
        for p in pairs(patterns) do
            if Wildcard.compile(p)(name) then
                table_insert(result, p)
            end
        end
        return result
    end

    -- Построение дерева решений (ленивая инициализация)
    if not state.decision_tree then
        local tree = { nodes = {}, patterns = {} }
        for p in pairs(patterns) do
            local current = tree
            -- Разбиваем паттерн на сегменты по разделителю (например, ":" или ".")
            for segment in p:gmatch("[^:.]+") do
                current.nodes = current.nodes or {}
                current.nodes[segment] = current.nodes[segment] or { nodes = {}, patterns = {} }
                current = current.nodes[segment]
            end
            table_insert(current.patterns, p)
        end
        state.decision_tree = tree
    end

    -- Поиск по дереву
    local result = {}
    local function search(node, segments, idx)
        -- Добавляем паттерны текущего узла
        for _, p in ipairs(node.patterns) do table_insert(result, p) end

        local seg = segments[idx]
        if not seg then return end

        if node.nodes then
            -- Точное совпадение сегмента
            if node.nodes[seg] then
                search(node.nodes[seg], segments, idx + 1)
            end
            -- Совпадение через wildcard (если есть в дереве)
            if node.nodes["*"] then
                search(node.nodes["*"], segments, idx + 1)
            end
        end
    end

    local name_segments = {}
    for s in name:gmatch("[^:.]+") do table_insert(name_segments, s) end
    search(state.decision_tree, name_segments, 1)

    return result
end

--- Компилирует маску в функцию сопоставления.
--- Поддерживает оптимизированные пути для частых случаев (префиксы, суффиксы, сегменты).
--- @param pattern string Маска (например, "channel:*", "adapter:1", "*", "a?c")
--- @return function Функция-матчер
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
    if state.cache_size >= _m_config.MaxCacheSize.wildcard then
        state.compile_cache = {}
        state.cache_size = 0
    end

    state.compile_cache[pattern] = matcher
    state.cache_size = state.cache_size + 1

    return matcher
end

-- ===========================================================================
-- Инициализация модуля
-- ===========================================================================

return Wildcard
