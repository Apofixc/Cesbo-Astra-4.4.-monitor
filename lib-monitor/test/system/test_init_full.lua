-- SYS: Init Module Structure (ПМИ 2.1)
-- Проверка структуры init_monitor без полной инициализации.
-- Полная init требует Astra с config.json (см. readme/template.lua).

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local suite = TestSuite:new("SYS.init_structure")
local saved_ModuleManager

suite:setup(function()
    saved_ModuleManager = _G.ModuleManager
end)

suite:teardown(function()
    _G.ModuleManager = saved_ModuleManager
    package.loaded["src.core.module_manager"] = nil
end)

suite:add_test("SYS-INIT-01: init_monitor — ModuleManager загружается", function()
    package.loaded["src.core.module_manager"] = nil
    local mm = require("src.core.module_manager")
    Assert.is_not_nil(mm, "ModuleManager загружен")
    Assert.is_true(type(mm.register_module) == "function", "register_module")
    Assert.is_true(type(mm.load_modules) == "function", "load_modules")
    Assert.is_true(type(mm.check_nested_dependency) == "function", "check_nested_dependency")
    _G.ModuleManager = saved_ModuleManager
end)

suite:add_test("SYS-INIT-02: init_monitor — пути lib-monitor в package.path", function()
    local found = package.path:find("lib%-monitor") or package.path:find("Cesbo")
    Assert.is_true(found ~= nil, "package.path содержит lib-monitor")
end)

suite:run()
