-- INT: Persistence Chain (PMI 1.2 #16)
-- MonitorConfig <-> json.save/load (Astra): atomic save/load, file system integration.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Error: Run via run_test.lua required.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local MonitorConfig
local save_calls
local load_calls
local mock_save_fail

local suite = TestSuite:new("INT.chains.persistence")

suite:setup(function()
    save_calls = {}
    load_calls = {}
    mock_save_fail = false
    _G.ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return { error = function() end, info = function() end, warning = function() end, debug = function() end }
            end
            if name == "core.event_dispatcher" then
                return { get_instance = function() return { subscribe = function() return "id" end, emit_safe = function() end } end }
            end
            return nil
        end,
        get_global_dependency = function(n)
            if n == "json.load" then
                return function(path)
                    table.insert(load_calls, { path = path })
                    return { Logger = { LogLevel = "DEBUG" }, System = {} }
                end
            end
            if n == "json.save" then
                return function(path, data)
                    if mock_save_fail then error("disk full") end
                    table.insert(save_calls, { path = path, data = data })
                    return true
                end
            end
            return nil
        end,
    }
    package.loaded["src.config.monitor_config"] = nil
    MonitorConfig = require("src.config.monitor_config")
end)

suite:teardown(function()
    package.loaded["src.config.monitor_config"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-PER-01: Persistence Chain - reload calls json.load", function()
    local n_before = #load_calls
    MonitorConfig.reload()
    Assert.is_true(#load_calls > n_before, "reload invokes json.load")
    Assert.are_equal("DEBUG", MonitorConfig.Logger.LogLevel, "loaded config applied")
end)

suite:add_test("INT-PER-02: Persistence Chain - save calls json.save with section data", function()
    MonitorConfig.reload()
    save_calls = {}
    MonitorConfig.update({ Logger = { LogLevel = "WARN" } })
    local ok = MonitorConfig.save()
    Assert.is_true(ok, "save returns true")
    Assert.is_true(#save_calls >= 1, "save invokes json.save")
    local last = save_calls[#save_calls]
    Assert.is_true(last.data ~= nil and type(last.data) == "table", "json.save receives table")
    Assert.is_true(last.data.Logger ~= nil, "Logger section in saved data")
    Assert.are_equal("WARN", last.data.Logger.LogLevel, "saved LogLevel")
end)

suite:add_test("INT-PER-03: Persistence Chain - save error returns false", function()
    mock_save_fail = true
    package.loaded["src.config.monitor_config"] = nil
    local cfg = require("src.config.monitor_config")
    local ok = cfg.save()
    Assert.is_false(ok, "save returns false on json.save error")
    mock_save_fail = false
end)

suite:run()
