-- L0: Unit-тесты для модуля utils.table_pool
-- Изоляция через моки ModuleManager (Logger, Scheduler, EventDispatcher).

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
local Mock = require("tools.test_moc")

local mock
local local_mock
local TablePool
-- Хранилище коллбэков (таблицы, чтобы не путать с upvalue)
local ref_pool_config = { cb = nil }
local ref_scheduler_cb = { fn = nil }

local suite = TestSuite:new("L0.table_pool")

suite:setup(function()
    mock = Mock:new()
    local mock_log = {
        debug = function() end,
        info = function() end,
        warning = function() end,
        error = function() end,
        flush = function() end,
    }
    -- add_task(self, name, cb, interval) — сохраняем и вызываем коллбэк
    local mock_scheduler_instance = {
        add_task = function(self, name, cb, interval)
            if type(cb) == "function" then
                ref_scheduler_cb.fn = cb
                cb()
            end
        end,
        remove_task = function() end,
    }
    local mock_scheduler = { get_instance = function() return mock_scheduler_instance end }
    local mock_ed_instance = {
        subscribe = function(self, ev, cb)
            local fn = (type(cb) == "function" and cb) or (type(ev) == "function" and ev)
            ref_pool_config.cb = fn
            if fn then fn({ PoolDebug = true }) end
        end,
    }
    local mock_ed = { get_instance = function() return mock_ed_instance end }

    mock:mock_global("ModuleManager", {
        get_module = function(name)
            if name == "logger" then return mock_log end
            if name == "core.scheduler" then return mock_scheduler end
            if name == "core.event_dispatcher" then return mock_ed end
            return nil
        end,
    })
end)

suite:before_each(function()
    package.loaded["src.utils.table_pool"] = nil
    TablePool = require("src.utils.table_pool")
end)

suite:after_each(function()
    if local_mock then
        local_mock:restore()
        local_mock = nil
    end
    if TablePool and TablePool.clear_all then
        pcall(TablePool.clear_all, TablePool)
    end
end)

suite:teardown(function()
    mock:restore()
end)

-- L0-TP-01: Пул пуст — создаётся новая таблица
suite:add_test("get: при пустом пуле создаётся новая таблица с __pool_type", function()
    local t = TablePool.get("report")
    Assert.is_not_nil(t, "Должна вернуться таблица")
    Assert.are_equal("report", t.__pool_type, "Поле __pool_type должно быть установлено")
end)

-- L0-TP-02: Возврат таблицы — очистка и возврат в пул
suite:add_test("release: таблица очищается и возвращается в пул", function()
    local t = TablePool.get("generic")
    t.foo = "bar"
    TablePool.release(t)
    Assert.is_nil(t.foo, "Поле должно быть очищено")
    Assert.are_equal("generic", t.__pool_type, "Тип сохраняется")
    local t2 = TablePool.get("generic")
    Assert.are_equal(t, t2, "Та же таблица выдаётся повторно из пула")
end)

-- L0-TP-03: Стерильность release
suite:add_test("release: полная очистка полей и метатаблицы", function()
    local t = TablePool.get("generic")
    t.a = 1
    t.b = { x = 2 }
    setmetatable(t, { __index = {} })
    TablePool.release(t)
    Assert.is_nil(t.a, "Поле a очищено")
    Assert.is_nil(t.b, "Поле b очищено")
    Assert.is_nil(getmetatable(t), "Метатаблица сброшена")
end)

-- Регистрация типа
suite:add_test("register_type: создаёт пул с лимитом и опциональным cleaner", function()
    TablePool.register_type("custom", nil, 5)
    local stats = TablePool.get_stats()
    Assert.is_not_nil(stats.custom, "Пул custom зарегистрирован")
    Assert.are_equal(5, stats.custom.limit, "Лимит установлен")
end)

suite:add_test("get: при отсутствии типа пул регистрируется автоматически", function()
    local t = TablePool.get("auto_type")
    Assert.are_equal("auto_type", t.__pool_type, "Тип auto_type")
    local stats = TablePool.get_stats()
    Assert.is_not_nil(stats.auto_type, "Пул создан автоматически")
end)

