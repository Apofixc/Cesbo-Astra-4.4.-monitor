-- ===========================================================================
-- Модуль `utils.wildcard`
--
-- Оптимизированный движок сопоставления масок (wildcards).
-- Предварительно компилирует маски в функции для ускорения маршрутизации.
-- Поддерживает символы `*` (любое количество символов) и `?` (один символ).
-- ===========================================================================

-- 1. Стандартные Lua функции
local type = type
local string_find = string.find
local string_gsub = string.gsub
local string_match = string.match
local setmetatable = setmetatable
local next = next

--- @class Wildcard
local Wildcard = {}

-- Кэш скомпилированных функций
local compile_cache = {}
local cache_size = 0
local MAX_CACHE_SIZE = 1000

--- Компилирует маску в функцию сопоставления.
--- @param pattern string Маска (например, "channel:*", "adapter:1", "*", "a?c")
--- @return function Функция вида function(name) -> boolean
function Wildcard.compile(pattern)
    if not pattern or type(pattern) ~= "string" then
        return function() return false end
    end

    -- Проверка кэша
    local cached = compile_cache[pattern]
    if cached then return cached end

    local matcher

    -- 1. Полное совпадение или любая строка
    if pattern == "*" then
        matcher = function(name)
            return name ~= nil and type(name) == "string"
        end
    -- 2. Если маска не содержит спецсимволов, используем прямое сравнение строк
    elseif not string_find(pattern, "[%*%?]") then
        matcher = function(name)
            return pattern == name
        end
    -- 3. Оптимизация: Быстрая проверка префикса для масок вида "prefix:*"
    elseif string_match(pattern, "^[^%*%?]+%*$") then
        local prefix = pattern:sub(1, -2)
        matcher = function(name)
            if not name or type(name) ~= "string" then return false end
            return string_find(name, prefix, 1, true) == 1
        end
    -- 4. Оптимизация: Быстрая проверка суффикса для масок вида "*:suffix"
    elseif string_match(pattern, "^%*[^%*%?]+$") then
        local suffix = pattern:sub(2)
        local suffix_len = #suffix
        matcher = function(name)
            if not name or type(name) ~= "string" then return false end
            return string_find(name, suffix, -suffix_len, true) ~= nil
        end
    -- 5. Оптимизация: Быстрая проверка вхождения для масок вида "*middle*"
    elseif string_match(pattern, "^%*[^%*%?]+%*$") then
        local middle = pattern:sub(2, -2)
        matcher = function(name)
            if not name or type(name) ~= "string" then return false end
            return string_find(name, middle, 1, true) ~= nil
        end
    -- 6. Оптимизация: Множественные сегменты (только *)
    -- Например: "prefix*middle*suffix"
    elseif not string_find(pattern, "?", 1, true) then
        local segments = {}
        local segment_lens = {}
        for seg in pattern:gmatch("[^*]+") do
            segments[#segments + 1] = seg
            segment_lens[#segment_lens + 1] = #seg
        end
        
        local num_segments = #segments
        if num_segments == 0 then -- Только звезды
            matcher = function(name) return name ~= nil and type(name) == "string" end
        else
            local first_is_star = pattern:sub(1, 1) == "*"
            local last_is_star = pattern:sub(-1, -1) == "*"
            
            local start_idx = first_is_star and 1 or 2
            local end_idx = last_is_star and num_segments or num_segments - 1
            local first_seg = segments[1]
            local first_seg_len = segment_lens[1]
            local last_seg = segments[num_segments]
            local last_seg_len = segment_lens[num_segments]

            matcher = function(name)
                if not name or type(name) ~= "string" then return false end
                local pos = 1
                
                -- Проверка первого сегмента
                if not first_is_star then
                    if string_find(name, first_seg, 1, true) ~= 1 then return false end
                    pos = first_seg_len + 1
                end
                
                -- Проверка промежуточных сегментов
                for i = start_idx, end_idx do
                    local s, e = string_find(name, segments[i], pos, true)
                    if not s then return false end
                    pos = e + 1
                end
                
                -- Проверка последнего сегмента
                if not last_is_star and num_segments > (first_is_star and 0 or 1) then
                    if string_find(name, last_seg, -last_seg_len, true) == nil then return false end
                end
                
                return true
            end
        end
    else
        -- 7. Общий случай: Регулярное выражение Lua
        local regex = pattern:gsub("%%", "%%%%")
        regex = regex:gsub("([%^%$%(%)%.%[%]%+%-%?])", function(c)
            if c == "?" then return "." end
            return "%%" .. c
        end)
        regex = regex:gsub("%*", ".*")
        local final_regex = "^" .. regex .. "$"

        matcher = function(name)
            if not name or type(name) ~= "string" then return false end
            return string_match(name, final_regex) ~= nil
        end
    end

    -- Управление кэшем
    if cache_size >= MAX_CACHE_SIZE then
        compile_cache = {}
        cache_size = 0
    end
    compile_cache[pattern] = matcher
    cache_size = cache_size + 1
    
    return matcher
end

return Wildcard
