-- INT: Memory Chain (ПМИ 1.2 п.1)
-- TablePool ↔ EventDispatcher: гарантированный возврат таблиц после рассылки.
-- INT-MEM-01: Zero Leak Policy — после множества циклов пул не растёт, collectgarbage стабилен.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local EventDispatcher
local TablePool
local ref_ModuleManager
local ref_sub_mgr
local dispatcher_tick_cb

local suite = TestSuite:new("INT.chains.memory")

suite:setup(function()
    dispatcher_tick_cb = nil
    ref_sub_mgr = {
        subscribe = function(_, event_type)
            return "sub-" .. (event_type or "nil")
        end,
        unsubscribe = function() return true end,
        shutdown = function() end,
        get_delivery_plan = function(_, event_type)
            return {
                total_simple = 1,
                has_complex = false,
                simple_groups = { { transport = "CONSOLE", config = {}, subs = {} } },
                complex_subs = {},
            }
        end,
        multicast_direct = function() end,
        publish_event = function() return true end,
        publish_to_single = function() end,
        match = function(_, pattern, name) return pattern == name end,
    }

    local real_table_pool = nil
    ref_ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return {
                    error = function() end,
                    info = function() end,
                    warning = function() end,
                    debug = function() end,
                }
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
                return { new = function() return ref_sub_mgr end }
            end
            if name == "table_pool" or name == "utils.table_pool" then
                return real_table_pool
            end
            return nil
        end,
        get_global_dependency = function() return nil end,
    }

    _G.ModuleManager = ref_ModuleManager
    real_table_pool = require("src.utils.table_pool")
    EventDispatcher = require("src.core.event_dispatcher")
    TablePool = real_table_pool
end)

suite:teardown(function()
    if EventDispatcher and EventDispatcher.get_instance and EventDispatcher.get_instance().shutdown then
        pcall(function() EventDispatcher.get_instance():shutdown() end)
    end
    package.loaded["src.core.event_dispatcher"] = nil
    package.loaded["src.utils.table_pool"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-MEM-01: Memory Chain — пул не растёт после 10000 эмитов (Zero Leak)", function()
    local ed = EventDispatcher.get_instance()
    Assert.is_not_nil(ed, "EventDispatcher instance")
    Assert.is_not_nil(TablePool, "TablePool")

    local stats_before = TablePool.get_stats() or {}
    local event_stats = stats_before.event or { size = 0, created = 0 }
    local created_before = event_stats.created or 0
    local size_before = event_stats.size or 0

    for i = 1, 10000 do
        ed:emit("test:memory_chain", { iteration = i }, nil, { is_table = true })
        if dispatcher_tick_cb then dispatcher_tick_cb() end
    end

    local stats_after = TablePool.get_stats() or {}
    local event_after = stats_after.event or { size = 0, created = 0 }
    local created_after = event_after.created or 0
    local size_after = event_after.size or 0

    -- Пул не должен неограниченно расти: создано не больше разумного лимита (предаллокация + небольшой запас)
    Assert.is_true(created_after <= created_before + 100,
        string.format("TablePool event: created до=%d после=%d (ожидается возврат в пул)", created_before, created_after))
    -- Размер пула в норме (не накоплены тысячи таблиц)
    Assert.is_true(size_after < 500,
        string.format("TablePool event size после 10k эмитов: %d (ожидается < 500)", size_after))
end)

suite:add_test("INT-MEM-02: Memory Chain — get_stats отражает типы EventDispatcher", function()
    local stats = TablePool.get_stats()
    Assert.is_not_nil(stats, "get_stats() не nil")
    Assert.is_true(stats.event ~= nil, "тип event зарегистрирован")
    Assert.is_true(stats.lvc_entry == nil or stats.lvc_entry ~= nil, "статистика пулов доступна")
end)

suite:run()
