-- INT: Module Dependency Chain (ПМИ 1.2 п.20)
-- ModuleManager: обнаружение циклических зависимостей.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local suite = TestSuite:new("INT.chains.module_dependency")

suite:setup(function()
    package.loaded["src.core.module_manager"] = nil
    _G.ModuleManager = nil
end)

suite:teardown(function()
    package.loaded["src.core.module_manager"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-MOD-01: Module Dependency Chain - циклические зависимости обнаруживаются", function()
    local ModuleManager = require("src.core.module_manager")
    ModuleManager.register_module("int_mod_a", "src.utils.wildcard", { "int_mod_b" })
    ModuleManager.register_module("int_mod_b", "src.utils.wildcard", { "int_mod_a" })

    local load_order = ModuleManager.load_modules()
    Assert.is_nil(load_order, "load_modules возвращает nil при циклической зависимости")
    _G.ModuleManager = nil
end)

suite:run()
