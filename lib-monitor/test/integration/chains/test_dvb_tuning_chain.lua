-- INT: DVB Tuning Chain (PMI 1.2 #12)
-- Adapter <-> dvb_tune (Astra) <-> TunerMonitor: tuning params to Astra, Lock/Signal status.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Error: Run via run_test.lua required.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local TunerMonitor
local dvb_tune_calls

local suite = TestSuite:new("INT.chains.dvb_tuning")

suite:setup(function()
    dvb_tune_calls = {}
    _G.ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return { error = function() end, info = function() end, warning = function() end, debug = function() end }
            end
            if name == "utils" then
                return {
                    table_copy = function(t) local r = {} for k, v in pairs(t or {}) do r[k] = v end return r end,
                    init_report = function(t, ty, n) if type(t) == "table" then t.type = ty t.name = n end end,
                    validate_monitor_param = function(_, v) return v end
                }
            end
            if name == "monitor_config" then return { get = function() return {} end } end
            if name == "core.scheduler" then
                return { get_instance = function() return { add_task = function() end, remove_task = function() end } end }
            end
            if name == "table_pool" or name == "utils.table_pool" then
                return { get = function() return {} end, release = function() end, register_type = function() end }
            end
            if name == "core.base_monitor" then return require("src.core.base_monitor") end
            if name == "core.event_dispatcher" then
                return { get_instance = function() return { subscribe = function() return "id" end } end }
            end
            return nil
        end,
        get_global_dependency = function(n)
            if n == "dvb_tune" then
                return function(conf)
                    table.insert(dvb_tune_calls, { conf = conf })
                    return { close = function() end }
                end
            end
            return nil
        end,
    }
    package.loaded["src.adapters.tuner_monitor"] = nil
    TunerMonitor = require("src.adapters.tuner_monitor")
end)

suite:teardown(function()
    package.loaded["src.adapters.tuner_monitor"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-DVB-01: DVB Tuning Chain - TunerMonitor.start calls dvb_tune with astra conf", function()
    local tm = TunerMonitor.new({ name_adapter = "t1", freq = 1000, type = "DVB-S2", method_comparison = 1 })
    Assert.is_not_nil(tm, "TunerMonitor.new")
    local inst = tm:start()
    Assert.is_true(#dvb_tune_calls >= 1, "dvb_tune called")
    local call = dvb_tune_calls[1]
    Assert.is_true(call.conf.freq == 1000, "freq passed to dvb_tune")
    Assert.are_equal("t1", call.conf.name_adapter, "name_adapter passed")
    Assert.is_true(type(call.conf.callback) == "function", "callback passed to dvb_tune")
end)

suite:run()
