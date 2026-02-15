-- INT: State Chain (ПМИ 1.2 п.2)
-- Scheduler ↔ BaseRepository ↔ Monitor: корректность переходов состояний и очистка ресурсов.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local BaseRepository
local add_task_ids
local remove_task_ids

local suite = TestSuite:new("INT.chains.state")

suite:setup(function()
    add_task_ids = {}
    remove_task_ids = {}
    local mock_scheduler = {
        add_task = function(_, id)
            add_task_ids[id] = (add_task_ids[id] or 0) + 1
        end,
        remove_task = function(_, id)
            remove_task_ids[id] = (remove_task_ids[id] or 0) + 1
        end,
    }
    _G.ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return {
                    error = function() end,
                    info = function() end,
                    warning = function() end,
                    debug = function() end,
                }
            end
            if name == "core.scheduler" then
                return { get_instance = function() return mock_scheduler end }
            end
            if name == "core.base_monitor" then
                return {
                    STATE = { IDLE = 1, RUNNING = 2, STOPPED = 3 },
                }
            end
            if name == "core.event_dispatcher" then
                return { get_instance = function() return { subscribe = function() return "id" end, emit_safe = function() end } end }
            end
            return nil
        end,
        get_global_dependency = function() return nil end,
    }
    BaseRepository = require("src.core.base_repository")
end)

suite:teardown(function()
    package.loaded["src.core.base_repository"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-STA-01: State Chain — BaseRepository добавляет задачу в Scheduler", function()
    local repo = BaseRepository.new("StateChainTest")
    Assert.is_not_nil(repo, "BaseRepository.new")
    local task_id = "maintenance_StateChainTest"
    Assert.is_true(add_task_ids[task_id] == 1, "Scheduler.add_task вызван с maintenance_StateChainTest")
end)

suite:add_test("INT-STA-02: State Chain — shutdown удаляет задачу и очищает ресурсы", function()
    local repo = BaseRepository.new("StateChainTest")
    local task_id = "maintenance_StateChainTest"
    Assert.is_true((add_task_ids[task_id] or 0) >= 1, "задача добавлена")
    repo:shutdown()
    Assert.is_true((remove_task_ids[task_id] or 0) >= 1, "Scheduler.remove_task вызван при shutdown")
end)

suite:run()
