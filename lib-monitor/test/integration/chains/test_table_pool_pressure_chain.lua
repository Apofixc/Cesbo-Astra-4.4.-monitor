-- INT: Table Pool Pressure Chain (ПМИ 1.2 п.32)
-- TablePool ↔ collectgarbage (Lua): поведение пула при принудительном вызове GC.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local TablePool

local suite = TestSuite:new("INT.chains.table_pool_pressure")

suite:setup(function()
    _G.ModuleManager = {
        get_module = function(name)
            if name == "logger" then return { error = function() end, info = function() end, warning = function() end, debug = function() end } end
            if name == "core.scheduler" then return { get_instance = function() return { add_task = function() end, remove_task = function() end } end } end
            return nil
        end,
        get_global_dependency = function() return nil end,
    }
    TablePool = require("src.utils.table_pool")
end)

suite:teardown(function()
    package.loaded["src.utils.table_pool"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-TPP-01: Table Pool Pressure — после collectgarbage пул работает", function()
    TablePool.register_type("pressure_test", nil, 50, 5)
    local t = TablePool.get("pressure_test")
    Assert.is_not_nil(t, "get возвращает таблицу")
    TablePool.release(t, "pressure_test")
    collectgarbage("collect")
    local t2 = TablePool.get("pressure_test")
    Assert.is_not_nil(t2, "после GC get всё ещё работает")
    TablePool.release(t2, "pressure_test")
end)

suite:add_test("INT-TPP-02: Table Pool Pressure — maintain не падает после GC", function()
    TablePool.register_type("pressure_test2", nil, 50, 2)
    for _ = 1, 10 do TablePool.get("pressure_test2") end
    collectgarbage("collect")
    local ok = pcall(TablePool.maintain)
    Assert.is_true(ok, "maintain после GC выполняется без ошибок")
end)

suite:run()
