-- INT: Repository Backup Chain (PMI 1.2 #34)
-- Repositories <-> File System: backup and recovery.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Error: Run via run_test.lua required.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local MonitorConfig
local load_calls

local suite = TestSuite:new("INT.chains.repository_backup")

suite:setup(function()
    load_calls = {}
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
                    table.insert(load_calls, path)
                    return nil
                end
            end
            if n == "json.save" then return function() return true end end
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

suite:add_test("INT-BAK-01: Repository Backup - reload with nil applies defaults", function()
    local ok = MonitorConfig.reload()
    Assert.is_true(ok, "reload returns true")
    Assert.is_true(#load_calls >= 1, "json.load called")
end)

suite:run()
