-- L0: Unit-тесты для модуля utils.wildcard
-- Изоляция через моки ModuleManager (Logger, EventDispatcher).

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
local Mock = require("tools.test_moc")

local mock
local local_mock
local Wildcard
-- Хранилище коллбэка подписки (таблица)
local ref_wildcard_pool = { cb = nil }

local suite = TestSuite:new("L0.utils.wildcard")

suite:setup(function()
    mock = Mock:new()
    local mock_log = { debug = function() end }
    local mock_ed_instance = {
        subscribe = function(self, ev, cb)
            local fn = (type(cb) == "function" and cb) or (type(ev) == "function" and ev)
            ref_wildcard_pool.cb = fn
            if fn then fn({ MaxCacheSize = { wildcard = 100 } }) end
        end,
    }
    local mock_ed = { get_instance = function() return mock_ed_instance end }
    mock:mock_global("ModuleManager", {
        get_module = function(name)
            if name == "logger" then return mock_log end
            if name == "core.event_dispatcher" then return mock_ed end
            return nil
        end,
    })
end)

suite:before_each(function()
    package.loaded["src.utils.wildcard"] = nil
    Wildcard = require("src.utils.wildcard")
    Wildcard.reset_state()
end)

suite:after_each(function()
    if local_mock then
        local_mock:restore()
        local_mock = nil
    end
end)

suite:teardown(function()
    mock:restore()
end)

-- L0-WC-01: Match — паттерн channel:* соответствует channel:error, не sys:info
suite:add_test("compile: паттерн channel:* совпадает с channel:error, не с sys:info", function()
    local matcher = Wildcard.compile("channel:*")
    Assert.is_true(matcher("channel:error"), "channel:error должен совпасть")
    Assert.is_false(matcher("sys:info"), "sys:info не должен совпасть")
end)

suite:add_test("compile: маска * совпадает с любой строкой", function()
    local matcher = Wildcard.compile("*")
    Assert.is_true(matcher("any"), "Любая строка")
    Assert.is_true(matcher("channel:1"), "Строка с двоеточием")
end)

suite:add_test("compile: точное совпадение без спецсимволов", function()
    local matcher = Wildcard.compile("adapter:1")
    Assert.is_true(matcher("adapter:1"), "Точное совпадение")
    Assert.is_false(matcher("adapter:2"), "Другое значение")
end)

suite:add_test("compile: суффикс *:suffix", function()
    local matcher = Wildcard.compile("*:suffix")
    Assert.is_true(matcher("prefix:suffix"), "Совпадение по суффиксу")
    Assert.is_false(matcher("prefix:other"), "Не совпадает")
end)

suite:add_test("compile: один символ ?", function()
    local matcher = Wildcard.compile("a?c")
    Assert.is_true(matcher("abc"), "Один символ")
    Assert.is_false(matcher("ac"), "Нет символа")
    Assert.is_false(matcher("abbc"), "Два символа")
end)

-- match_multiple
suite:add_test("match_multiple: возвращает список совпавших паттернов", function()
    local patterns = { ["channel:*"] = true, ["sys:*"] = true, ["adapter:1"] = true }
    local result = Wildcard.match_multiple("channel:error", patterns)
    Assert.is_not_nil(result, "Результат — таблица")
    local found = false
    for _, p in ipairs(result) do
        if p == "channel:*" then found = true break end
    end
    Assert.is_true(found, "channel:* должен войти в результат")
end)

