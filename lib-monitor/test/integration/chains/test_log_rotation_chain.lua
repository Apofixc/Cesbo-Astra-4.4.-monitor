-- INT: Log Rotation Chain (PMI 1.2 #36)
-- Logger <-> OS.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Error: Run via run_test.lua required.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local Logger
local log_calls

local suite = TestSuite:new("INT.chains.log_rotation")

suite:setup(function()
    log_calls = {}
    _G.ModuleManager = {
        get_module = function(name)
            if name == "monitor_config" then return { get = function() return {} end } end
            if name == "core.event_dispatcher" then return { get_instance = function() return { subscribe = function() return "id" end } end } end
            if name == "table_pool" then return { get = function() return {} end, release = function() end, register_type = function() end } end
            return nil
        end,
        get_global_dependency = function(n)
            if n == "log" then
                return {
                    debug = function(m) table.insert(log_calls, m) end,
                    info = function(m) table.insert(log_calls, m) end,
                    warning = function(m) table.insert(log_calls, m) end,
                    error = function(m) table.insert(log_calls, m) end,
                }
            end
            if n == "json.encode" then return function() return "{}" end end
            return nil
        end,
    }
    package.loaded["src.utils.logger"] = nil
    Logger = require("src.utils.logger")
end)

suite:teardown(function()
    package.loaded["src.utils.logger"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-LOGROT-01: Log Rotation - Logger writes via log dependency", function()
    Logger.init_config_subscription()
    Logger.info("TestComp", "msg")
    Assert.is_true(#log_calls >= 1, "log called")
end)

suite:run()
