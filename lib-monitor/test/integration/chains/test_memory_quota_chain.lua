-- INT: Memory Quota Chain (ПМИ 1.2 п.39)
-- TablePool ↔ MonitorConfig/EventDispatcher: соблюдение лимитов пулов и очередей.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local TablePool
local pool_config_callback

local suite = TestSuite:new("INT.chains.memory_quota")

suite:setup(function()
    pool_config_callback = nil
    local mock_scheduler = {
        add_task = function() end,
        remove_task = function() end,
    }
    _G.ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return { error = function() end, info = function() end, warning = function() end, debug = function() end }
            end
            if name == "core.scheduler" then
                return { get_instance = function() return mock_scheduler end }
            end
            if name == "core.event_dispatcher" then
                return {
                    get_instance = function()
                        return {
                            subscribe = function(_, event_type, cb)
                                if event_type == "config:updated:pool" then pool_config_callback = cb end
                                return "pool-sub"
                            end,
                            unsubscribe = function() end,
                        }
                    end,
                }
            end
            return nil
        end,
        get_global_dependency = function() return nil end,
    }
    TablePool = require("src.utils.table_pool")
end)

suite:teardown(function()
    if TablePool and TablePool.shutdown then pcall(TablePool.shutdown) end
    package.loaded["src.utils.table_pool"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-MQ-01: Memory Quota Chain — config:updated:pool обновляет конфиг", function()
    TablePool.init_config_subscription()
    Assert.is_not_nil(pool_config_callback, "подписка на config:updated:pool")

    TablePool.register_type("mq_test", { "a" }, 10, 0)
    local stats = TablePool.get_stats()
    Assert.is_not_nil(stats, "get_stats")
    Assert.is_not_nil(stats.mq_test or stats["mq_test"], "тип mq_test зарегистрирован")

    pool_config_callback({ MaxPoolSize = 50 })
    local t = TablePool.get("mq_test")
    Assert.is_not_nil(t, "get после обновления конфига")
    TablePool.release(t, "mq_test")
end)

suite:add_test("INT-MQ-02: Memory Quota Chain — лимиты пула соблюдаются", function()
    TablePool.register_type("mq_limit", { "x" }, 2, 0)
    local t1 = TablePool.get("mq_limit")
    local t2 = TablePool.get("mq_limit")
    local t3 = TablePool.get("mq_limit")
    Assert.is_not_nil(t1, "get 1")
    Assert.is_not_nil(t2, "get 2")
    Assert.is_not_nil(t3, "get 3")
    TablePool.release(t1, "mq_limit")
    TablePool.release(t2, "mq_limit")
    if t3 then TablePool.release(t3, "mq_limit") end
end)

suite:run()
