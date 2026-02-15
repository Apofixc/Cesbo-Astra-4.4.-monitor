-- SYS: Init & Shutdown (ПМИ 2.1)
-- Проверка модуля init_monitor и graceful_shutdown.
-- Полная инициализация требует Astra с config.json и всеми зависимостями.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local suite = TestSuite:new("SYS.init_shutdown")

suite:add_test("SYS-INIT-01: init_monitor модуль загружается и возвращает ModuleManager", function()
    package.loaded["init_monitor"] = nil
    local mm = require("init_monitor")
    Assert.is_not_nil(mm, "init_monitor возвращает значение")
    Assert.is_true(type(mm) == "table", "возвращает таблицу")
    Assert.is_true(type(mm.get_module) == "function", "имеет get_module")
    Assert.is_true(type(mm.check_nested_dependency) == "function", "имеет check_nested_dependency")
end)

suite:add_test("SYS-INIT-02: add_shutdown_handler и graceful_shutdown экспортированы в _G", function()
    Assert.is_not_nil(_G.add_shutdown_handler, "add_shutdown_handler в _G")
    Assert.is_not_nil(_G.graceful_shutdown, "graceful_shutdown в _G")
    Assert.is_true(type(_G.add_shutdown_handler) == "function", "add_shutdown_handler — функция")
    Assert.is_true(type(_G.graceful_shutdown) == "function", "graceful_shutdown — функция")
end)

suite:add_test("SYS-INIT-03: graceful_shutdown выполняется без падения", function()
    local ok, err = pcall(_G.graceful_shutdown)
    Assert.is_true(ok, "graceful_shutdown выполнен: " .. tostring(err))
end)

suite:add_test("SYS-INIT-04: add_shutdown_handler регистрирует обработчик", function()
    local called = false
    _G.add_shutdown_handler("test_sys_handler", function() called = true end)
    _G.graceful_shutdown()
    Assert.is_true(called, "обработчик вызван при shutdown")
end)

suite:run()
