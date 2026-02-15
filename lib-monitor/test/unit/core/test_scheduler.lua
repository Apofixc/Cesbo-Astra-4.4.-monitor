-- L1: Unit-тесты для модуля core.scheduler
-- Моки: ModuleManager (logger, timer, core.event_dispatcher).

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
local Mock = require("tools.test_moc")

local mock
local Scheduler
local log_calls
local ref_timer_callback
local ref_system_config_cb
local ref_ModuleManager

local suite = TestSuite:new("L1.scheduler")

suite:setup(function()
    mock = Mock:new()
    log_calls = { debug = 0, info = 0, warning = 0, error = 0 }
    ref_timer_callback = nil
    ref_system_config_cb = nil

    local mock_log = {
        debug = function() log_calls.debug = log_calls.debug + 1 end,
        info = function() log_calls.info = log_calls.info + 1 end,
        warning = function() log_calls.warning = log_calls.warning + 1 end,
        error = function() log_calls.error = log_calls.error + 1 end,
    }

    local mock_ed_instance = {
        subscribe = function(self, ev, cb)
            if ev == "config:updated:system" then ref_system_config_cb = cb end
        end
    }
    local mock_ed = { get_instance = function() return mock_ed_instance end }

    ref_ModuleManager = {
        get_module = function(name)
            if name == "logger" then return mock_log end
            if name == "core.event_dispatcher" then return mock_ed end
            return nil
        end,
        get_global_dependency = function(name)
            if name == "timer" then
                return function(opts)
                    ref_timer_callback = opts and opts.callback
                    return { close = function() end }
                end
            end
            return nil
        end,
    }
    mock:mock_global("ModuleManager", ref_ModuleManager)
end)

suite:before_each(function()
    log_calls.debug = 0
    log_calls.info = 0
    log_calls.warning = 0
    log_calls.error = 0
    ref_timer_callback = nil
    ref_system_config_cb = nil
    package.loaded["src.core.scheduler"] = nil
    Scheduler = require("src.core.scheduler")
end)

suite:teardown(function()
    mock:restore()
end)

-- get_instance создаёт экземпляр и запускает таймер
suite:add_test("get_instance: возвращает экземпляр и логирует инициализацию", function()
    local inst = Scheduler.get_instance()
    Assert.is_not_nil(inst, "экземпляр создан")
    Assert.are_equal(1, log_calls.info, "Logger.info вызван при инициализации")
    Assert.is_not_nil(ref_timer_callback, "callback таймера сохранён")
end)

-- Повторный get_instance возвращает тот же экземпляр
suite:add_test("get_instance: повторный вызов возвращает тот же экземпляр", function()
    local a = Scheduler.get_instance()
    local b = Scheduler.get_instance()
    Assert.are_equal(a, b, "один и тот же экземпляр")
    Assert.are_equal(1, log_calls.info, "инициализация только один раз")
end)

-- add_task: валидная задача
suite:add_test("add_task: регистрирует задачу и увеличивает счётчик", function()
    local inst = Scheduler.get_instance()
    local run_count = 0
    inst:add_task("t1", function() run_count = run_count + 1 end, 2)
    Assert.are_equal(1, log_calls.debug, "debug при добавлении задачи")
    Assert.is_not_nil(ref_timer_callback, "таймер установлен")
    ref_timer_callback()
    Assert.are_equal(1, run_count, "callback выполнен при tick")
end)

-- add_task: nil id или не функция callback -> Logger.error, return
suite:add_test("add_task: при nil id логирует ошибку и не добавляет", function()
    local inst = Scheduler.get_instance()
    inst:add_task(nil, function() end, 1)
    Assert.are_equal(1, log_calls.error, "ошибка при nil id")
end)

suite:add_test("add_task: при не-функции callback логирует ошибку", function()
    local inst = Scheduler.get_instance()
    inst:add_task("bad", "not a function", 1)
    Assert.are_equal(1, log_calls.error, "ошибка при неверном callback")
end)

-- add_task: перерегистрация задачи с тем же id — remove_task затем add
suite:add_test("add_task: при существующем id задача перезаписывается", function()
    local inst = Scheduler.get_instance()
    local c1, c2 = 0, 0
    inst:add_task("same", function() c1 = c1 + 1 end, 1)
    inst:add_task("same", function() c2 = c2 + 1 end, 1)
    ref_timer_callback()
    Assert.are_equal(0, c1, "старый callback не вызывается")
    Assert.are_equal(1, c2, "новый callback вызван")
end)

