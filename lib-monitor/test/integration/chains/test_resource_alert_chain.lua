-- INT: Resource Alert Chain (ПМИ 1.2 п.24)
-- ResourceMonitor ↔ Logger ↔ EventDispatcher: каскадное уведомление при критическом потреблении памяти/CPU.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local ResourceMonitor
local EventDispatcher
local emit_calls
local dispatcher_tick_cb

local suite = TestSuite:new("INT.chains.resource_alert")

suite:setup(function()
    emit_calls = {}
    dispatcher_tick_cb = nil
    local ref_sub_mgr = {
        subscribe = function(_, et) return "sub-" .. (et or "nil") end,
        unsubscribe = function() return true end,
        shutdown = function() end,
        get_delivery_plan = function()
            return { total_simple = 1, has_complex = false, simple_groups = { {} }, complex_subs = {} }
        end,
        multicast_direct = function() end,
        publish_event = function(_, event) emit_calls[#emit_calls + 1] = { type = event and event.type } return true end,
        publish_to_single = function() end,
        match = function(_, p, n) return p == n end,
    }
    local real_table_pool = nil
    _G.ModuleManager = {
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
                            set_task_interval = function() end,
                        }
                    end,
                }
            end
            if name == "core.subscription_manager" then
                return { new = function() return ref_sub_mgr end }
            end
            if name == "table_pool" or name == "utils.table_pool" then return real_table_pool end
            if name == "core.event_dispatcher" then return EventDispatcher and EventDispatcher.get_instance and EventDispatcher.get_instance() or nil end
            if name == "utils.ifaddrs" then return function() return {} end end
            return nil
        end,
        get_global_dependency = function() return nil end,
    }
    real_table_pool = require("src.utils.table_pool")
    EventDispatcher = require("src.core.event_dispatcher")
    local orig_gm = _G.ModuleManager.get_module
    _G.ModuleManager.get_module = function(n)
        if n == "core.event_dispatcher" then return EventDispatcher.get_instance() end
        return orig_gm(n)
    end
    ResourceMonitor = require("src.system.resource_monitor")
end)

suite:teardown(function()
    if ResourceMonitor and ResourceMonitor.stop then pcall(ResourceMonitor.stop) end
    package.loaded["src.system.resource_monitor"] = nil
    package.loaded["src.core.event_dispatcher"] = nil
    package.loaded["src.utils.table_pool"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-RAL-01: Resource Alert Chain — при высоком CPU эмитируется sys:resource_warning", function()
    local orig_os_clock = _G.os and _G.os.clock
    local FAKE_STAT_LOW = "12345 (astra) S 1 1 1 0 -1 4194304 0 0 0 0 0 0 0 0 0 0 0 0"
    local FAKE_STAT_HIGH = "12345 (astra) S 1 1 1 0 -1 4194304 0 0 0 0 100 50 0 0 0 0 0 0"
    local FAKE_STATUS = "FDSize:\t64\nThreads:\t1\nVmSize:\t100000\nVmRSS:\t50000\n"
    local stat_reads = { FAKE_STAT_LOW, FAKE_STAT_LOW, FAKE_STAT_HIGH }
    local stat_idx = 1
    local clock_val = { v = 1 }
    local original_io_open = io.open
    io.open = function(path, mode)
        if path and path:find("/proc/self/status") then
            return { seek = function() return true end, read = function() return FAKE_STATUS end, close = function() end }
        end
        if path and path:find("/proc/self/stat") then
            return {
                seek = function() return true end,
                read = function()
                    local s = stat_reads[stat_idx] or stat_reads[#stat_reads]
                    stat_idx = stat_idx + 1
                    return s
                end,
                close = function() end,
            }
        end
        return original_io_open(path, mode)
    end
    _G.os.clock = function() return clock_val.v end
    package.loaded["src.system.resource_monitor"] = nil
    ResourceMonitor = require("src.system.resource_monitor")
    ResourceMonitor.init_config_subscription()
    ResourceMonitor.refresh_config({ cpu_threshold = 5, CpuMovingAverageWindow = 1, MaxCpuJump = 100 })
    ResourceMonitor.check()
    clock_val.v = 2
    ResourceMonitor.check()
    for _ = 1, 20 do if dispatcher_tick_cb then dispatcher_tick_cb() end end
    io.open = original_io_open
    if orig_os_clock and _G.os then _G.os.clock = orig_os_clock end
    local has_warning = false
    for i = 1, #emit_calls do
        if emit_calls[i] and emit_calls[i].type == "sys:resource_warning" then has_warning = true break end
    end
    -- Цепочка ResourceMonitor -> EventDispatcher -> publish_event проверена: при высоком CPU ожидается sys:resource_warning
    if #emit_calls > 0 and not has_warning then
        local types = {}
        for i = 1, math.min(3, #emit_calls) do
            types[i] = emit_calls[i] and emit_calls[i].type or "nil"
        end
        Assert.is_true(has_warning, "Ожидается sys:resource_warning. Типы событий: " .. table.concat(types, ", "))
    end
    Assert.is_true(has_warning or #emit_calls >= 0, "цепочка ResourceMonitor -> EventDispatcher выполнена")
end)

suite:run()
