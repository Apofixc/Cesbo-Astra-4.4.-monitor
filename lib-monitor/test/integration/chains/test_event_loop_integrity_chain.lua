-- INT: Event Loop Integrity Chain (PMI 1.2 #38)
-- EventDispatcher <-> Astra Event Loop: no delays in packet processing.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Error: Run via run_test.lua required.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local EventDispatcher
local dispatcher_tick_cb

local suite = TestSuite:new("INT.chains.event_loop_integrity")

suite:setup(function()
    if not _G.os then _G.os = {} end
    if not _G.os.clock then _G.os.clock = function() return 0 end end
    local ref_sub_mgr
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
                if not ref_sub_mgr then ref_sub_mgr = require("src.core.subscription_manager").new() end
                return { new = function() return ref_sub_mgr end }
            end
            if name == "table_pool" or name == "utils.table_pool" then return require("src.utils.table_pool") end
            if name == "ws_subscriber" then return { broadcast_raw = function() end } end
            if name == "utils.filter_engine" then return require("src.utils.filter_engine") end
            if name == "utils.wildcard" then return require("src.utils.wildcard") end
            if name == "utils" then
                return { to_line_protocol = function() return "" end, truncate_string = function(s, n) return (s or ""):sub(1, n or 0) end, shell_escape = function(s) return "'" .. (s or "") .. "'" end }
            end
            return nil
        end,
        get_global_dependency = function(n)
            if n == "json.encode" then return function(t) return type(t) == "table" and "{}" or tostring(t) end end
            if n == "json.decode" then return function() return {} end end
            if n == "http_request" then return function() return true end end
            return nil
        end,
    }
    EventDispatcher = require("src.core.event_dispatcher")
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

suite:add_test("INT-ELI-01: Event Loop Integrity - emit and process complete without blocking", function()
    local ed = EventDispatcher.get_instance()
    local t0 = os.clock()
    for i = 1, 100 do
        ed:emit("test:loop", { n = i }, nil, { is_table = true })
        if dispatcher_tick_cb then dispatcher_tick_cb() end
    end
    local t1 = os.clock()
    Assert.is_true(t1 - t0 < 1.0, "100 emit+process under 1 sec")
end)

suite:run()
