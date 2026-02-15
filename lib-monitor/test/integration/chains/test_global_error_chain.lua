-- INT: Global Error Chain (PMI 1.2 #17)
-- Any Module <-> Logger <-> EventDispatcher <-> WebSocket: critical error reaches UI as alert.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Error: Run via run_test.lua required.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local EventDispatcher
local broadcast_calls
local dispatcher_tick_cb
local ref_sub_mgr

local suite = TestSuite:new("INT.chains.global_error")

suite:setup(function()
    broadcast_calls = {}
    dispatcher_tick_cb = nil
    if not _G.os then _G.os = {} end
    if not _G.os.clock then _G.os.clock = function() return 0 end end
    local ws_mock = {
        broadcast_raw = function(event_type, json_data)
            table.insert(broadcast_calls, { event_type = event_type, json_data = json_data })
        end,
    }
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
                if not ref_sub_mgr then
                    ref_sub_mgr = require("src.core.subscription_manager").new()
                end
                return { new = function() return ref_sub_mgr end }
            end
            if name == "table_pool" or name == "utils.table_pool" then return real_table_pool end
            if name == "ws_subscriber" then return ws_mock end
            if name == "utils.filter_engine" then return require("src.utils.filter_engine") end
            if name == "utils.wildcard" then return require("src.utils.wildcard") end
            if name == "utils" then
                return {
                    to_line_protocol = function() return "" end,
                    truncate_string = function(s, n) return (s or ""):sub(1, n or 0) end,
                    shell_escape = function(s) return "'" .. (s or "") .. "'" end,
                }
            end
            return nil
        end,
        get_global_dependency = function(n)
            if n == "json.encode" then
                return function(t) return (t and type(t) == "table") and '{"err":"test"}' or tostring(t) end
            end
            if n == "json.decode" then return function() return {} end end
            if n == "http_request" then return function() return true end end
            return nil
        end,
    }
    real_table_pool = require("src.utils.table_pool")
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    if ref_sub_mgr then
        ref_sub_mgr:subscribe("channel:*", { callback = { type = "WS" } })
    end
end)

suite:teardown(function()
    if EventDispatcher and EventDispatcher.get_instance and EventDispatcher.get_instance().shutdown then
        pcall(function() EventDispatcher.get_instance():shutdown() end)
    end
    package.loaded["src.core.event_dispatcher"] = nil
    package.loaded["src.core.subscription_manager"] = nil
    package.loaded["src.utils.table_pool"] = nil
    package.loaded["src.utils.filter_engine"] = nil
    package.loaded["src.utils.wildcard"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-GE-01: Global Error Chain - channel:error delivered to WebSocket", function()
    local ed = EventDispatcher.get_instance()
    Assert.is_not_nil(ed, "EventDispatcher instance")
    Assert.is_not_nil(dispatcher_tick_cb, "dispatcher_tick_cb")
    local before = #broadcast_calls
    ed:emit("channel:error", { err = "test", source = "monitor" }, nil, { is_table = true })
    for _ = 1, 5 do
        if dispatcher_tick_cb then dispatcher_tick_cb() end
    end
    Assert.is_true(#broadcast_calls > before,
        string.format("channel:error delivered: was %d, now %d", before, #broadcast_calls))
    local last = broadcast_calls[#broadcast_calls]
    Assert.are_equal("channel:error", last.event_type, "event type channel:error")
end)

suite:add_test("INT-GE-02: Global Error Chain - sys:resource_warning delivered to WebSocket", function()
    local ed = EventDispatcher.get_instance()
    if ref_sub_mgr then
        ref_sub_mgr:subscribe("sys:*", { callback = { type = "WS" } })
    end
    local before = #broadcast_calls
    ed:emit("sys:resource_warning", { level = "critical", cpu = 95 }, nil, { is_table = true })
    for _ = 1, 5 do
        if dispatcher_tick_cb then dispatcher_tick_cb() end
    end
    local found = false
    for i = 1, #broadcast_calls do
        if broadcast_calls[i].event_type == "sys:resource_warning" then found = true break end
    end
    Assert.is_true(found, "sys:resource_warning delivered to broadcast_raw")
end)

suite:run()
