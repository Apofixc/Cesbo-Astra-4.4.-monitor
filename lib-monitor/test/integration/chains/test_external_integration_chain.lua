-- INT: External Integration Chain (PMI 1.2 #14)
-- Logic <-> http_request (Astra) <-> External API.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Error: Run via run_test.lua required.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local SubscriptionManager
local http_request_calls

local suite = TestSuite:new("INT.chains.external_integration")

suite:setup(function()
    http_request_calls = {}
    _G.ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return { error = function() end, info = function() end, warning = function() end, debug = function() end }
            end
            if name == "monitor_config" then return { get = function() return {} end } end
            if name == "utils.filter_engine" then return require("src.utils.filter_engine") end
            if name == "utils.wildcard" then return require("src.utils.wildcard") end
            if name == "core.scheduler" then
                return { get_instance = function() return { add_task = function() end, remove_task = function() end } end }
            end
            if name == "table_pool" or name == "utils.table_pool" then
                return { get = function() return {} end, release = function() end, register_type = function() end }
            end
            if name == "ws_subscriber" then return { broadcast_raw = function() end } end
            if name == "core.event_dispatcher" then return nil end
            return nil
        end,
        get_global_dependency = function(n)
            if n == "http_request" then
                return function(opts)
                    table.insert(http_request_calls, opts)
                    return { close = function() end }
                end
            end
            if n == "json.encode" then return function() return "{}" end end
            if n == "json.decode" then return function() return {} end end
            if n == "astra.version" then return "4.4.182" end
            return nil
        end,
    }
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
end)

suite:teardown(function()
    package.loaded["src.core.subscription_manager"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-EXT-01: External Integration - HTTP transport uses http_request", function()
    local sm = SubscriptionManager.new()
    sm:subscribe("channel:error", { callback = { type = "HTTP", host = "api.test.com", port = 80, path = "/hook" } })
    sm:publish_event({ type = "channel:error", data = { err = "test" } })
    Assert.is_true(#http_request_calls >= 1, "http_request invoked")
end)

suite:run()
