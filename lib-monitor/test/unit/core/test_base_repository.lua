-- L2: Unit-тесты для модуля core.base_repository
-- Моки: Logger, BaseMonitor, Scheduler, EventDispatcher.

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
local Mock = require("tools.test_moc")

local mock
local local_mock
local BaseRepository
local ref_ModuleManager
local add_task_called
local remove_task_called

local suite = TestSuite:new("L2.base_repository")

suite:setup(function()
    mock = Mock:new()
    add_task_called = {}
    remove_task_called = {}

    ref_ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return {
                    error = function() end,
                    info = function() end,
                    warning = function() end,
                    debug = function() end,
                }
            end
            if name == "core.base_monitor" then
                return {
                    STATE = { IDLE = 1, RUNNING = 2, STOPPED = 3 },
                }
            end
            if name == "core.scheduler" then
                return {
                    get_instance = function()
                        return {
                            add_task = function(_, task_id, cb, interval, opts)
                                add_task_called[#add_task_called + 1] = { task_id = task_id, cb = cb, interval = interval, opts = opts }
                            end,
                            remove_task = function(_, id)
                                remove_task_called[#remove_task_called + 1] = id
                            end,
                            set_task_interval = function() end,
                        }
                    end
                }
            end
            if name == "core.event_dispatcher" then
                return {
                    PRIORITIES = { HIGH = 1 },
                    get_instance = function()
                        return {
                            emit_safe = function() end,
                            subscribe = function(_, ev, cb) return "sub_" .. (ev or "") end,
                        }
                    end
                }
            end
            return nil
        end,
    }
    mock:mock_global("ModuleManager", ref_ModuleManager)
end)

suite:before_each(function()
    add_task_called = {}
    remove_task_called = {}
    package.loaded["src.core.base_repository"] = nil
    BaseRepository = require("src.core.base_repository")
end)

suite:after_each(function()
    if local_mock then
        local_mock:restore()
        local_mock = nil
    end
end)

suite:teardown(function()
    mock:restore()
end)

suite:add_test("new: создаёт репозиторий и запускает maintenance task", function()
    local repo = BaseRepository.new("TestRepo")
    Assert.is_not_nil(repo._state, "_state инициализирован")
    Assert.are_equal("TestRepo", repo._component_name, "component_name из аргумента")
    Assert.are_equal(0, repo:count(), "изначально count 0")
    Assert.are_equal(1, #add_task_called, "maintenance task добавлена")
    Assert.is_true(add_task_called[1].task_id:find("maintenance") ~= nil, "task_id содержит maintenance")
end)

suite:add_test("register и find: объект доступен по имени", function()
    local repo = BaseRepository.new("R")
    local fake_monitor = { destroy = function(_, force) return { name = "m1" } end }
    local ok = repo:register("m1", fake_monitor, {})
    Assert.is_true(ok, "register успешен")
    Assert.are_equal(1, repo:count(), "count 1 после регистрации")
    Assert.are_equal(fake_monitor, repo:find("m1"), "find возвращает зарегистрированный объект")
end)

suite:add_test("register: повторная регистрация того же имени false", function()
    local repo = BaseRepository.new("R")
    local m = { destroy = function() return {} end }
    repo:register("x", m, {})
    local ok2 = repo:register("x", m, {})
    Assert.is_false(ok2, "повторная регистрация того же имени — false")
end)

suite:add_test("unregister: вызывает destroy и удаляет объект", function()
    local repo = BaseRepository.new("R")
    local config = { name = "m1" }
    local fake_monitor = { destroy = function(_, force) return config end }
    repo:register("m1", fake_monitor, {})
    local ret = repo:unregister("m1", true)
    Assert.are_equal(config, ret, "unregister возвращает конфиг от destroy")
    Assert.are_equal(0, repo:count(), "после unregister count 0")
    Assert.is_nil(repo:find("m1"), "find не находит удалённый объект")
end)

suite:add_test("unregister: несуществующий объект возвращает nil", function()
    local repo = BaseRepository.new("R")
    Assert.is_nil(repo:unregister("nonexistent"), "несуществующий объект — nil")
end)

suite:add_test("get_all: возвращает таблицу мониторов", function()
    local repo = BaseRepository.new("R")
    local m = { destroy = function() return {} end }
    repo:register("a", m, {})
    local all = repo:get_all()
    Assert.are_equal(m, all.a, "get_all возвращает объект по имени")
end)

suite:add_test("shutdown: удаляет maintenance task и все объекты", function()
    local repo = BaseRepository.new("R")
    local m = { destroy = function() return {} end }
    repo:register("m1", m, {})
    repo:shutdown()
    Assert.are_equal(1, #remove_task_called, "shutdown снимает maintenance task")
    Assert.are_equal(0, repo:count(), "после shutdown пусто")
end)

suite:add_test("update_settings: применяет snake_case и PascalCase", function()
    local repo = BaseRepository.new("R")
    local ok = repo:update_settings({
        auto_recover_enabled = true,
        AutoRecoverInterval = 120,
        watchdog_enabled = true,
        WatchdogInterval = 10,
    })
    Assert.is_true(ok, "update_settings успешен")
    Assert.is_true(repo._state.settings.auto_recover.enabled, "auto_recover включён")
    Assert.are_equal(120, repo._state.settings.auto_recover.interval, "interval из PascalCase")
    Assert.are_equal(10, repo._state.settings.watchdog.interval, "watchdog interval")
end)

suite:add_test("update_settings: не таблица — false", function()
    local repo = BaseRepository.new("R")
    Assert.is_false(repo:update_settings(nil), "не таблица — false")
end)

suite:add_test("enable_watchdog / disable_watchdog: переключают флаг", function()
    local repo = BaseRepository.new("R")
    repo:enable_watchdog()
    Assert.is_true(repo._state.settings.watchdog.enabled, "watchdog включён")
    repo:disable_watchdog()
    Assert.is_false(repo._state.settings.watchdog.enabled, "watchdog выключен")
end)

suite:add_test("enable_auto_recovery / disable_auto_recovery: переключают флаг", function()
    local repo = BaseRepository.new("R")
    repo:enable_auto_recovery(60)
    Assert.is_true(repo._state.settings.auto_recover.enabled, "auto_recover включён")
    Assert.are_equal(60, repo._state.settings.auto_recover.interval, "interval 60")
    repo:disable_auto_recovery()
    Assert.is_false(repo._state.settings.auto_recover.enabled, "auto_recover выключен")
end)

suite:add_test("get_stats: возвращает active_count и компонент", function()
    local repo = BaseRepository.new("R")
    local m = { destroy = function() return {} end }
    repo:register("a", m, {})
    local stats = repo:get_stats()
    Assert.are_equal("R", stats.component, "component в get_stats")
    Assert.are_equal(1, stats.active_count, "active_count 1")
end)

suite:add_test("get_health_score: при 0 активных возвращает 100", function()
    local repo = BaseRepository.new("R")
    Assert.are_equal(100, repo:get_health_score(), "при 0 активных — 100")
end)

suite:add_test("get_health_score: учитывает RUNNING мониторы", function()
    local repo = BaseRepository.new("R")
    local BaseMonitor = ref_ModuleManager.get_module("core.base_monitor")
    local m = {
        destroy = function() return {} end,
        get_state = function() return BaseMonitor.STATE.RUNNING end,
    }
    repo:register("a", m, {})
    Assert.are_equal(100, repo:get_health_score(), "учёт RUNNING мониторов")
end)

suite:add_test("auto_recover: вызывает _maintenance_tick без падения", function()
    local repo = BaseRepository.new("R")
    local rec, fail = repo:auto_recover()
    Assert.are_equal(0, rec, "без тишины rec 0")
    Assert.are_equal(0, fail, "fail 0")
end)

-- _maintenance_tick: запуск через callback планировщика
suite:add_test("_maintenance_tick: вызывается из задачи планировщика", function()
    local repo = BaseRepository.new("R")
    Assert.are_equal(1, #add_task_called, "maintenance task зарегистрирована")
    add_task_called[1].cb()
end)

-- Восстановление по "тишине": auto_recover, get_software_status, _perform_recovery успех
suite:add_test("auto_recover: при тишине монитора вызывает _perform_recovery и успешно пересоздаёт", function()
    local BaseMonitor = ref_ModuleManager.get_module("core.base_monitor")
    local repo = BaseRepository.new("R")
    repo:update_settings({ auto_recover_enabled = true, auto_recover_interval = 1 })
    local config = { name = "m1" }
    local monitor = {
        destroy = function(_, force) return config end,
        get_software_status = function() return { state = BaseMonitor.STATE.RUNNING, last_update = 0 } end,
        get_config = function() return config end,
    }
    local class = {
        new = function(cfg) return { start = function() return true end } end,
    }
    repo:register("m1", monitor, class)
    local rec, fail = repo:auto_recover()
    Assert.are_equal(1, rec, "один восстановлен")
    Assert.are_equal(0, fail, "fail 0")
    Assert.are_equal(1, repo._state.stats.total_recovered, "total_recovered 1")
end)

-- _perform_recovery: лимит попыток превышен
suite:add_test("auto_recover: при превышении лимита попыток не пересоздаёт и логирует", function()
    local BaseMonitor = ref_ModuleManager.get_module("core.base_monitor")
    local repo = BaseRepository.new("R")
    repo:update_settings({ auto_recover_enabled = true, auto_recover_interval = 1, auto_recover_max_attempts = 1 })
    local config = { name = "m2" }
    local monitor = {
        destroy = function() return config end,
        get_software_status = function() return { state = BaseMonitor.STATE.RUNNING, last_update = 0 } end,
        get_config = function() return config end,
        pause = function() end,
    }
    local start_count = 0
    local class = {
        new = function() return { start = function() start_count = start_count + 1; return false end } end
    }
    repo:register("m2", monitor, class)
    repo:auto_recover()
    repo:auto_recover()
    Assert.are_equal(1, repo._state.stats.limit_reached, "limit_reached после превышения попыток")
end)

-- recover_monitor: вызов вручную
suite:add_test("recover_monitor: ручной вызов выполняет _perform_recovery", function()
    local BaseMonitor = ref_ModuleManager.get_module("core.base_monitor")
    local repo = BaseRepository.new("R")
    local config = { name = "m3" }
    local monitor = {
        destroy = function() return config end,
        get_software_status = function() return { state = BaseMonitor.STATE.RUNNING } end,
        get_config = function() return config end,
    }
    local class = { new = function() return { start = function() return true end } end }
    repo:register("m3", monitor, class)
    local ok = repo:recover_monitor("m3", "manual")
    Assert.is_true(ok, "recover_monitor ручной вызов успешен")
end)

-- recover_monitor: объект не найден
suite:add_test("recover_monitor: при отсутствии монитора возвращает false", function()
    local repo = BaseRepository.new("R")
    local ok = repo:recover_monitor("nonexistent", "manual")
    Assert.is_false(ok, "при отсутствии монитора — false")
end)

-- _perform_recovery: _on_before_recreate возвращает false
suite:add_test("auto_recover: при _on_before_recreate false восстановление прерывается", function()
    local BaseMonitor = ref_ModuleManager.get_module("core.base_monitor")
    local repo = BaseRepository.new("R")
    repo:update_settings({ auto_recover_enabled = true, auto_recover_interval = 1 })
    local monitor = {
        destroy = function() return { name = "m4" } end,
        get_software_status = function() return { state = BaseMonitor.STATE.RUNNING, last_update = 0 } end,
        get_config = function() return { name = "m4" } end,
    }
    local class = { new = function() return { start = function() return true end } end }
    repo:register("m4", monitor, class)
    repo._on_before_recreate = function() return false end
    local rec, fail = repo:auto_recover()
    Assert.are_equal(0, rec, "при _on_before_recreate false rec 0")
    Assert.are_equal(1, fail, "fail 1")
end)

-- _perform_recovery: отсутствует get_config или class.new
suite:add_test("auto_recover: при отсутствии конфига или class.new увеличивает total_failed", function()
    local BaseMonitor = ref_ModuleManager.get_module("core.base_monitor")
    local repo = BaseRepository.new("R")
    repo:update_settings({ auto_recover_enabled = true, auto_recover_interval = 1 })
    local monitor = {
        destroy = function() return { name = "m5" } end,
        get_software_status = function() return { state = BaseMonitor.STATE.RUNNING, last_update = 0 } end,
        get_config = function() return nil end,
    }
    local class = { new = function() return { start = function() return true end } end }
    repo:register("m5", monitor, class)
    local rec, fail = repo:auto_recover()
    Assert.are_equal(0, rec, "при отсутствии конфига rec 0")
    Assert.are_equal(1, fail, "fail 1")
    Assert.are_equal(1, repo._state.stats.total_failed, "total_failed увеличен")
end)

-- _maintenance_tick: watchdog path (check_infrastructure_health false)
suite:add_test("auto_recover: при watchdog и check_infrastructure_health false запускает восстановление", function()
    local BaseMonitor = ref_ModuleManager.get_module("core.base_monitor")
    local repo = BaseRepository.new("R")
    repo:update_settings({ watchdog_enabled = true, auto_recover_interval = 999 })
    local config = { name = "m6" }
    local monitor = {
        destroy = function() return config end,
        get_software_status = function() return { state = BaseMonitor.STATE.RUNNING, last_update = os.time() } end,
        get_config = function() return config end,
        check_infrastructure_health = function() return false end,
    }
    local class = { new = function() return { start = function() return true end } end }
    repo:register("m6", monitor, class)
    local rec, fail = repo:auto_recover()
    Assert.are_equal(1, rec, "watchdog запускает восстановление")
    Assert.are_equal(0, fail, "fail 0")
end)

-- _maintenance_tick: cooldown сброс attempts при стабильной работе
suite:add_test("auto_recover: при cooldown сбрасывает attempts после стабильной работы", function()
    local BaseMonitor = ref_ModuleManager.get_module("core.base_monitor")
    local repo = BaseRepository.new("R")
    repo:update_settings({ auto_recover_enabled = true, auto_recover_interval = 1, auto_recover_cooldown = 1 })
    local config = { name = "m7" }
    local monitor = {
        destroy = function() return config end,
        get_software_status = function() return { state = BaseMonitor.STATE.RUNNING, last_update = os.time() } end,
        get_config = function() return config end,
    }
    local class = { new = function() return { start = function() return true end } end }
    repo:register("m7", monitor, class)
    repo:auto_recover()
    repo._state.recovery.last_success["m7"] = os.time() - 2
    repo._state.recovery.attempts["m7"] = 1
    repo:auto_recover()
    Assert.is_nil(repo._state.recovery.attempts["m7"], "после cooldown attempts сброшены")
end)

-- unregister: destroy возвращает nil — логирование ошибки
suite:add_test("unregister: при destroy возвращающем nil логирует ошибку", function()
    local repo = BaseRepository.new("R")
    local bad_monitor = { destroy = function() return nil end }
    repo:register("bad", bad_monitor, {})
    local ret = repo:unregister("bad", true)
    Assert.is_nil(ret, "при destroy возвращающем nil — nil")
end)

-- _emit_event: при отсутствии dispatcher возврат без ошибки
suite:add_test("_emit_event: при get_instance nil не падает", function()
    local BaseMonitor = ref_ModuleManager.get_module("core.base_monitor")
    local_mock = Mock:new()
    local mod_mm = {
        get_module = function(name)
            if name == "core.event_dispatcher" then
                return {
                    PRIORITIES = { HIGH = 1 },
                    get_instance = function() return nil end,
                }
            end
            return ref_ModuleManager.get_module(name)
        end,
        get_global_dependency = ref_ModuleManager.get_global_dependency,
    }
    local_mock:mock_global("ModuleManager", mod_mm)
    package.loaded["src.core.base_repository"] = nil
    BaseRepository = require("src.core.base_repository")
    local repo = BaseRepository.new("R")
    repo:update_settings({ auto_recover_enabled = true, auto_recover_interval = 1 })
    local config = { name = "m_emit" }
    local monitor = {
        destroy = function(_, force) return config end,
        get_software_status = function() return { state = BaseMonitor.STATE.RUNNING, last_update = 0 } end,
        get_config = function() return config end,
    }
    local class = { new = function() return { start = function() return true end } end }
    repo:register("m_emit", monitor, class)
    local rec, fail = repo:auto_recover()
    Assert.are_equal(1, rec, "восстановление выполнено даже без dispatcher")
    Assert.are_equal(0, fail, "fail 0")
end)

-- init_base_config_subscription (экземплярный метод)
suite:add_test("init_base_config_subscription: подписывается на config:updated:recovery и watchdog", function()
    local subscribe_events = {}
    local_mock = Mock:new()
    local mod_mm = {
        get_module = function(name)
            if name == "core.event_dispatcher" then
                return {
                    PRIORITIES = { HIGH = 1 },
                    get_instance = function()
                        return {
                            subscribe = function(_, ev) subscribe_events[ev] = true end,
                            emit_safe = function() end,
                        }
                    end
                }
            end
            return ref_ModuleManager.get_module(name)
        end,
        get_global_dependency = ref_ModuleManager.get_global_dependency,
    }
    local_mock:mock_global("ModuleManager", mod_mm)
    package.loaded["src.core.base_repository"] = nil
    BaseRepository = require("src.core.base_repository")
    local repo = BaseRepository.new("R")
    repo:init_base_config_subscription()
    Assert.are_equal(true, subscribe_events["config:updated:recovery"], "должна быть подписка на config:updated:recovery")
    Assert.are_equal(true, subscribe_events["config:updated:watchdog"], "должна быть подписка на config:updated:watchdog")
end)

-- Коллбэки config:updated:recovery и config:updated:watchdog вызывают update_settings
suite:add_test("init_base_config_subscription: коллбэки recovery и watchdog обновляют настройки", function()
    local subscribe_cbs = {}
    local_mock = Mock:new()
    local mod_mm = {
        get_module = function(name)
            if name == "core.event_dispatcher" then
                return {
                    PRIORITIES = { HIGH = 1 },
                    get_instance = function()
                        return {
                            subscribe = function(_, ev, cb) subscribe_cbs[ev] = cb end,
                            emit_safe = function() end,
                        }
                    end
                }
            end
            return ref_ModuleManager.get_module(name)
        end,
        get_global_dependency = ref_ModuleManager.get_global_dependency,
    }
    local_mock:mock_global("ModuleManager", mod_mm)
    package.loaded["src.core.base_repository"] = nil
    BaseRepository = require("src.core.base_repository")
    local repo = BaseRepository.new("R")
    repo:init_base_config_subscription()
    Assert.is_not_nil(subscribe_cbs["config:updated:recovery"], "коллбэк recovery сохранён")
    Assert.is_not_nil(subscribe_cbs["config:updated:watchdog"], "коллбэк watchdog сохранён")
    subscribe_cbs["config:updated:recovery"]({ auto_recover_enabled = true, auto_recover_interval = 100 })
    Assert.is_true(repo._state.settings.auto_recover.enabled, "recovery.enabled обновлён через коллбэк")
    Assert.are_equal(100, repo._state.settings.auto_recover.interval, "recovery.interval обновлён")
    subscribe_cbs["config:updated:watchdog"]({ watchdog_enabled = true, watchdog_interval = 10 })
    Assert.is_true(repo._state.settings.watchdog.enabled, "watchdog.enabled обновлён через коллбэк")
    Assert.are_equal(10, repo._state.settings.watchdog.interval, "watchdog.interval обновлён")
end)

suite:run()
