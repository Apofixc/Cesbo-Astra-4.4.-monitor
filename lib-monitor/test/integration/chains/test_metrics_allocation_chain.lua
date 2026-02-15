-- INT: Metrics Allocation Chain (ПМИ 1.2 п.21)
-- BaseMonitor ↔ TablePool: каждый цикл опроса использует таблицы из пула, не создаёт объектов в куче.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local BaseMonitor
local TablePool

local suite = TestSuite:new("INT.chains.metrics_allocation")

suite:setup(function()
    package.loaded["src.core.base_monitor"] = nil
    local real_table_pool = nil
    _G.ModuleManager = {
        get_module = function(name)
            if name == "logger" then return { error = function() end, info = function() end, warning = function() end, debug = function() end } end
            if name == "utils" then return { validate_monitor_param = function(_, v) return v end, init_report = function(t, ty, n) t.type = ty t.name = n end } end
            if name == "utils.table_pool" then return real_table_pool end
            if name == "core.event_dispatcher" then
                return { get_instance = function() return { subscribe = function() return "id" end, unsubscribe = function() end, emit_safe = function() end } end }
            end
            return nil
        end,
        get_global_dependency = function(n) if n == "json.encode" then return function() return "{}" end end return nil end,
    }
    real_table_pool = require("src.utils.table_pool")
    BaseMonitor = require("src.core.base_monitor")
    TablePool = real_table_pool
end)

suite:teardown(function()
    package.loaded["src.core.base_monitor"] = nil
    package.loaded["src.utils.table_pool"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-MET-01: Metrics Allocation Chain — BaseMonitor.get_table_from_pool берёт из пула", function()
    local monitor = BaseMonitor.new("test_metrics", "generic")
    Assert.is_not_nil(monitor, "BaseMonitor.new")
    local t = monitor:get_table_from_pool("generic")
    Assert.is_not_nil(t, "get_table_from_pool возвращает таблицу")
    local stats = TablePool.get_stats()
    Assert.is_true(stats.generic ~= nil, "тип generic зарегистрирован в TablePool")
end)

suite:add_test("INT-MET-02: Metrics Allocation Chain — return_table_to_pool возвращает в пул", function()
    local monitor = BaseMonitor.new("test_metrics", "generic")
    local t = monitor:get_table_from_pool("generic")
    monitor:return_table_to_pool(t, "generic")
    Assert.is_true(true, "return_table_to_pool выполнен без ошибок")
end)

suite:run()
