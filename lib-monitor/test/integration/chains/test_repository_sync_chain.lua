-- INT: Repository Sync Chain (ПМИ 1.2 п.10)
-- Repositories <-> Monitors: синхронизация состояний через register/unregister.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local BaseRepository

local suite = TestSuite:new("INT.chains.repository_sync")

suite:setup(function()
    local mock_scheduler = { add_task = function() end, remove_task = function() end }
    _G.ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return { error = function() end, info = function() end, warning = function() end, debug = function() end }
            end
            if name == "core.scheduler" then return { get_instance = function() return mock_scheduler end } end
            if name == "core.base_monitor" then return { STATE = { IDLE = 1, RUNNING = 2, STOPPED = 3 } } end
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

suite:add_test("INT-REP-01: Repository Sync - register и unregister синхронизируют состояние", function()
    local repo = BaseRepository.new("SyncTest")
    local mock_monitor = {
        destroy = function() return {} end,
        get_software_status = function() return { state = 2, last_update = os.time() } end,
    }
    local ok = repo:register("mon1", mock_monitor)
    Assert.is_true(ok, "register успешен")
    Assert.is_not_nil(repo:find("mon1"), "find возвращает объект")
    local config = repo:unregister("mon1")
    Assert.is_not_nil(config, "unregister возвращает конфиг")
    Assert.is_nil(repo:find("mon1"), "find nil после unregister")
end)

suite:run()
