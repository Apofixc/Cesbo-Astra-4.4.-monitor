-- SYS: Graceful Degradation (ПМИ 2.20)
-- Auxiliary Service Failure: сбой в одном модуле не останавливает основной функционал.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local EventDispatcher
local dispatcher_tick_cb

local suite = TestSuite:new("SYS.graceful_degradation")

suite:setup(function()
    dispatcher_tick_cb = nil
    local real_table_pool = nil
    _G.ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return { error = function() end, info = function() end, warning = function() end, debug = function() end }
            end
            if name == "core.scheduler" then
                return {
                    get_instance = function()
                        return {
                            add_task = function(_, id, cb)
                                if id == "event_dispatcher_queue" then dispatcher_tick_cb = cb end
                            end,
                            remove_task = function() end,
                        }
                    end,
                }
            end
            if name == "core.subscription_manager" then
                return { new = function() return require("src.core.subscription_manager").new() end }
            end
            if name == "table_pool" or name == "utils.table_pool" then return real_table_pool end
            if name == "utils" then return { validate_monitor_param = function(_, v) return v end, init_report = function(t, ty, n) t.type = ty t.name = n end } end
            if name == "utils.filter_engine" then return require("src.utils.filter_engine") end
            if name == "utils.wildcard" then return require("src.utils.wildcard") end
            return nil
        end,
        get_global_dependency = function(n)
            if n == "json.encode" then return function() return "{}" end end
            return nil
        end,
    }
    real_table_pool = require("src.utils.table_pool")
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
end)

suite:teardown(function()
    if EventDispatcher and EventDispatcher.get_instance and EventDispatcher.get_instance().shutdown then
        pcall(EventDispatcher.get_instance().shutdown, EventDispatcher.get_instance())
    end
    package.loaded["src.core.event_dispatcher"] = nil
    package.loaded["src.core.subscription_manager"] = nil
    package.loaded["src.utils.table_pool"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("SYS-GRAC-01: Graceful Degradation — emit продолжает работать при падении callback подписчика", function()
    local ed = EventDispatcher.get_instance()
    local good_received = false
    ed:subscribe("test:event", function() good_received = true end)
    ed:subscribe("test:event", function() error("subscriber crash") end)
    ed:emit_safe("test:event", {})
    for _ = 1, 5 do if dispatcher_tick_cb then dispatcher_tick_cb() end end
    Assert.is_true(good_received, "рабочий подписчик получил событие")
    local ok = pcall(function() ed:emit_safe("test:event2", {}) end)
    Assert.is_true(ok, "emit_safe не падает после ошибки в callback")
end)

suite:add_test("SYS-GRAC-02: Graceful Degradation — EventDispatcher остаётся активным после ошибок", function()
    local ed = EventDispatcher.get_instance()
    ed:subscribe("test:err", function() error("fail") end)
    ed:emit_safe("test:err", {})
    for _ = 1, 3 do if dispatcher_tick_cb then dispatcher_tick_cb() end end
    local id = ed:emit_safe("test:ok", { x = 1 })
    Assert.is_true(id ~= nil, "emit после ошибки подписчика работает")
end)

suite:run()