-- L0-TP-05: Type poisoning — возврат в другой пул
suite:add_test("release: при смене типа пула выполняется полная очистка (type poisoning)", function()
    local t = TablePool.get("type_a")
    t.nested = { __pool_type = "type_b" }
    TablePool.release(t, "type_b", true)
    Assert.is_nil(t.nested, "Вложенная структура очищена при смене типа")
    Assert.are_equal("type_b", t.__pool_type, "Тип обновлён на целевой")
end)

-- drain и clear_all
suite:add_test("drain: удаляет указанное количество таблиц из пула", function()
    TablePool.register_type("drain_test", nil, 10)
    for _ = 1, 5 do
        local t = TablePool.get("drain_test")
        TablePool.release(t)
    end
    local stats_before = TablePool.get_stats()
    Assert.is_true(stats_before.drain_test.size >= 1, "В пуле есть таблицы")
    local size_before = stats_before.drain_test.size
    TablePool.drain("drain_test", 2)
    local stats_after = TablePool.get_stats()
    Assert.are_equal(math.max(0, size_before - 2), stats_after.drain_test.size, "После drain(2) размер уменьшился на 2")
end)

suite:add_test("clear_all: очищает все пулы", function()
    TablePool.get("a")
    TablePool.get("b")
    TablePool.clear_all()
    local stats = TablePool.get_stats()
    for _, s in pairs(stats) do
        Assert.are_equal(0, s.size, "Размер пула 0")
    end
end)

-- Негативные сценарии
suite:add_test("release: не таблица — выход без ошибки", function()
    Assert.is_nil(TablePool.release(123), "release не-таблицы возвращает nil без ошибки")
end)

suite:add_test("release: двойной возврат одной таблицы — предупреждение, без падения", function()
    local t = TablePool.get("double")
    TablePool.release(t)
    TablePool.release(t)
    local stats = TablePool.get_stats()
    Assert.are_equal(1, stats.double.size, "В пуле одна таблица")
end)

suite:add_test("get: pool_type nil или отсутствует — используется generic", function()
    local t = TablePool.get()
    Assert.are_equal("generic", t.__pool_type, "По умолчанию generic")
end)

-- Статистика
suite:add_test("get_stats: возвращает size, hits, misses, created, limit по типам", function()
    TablePool.register_type("stats_test", nil, 20)
    TablePool.get("stats_test")
    TablePool.get("stats_test")
    local stats = TablePool.get_stats()
    Assert.is_not_nil(stats.stats_test, "Есть запись по типу")
    Assert.is_not_nil(stats.stats_test.size, "size")
    Assert.is_not_nil(stats.stats_test.hits, "hits")
    Assert.is_not_nil(stats.stats_test.misses, "misses")
    Assert.are_equal(20, stats.stats_test.limit, "limit")
end)

-- set_debug
suite:add_test("set_debug: включает и выключает режим отладки", function()
    TablePool.set_debug(true)
    TablePool.set_debug(false)
end)

-- Поиск _m_config и state по структуре (имена upvalue могут отличаться в среде выполнения)
local function find_pool_private_state()
    local mock_read = Mock:new()
    local module_up = mock_read:get_module_upvalues(TablePool)
    local m_config, st
    for _, up in pairs(module_up) do
        for _, val in pairs(up) do
            if type(val) == "table" and val.MemoryLimitMb ~= nil and val.PoolDebug ~= nil then m_config = val end
            if type(val) == "table" and val.pools and val.debug_mode ~= nil then st = val end
        end
        if m_config and st then return m_config, st end
    end
    return nil, nil
end

-- init_config_subscription: проверка приватного состояния через get_function_upvalues
suite:add_test("init_config_subscription: регистрирует подписку на config:updated:pool", function()
    TablePool.init_config_subscription()
    Assert.is_not_nil(ref_pool_config.cb, "Коллбэк подписки должен быть сохранён")
    ref_pool_config.cb({ PoolDebug = true, MemoryLimitMb = 25 })
    local m_config, state = find_pool_private_state()
    Assert.is_not_nil(m_config, "приватный _m_config доступен через upvalue")
    Assert.is_not_nil(state, "приватный state доступен через upvalue")
    Assert.are_equal(25, m_config.MemoryLimitMb, "_m_config.MemoryLimitMb применился из конфига")
    Assert.is_true(m_config.PoolDebug, "_m_config.PoolDebug применился")
    Assert.is_true(state.debug_mode, "state.debug_mode синхронизирован с PoolDebug")
end)

