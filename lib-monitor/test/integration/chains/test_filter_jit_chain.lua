-- INT: Filter JIT Chain (ПМИ 1.2 п.31)
-- FilterEngine ↔ load (Lua): проверка компиляции и выполнения JIT-фильтров.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local FilterEngine

local suite = TestSuite:new("INT.chains.filter_jit")

suite:setup(function()
    _G.ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return { error = function() end, info = function() end, warning = function() end, debug = function() end }
            end
            if name == "table_pool" or name == "utils.table_pool" then
                return { get = function() return {} end, release = function() end, register_type = function() end }
            end
            return nil
        end,
        get_global_dependency = function() return nil end,
    }
    FilterEngine = require("src.utils.filter_engine")
end)

suite:teardown(function()
    package.loaded["src.utils.filter_engine"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-JIT-01: Filter JIT Chain — скрипт компилируется и выполняется", function()
    local filters = { script = "return data.x == 42" }
    local result = FilterEngine.match({ x = 42 }, filters)
    Assert.is_true(result, "match true при data.x == 42")

    local result2 = FilterEngine.match({ x = 0 }, filters)
    Assert.is_false(result2, "match false при data.x ~= 42")
end)

suite:add_test("INT-JIT-02: Filter JIT Chain — conditions JIT компилируется", function()
    local filters = {
        conditions = {
            { field = "type", operator = "eq", value = "channel:error" }
        },
        logic = "and",
    }
    local result = FilterEngine.match({ type = "channel:error" }, filters)
    Assert.is_true(result, "conditions match при совпадении")
    local result2 = FilterEngine.match({ type = "channel:ok" }, filters)
    Assert.is_false(result2, "conditions match false при несовпадении")
end)

suite:run()
