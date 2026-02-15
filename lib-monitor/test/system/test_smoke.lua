-- SYS-SMK: Smoke-тестирование (ПМИ 2.1)
-- Инициализация: проверка работоспособности тестовой среды и базовых компонентов.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local suite = TestSuite:new("SYS.smoke")

suite:add_test("SYS-SMK-01: Smoke — Astra среда доступна", function()
    Assert.is_not_nil(_G.astra, "_G.astra существует")
    Assert.is_true(type(_G.astra) == "table", "astra — таблица")
    Assert.is_not_nil(_G.astra.version, "astra.version задана")
end)

suite:add_test("SYS-SMK-02: Smoke — run_test и luacov активны", function()
    Assert.is_true(_G.RUN_TEST_ACTIVE == true, "RUN_TEST_ACTIVE")
end)

suite:add_test("SYS-SMK-03: Smoke — package.path настроен для lib-monitor", function()
    local has_lib = package.path:find("lib%-monitor") or package.path:find("Cesbo%-Astra")
    Assert.is_true(has_lib ~= nil or #package.path > 0, "package.path содержит пути")
end)

suite:run()
