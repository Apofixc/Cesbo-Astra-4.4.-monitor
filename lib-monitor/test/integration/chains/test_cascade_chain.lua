-- INT: Cascade Chain (PMI 1.2 #4)
-- Adapter <-> Channel: automatic management of dependent entities (channels follow adapter).

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Error: Run via run_test.lua required.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local Adapter
local reconfigure_calls
local mock_tuner

local suite = TestSuite:new("INT.chains.cascade")

suite:setup(function()
    reconfigure_calls = {}
    mock_tuner = {
        get_config = function() return { name_adapter = "t1", freq = 1000 } end,
        set_backup = function() end,
        pause = function() return true end,
        start = function() return true end,
    }
    _G.ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return { error = function() end, info = function() end, warning = function() end, debug = function() end }
            end
            if name == "tuner_monitor" then
                return {
                    new = function() return mock_tuner end,
                }
            end
            if name == "dvb_repository" then
                return {
                    find = function(_, n) return mock_tuner end,
                }
            end
            if name == "utils" then
                return {
                    table_copy = function(t)
                        local r = {}
                        for k, v in pairs(t or {}) do r[k] = v end
                        return r
                    end,
                }
            end
            if name == "core.event_dispatcher" then
                return { get_instance = function() return { subscribe = function() return "id" end } end }
            end
            if name == "channel" then
                return {
                    reconfigure_streams = function(adapter_list, callback, updates)
                        table.insert(reconfigure_calls, { adapter_list = adapter_list, callback = callback, updates = updates })
                        return true
                    end,
                }
            end
            return nil
        end,
        get_global_dependency = function() return nil end,
    }
    package.loaded["src.adapters.adapter"] = nil
    Adapter = require("src.adapters.adapter")
end)

suite:teardown(function()
    package.loaded["src.adapters.adapter"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-CAS-01: Cascade Chain - reconfigure calls Channel.reconfigure_streams", function()
    local ok = Adapter.reconfigure({ "t1" }, {})
    Assert.is_true(#reconfigure_calls >= 1, "Channel.reconfigure_streams called")
    local call = reconfigure_calls[1]
    Assert.are_equal(1, #call.adapter_list, "adapter_list has one element")
    Assert.are_equal("t1", call.adapter_list[1], "adapter_list[1] = t1")
    Assert.is_true(type(call.callback) == "function", "callback is function")
end)

suite:add_test("INT-CAS-02: Cascade Chain - invalid adapter_list returns false", function()
    local ok = Adapter.reconfigure("not_a_table", {})
    Assert.is_false(ok, "reconfigure with non-table returns false")
end)

suite:run()