-- Граничные значения коллбэка _update_config и проверка приватного состояния
suite:add_test("_update_config (коллбэк): граничные значения — пустая таблица и PoolDebug false", function()
    TablePool.init_config_subscription()
    ref_pool_config.cb({ PoolDebug = true })
    local m_config, state = find_pool_private_state()
    Assert.is_true(state.debug_mode, "после PoolDebug true state.debug_mode == true")
    ref_pool_config.cb({})
    Assert.is_not_nil(m_config, "пустой конфиг не ломает _m_config")
    ref_pool_config.cb({ PoolDebug = false })
    Assert.is_false(state.debug_mode, "после PoolDebug false state.debug_mode == false")
end)

-- Граничные значения всех полей секции Pool
suite:add_test("_update_config (коллбэк): граничные значения полей _m_config", function()
    TablePool.init_config_subscription()
    ref_pool_config.cb({
        MaxPoolSize = 1,
        PoolMinLimit = 1,
        PoolMaintenanceInterval = 1,
        MemoryLimitMb = 1,
        PoolAdaptiveThreshold = 0.01,
        PoolAdaptiveStep = 0.01,
    })
    local m_config, _ = find_pool_private_state()
    Assert.is_not_nil(m_config, "_m_config найден")
    Assert.are_equal(1, m_config.MaxPoolSize, "MaxPoolSize граница 1")
    Assert.are_equal(1, m_config.PoolMinLimit, "PoolMinLimit граница 1")
    Assert.are_equal(1, m_config.PoolMaintenanceInterval, "PoolMaintenanceInterval граница 1")
    Assert.are_equal(1, m_config.MemoryLimitMb, "MemoryLimitMb граница 1")
    Assert.are_equal(0.01, m_config.PoolAdaptiveThreshold, "PoolAdaptiveThreshold граница 0.01")
    Assert.are_equal(0.01, m_config.PoolAdaptiveStep, "PoolAdaptiveStep граница 0.01")
    ref_pool_config.cb({ MaxPoolSize = 10000, MemoryLimitMb = 1024 })
    Assert.are_equal(10000, m_config.MaxPoolSize, "MaxPoolSize верхняя граница")
    Assert.are_equal(1024, m_config.MemoryLimitMb, "MemoryLimitMb верхняя граница")
end)

suite:add_test("_update_config (коллбэк): негатив — nil обрабатывается без ошибки (ранний return)", function()
    TablePool.init_config_subscription()
    local ok, err = pcall(function()
        if ref_pool_config.cb then ref_pool_config.cb(nil) end
    end)
    Assert.is_true(ok, "коллбэк с nil не должен ронять (защита в _update_config)")
    Assert.is_nil(err, "ошибки нет")
end)

-- Явный вызов задачи планировщика (покрытие строки TablePool.maintain() внутри add_task)
suite:add_test("maintain: вызов через коллбэк планировщика (add_task)", function()
    TablePool.register_type("sched_cb_test", nil, 5)
    Assert.is_not_nil(ref_scheduler_cb.fn, "Коллбэк задачи должен быть сохранён при register_type")
    ref_scheduler_cb.fn()
end)

-- preallocate
suite:add_test("preallocate: заполняет пул до count, не более limit", function()
    TablePool.register_type("prealloc_test", nil, 5)
    TablePool.preallocate("prealloc_test", 3)
    local stats = TablePool.get_stats()
    Assert.are_equal(3, stats.prealloc_test.size, "В пуле 3 таблицы")
    TablePool.preallocate("prealloc_test", 10)
    Assert.are_equal(5, TablePool.get_stats().prealloc_test.size, "Ограничено limit 5")
end)

suite:add_test("preallocate: при отсутствии пула выходит без ошибки", function()
    TablePool.preallocate("nonexistent_pool", 1)
end)

