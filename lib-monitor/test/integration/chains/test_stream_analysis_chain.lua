-- INT: Stream Analysis Chain (PMI 1.2 #13)
-- Channel <-> analyze (Astra) <-> ChannelMonitor: stream init, CC/Bitrate parsing.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Error: Run via run_test.lua required.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local ChannelMonitor
local analyze_calls
local mock_upstream

local suite = TestSuite:new("INT.chains.stream_analysis")

suite:setup(function()
    analyze_calls = {}
    mock_upstream = { stream = function() return { close = function() end } end }
    _G.ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return { error = function() end, info = function() end, warning = function() end, debug = function() end }
            end
            if name == "utils" then
                return {
                    table_copy = function(t) local r = {} for k, v in pairs(t or {}) do r[k] = v end return r end,
                    ratio = function(a, b) return (a or 0) / (math.max(b or 1, 1)) end,
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
            if n == "analyze" then
                return function(opts)
                    table.insert(analyze_calls, { opts = opts })
                    return { close = function() end }
                end
            end
            if n == "kill_input" then return function() end end
            return nil
        end,
    }
    package.loaded["src.channel.channel_monitor"] = nil
    ChannelMonitor = require("src.channel.channel_monitor")
end)

suite:teardown(function()
    package.loaded["src.channel.channel_monitor"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-STR-01: Stream Analysis Chain - ChannelMonitor.start calls analyze with opts", function()
    local config = { monitor = "test", upstream = mock_upstream, name = "ch1", cc_limit = 10, bitrate_limit = 0.9, method_comparison = 1 }
    local cm = ChannelMonitor.new(config, { name = "ch1" })
    Assert.is_not_nil(cm, "ChannelMonitor.new")
    cm._astra_conf = { cc_limit = 10, bitrate_limit = 0.9, join_pid = nil }
    cm:start()
    Assert.is_true(#analyze_calls >= 1, "analyze invoked")
    local call = analyze_calls[1]
    Assert.is_true(call.opts.upstream ~= nil, "upstream passed to analyze")
    Assert.are_equal(10, call.opts.cc_limit, "cc_limit passed")
end)

suite:run()