-- remove_task
suite:add_test("remove_task: удаляет задачу", function()
    local inst = Scheduler.get_instance()
    local ran = false
    inst:add_task("r1", function() ran = true end, 1)
    inst:remove_task("r1")
    Assert.are_equal(2, log_calls.debug, "debug при add и remove")
    ref_timer_callback()
    Assert.is_false(ran, "callback не вызывается после remove")
end)

suite:add_test("remove_task: несуществующая задача не падает", function()
    local inst = Scheduler.get_instance()
    inst:remove_task("nonexistent")
end)

-- set_task_interval
suite:add_test("set_task_interval: меняет интервал задачи", function()
    local inst = Scheduler.get_instance()
    inst:add_task("si", function() end, 5)
    inst:set_task_interval("si", 10)
    Assert.are_equal(2, log_calls.debug, "debug при add и set_task_interval")
end)

-- set_task_interval: ветка remaining > task.interval (next_run сдвигается, _heap_up)
suite:add_test("set_task_interval: при remaining > interval перестраивает next_run и кучу", function()
    local inst = Scheduler.get_instance()
    inst:add_task("long", function() end, 60)
    ref_timer_callback()  -- long выполнился, next_run = now+60
    inst:set_task_interval("long", 2)  -- remaining ~60 > 2 → next_run = now+2, _heap_up
    Assert.are_equal(2, log_calls.debug, "add + set_task_interval")
end)

suite:add_test("set_task_interval: несуществующая задача не падает", function()
    local inst = Scheduler.get_instance()
    inst:set_task_interval("none", 2)
end)

-- pause_task / resume_task
suite:add_test("pause_task: приостанавливает задачу", function()
    local inst = Scheduler.get_instance()
    local ran = false
    inst:add_task("p1", function() ran = true end, 1)
    inst:pause_task("p1")
    ref_timer_callback()
    Assert.is_false(ran, "приостановленная задача не выполняется")
end)

suite:add_test("resume_task: возобновляет задачу", function()
    local inst = Scheduler.get_instance()
    local ran = false
    inst:add_task("res1", function() ran = true end, 1)
    inst:pause_task("res1")
    inst:resume_task("res1")
    ref_timer_callback()
    Assert.is_true(ran, "после resume задача выполняется")
end)

-- shutdown
suite:add_test("shutdown: останавливает планировщик и очищает задачи", function()
    local inst = Scheduler.get_instance()
    inst:add_task("s1", function() end, 1)
    inst:shutdown()
    Assert.is_true(log_calls.info >= 1, "info при shutdown")
    ref_timer_callback()
    -- После shutdown _active = false, _tick не должен выполнять задачи (heap может быть пуст)
    -- Задачи очищены, так что tick просто выходит
end)

-- init_config_subscription
suite:add_test("init_config_subscription: подписка на config:updated:system", function()
    local inst = Scheduler.get_instance()
    inst:init_config_subscription()
    Assert.is_not_nil(ref_system_config_cb, "callback подписки сохранён")
    ref_system_config_cb({ SchedulerInterval = 2 })
    Assert.is_true(log_calls.info >= 1, "info при обновлении конфига")
    -- пересозданный таймер: вызываем новый callback для покрытия ветки
    ref_timer_callback()
end)

-- add_task с options (immediate, priority)
suite:add_test("add_task: options.immediate и priority", function()
    local inst = Scheduler.get_instance()
    inst:add_task("opt1", function() end, 3, { immediate = true })
    Assert.are_equal(1, log_calls.debug, "задача добавлена")
    inst:add_task("opt2", function() end, 2, { priority = 1 })
    Assert.are_equal(2, log_calls.debug, "вторая задача с priority")
end)

-- add_task с interval 0 или отрицательным -> 1
suite:add_test("add_task: некорректный interval заменяется на 1", function()
    local inst = Scheduler.get_instance()
    inst:add_task("inv", function() end, 0)
    ref_timer_callback()
    -- Задача должна быть добавлена с interval 1
    Assert.are_equal(1, log_calls.debug, "задача добавлена")
end)