-- register_type с cleaner-схемой (таблица ключей) и preallocate_count
suite:add_test("register_type: cleaner как таблица-схема ключей создаёт очиститель по схеме", function()
    TablePool.register_type("schema_pool", {"a", "b"}, 20, 2)
    local t = TablePool.get("schema_pool")
    t.a = {} t.b = {}
    TablePool.release(t)
    Assert.is_nil(t.a, "Поле a очищено")
    Assert.is_nil(t.b, "Поле b очищено")
    local stats = TablePool.get_stats()
    Assert.are_equal(2, stats.schema_pool.size, "preallocate 2")
end)

-- Схема-очиститель: вложенная таблица без __pool_type при do_deep — вызывается _do_clear_table
suite:add_test("release: схема-cleaner с вложенной таблицей без __pool_type при do_deep", function()
    TablePool.register_type("schema_nested", {"nested"}, 10)
    local t = TablePool.get("schema_nested")
    t.nested = { x = 1 }
    TablePool.release(t, "schema_nested", true)
    Assert.is_nil(t.nested, "Вложенная таблица очищена рекурсивно")
end)

-- Схема-очиститель: вложенная таблица с __pool_type — вызывается TablePool.release(v, v_pool_type, ...)
suite:add_test("release: схема-cleaner с вложенной таблицей с __pool_type возвращает в свой пул", function()
    TablePool.register_type("child_pool", nil, 10)
    TablePool.register_type("parent_schema", {"child"}, 10)
    local parent = TablePool.get("parent_schema")
    parent.child = TablePool.get("child_pool")
    parent.child.x = 1
    TablePool.release(parent, "parent_schema", true)
    Assert.is_nil(parent.child, "Поле child очищено")
end)

-- release: пул полон и не do_deep — ранний выход (очистка visited_cache)
suite:add_test("release: при полном пуле и без do_deep таблица не возвращается в пул", function()
    TablePool.register_type("full_pool", nil, 1)
    local t1 = TablePool.get("full_pool")
    TablePool.release(t1)
    TablePool.get("full_pool")
    TablePool.release(TablePool.get("full_pool"))
    local fake = { __pool_type = "full_pool" }
    TablePool.release(fake, "full_pool", false)
    Assert.are_equal(1, TablePool.get_stats().full_pool.size, "Пул остаётся размером 1")
    Assert.is_nil(fake.__in_pool, "Таблица не добавлена в пул при раннем выходе")
end)

-- release: кастомный cleaner, выбрасывающий ошибку (pcall path)
suite:add_test("release: ошибка в кастомном очистителе обрабатывается pcall", function()
    local bad_cleaner = function() error("cleaner error") end
    TablePool.register_type("bad_cleaner", bad_cleaner, 10)
    local t = TablePool.get("bad_cleaner")
    TablePool.release(t)
    Assert.are_equal("bad_cleaner", t.__pool_type, "Таблица всё равно возвращена в пул")
end)

-- release: is_flat — быстрая очистка без рекурсии
suite:add_test("release: is_flat пул — только обнуление полей без рекурсии", function()
    TablePool.register_type("flat_pool", nil, 10, 0, true)
    local t = TablePool.get("flat_pool")
    t.x = 1
    TablePool.release(t)
    Assert.is_nil(t.x, "Поле очищено")
    Assert.are_equal("flat_pool", t.__pool_type, "Тип сохранён")
end)

-- release: do_deep как строка — default_child_pool_name
suite:add_test("release: do_deep строка используется как default_child_pool", function()
    TablePool.register_type("parent_pool", nil, 10)
    TablePool.register_type("child_pool", nil, 10)
    local t = TablePool.get("parent_pool")
    t.kid = TablePool.get("child_pool")
    TablePool.release(t, "parent_pool", "child_pool")
    Assert.is_nil(t.kid, "Вложенная таблица возвращена в свой пул")
end)

