-- INT: Reactive Chain (ПМИ 1.2 п.3)
-- ResourceMonitor <-> EventDispatcher <-> BaseMonitor: load shedding при нагрузке.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local EventDispatcher, BaseMonitor, dispatcher_tick_cb

local suite = TestSuite:new("INT.chains.reactive")

suite:setup(function()
    dispatcher_tick_cb = nil
    if not _G.os then _G.os = {} end
    if not _G.os.clock then _G.os.clock = function() return 0 end end
    local ref_sub_mgr = nil
    local real_table_pool = nil
    _G.ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return { error = function() end, info = function() end, warning = function() end, debug = function() end }
            end
            if name == "utils" then
                return {
                    validate_monitor_param = function(_, v) return v end,
                    init_report = function(t, ty, n) t.type = ty t.name = n end,
                    to_line_protocol = function() return "" end,
                    truncate_string = function(s, n) return (s or ""):sub(1, n or 0) end,
                    shell_escape = function(s) return "'" .. (s or "") .. "'" end,
                }
            end
            if name == "utils.table_pool" or name == "table_pool" then return real_table_pool end
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
                if not ref_sub_mgr then ref_sub_mgr = require("src.core.subscription_manager").new() end
                return { new = function() return ref_sub_mgr end }
            end
            if name == "utils.filter_engine" then return require("src.utils.filter_engine") end
            if name == "utils.wildcard" then return require("src.utils.wildcard") end
            if name == "ws_subscriber" then return { broadcast_raw = function() end } end
            if name == "core.event_dispatcher" then return EventDispatcher end
            return nil
        end,
        get_global_dependency = function(n)
            if n == "json.encode" then return function(t) return (t and type(t) == "table") and "{}" or tostring(t) end end
            if n == "json.decode" then return function() return {} end end
            if n == "http_request" then return function() return true end end
            return nil
        end,
    }
    real_table_pool = require("src.utils.table_pool")
    EventDispatcher = require("src.core.event_dispatcher")
    BaseMonitor = require("src.core.base_monitor")
end)

suite:teardown(function()
    if EventDispatcher and EventDispatcher.get_instance and EventDispatcher.get_instance().shutdown then
        pcall(function() EventDispatcher.get_instance():shutdown() end)
    end
    package.loaded["src.core.event_dispatcher"] = nil
    package.loaded["src.core.base_monitor"] = nil
    package.loaded["src.core.subscription_manager"] = nil
    package.loaded["src.utils.table_pool"] = nil
    package.loaded["src.utils.filter_engine"] = nil
    package.loaded["src.utils.wildcard"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-REC-01: Reactive Chain - sys:resource_warning доставляется подписчику", function()
    local received = {}
    local ed = EventDispatcher.get_instance()
    ed:subscribe("sys:resource_warning", function(data)
        table.insert(received, data and data.type)
    end)
    ed:emit("sys:resource_warning", { type = "cpu", status = "critical" })
    for _ = 1, 5 do if dispatcher_tick_cb then dispatcher_tick_cb() end end
    Assert.is_true(#received >= 1, "подписчик получил событие")
    Assert.are_equal("cpu", received[1], "type=cpu доставлен")
end)

suite:add_test("INT-REC-02: Reactive Chain - BaseMonitor включает load_shedding при critical", function()
    local monitor = BaseMonitor.new("reactive_test", "generic")
    Assert.is_not_nil(monitor, "BaseMonitor.new")
    local ed = EventDispatcher.get_instance()
    ed:emit("sys:resource_warning", { type = "cpu", status = "critical" })
    for _ = 1, 25 do if dispatcher_tick_cb then dispatcher_tick_cb() end end
    Assert.is_true(monitor._load_shedding_active == true, "load_shedding включен при critical")
end)

suite:run()
