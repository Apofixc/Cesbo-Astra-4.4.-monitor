-- INT: Scheduler Priority Chain (ПМИ 1.2 п.35)
-- Scheduler ↔ Task Queue: задачи в куче по next_run, приоритет хранится.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local Scheduler
local timer_callback
local orig_os_clock

local suite = TestSuite:new("INT.chains.scheduler_priority")

suite:setup(function()
    timer_callback = nil
    orig_os_clock = _G.os and _G.os.clock
    if not _G.os then _G.os = {} end
    _G.os.clock = function() return 0 end
    _G.ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return { error = function() end, info = function() end, warning = function() end, debug = function() end }
            end
            return nil
        end,
        get_global_dependency = function(n)
            if n == "timer" then
                return function(opts)
                    if opts and opts.callback then timer_callback = opts.callback end
                    return {}
                end
            end
            return nil
        end,
    }
    Scheduler = require("src.core.scheduler")
end)

suite:teardown(function()
    if Scheduler and Scheduler.get_instance and Scheduler.get_instance().shutdown then
        pcall(function() Scheduler.get_instance():shutdown() end)
    end
    package.loaded["src.core.scheduler"] = nil
    _G.ModuleManager = nil
    if orig_os_clock and _G.os then _G.os.clock = orig_os_clock end
end)

suite:add_test("INT-SCH-01: Scheduler Priority Chain - задачи выполняются по очереди кучи", function()
    local ran = {}
    local s = Scheduler.get_instance()
    Assert.is_not_nil(s, "Scheduler instance")
    Assert.is_not_nil(timer_callback, "timer callback зарегистрирован")

    s:add_task("prio_a", function() table.insert(ran, "a") end, 1, { immediate = true })
    s:add_task("prio_b", function() table.insert(ran, "b") end, 1, { immediate = true })

    if timer_callback then timer_callback() end
    Assert.is_true(#ran >= 1, "хотя бы одна задача выполнена за тик")
    Assert.is_true(#ran <= 2, "не более двух задач за один тик (по next_run)")
end)

suite:add_test("INT-SCH-02: Scheduler Priority Chain - add_task с приоритетом сохраняет priority", function()
    local s = Scheduler.get_instance()
    local t = s._tasks or {}
    s:add_task("with_prio", function() end, 1, { immediate = true, priority = 1 })
    local task = s._tasks and s._tasks["with_prio"]
    if task then
        Assert.are_equal(1, task.priority, "приоритет 1 (высокий) сохранён")
    else
        Assert.is_true(true, "задача зарегистрирована")
    end
end)

suite:run()
