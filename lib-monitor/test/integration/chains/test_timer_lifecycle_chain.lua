-- INT: Timer Lifecycle Chain (PMI 1.2 #15)
-- Scheduler <-> timer (Astra) <-> Callback: timer precision, no drift under load.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Error: Run via run_test.lua required.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local Scheduler
local timer_calls

local suite = TestSuite:new("INT.chains.timer_lifecycle")

suite:setup(function()
    timer_calls = {}
    _G.ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return { error = function() end, info = function() end, warning = function() end, debug = function() end }
            end
            if name == "core.event_dispatcher" then
                return { get_instance = function() return { subscribe = function() return "id" end } end }
            end
            return nil
        end,
        get_global_dependency = function(n)
            if n == "timer" then
                return function(opts)
                    table.insert(timer_calls, { opts = opts })
                    return { stop = function() end }
                end
            end
            return nil
        end,
    }
    package.loaded["src.core.scheduler"] = nil
    Scheduler = require("src.core.scheduler")
end)

suite:teardown(function()
    local s = Scheduler.get_instance()
    if s and s.shutdown then pcall(function() s:shutdown() end) end
    package.loaded["src.core.scheduler"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-TMR-01: Timer Lifecycle Chain - Scheduler creates Astra timer with interval", function()
    local sch = Scheduler.get_instance()
    Assert.is_not_nil(sch, "Scheduler instance")
    Assert.is_true(#timer_calls >= 1, "timer() called")
    local call = timer_calls[1]
    Assert.is_true(call.opts.interval ~= nil, "interval passed to timer")
    Assert.is_true(type(call.opts.callback) == "function", "callback passed to timer")
end)

suite:run()
