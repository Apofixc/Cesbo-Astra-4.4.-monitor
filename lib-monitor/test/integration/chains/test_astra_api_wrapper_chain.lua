-- INT: Astra API Wrapper Chain (ПМИ 1.2 п.37)
-- ModuleManager ↔ Astra Global API: изоляция вызовов Astra API через обертки для мокирования.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local ModuleManager
local saved_astra_obj

local suite = TestSuite:new("INT.chains.astra_api_wrapper")

suite:setup(function()
    package.loaded["src.core.module_manager"] = nil
    _G.ModuleManager = nil
    saved_astra_obj = nil
    ModuleManager = require("src.core.module_manager")
end)

suite:teardown(function()
    if saved_astra_obj ~= nil then
        _G.test_astra_wrapper_obj = nil
    end
    package.loaded["src.core.module_manager"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-API-01: Astra API Wrapper — check_nested_dependency разрешает вложенный путь", function()
    saved_astra_obj = { foo = { bar = "baz" } }
    _G.test_astra_wrapper_obj = saved_astra_obj

    local obj = ModuleManager.check_nested_dependency("test_astra_wrapper_obj.foo.bar")
    Assert.are_equal("baz", obj, "check_nested_dependency('obj.foo.bar') возвращает значение")

    local tbl = ModuleManager.check_nested_dependency("test_astra_wrapper_obj.foo")
    Assert.is_true(type(tbl) == "table", "check_nested_dependency возвращает таблицу для промежуточного пути")
    Assert.are_equal("baz", tbl.bar, "промежуточная таблица содержит bar")

    _G.test_astra_wrapper_obj = nil
    saved_astra_obj = nil
end)

suite:add_test("INT-API-02: Astra API Wrapper — check_nested_dependency возвращает nil для несуществующего пути", function()
    local obj = ModuleManager.check_nested_dependency("nonexistent.path.to.obj")
    Assert.is_nil(obj, "check_nested_dependency для несуществующего пути возвращает nil")

    obj = ModuleManager.check_nested_dependency("nonexistent_top_level_key")
    Assert.is_nil(obj, "check_nested_dependency для несуществующего ключа возвращает nil")
end)

suite:add_test("INT-API-03: Astra API Wrapper — set_global_dependencies и get_global_dependency изолируют вызовы", function()
    local mock_timer = function() return "timer_id" end
    ModuleManager.set_global_dependencies({ ["timer"] = mock_timer })

    local dep = ModuleManager.get_global_dependency("timer")
    Assert.is_not_nil(dep, "get_global_dependency возвращает мок")
    Assert.are_equal("timer_id", dep(), "мок timer возвращает ожидаемое значение")

    ModuleManager.remove_global_dependency("timer")
    local after_remove = ModuleManager.get_global_dependency("timer")
    Assert.is_nil(after_remove, "после remove_global_dependency зависимость удалена")
end)

suite:run()