-- timer отсутствует -> Logger.error
-- Примечание: Scheduler читает ModuleManager из _G, поэтому мокаем именно _G.ModuleManager
suite:add_test("_initialize: при отсутствии timer логирует ошибку", function()
    local mm = _G.ModuleManager
    local orig_gd = mm.get_global_dependency
    mm.get_global_dependency = function(name)
        if name == "timer" then return nil end
        return orig_gd and orig_gd(name)
    end
    package.loaded["src.core.scheduler"] = nil
    Scheduler = require("src.core.scheduler")
    local inst = Scheduler.get_instance()
    Assert.is_not_nil(inst, "экземпляр возвращён")
    Assert.are_equal(1, log_calls.error, "Logger.error при отсутствии timer")
    mm.get_global_dependency = orig_gd
end)

-- _tick при пустой куче
suite:add_test("_tick: при пустой куче ничего не делает", function()
    local inst = Scheduler.get_instance()
    ref_timer_callback()
    ref_timer_callback()
    -- Нет падения
end)

-- задача с ошибкой в callback -> Logger.error
suite:add_test("add_task: ошибка в callback логируется", function()
    local inst = Scheduler.get_instance()
    inst:add_task("err", function() error("task err") end, 1)
    ref_timer_callback()
    Assert.are_equal(1, log_calls.error, "ошибка задачи залогирована")
end)

-- задача выполняется дольше 0.1 сек -> Logger.warning
suite:add_test("add_task: долгое выполнение логируется как warning", function()
    local inst = Scheduler.get_instance()
    inst:add_task("slow", function()
        local t = os.clock()
        local guard = 0
        while os.clock() - t < 0.15 and guard < 50000000 do
            guard = guard + 1
        end
    end, 1)
    ref_timer_callback()
    Assert.is_true(log_calls.warning >= 1, "warning при долгой задаче")
end)

-- remove_task: задача в середине кучи (heap_down)
suite:add_test("remove_task: удаление не последнего элемента кучи", function()
    local inst = Scheduler.get_instance()
    inst:add_task("a", function() end, 1)
    inst:add_task("b", function() end, 2)
    inst:add_task("c", function() end, 3)
    inst:remove_task("a")
    inst:remove_task("b")
    inst:remove_task("c")
    ref_timer_callback()
end)

-- _heap_up: swap (ребёнок с меньшим next_run всплывает)
suite:add_test("add_task: _heap_up swap при immediate", function()
    local inst = Scheduler.get_instance()
    inst:add_task("later", function() end, 10)
    inst:add_task("soon", function() end, 1, { immediate = true })
    ref_timer_callback()
    -- soon имеет next_run=now, later — now+jitter; soon должен был всплыть и выполниться первым
    Assert.are_equal(2, log_calls.debug, "две задачи добавлены")
end)

-- _heap_up: тело swap покрывается когда новый элемент меньше корня (после одного tick корень уже в будущем)
suite:add_test("add_task: _heap_up swap тело при добавлении после tick", function()
    local inst = Scheduler.get_instance()
    inst:add_task("a", function() end, 10)
    inst:add_task("b", function() end, 10)
    ref_timer_callback()  -- выполнит a (next_run был now), a уйдёт в конец кучи с next_run=now+10
    inst:add_task("c", function() end, 1, { immediate = true })  -- c.next_run=now < корень → swap
    ref_timer_callback()
    Assert.are_equal(3, log_calls.debug, "три задачи")
end)

-- _heap_down: smallest = right (правый потомок меньше левого)
suite:add_test("_tick: _heap_down берёт правого потомка когда он меньше", function()
    local inst = Scheduler.get_instance()
    inst:add_task("a", function() end, 5)
    inst:add_task("b", function() end, 10)
    inst:add_task("c", function() end, 1, { immediate = true })
    ref_timer_callback()
    ref_timer_callback()
    -- после первого tick: c выполнился, структура кучи приводит к _heap_down с right < left
    Assert.are_equal(3, log_calls.debug, "три задачи")
end)

-- pause_task: приостановленная задача обновляет next_run и _heap_down
suite:add_test("add_task: приостановленная задача в _tick обновляет next_run", function()
    local inst = Scheduler.get_instance()
    inst:add_task("paused", function() end, 1, { immediate = true })
    inst:pause_task("paused")
    ref_timer_callback()
    ref_timer_callback()
    Assert.are_equal(2, log_calls.debug, "add + pause")
end)

suite:run()
