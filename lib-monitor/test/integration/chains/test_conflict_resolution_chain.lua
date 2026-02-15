-- INT: Conflict Resolution Chain (PMI 1.2 #25)
-- Adapter <-> DvbRepository <-> Channel: block channel start if adapter busy.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Error: Run via run_test.lua required.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local DvbRepository
local find_calls

local suite = TestSuite:new("INT.chains.conflict_resolution")

suite:setup(function()
    find_calls = {}
    _G.ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return { error = function() end, info = function() end, warning = function() end, debug = function() end }
            end
            if name == "core.base_repository" then return require("src.core.base_repository") end
            if name == "core.event_dispatcher" then
                return { get_instance = function() return { subscribe = function() return "id" end } end }
            end
            return nil
        end,
        get_global_dependency = function() return nil end,
    }
    package.loaded["src.repository.dvb_repository"] = nil
    DvbRepository = require("src.repository.dvb_repository")
end)

suite:teardown(function()
    package.loaded["src.repository.dvb_repository"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-CFL-01: Conflict Resolution Chain - DvbRepository:find returns nil for missing adapter", function()
    local repo = DvbRepository
    local inst = repo:find("nonexistent")
    Assert.is_nil(inst, "find returns nil when adapter not registered")
end)

suite:add_test("INT-CFL-02: Conflict Resolution Chain - DvbRepository register/unregister", function()
    local MonitorClass = {}
    MonitorClass.__index = MonitorClass
    function MonitorClass.new(_, config) return setmetatable({ destroy = function() return config end }, MonitorClass) end
    local instance = MonitorClass.new(nil, { name_adapter = "t1" })
    local ok = DvbRepository:register("t1", instance, MonitorClass)
    Assert.is_true(ok, "register succeeds")
    local found = DvbRepository:find("t1")
    Assert.is_not_nil(found, "find returns monitor after register")
    local cfg = DvbRepository:unregister("t1", true)
    Assert.is_not_nil(cfg, "unregister returns config")
end)

suite:run()
