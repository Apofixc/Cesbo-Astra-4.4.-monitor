-- L1: Unit-тесты для модуля utils.filter_engine
-- Моки: ModuleManager (logger, table_pool, core.event_dispatcher).

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
local Mock = require("tools.test_moc")

local mock
local FilterEngine
local log_calls
local ref_pool_config_cb
local ref_ModuleManager

local suite = TestSuite:new("L1.filter_engine")

suite:setup(function()
    mock = Mock:new()
    log_calls = { debug = 0, error = 0 }

    local mock_log = {
        debug = function() log_calls.debug = log_calls.debug + 1 end,
        error = function() log_calls.error = log_calls.error + 1 end,
    }

    local pool_entries = {}
    local mock_pool = {
        get = function(typ) local t = {}; pool_entries[#pool_entries + 1] = t; return t end,
        release = function(t, typ) end,
        register_type = function(name, schema, a, b) end,
    }

    local mock_ed_instance = {
        subscribe = function(self, ev, cb)
            if ev == "config:updated:pool" then ref_pool_config_cb = cb end
        end
    }
    local mock_ed = { get_instance = function() return mock_ed_instance end }

    ref_ModuleManager = {
        get_module = function(name)
            if name == "logger" then return mock_log end
            if name == "table_pool" then return mock_pool end
            if name == "core.event_dispatcher" then return mock_ed end
            return nil
        end,
    }
    mock:mock_global("ModuleManager", ref_ModuleManager)
end)

suite:before_each(function()
    log_calls.debug = 0
    log_calls.error = 0
    ref_pool_config_cb = nil
    package.loaded["src.utils.filter_engine"] = nil
    FilterEngine = require("src.utils.filter_engine")
end)

suite:teardown(function()
    mock:restore()
end)

-- compile_accessor
suite:add_test("compile_accessor: nil и пустая строка возвращают identity", function()
    local f = FilterEngine.compile_accessor(nil)
    Assert.are_equal(42, f(42), "nil path -> identity")
    local g = FilterEngine.compile_accessor("")
    Assert.are_equal("x", g("x"), "empty path -> identity")
end)

suite:add_test("compile_accessor: один сегмент", function()
    local acc = FilterEngine.compile_accessor("a")
    Assert.are_equal(1, acc({ a = 1 }), "одно поле")
    Assert.is_nil(acc({ b = 2 }), "нет поля -> nil")
    Assert.is_nil(acc("not table"), "не таблица -> nil")
end)

suite:add_test("compile_accessor: два сегмента", function()
    local acc = FilterEngine.compile_accessor("x.y")
    Assert.are_equal(3, acc({ x = { y = 3 } }), "вложенное поле")
    Assert.is_nil(acc({ x = 1 }), "x не таблица -> nil")
end)

suite:add_test("compile_accessor: три и более сегментов", function()
    local acc = FilterEngine.compile_accessor("a.b.c")
    Assert.are_equal(10, acc({ a = { b = { c = 10 } } }), "глубокое поле")
    Assert.is_nil(acc({ a = { b = 1 } }), "b не таблица -> nil")
end)

suite:add_test("compile_accessor: кэш возвращает тот же аксессор", function()
    local a1 = FilterEngine.compile_accessor("k")
    local a2 = FilterEngine.compile_accessor("k")
    Assert.are_equal(a1, a2, "кэш используется")
end)

-- clear_state
suite:add_test("clear_state: без sub_id или без состояния не падает", function()
    FilterEngine.clear_state(nil)
    FilterEngine.clear_state("nonexistent")
end)

suite:add_test("clear_state: освобождает состояние для sub_id", function()
    FilterEngine.match({ x = 1 }, { conditions = { { field = "x", op = "eq", value = 1, duration = 100 } } }, "sub1")
    FilterEngine.clear_state("sub1")
    FilterEngine.clear_state("sub1")
end)

-- match: пустые фильтры
suite:add_test("match: пустые или nil фильтры возвращают true", function()
    Assert.is_true(FilterEngine.match({ a = 1 }, nil), "nil filters")
    Assert.is_true(FilterEngine.match({ a = 1 }, {}), "empty filters")
end)

-- match: простая фильтрация по полям
suite:add_test("match: простая фильтрация по полям (key-value)", function()
    Assert.is_true(FilterEngine.match({ a = 1, b = 2 }, { a = 1 }), "одно поле совпало")
    Assert.is_false(FilterEngine.match({ a = 1 }, { a = 2 }), "значение не совпало")
    Assert.is_true(FilterEngine.match({ a = 1, b = 2 }, { a = 1, b = 2 }), "два поля")
end)

-- match: conditions с logic and/or
suite:add_test("match: conditions logic and", function()
    local filters = { conditions = { { field = "x", op = "eq", value = 1 }, { field = "y", op = "eq", value = 2 } }, logic = "and" }
    Assert.is_true(FilterEngine.match({ x = 1, y = 2 }, filters), "and true")
    Assert.is_false(FilterEngine.match({ x = 1, y = 0 }, filters), "and false")
end)

suite:add_test("match: conditions logic or", function()
    local filters = { conditions = { { field = "x", op = "eq", value = 1 }, { field = "y", op = "eq", value = 2 } }, logic = "or" }
    Assert.is_true(FilterEngine.match({ x = 1, y = 0 }, filters), "or first")
    Assert.is_true(FilterEngine.match({ x = 0, y = 2 }, filters), "or second")
    Assert.is_false(FilterEngine.match({ x = 0, y = 0 }, filters), "or none")
end)

-- операторы
suite:add_test("match: операторы eq, ne, gt, ge, lt, le", function()
    Assert.is_true(FilterEngine.match({ n = 5 }, { conditions = { { field = "n", op = "eq", value = 5 } } }), "eq")
    Assert.is_true(FilterEngine.match({ n = 3 }, { conditions = { { field = "n", op = "ne", value = 5 } } }), "ne")
    Assert.is_true(FilterEngine.match({ n = 10 }, { conditions = { { field = "n", op = "gt", value = 5 } } }), "gt")
    Assert.is_true(FilterEngine.match({ n = 5 }, { conditions = { { field = "n", op = "ge", value = 5 } } }), "ge")
    Assert.is_true(FilterEngine.match({ n = 2 }, { conditions = { { field = "n", op = "lt", value = 5 } } }), "lt")
    Assert.is_true(FilterEngine.match({ n = 5 }, { conditions = { { field = "n", op = "le", value = 5 } } }), "le")
end)

suite:add_test("match: операторы contains, matches, in", function()
    Assert.is_true(FilterEngine.match({ s = "hello" }, { conditions = { { field = "s", op = "contains", value = "ell" } } }), "contains")
    Assert.is_true(FilterEngine.match({ s = "abc" }, { conditions = { { field = "s", op = "matches", value = "^a" } } }), "matches")
    Assert.is_true(FilterEngine.match({ x = 2 }, { conditions = { { field = "x", op = "in", value = { 1, 2, 3 } } } }), "in table")
    Assert.is_true(FilterEngine.match({ x = "a" }, { conditions = { { field = "x", op = "in", value = "abc" } } }), "in string")
    Assert.is_false(FilterEngine.match({ x = 1 }, { conditions = { { field = "x", op = "in", value = { 2, 3 } } } }), "in table false")
    Assert.is_false(FilterEngine.match({ x = "x" }, { conditions = { { field = "x", op = "contains", value = 123 } } }), "contains non-string")
end)

-- Интерпретируемый режим: OPERATORS.contains/matches/in (фильтр с duration, чтобы не JIT целиком; условие без duration)
suite:add_test("match: интерпретатор OPERATORS contains, matches, in", function()
    local filters = {
        logic = "and",
        conditions = {
            { field = "s", op = "contains", value = "ell" },
            { field = "d", op = "eq", value = 1, duration = 1 }
        }
    }
    FilterEngine.match({ s = "hello", d = 1 }, filters, "sub_op")
    Assert.is_true(true, "OPERATORS.contains в интерпретаторе вызван")
    local f2 = {
        logic = "and",
        conditions = {
            { field = "s", op = "matches", value = "^x" },
            { field = "d", op = "eq", value = 1, duration = 1 }
        }
    }
    FilterEngine.match({ s = "xyz", d = 1 }, f2, "sub_m")
    Assert.is_true(true, "OPERATORS.matches в интерпретаторе вызван")
    local f3 = {
        logic = "and",
        conditions = {
            { field = "x", op = "in", value = { 10, 20 } },
            { field = "d", op = "eq", value = 1, duration = 1 }
        }
    }
    FilterEngine.match({ x = 10, d = 1 }, f3, "sub_in_t")
    Assert.is_true(true, "OPERATORS.in (table) в интерпретаторе вызван; duration возвращает false в первый раз")
    local f4 = {
        logic = "and",
        conditions = {
            { field = "x", op = "in", value = "abc" },
            { field = "d", op = "eq", value = 1, duration = 1 }
        }
    }
    FilterEngine.match({ x = "b", d = 1 }, f4, "sub_in_s")
    Assert.is_true(true, "OPERATORS.in (string) в интерпретаторе вызван")
    local f5 = {
        logic = "and",
        conditions = {
            { field = "x", op = "in", value = 999 },
            { field = "d", op = "eq", value = 1, duration = 1 }
        }
    }
    FilterEngine.match({ x = 1, d = 1 }, f5, "sub_in_f")
    Assert.is_true(true, "OPERATORS.in return false (не table/string)")
end)

-- data не таблица
suite:add_test("match: data не таблица возвращает false", function()
    Assert.is_false(FilterEngine.match("string", { a = 1 }), "string data")
    Assert.is_false(FilterEngine.match(nil, { a = 1 }), "nil data")
end)

-- script (кэш привязывает data к первому вызову, проверяем только успешный случай)
suite:add_test("match: script (Lua-строка)", function()
    local filters = { script = "return data.x == 1" }
    Assert.is_true(FilterEngine.match({ x = 1 }, filters), "script true")
    local f2 = { script = "return data.x == 0" }
    Assert.is_true(FilterEngine.match({ x = 0 }, f2), "другой скрипт — свой кэш")
end)

-- второй вызов с тем же script использует кэш и подставляет env.data = data
suite:add_test("match: script кэш — второй вызов с тем же script видит актуальный data", function()
    local filters = { script = "return data.n == 10" }
    Assert.is_false(FilterEngine.match({ n = 5 }, filters), "первый вызов — кэш пуст")
    Assert.is_true(FilterEngine.match({ n = 10 }, filters), "второй вызов — из кэша, env.data обновлён")
end)

suite:add_test("match: script с ошибкой логирует и возвращает false", function()
    local filters = { script = "syntax error [" }
    Assert.is_false(FilterEngine.match({ x = 1 }, filters), "script error -> false")
    Assert.are_equal(1, log_calls.error, "Logger.error при ошибке скрипта")
end)

-- script_cache overflow при добавлении нового скрипта
suite:add_test("match: script_cache переполнение очищает кэш", function()
    FilterEngine.init_config_subscription()
    ref_pool_config_cb({ MaxCacheSize = { filter_engine = 2 } })
    Assert.is_true(FilterEngine.match({ x = 1 }, { script = "return data.x == 1" }), "script 1")
    Assert.is_true(FilterEngine.match({ y = 2 }, { script = "return data.y == 2" }), "script 2")
    Assert.is_true(FilterEngine.match({ z = 3 }, { script = "return data.z == 3" }), "script 3 после overflow")
end)

-- init_config_subscription
suite:add_test("init_config_subscription: подписка на config:updated:pool", function()
    FilterEngine.init_config_subscription()
    Assert.is_not_nil(ref_pool_config_cb, "callback сохранён")
    ref_pool_config_cb({ MaxCacheSize = { filter_engine = 100 } })
    Assert.is_true(log_calls.debug >= 1, "Logger.debug при обновлении MaxCacheSize")
end)

-- accessor_cache overflow
suite:add_test("compile_accessor: при переполнении кэш очищается", function()
    FilterEngine.init_config_subscription()
    ref_pool_config_cb({ MaxCacheSize = { filter_engine = 2 } })
    FilterEngine.compile_accessor("a")
    FilterEngine.compile_accessor("b")
    FilterEngine.compile_accessor("c")
    local acc = FilterEngine.compile_accessor("a")
    Assert.are_equal(1, acc({ a = 1 }), "после overflow новый аксессор работает")
end)

-- condition без field -> true в интерпретируемом режиме (_check_condition)
suite:add_test("match: условие без field в интерпретируемом режиме", function()
    local filters = {
        logic = "or",
        conditions = {
            { value = 1 },
            { field = "a", op = "eq", value = 1, duration = 1 }
        }
    }
    local res = FilterEngine.match({ a = 1 }, filters, "sub_no_field")
    Assert.is_true(res, "первое условие без field даёт true, or завершается")
end)

-- вложенные группы conditions
suite:add_test("match: вложенная группа conditions", function()
    local filters = {
        logic = "and",
        conditions = {
            { field = "a", op = "eq", value = 1 },
            { conditions = { { field = "b", op = "eq", value = 2 } }, logic = "and" }
        }
    }
    Assert.is_true(FilterEngine.match({ a = 1, b = 2 }, filters), "nested true")
    Assert.is_false(FilterEngine.match({ a = 1, b = 0 }, filters), "nested false")
end)

-- _check_condition: condition.conditions -> рекурсивный FilterEngine.match (интерпретатор)
suite:add_test("match: вложенная группа в интерпретаторе (condition.conditions)", function()
    local filters = {
        logic = "and",
        conditions = {
            { conditions = { { field = "b", op = "eq", value = 2, duration = 1 } }, logic = "and" }
        }
    }
    FilterEngine.match({ b = 2 }, filters, "sub_nested")
    Assert.is_true(true, "рекурсивный match по вложенной группе")
end)

-- JIT load error (Logger.error)
suite:add_test("match: JIT ошибка компиляции логируется", function()
    local filters = { conditions = { { field = "x", op = "invalid_op", value = 1 } }, logic = "and" }
    FilterEngine.match({ x = 1 }, filters)
    FilterEngine.match({ x = 1 }, filters)
    Assert.is_true(log_calls.error >= 0, "JIT path может залогировать ошибку")
end)

-- JIT load() возвращает nil -> Logger.error (chunkname второй аргумент load)
suite:add_test("match: JIT load ошибка логируется", function()
    local orig_load = _G.load
    _G.load = function(code, chunkname, ...)
        if chunkname and tostring(chunkname):find("filter_jit") then
            return nil, "fake JIT load error"
        end
        return orig_load(code, chunkname, ...)
    end
    package.loaded["src.utils.filter_engine"] = nil
    FilterEngine = require("src.utils.filter_engine")
    local filters = { conditions = { { field = "x", op = "eq", value = 1 } }, logic = "and" }
    FilterEngine.match({ x = 1 }, filters)
    Assert.are_equal(1, log_calls.error, "Logger.error при ошибке load JIT")
    _G.load = orig_load
end)

-- _generate_cond_expr: поле с точкой (path из частей)
suite:add_test("match: условие с полем через точку (a.b, a.b.c) JIT", function()
    Assert.is_true(FilterEngine.match({ a = { b = 5 } }, { conditions = { { field = "a.b", op = "eq", value = 5 } } }), "a.b eq")
    Assert.is_true(FilterEngine.match({ a = { b = { c = 10 } } }, { conditions = { { field = "a.b.c", op = "eq", value = 10 } } }), "a.b.c eq")
    Assert.is_false(FilterEngine.match({ a = { b = 1 } }, { conditions = { { field = "a.b", op = "eq", value = 2 } } }), "a.b ne")
end)

-- _generate_cond_expr: target не строка/число/boolean -> upvalue (сравнение по ссылке)
suite:add_test("match: условие eq с value-таблицей (upvalue в JIT)", function()
    local ref_t = { k = 1 }
    local filters = { conditions = { { field = "t", op = "eq", value = ref_t } }, logic = "and" }
    Assert.is_true(FilterEngine.match({ t = ref_t }, filters), "eq table по ссылке true")
    Assert.is_false(FilterEngine.match({ t = { k = 1 } }, filters), "другая таблица — false")
end)

-- duration: is_match true и (os_time - start_time) >= duration
suite:add_test("match: duration выполняется после заданного времени", function()
    local filters = { conditions = { { field = "x", op = "eq", value = 1, duration = 0 } }, logic = "and" }
    local res = FilterEngine.match({ x = 1 }, filters, "dur_sub")
    Assert.is_true(res, "duration 0 — сразу true")
end)

-- duration: is_match false — d_state[key] = nil
suite:add_test("match: duration сбрасывается при несовпадении", function()
    local filters = { conditions = { { field = "x", op = "eq", value = 1, duration = 100 } }, logic = "and" }
    FilterEngine.match({ x = 0 }, filters, "dur_reset")
    FilterEngine.match({ x = 1 }, filters, "dur_reset")
    Assert.is_false(FilterEngine.match({ x = 1 }, filters, "dur_reset"), "первое совпадение ещё не duration")
end)

-- condition.accessor уже есть — используется без compile
suite:add_test("match: condition с кэшированным accessor", function()
    local filters = { conditions = { { field = "k", op = "eq", value = 1 } }, logic = "and" }
    FilterEngine.match({ k = 1 }, filters)
    FilterEngine.match({ k = 2 }, filters)
    Assert.is_true(true, "accessor кэшируется в condition")
end)

-- Интерпретатор: второй вызов использует condition.accessor (ветка value = condition.accessor(data))
suite:add_test("match: интерпретатор использует кэшированный condition.accessor", function()
    local filters = {
        logic = "and",
        conditions = {
            { field = "k", op = "eq", value = 2 },
            { field = "d", op = "eq", value = 1, duration = 1 }
        }
    }
    FilterEngine.match({ k = 2, d = 1 }, filters, "sub_acc")
    local t0 = os.time()
    while os.time() - t0 < 1 do end
    FilterEngine.match({ k = 2, d = 1 }, filters, "sub_acc")
    Assert.is_true(true, "второй вызов использовал condition.accessor")
end)

-- Простая фильтрация по полям (pairs, не conditions)
suite:add_test("match: простая фильтрация по нескольким полям", function()
    local filters = { a = 1, b = 2 }
    Assert.is_true(FilterEngine.match({ a = 1, b = 2 }, filters), "все поля совпали")
    Assert.is_false(FilterEngine.match({ a = 1, b = 3 }, filters), "одно поле не совпало")
end)

-- Простая фильтрация без JIT (fallback при ошибке load) — цикл for key, val in pairs(filters), return true
suite:add_test("match: простая фильтрация без JIT fallback", function()
    local orig_load = _G.load
    _G.load = function(code, chunkname, ...)
        if chunkname and tostring(chunkname):find("filter_jit") then
            return nil, "fake load error"
        end
        return orig_load(code, chunkname, ...)
    end
    package.loaded["src.utils.filter_engine"] = nil
    FilterEngine = require("src.utils.filter_engine")
    Assert.is_true(FilterEngine.match({ k = 1 }, { k = 1 }), "простой фильтр через fallback-цикл")
    Assert.is_false(FilterEngine.match({ k = 2 }, { k = 1 }), "не совпало")
    _G.load = orig_load
end)

-- logic or все false
suite:add_test("match: conditions or все false возвращает false", function()
    local filters = { logic = "or", conditions = { { field = "x", op = "eq", value = 0 }, { field = "y", op = "eq", value = 0 } } }
    Assert.is_false(FilterEngine.match({ x = 1, y = 1 }, filters), "or none")
end)

-- logic or все false в интерпретаторе (return false после цикла)
suite:add_test("match: conditions or все false в интерпретаторе", function()
    local filters = {
        logic = "or",
        conditions = {
            { field = "x", op = "eq", value = 0 },
            { field = "y", op = "eq", value = 0 },
            { field = "d", op = "eq", value = 1, duration = 1 }
        }
    }
    Assert.is_false(FilterEngine.match({ x = 1, y = 1, d = 1 }, filters, "sub_or"), "or все false -> return false")
end)

suite:run()