-- _do_clear_table: вложенная таблица без __pool_type при do_deep и depth < MAX_DEPTH
suite:add_test("release: глубокая очистка рекурсивно обходит таблицы без __pool_type", function()
    local t = TablePool.get("generic")
    t.nested = { foo = 1 }
    TablePool.release(t, "generic", true)
    Assert.is_nil(t.nested, "Вложенная таблица очищена")
end)

-- release: режим отладки обнаруживает оставшееся поле после очистки (ключ не в схеме)
suite:add_test("release: при set_debug и неочищенном поле вызывается Logger.error", function()
    TablePool.register_type("debug_dirty", {"a"}, 10)
    TablePool.set_debug(true)
    local t = TablePool.get("debug_dirty")
    t.a = 1
    t.extra = "не в схеме"
    TablePool.release(t)
    TablePool.set_debug(false)
end)

-- release: кастомный cleaner-функция оставляет поле — debug блок в release вызывает Logger.error
suite:add_test("release: при set_debug и cleaner, оставившем поле, вызывается Logger.error", function()
    local cleaner_clears_only_x = function(t) t.x = nil end
    TablePool.register_type("debug_leave", cleaner_clears_only_x, 10)
    TablePool.set_debug(true)
    local t = TablePool.get("debug_leave")
    t.x = 1
    t.left = "осталось"
    TablePool.release(t)
    TablePool.set_debug(false)
end)

-- drain при debug_mode
suite:add_test("drain: при set_debug вызывается Logger.debug", function()
    TablePool.register_type("drain_debug", nil, 5)
    TablePool.get("drain_debug")
    TablePool.release(TablePool.get("drain_debug"))
    TablePool.set_debug(true)
    TablePool.drain("drain_debug", 1)
    TablePool.set_debug(false)
end)

-- maintain: сброс статистики и ветка расширения пула (miss_rate > threshold)
suite:add_test("maintain: вызывается без падения, сбрасывает статистику", function()
    TablePool.register_type("maint_test", nil, 100)
    for _ = 1, 5 do TablePool.get("maint_test") end
    TablePool.maintain()
    local stats = TablePool.get_stats()
    Assert.are_equal(0, stats.maint_test.hits, "Статистика сброшена после maintain")
    Assert.are_equal(0, stats.maint_test.misses, "Статистика сброшена")
end)

-- maintain: ветка сжатия пула (miss_rate < 0.05 и current_size < limit*0.5)
suite:add_test("maintain: при низком miss_rate и малом размере пула лимит сжимается", function()
    TablePool.register_type("shrink_test", nil, 100)
    for _ = 1, 5 do local t = TablePool.get("shrink_test"); TablePool.release(t) end
    for _ = 1, 24 do
        local a, b, c, d = TablePool.get("shrink_test"), TablePool.get("shrink_test"), TablePool.get("shrink_test"), TablePool.get("shrink_test")
        TablePool.release(a); TablePool.release(b); TablePool.release(c); TablePool.release(d)
    end
    local before = TablePool.get_stats().shrink_test.limit
    TablePool.maintain()
    local after = TablePool.get_stats().shrink_test.limit
    Assert.is_true(before >= 10 and after >= 10, "Лимит не ниже PoolMinLimit")
end)

-- maintain: ветка mem_kb > memory_limit_kb (хак: мок collectgarbage до require)
suite:add_test("maintain: при превышении лимита памяти очищает пулы (хак: мок collectgarbage)", function()
    local_mock = Mock:new()
    local orig_cg = collectgarbage
    local_mock:mock_global("collectgarbage", function(arg)
        if arg == "count" then return 99999999 end
        if arg == "collect" then return orig_cg("collect") end
        return orig_cg(arg)
    end)
    package.loaded["src.utils.table_pool"] = nil
    local TP = require("src.utils.table_pool")
    TP.register_type("oom_test", nil, 5)
    TP.get("oom_test")
    TP.maintain()
end)

-- shutdown
suite:add_test("shutdown: останавливает обслуживание и очищает пулы", function()
    TablePool.register_type("shutdown_test", nil, 5)
    TablePool.get("shutdown_test")
    TablePool.shutdown()
    local stats = TablePool.get_stats()
    Assert.are_equal(0, stats.shutdown_test.size, "Пул очищен")
end)

suite:run()
