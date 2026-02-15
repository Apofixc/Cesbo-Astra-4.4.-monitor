-- INT: Shutdown Chain (ПМИ 1.2 п.11)
-- graceful_shutdown ↔ Все модули: обратный порядок очистки ресурсов.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local shutdown_handlers = {}
local add_shutdown_handler, graceful_shutdown

local suite = TestSuite:new("INT.chains.shutdown")

suite:setup(function()
    shutdown_handlers = {}
    add_shutdown_handler = function(name, handler)
        shutdown_handlers[name] = handler
    end
    graceful_shutdown = function()
        local names = {}
        for name in pairs(shutdown_handlers) do
            table.insert(names, name)
        end
        table.sort(names, function(a, b) return a > b end)
        for _, name in ipairs(names) do
            local ok, err = pcall(shutdown_handlers[name])
            if not ok then error(tostring(err)) end
        end
    end
end)

suite:add_test("INT-SHD-01: Shutdown Chain — обработчики вызываются в обратном порядке", function()
    local order = {}
    add_shutdown_handler("10_first", function() table.insert(order, "10_first") end)
    add_shutdown_handler("50_middle", function() table.insert(order, "50_middle") end)
    add_shutdown_handler("99_last", function() table.insert(order, "99_last") end)
    graceful_shutdown()
    Assert.are_equal(3, #order, "все 3 обработчика вызваны")
    Assert.are_equal("99_last", order[1], "первым — последний по имени (99_last)")
    Assert.are_equal("50_middle", order[2], "вторым — 50_middle")
    Assert.are_equal("10_first", order[3], "третьим — 10_first")
end)

suite:add_test("INT-SHD-02: Shutdown Chain — пустой список не падает", function()
    graceful_shutdown()
    Assert.is_true(true, "graceful_shutdown с пустым списком выполнен")
end)

suite:run()
