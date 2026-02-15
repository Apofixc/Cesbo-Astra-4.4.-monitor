-- INT: Initialization Chain (PMI 1.2 #8)
-- ModuleManager <-> init_monitor: phased loading.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Error: Run via run_test.lua required.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local ModuleManager

local suite = TestSuite:new("INT.chains.initialization")

suite:setup(function()
    package.loaded["src.core.module_manager"] = nil
    _G.ModuleManager = nil
    ModuleManager = require("src.core.module_manager")
end)

suite:teardown(function()
    package.loaded["src.core.module_manager"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-INIT-01: Initialization Chain - check_nested_dependency finds stubbed deps", function()
    _G.dvb_tune = function() return {} end
    _G.timer = function() return "tid" end
    _G.json = { save = function() return true end, load = function() return {} end }
    local r = ModuleManager.check_nested_dependency("dvb_tune")
    Assert.is_not_nil(r, "dvb_tune found")
    _G.dvb_tune = nil
    _G.timer = nil
    _G.json = nil
end)

suite:add_test("INT-INIT-02: Initialization Chain - set_global_dependencies stores deps", function()
    local mock_timer = function() return "tid" end
    ModuleManager.set_global_dependencies({ ["timer"] = mock_timer })
    local dep = ModuleManager.get_global_dependency("timer")
    Assert.are_equal(mock_timer, dep, "get_global_dependency returns stored value")
    ModuleManager.remove_global_dependency("timer")
end)

suite:run()