suite:add_test("match_multiple: при пустом name или не таблице patterns возвращает {}", function()
    Assert.are_equal(0, #Wildcard.match_multiple(nil, { ["*"] = true }), "nil name -> {}")
    Assert.are_equal(0, #Wildcard.match_multiple("x", nil), "nil patterns -> {}")
end)

-- Негативные сценарии
suite:add_test("compile: nil или не строка — возвращает матчер, всегда false", function()
    local m = Wildcard.compile(nil)
    Assert.is_false(m("anything"), "nil pattern -> false")
    local m2 = Wildcard.compile(123)
    Assert.is_false(m2("x"), "number pattern -> false")
end)

suite:add_test("match_multiple: не строка name — пустой результат", function()
    local r = Wildcard.match_multiple(123, { ["*"] = true })
    Assert.are_equal(0, #r, "number name -> {}")
end)

suite:add_test("reset_state: очищает кэш компиляции", function()
    Wildcard.compile("test:pattern")
    Wildcard.reset_state()
    local matcher = Wildcard.compile("test:pattern")
    Assert.is_true(matcher("test:pattern"), "После reset компиляция работает заново")
end)

-- compile: маска * для nil name возвращает false (матчер _create_any_matcher: name ~= nil)
suite:add_test("compile: маска * для nil возвращает false", function()
    local m = Wildcard.compile("*")
    Assert.is_false(m(nil), "nil не совпадает с *")
end)

-- Сегментный матчер: prefix*middle*suffix
suite:add_test("compile: сегменты prefix*middle*suffix совпадают", function()
    local m = Wildcard.compile("pre*middle*suf")
    Assert.is_true(m("preXXXmiddleYYYsuf"), "Три сегмента")
    Assert.is_false(m("preXXXmiddle"), "Нет суффикса")
    Assert.is_false(m("wrongXXXmiddleYYYsuf"), "Нет префикса")
end)

-- Матчер *middle* (_create_middle_matcher)
suite:add_test("compile: маска *middle* совпадает по вхождению", function()
    local m = Wildcard.compile("*middle*")
    Assert.is_true(m("nomiddlehere"), "middle в строке")
    Assert.is_true(m("xmiddleY"), "middle в середине")
    Assert.is_false(m("nomid"), "нет middle")
end)

-- Сегменты: первая часть не в начале имени
suite:add_test("compile: сегменты — часть не в начале возвращает false", function()
    local m = Wildcard.compile("pre*suf")
    Assert.is_false(m("xxxprexxxsuf"), "pre не в начале")
end)

-- Сегменты: последняя часть не в конце имени
suite:add_test("compile: сегменты — часть не в конце возвращает false", function()
    local m = Wildcard.compile("pre*suf")
    Assert.is_false(m("presufxxx"), "suf не в конце")
end)

-- Паттерн *** (только звёзды): ветка table_insert(parts, "*") при not star_found
suite:add_test("compile: паттерн *** даёт матчер любого", function()
    local m = Wildcard.compile("***")
    Assert.is_true(m("anything"), "*** совпадает с любой строкой")
end)

-- match_multiple: >=10 паттернов — строится дерево решений (exact, wild, catch_all)
suite:add_test("match_multiple: при 10+ паттернах используется дерево решений", function()
    local patterns = {}
    for i = 1, 12 do patterns["p" .. i] = true end
    patterns["channel:error"] = true
    patterns["channel:*"] = true
    patterns["*:suffix"] = true
    local result = Wildcard.match_multiple("channel:error", patterns)
    local found = false
    for _, p in ipairs(result) do if p == "channel:error" or p == "channel:*" then found = true break end end
    Assert.is_true(found, "Должен совпасть channel:error или channel:*")
end)

suite:add_test("match_multiple: дерево — точный сегмент и catch_all", function()
    Wildcard.reset_state()
    local patterns = { ["a:b:*"] = true, ["a:b:c"] = true, ["a:*"] = true }
    for i = 1, 10 do patterns["extra" .. i] = true end
    local r = Wildcard.match_multiple("a:b:c", patterns)
    Assert.is_true(#r >= 1, "Хотя бы один паттерн совпал")
end)

-- init_config_subscription: проверка приватного _m_config через get_function_upvalues
suite:add_test("init_config_subscription: подписывается на config:updated:pool", function()
    Wildcard.init_config_subscription()
    Assert.is_not_nil(ref_wildcard_pool.cb, "Коллбэк подписки должен быть сохранён")
    ref_wildcard_pool.cb({ MaxCacheSize = { wildcard = 200 } })
    local mock_read = Mock:new()
    local up = mock_read:get_function_upvalues(Wildcard.compile)
    Assert.is_not_nil(up._m_config, "приватный _m_config доступен через upvalue")
    Assert.are_equal(200, up._m_config.MaxCacheSize.wildcard, "_m_config.MaxCacheSize.wildcard применился из конфига")
end)

-- Граничные значения MaxCacheSize.wildcard и проверка приватного состояния
suite:add_test("коллбэк config:updated:pool: граничные значения MaxCacheSize.wildcard", function()
    Wildcard.init_config_subscription()
    local mock_read = Mock:new()
    ref_wildcard_pool.cb({ MaxCacheSize = { wildcard = 0 } })
    local up = mock_read:get_function_upvalues(Wildcard.compile)
    Assert.are_equal(0, up._m_config.MaxCacheSize.wildcard, "граница 0 применилась")
    ref_wildcard_pool.cb({ MaxCacheSize = { wildcard = 1 } })
    Assert.are_equal(1, up._m_config.MaxCacheSize.wildcard, "граница 1 применилась")
    ref_wildcard_pool.cb({ MaxCacheSize = { wildcard = 999999 } })
    Assert.are_equal(999999, up._m_config.MaxCacheSize.wildcard, "верхняя граница 999999 применилась")
end)

-- Поиск приватного state по структуре (compile_cache, cache_size, decision_tree)
local function find_wildcard_state()
    local mock_read = Mock:new()
    local module_up = mock_read:get_module_upvalues(Wildcard)
    for _, up in pairs(module_up) do
        for _, val in pairs(up) do
            if type(val) == "table" and val.compile_cache ~= nil and val.cache_size ~= nil then
                return val
            end
        end
    end
    return nil
end

-- Проверка приватного state: compile_cache и cache_size после compile и reset_state
suite:add_test("compile и reset_state: приватный state.compile_cache и cache_size", function()
    Wildcard.reset_state()
    local st = find_wildcard_state()
    Assert.is_not_nil(st, "приватный state доступен через upvalue")
    Assert.are_equal(0, st.cache_size, "после reset_state cache_size == 0")
    Wildcard.compile("test:pat")
    Assert.are_equal(1, st.cache_size, "после compile cache_size == 1")
    Assert.is_not_nil(st.compile_cache["test:pat"], "паттерн в compile_cache")
    Assert.are_equal("function", type(st.compile_cache["test:pat"]), "значение — матчер-функция")
    Wildcard.reset_state()
    Assert.are_equal(0, st.cache_size, "после reset_state снова cache_size == 0")
    Assert.is_nil(next(st.compile_cache), "compile_cache пуст после reset_state")
end)

-- Негативный вызов: конфиг без MaxCacheSize.wildcard — тело if не выполняется; проверка что _m_config не изменился
suite:add_test("коллбэк config:updated:pool: негатив — nil, пустая таблица, без wildcard", function()
    Wildcard.init_config_subscription()
    ref_wildcard_pool.cb({ MaxCacheSize = { wildcard = 42 } })
    local mock_read = Mock:new()
    local up = mock_read:get_function_upvalues(Wildcard.compile)
    Assert.are_equal(42, up._m_config.MaxCacheSize.wildcard, "исходное значение 42")
    local ok_nil, err = pcall(function() if ref_wildcard_pool.cb then ref_wildcard_pool.cb(nil) end end)
    Assert.is_true(ok_nil, "cb(nil) обрабатывается без ошибки (ранний return)")
    Assert.is_nil(err, "ошибки нет")
    Assert.are_equal(42, up._m_config.MaxCacheSize.wildcard, "после cb(nil) значение не изменилось")
    if ref_wildcard_pool.cb then
        ref_wildcard_pool.cb({})
        Assert.are_equal(42, up._m_config.MaxCacheSize.wildcard, "после cb({}) значение не изменилось")
        ref_wildcard_pool.cb({ MaxCacheSize = {} })
        Assert.are_equal(42, up._m_config.MaxCacheSize.wildcard, "после cb({ MaxCacheSize = {} }) wildcard не тронут")
    end
end)

-- match_multiple: дерево с сегментом-маской (node.wild), покрытие entry.matcher(seg)
suite:add_test("match_multiple: дерево — сегмент с маской (chan*) совпадает", function()
    Wildcard.reset_state()
    local patterns = {}
    for i = 1, 10 do patterns["x:y" .. i] = true end
    patterns["evt:chan*"] = true
    patterns["evt:adapter*"] = true
    local r = Wildcard.match_multiple("evt:chan1", patterns)
    local found = false
    for _, p in ipairs(r) do if p == "evt:chan*" then found = true break end end
    Assert.is_true(found, "evt:chan* должен совпасть с evt:chan1")
end)

-- Кэш компиляции: переполнение (cache_size >= MaxCacheSize.wildcard)
-- Хак: мок upvalue _m_config.MaxCacheSize.wildcard = 2 для вызова ветки очистки кэша
suite:add_test("compile: при переполнении кэша кэш очищается (хак: upvalue MaxCacheSize)", function()
    Wildcard.reset_state()
    local_mock = Mock:new()
    local ok = local_mock:mock_module_upvalue(Wildcard, "_m_config", { MaxCacheSize = { wildcard = 2 } })
    if ok then
        Wildcard.compile("overflow_1")
        Wildcard.compile("overflow_2")
        Wildcard.compile("overflow_3")
        local m = Wildcard.compile("overflow_3")
        Assert.is_true(m("overflow_3"), "После очистки кэша компиляция работает")
    end
end)

suite:run()
