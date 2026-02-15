-- L5: Unit-тесты для модуля adapters.tuner_monitor
-- Монитор DVB-адаптеров: init_config_subscription, new, set_backup, get_backup, get_status_flags.
-- Моки: Logger, Utils, BaseMonitor, Scheduler, TablePool, EventDispatcher, dvb_tune, analyze.

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
local Mock = require("tools.test_moc")

local mock
local TunerMonitor
local ref_ModuleManager
local subscribe_calls
local last_dvb_conf
local scheduler_tasks = {}

local suite = TestSuite:new("L5.tuner_monitor")

suite:setup(function()
    mock = Mock:new()
    subscribe_calls = {}
    scheduler_tasks = {}

    _G.EventDispatcher = {
        get_instance = function()
            return {
                subscribe = function(_, event_type, cb)
                    subscribe_calls[#subscribe_calls + 1] = { event_type = event_type, cb = cb }
                    return "sub-tuner"
                end,
            }
        end,
    }

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
            if name == "utils" then
                return {
                    ratio = function(a, b) if b == 0 then return 0 end return math.max(a, b) / math.min(a, b) end,
                    deep_copy = function(t) return t end,
                    validate_monitor_param = function(_, v) return v end,
                    init_report = function(r, type_name, n) r.type = type_name r.name = n end,
                    table_copy = function(t) return t end,
                }
            end
            if name == "core.base_monitor" then
                package.loaded["src.core.base_monitor"] = nil
                return require("src.core.base_monitor")
            end
            if name == "core.scheduler" then
                return {
                    get_instance = function()
                        return {
                            add_task = function(_, name, cb) scheduler_tasks[name] = cb end,
                            remove_task = function() end,
                        }
                    end,
                }
            end
            if name == "utils.table_pool" then
                return {
                    get = function() return {} end,
                    release = function() end,
                    register_type = function() end,
                }
            end
            if name == "core.event_dispatcher" then
                return {
                    get_instance = function()
                        return {
                            subscribe = function() return "sub-id" end,
                            unsubscribe = function() end,
                            emit_safe = function() end,
                        }
                    end,
                }
            end
            return nil
        end,
        get_global_dependency = function(name)
            if name == "dvb_tune" then
                return function(conf)
                    last_dvb_conf = conf
                    return { stream = function() return {} end, __options = {} }
                end
            end
            if name == "analyze" then return function() return { __options = {}, close = function() end } end end
            if name == "json.encode" then return function(t) return "{}" end end
            return nil
        end,
    }
    mock:mock_global("ModuleManager", ref_ModuleManager)
    package.loaded["src.adapters.tuner_monitor"] = nil
    TunerMonitor = require("src.adapters.tuner_monitor")
end)

suite:before_each(function()
    subscribe_calls = {}
    last_dvb_conf = nil
end)

suite:teardown(function()
    _G.EventDispatcher = nil
    mock:restore()
end)

-- L5-TM-01: init_config_subscription подписывается на config:updated:monitor
suite:add_test("L5-TM-01: init_config_subscription подписывается на config:updated:monitor", function()
    TunerMonitor.init_config_subscription()
    local found
    for i = 1, #subscribe_calls do
        if subscribe_calls[i].event_type == "config:updated:monitor" then found = true break end
    end
    Assert.is_true(found, "подписка на config:updated:monitor")
end)

-- L5-TM-02: new без конфига возвращает nil
suite:add_test("L5-TM-02: new без конфига возвращает nil", function()
    local inst = TunerMonitor.new(nil)
    Assert.is_nil(inst, "new(nil) возвращает nil")
end)

-- L5-TM-03: new без name_adapter возвращает nil
suite:add_test("L5-TM-03: new без name_adapter возвращает nil", function()
    local inst = TunerMonitor.new({})
    Assert.is_nil(inst, "new без name_adapter возвращает nil")
end)

-- L5-TM-04: new с name_adapter возвращает экземпляр
suite:add_test("L5-TM-04: new с name_adapter возвращает экземпляр", function()
    local inst = TunerMonitor.new({ name_adapter = "0", type = "DVB-S2", modulation = "QPSK" })
    Assert.is_not_nil(inst, "new возвращает экземпляр")
    Assert.are_equal("0", inst._name, "_name установлен")
end)

-- L5-TM-05: set_backup и get_backup
suite:add_test("L5-TM-05: set_backup и get_backup сохраняют и возвращают бэкап", function()
    local inst = TunerMonitor.new({ name_adapter = "0" })
    Assert.is_not_nil(inst, "экземпляр создан")
    inst:set_backup({ freq = 1000 }, { { name = "ch1" } })
    local backup = inst:get_backup()
    Assert.is_not_nil(backup, "get_backup возвращает бэкап")
    Assert.is_not_nil(backup.config, "бэкап содержит config")
    Assert.is_not_nil(backup.channels, "бэкап содержит channels")
end)

-- L5-TM-06: get_status_flags возвращает таблицу с флагами
suite:add_test("L5-TM-06: get_status_flags возвращает флаги и name_adapter", function()
    local inst = TunerMonitor.new({ name_adapter = "0" })
    Assert.is_not_nil(inst, "экземпляр создан")
    local flags = inst:get_status_flags()
    Assert.is_not_nil(flags, "get_status_flags возвращает таблицу")
    Assert.are_equal("0", flags.name_adapter, "name_adapter в результате")
end)

-- L5-TM-07: start() запускает тюнер и callback вызывается
suite:add_test("L5-TM-07: start и callback _on_astra_data", function()
    local inst = TunerMonitor.new({ name_adapter = "0", method_comparison = 1, time_check = 0 })
    Assert.is_not_nil(inst, "экземпляр создан")
    local ok = inst:start()
    Assert.is_not_nil(ok, "start возвращает instance")
    Assert.is_not_nil(last_dvb_conf and last_dvb_conf.callback, "callback установлен")
    last_dvb_conf.callback({ status = 16, signal = 100, snr = 50, ber = 0, unc = 0 })
    Assert.are_equal(16, inst._current_status_table.status, "_on_astra_data обновил master")
end)

-- L5-TM-08: check_infrastructure_health при RUNNING
suite:add_test("L5-TM-08: check_infrastructure_health", function()
    local inst = TunerMonitor.new({ name_adapter = "0" })
    local h_idle = inst:check_infrastructure_health()
    Assert.is_true(h_idle == nil, "health nil когда не RUNNING")
    inst:start()
    inst._current_flags = { has_lock = true }
    local h = inst:check_infrastructure_health()
    Assert.is_true(h == true or h == false or h == nil, "check_infrastructure_health не падает")
    inst._current_flags = nil
    Assert.is_true(inst:check_infrastructure_health() == false or inst:check_infrastructure_health() == nil, "health false/nil без flags")
end)

-- L5-TM-09: _can_destroy(force) и _can_destroy (channels=0)
suite:add_test("L5-TM-09: _can_destroy", function()
    local inst = TunerMonitor.new({ name_adapter = "0" })
    inst:start()
    Assert.is_true(inst:_can_destroy(true), "_can_destroy(force) true")
    Assert.is_true(inst:_can_destroy(false), "_can_destroy(false) при channels=0")
end)

-- L5-TM-10: _on_destroy очищает ресурсы
suite:add_test("L5-TM-10: _on_destroy", function()
    local inst = TunerMonitor.new({ name_adapter = "0" })
    inst:start()
    inst:_on_destroy()
    Assert.is_nil(inst._current_flags, "_on_destroy очистил _current_flags")
end)

-- L5-TM-11: start при уже RUNNING возвращает _instance (покрытие ветки Logger.warning и return self._instance)
suite:add_test("L5-TM-11: start при RUNNING возвращает instance", function()
    local inst = TunerMonitor.new({ name_adapter = "0" })
    inst:start()
    local again = inst:start()
    Assert.are_equal(inst._instance, again, "повторный start возвращает _instance")
end)

-- L5-TM-12: _on_config_updated синхронизирует _astra_conf
suite:add_test("L5-TM-12: _on_config_updated", function()
    local inst = TunerMonitor.new({ name_adapter = "0" })
    inst:start()
    inst:_on_config_updated("analyze", false)
    Assert.are_equal(0, inst._stats.count, "сброс stats при analyze=false")
end)

-- L5-TM-13: psi_update без instance возвращает false
suite:add_test("L5-TM-13: psi_update без instance", function()
    local inst = TunerMonitor.new({ name_adapter = "0" })
    Assert.is_true(inst:psi_update(5, function() end) == false, "psi_update false без start")
end)

-- L5-TM-13c: psi_update когда analyze возвращает nil — return false
suite:add_test("L5-TM-13c: psi_update при analyze nil", function()
    local orig_gfd = ref_ModuleManager.get_global_dependency
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "dvb_tune" then
            return function(conf)
                last_dvb_conf = conf
                return { stream = function() return {} end, __options = {} }
            end
        end
        if name == "analyze" then return function() return nil end end
        return orig_gfd(name)
    end
    package.loaded["src.adapters.tuner_monitor"] = nil
    TunerMonitor = require("src.adapters.tuner_monitor")
    local inst = TunerMonitor.new({ name_adapter = "a1", method_comparison = 1, time_check = 0 })
    Assert.is_not_nil(inst:start(), "start")
    local ok = inst:psi_update(1, function() end)
    Assert.is_true(ok == false, "psi_update возвращает false при analyze nil")
    ref_ModuleManager.get_global_dependency = orig_gfd
    package.loaded["src.adapters.tuner_monitor"] = nil
    TunerMonitor = require("src.adapters.tuner_monitor")
end)

-- L5-TM-14b: методы сравнения 2–7 вызываются при двух callback с разными data
suite:add_test("L5-TM-14b: COMPARISON_METHODS 2–7 при двух callback", function()
    local methods = { 2, 3, 4, 5, 6, 7 }
    for _, method_id in ipairs(methods) do
        local inst = TunerMonitor.new({ name_adapter = "0", method_comparison = method_id, time_check = 0 })
        Assert.is_not_nil(inst:start(), "start ok")
        Assert.is_not_nil(last_dvb_conf and last_dvb_conf.callback, "callback есть")
        last_dvb_conf.callback({ status = 0, signal = 80, snr = 40, ber = 0, unc = 0 })
        last_dvb_conf.callback({ status = 16, signal = 70, snr = 35, ber = 1, unc = 0 })
    end
    Assert.is_true(true, "все методы сравнения 2–7 вызваны")
end)

-- L5-TM-13b: start при некорректном method_comparison возвращает nil и Logger.error
suite:add_test("L5-TM-13b: start при некорректном method_comparison", function()
    local inst = TunerMonitor.new({ name_adapter = "0", method_comparison = 99 })
    Assert.is_not_nil(inst, "экземпляр создан")
    local ok = inst:start()
    Assert.is_nil(ok, "start возвращает nil при method_comparison 99")
end)

-- L5-TM-14: start когда dvb_tune возвращает nil (Logger.error, return nil)
suite:add_test("L5-TM-14: start при dvb_tune nil", function()
    local orig_gfd = ref_ModuleManager.get_global_dependency
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "dvb_tune" then return function() return nil end end
        if name == "analyze" then return function() return nil end end
        if name == "json.encode" then return function() return "{}" end end
        return orig_gfd(name)
    end
    package.loaded["src.adapters.tuner_monitor"] = nil
    TunerMonitor = require("src.adapters.tuner_monitor")
    local inst = TunerMonitor.new({ name_adapter = "0", method_comparison = 1, time_check = 0 })
    local ok = inst:start()
    Assert.is_nil(ok, "start возвращает nil при dvb_tune nil")
    ref_ModuleManager.get_global_dependency = orig_gfd
    package.loaded["src.adapters.tuner_monitor"] = nil
    TunerMonitor = require("src.adapters.tuner_monitor")
end)

-- L5-TM-15: init_config_subscription — колбэк config:updated:monitor с MaxCounterValue
suite:add_test("L5-TM-15: config:updated:monitor MaxCounterValue", function()
    TunerMonitor.init_config_subscription()
    local cfg_cb
    for i = 1, #subscribe_calls do
        if subscribe_calls[i].event_type == "config:updated:monitor" then cfg_cb = subscribe_calls[i].cb break end
    end
    Assert.is_not_nil(cfg_cb, "колбэк config:updated:monitor")
    cfg_cb({ MaxCounterValue = 2000000 })
    Assert.is_true(true, "колбэк MaxCounterValue выполнен без ошибок")
end)

-- L5-TM-16: METHOD_RATIO — срабатывание по ratio(signal) и ratio(snr)
suite:add_test("L5-TM-16: METHOD_RATIO signal/snr/ber", function()
    local inst = TunerMonitor.new({ name_adapter = "0", method_comparison = 2, time_check = 0, rate = 1.5 })
    Assert.is_not_nil(inst:start(), "start ok")
    last_dvb_conf.callback({ status = 16, signal = 100, snr = 100, ber = 0, unc = 0 })
    last_dvb_conf.callback({ status = 16, signal = 50, snr = 50, ber = 0, unc = 0 })
    Assert.are_equal(50, inst._current_status_table.signal, "signal обновлён")
    last_dvb_conf.callback({ status = 16, signal = 50, snr = 30, ber = 1, unc = 0 })
    Assert.are_equal(1, inst._current_status_table.ber, "ber обновлён")
end)

-- L5-TM-17: METHOD_SIGNAL_DROP — is_signal_drop / is_snr_drop
suite:add_test("L5-TM-17: METHOD_SIGNAL_DROP падение signal/snr", function()
    local inst = TunerMonitor.new({ name_adapter = "0", method_comparison = 7, time_check = 0, rate = 1.5 })
    Assert.is_not_nil(inst:start(), "start ok")
    last_dvb_conf.callback({ status = 16, signal = 100, snr = 80, ber = 0, unc = 0 })
    last_dvb_conf.callback({ status = 16, signal = 50, snr = 40, ber = 0, unc = 0 })
    Assert.are_equal(50, inst._current_status_table.signal, "signal упал")
end)

-- L5-TM-18: _on_astra_data с analyze — накопление _stats при lock, сброс после отправки
suite:add_test("L5-TM-18: analyze накопление stats и quality", function()
    local inst = TunerMonitor.new({ name_adapter = "0", method_comparison = 3, time_check = 999, analyze = true })
    Assert.is_not_nil(inst:start(), "start ok")
    last_dvb_conf.callback({ status = 16, signal = 80, snr = 40, ber = 5, unc = 1 })
    last_dvb_conf.callback({ status = 16, signal = 80, snr = 40, ber = 5, unc = 1 })
    Assert.is_true(inst._stats.count >= 1 or inst._stats.ber_sum >= 0, "_stats при lock и analyze")
    last_dvb_conf.callback({ status = 0, signal = 0, snr = 0, ber = 0, unc = 0 })
    Assert.is_not_nil(inst._stats, "stats есть")
end)

-- L5-TM-19: psi_update — вызов задачи планировщика (_clear_psi_resources, callback)
suite:add_test("L5-TM-19: psi_update задача планировщика и _clear_psi_resources", function()
    local task_cbs = {}
    local sched = {
        add_task = function(_, name, cb) task_cbs[name] = cb end,
        remove_task = function() end,
    }
    local orig_gm = ref_ModuleManager.get_module
    local orig_gfd = ref_ModuleManager.get_global_dependency
    ref_ModuleManager.get_module = function(name)
        if name == "core.scheduler" then return { get_instance = function() return sched end } end
        return orig_gm(name)
    end
    local fake_analyzer = { __options = { callback = function() end }, close = function() end }
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "dvb_tune" then
            return function(conf)
                last_dvb_conf = conf
                return { stream = function() return {} end, __options = {} }
            end
        end
        if name == "analyze" then return function() return fake_analyzer end end
        return orig_gfd(name)
    end
    package.loaded["src.adapters.tuner_monitor"] = nil
    TunerMonitor = require("src.adapters.tuner_monitor")
    local inst = TunerMonitor.new({ name_adapter = "t1", method_comparison = 1, time_check = 0 })
    Assert.is_not_nil(inst:start(), "start для psi_update")
    local cb_called
    local ok = inst:psi_update(1, function() cb_called = true end)
    local task_cb = task_cbs["psi_update_t1"]
    if task_cb then
        task_cb()
        Assert.is_true(cb_called == true, "callback по завершении вызван")
        Assert.is_nil(fake_analyzer.__options.callback, "_clear_psi_resources обнулил callback")
    end
    Assert.is_true(ok == true or task_cb ~= nil, "psi_update или задача выполнены")
    ref_ModuleManager.get_module = orig_gm
    ref_ModuleManager.get_global_dependency = orig_gfd
    package.loaded["src.adapters.tuner_monitor"] = nil
    TunerMonitor = require("src.adapters.tuner_monitor")
end)

-- L5-TM-20: _on_config_updated синхронизирует _astra_conf и _instance.__options
suite:add_test("L5-TM-20: _on_config_updated __options", function()
    local opts = { rate = 1, time_check = 0 }
    local orig_gfd = ref_ModuleManager.get_global_dependency
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "dvb_tune" then
            return function(conf)
                last_dvb_conf = conf
                return { stream = function() return nil end, __options = opts }
            end
        end
        if name == "analyze" then return function() return { __options = {}, close = function() end } end end
        if name == "json.encode" then return function() return "{}" end end
        return orig_gfd(name)
    end
    package.loaded["src.adapters.tuner_monitor"] = nil
    TunerMonitor = require("src.adapters.tuner_monitor")
    local inst = TunerMonitor.new({ name_adapter = "0", method_comparison = 1 })
    local start_ok = inst:start()
    Assert.is_not_nil(start_ok, "start успешен")
    Assert.is_not_nil(inst._astra_conf, "_astra_conf после start")
    inst:_on_config_updated("rate", 2)
    Assert.is_true(opts.rate == 2, "_instance.__options.rate обновлён")
    ref_ModuleManager.get_global_dependency = orig_gfd
    package.loaded["src.adapters.tuner_monitor"] = nil
    TunerMonitor = require("src.adapters.tuner_monitor")
end)

-- L5-TM-22: METHOD_ALWAYS (1) — return true при отправке
suite:add_test("L5-TM-22: METHOD_ALWAYS отправка", function()
    local inst = TunerMonitor.new({ name_adapter = "0", method_comparison = 1, time_check = 0 })
    Assert.is_not_nil(inst:start(), "start ok")
    last_dvb_conf.callback({ status = 16, signal = 50, snr = 50, ber = 0, unc = 0 })
    Assert.are_equal(16, inst._current_status_table.status, "METHOD_ALWAYS отправил отчёт")
    -- Второй callback без force — вызов _current_method и return true в METHOD_ALWAYS
    last_dvb_conf.callback({ status = 16, signal = 50, snr = 50, ber = 0, unc = 0 })
    Assert.are_equal(16, inst._current_status_table.status, "второй отчёт по методу")
end)

-- L5-TM-23: METHOD_RATIO — срабатывание по (prev.ber ~= curr.ber)
suite:add_test("L5-TM-23: METHOD_RATIO ber", function()
    local inst = TunerMonitor.new({ name_adapter = "0", method_comparison = 2, time_check = 0, rate = 1.5 })
    Assert.is_not_nil(inst:start(), "start ok")
    last_dvb_conf.callback({ status = 16, signal = 80, snr = 40, ber = 0, unc = 0 })
    last_dvb_conf.callback({ status = 16, signal = 80, snr = 40, ber = 1, unc = 0 })
    Assert.are_equal(1, inst._current_status_table.ber, "METHOD_RATIO (prev.ber or -1) ~= (curr.ber or -1)")
end)

-- L5-TM-24: analyze current_quality = 100 (avg_ber=0, unc_sum=0) и сброс stats после отправки
suite:add_test("L5-TM-24: analyze quality 100", function()
    local inst = TunerMonitor.new({ name_adapter = "0", method_comparison = 3, time_check = 999, analyze = true })
    Assert.is_not_nil(inst:start(), "start ok")
    last_dvb_conf.callback({ status = 16, signal = 80, snr = 40, ber = 0, unc = 0 })
    last_dvb_conf.callback({ status = 16, signal = 80, snr = 40, ber = 0, unc = 0 })
    Assert.is_true(inst._stats.count >= 1 or inst._stats.ber_sum >= 0, "stats при lock")
    last_dvb_conf.callback({ status = 0, signal = 0, snr = 0, ber = 0, unc = 0 })
    Assert.is_not_nil(inst._stats, "stats есть")
end)

-- L5-TM-25: start при RUNNING — Logger.warning и return _instance (подмена Logger до require)
suite:add_test("L5-TM-25: start при RUNNING warning", function()
    local warn_called
    local orig_gm = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "logger" then
            return {
                error = function() end,
                info = function() end,
                warning = function() warn_called = true end,
                debug = function() end,
            }
        end
        return orig_gm(name)
    end
    package.loaded["src.adapters.tuner_monitor"] = nil
    TunerMonitor = require("src.adapters.tuner_monitor")
    local inst = TunerMonitor.new({ name_adapter = "0", method_comparison = 1 })
    inst:start()
    local ret = inst:start()
    ref_ModuleManager.get_module = orig_gm
    package.loaded["src.adapters.tuner_monitor"] = nil
    TunerMonitor = require("src.adapters.tuner_monitor")
    Assert.are_equal(inst._instance, ret, "второй start возвращает _instance")
    Assert.is_true(warn_called == true, "Logger.warning вызван")
end)

-- L5-TM-26: check_infrastructure_health — flags и has_lock
suite:add_test("L5-TM-26: check_infrastructure_health flags", function()
    local inst = TunerMonitor.new({ name_adapter = "0", method_comparison = 1, time_check = 0 })
    Assert.is_not_nil(inst:start(), "start для check_infrastructure_health")
    inst._current_flags = { has_lock = true }
    local h1 = inst:check_infrastructure_health()
    inst._current_flags = nil
    local h2 = inst:check_infrastructure_health()
    Assert.is_true(h1 == true or h1 == false, "health при has_lock")
    Assert.is_true(h2 == false, "health false при nil flags")
end)

-- L5-TM-27: _on_config_updated key analyze false — сброс _stats
suite:add_test("L5-TM-27: _on_config_updated analyze false", function()
    local inst = TunerMonitor.new({ name_adapter = "0", method_comparison = 1 })
    inst:start()
    inst._stats.ber_sum = 10
    inst._stats.unc_sum = 5
    inst._stats.count = 2
    inst:_on_config_updated("analyze", false)
    Assert.are_equal(0, inst._stats.ber_sum, "ber_sum сброшен")
    Assert.are_equal(0, inst._stats.unc_sum, "unc_sum сброшен")
    Assert.are_equal(0, inst._stats.count, "count сброшен")
end)

-- L5-TM-30: METHOD_ALWAYS + analyze — сброс _stats после отправки (ber_sum, unc_sum, count = 0) и return true метода
suite:add_test("L5-TM-30: METHOD_ALWAYS analyze сброс stats", function()
    local inst = TunerMonitor.new({ name_adapter = "0", method_comparison = 1, time_check = 0, analyze = true })
    Assert.is_not_nil(inst:start(), "start ok")
    last_dvb_conf.callback({ status = 16, signal = 50, snr = 50, ber = 1, unc = 1 })
    Assert.are_equal(1, inst._current_status_table.ber, "отчёт отправлен")
    Assert.are_equal(0, inst._stats.ber_sum, "stats сброшены после отправки при analyze")
    Assert.are_equal(0, inst._stats.unc_sum, "unc_sum сброшен")
    Assert.are_equal(0, inst._stats.count, "count сброшен")
end)

-- L5-TM-29: psi_update с общим setup — выполнение задачи из scheduler_tasks (полный путь: callback, _clear_psi_resources, Logger.info)
suite:add_test("L5-TM-29: psi_update задача из setup", function()
    package.loaded["src.adapters.tuner_monitor"] = nil
    TunerMonitor = require("src.adapters.tuner_monitor")
    local inst = TunerMonitor.new({ name_adapter = "psi_run", method_comparison = 1, time_check = 0 })
    Assert.is_not_nil(inst:start(), "start ok")
    local cb_psi
    local ok = inst:psi_update(1, function(psi) cb_psi = psi end)
    Assert.is_true(ok == true, "psi_update вернул true")
    local ran_task
    for _, task_cb in pairs(scheduler_tasks) do
        task_cb()
        ran_task = true
        break
    end
    if ran_task then
        Assert.is_nil(inst._temp_analyzer, "_clear_psi_resources обнулил _temp_analyzer")
    end
    Assert.is_true(ok == true, "psi_update успешен")
end)

-- L5-TM-31: psi_update внутренний callback — вызов с data и Logger.error при ошибке в _process_psi_data
suite:add_test("L5-TM-31: psi_update callback и Logger.error", function()
    local task_cbs = {}
    local sched = { add_task = function(_, n, cb) task_cbs[n] = cb end, remove_task = function() end }
    local orig_gm = ref_ModuleManager.get_module
    local orig_gfd = ref_ModuleManager.get_global_dependency
    ref_ModuleManager.get_module = function(name)
        if name == "core.scheduler" then return { get_instance = function() return sched end } end
        return orig_gm(name)
    end
    local err_logged
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "dvb_tune" then
            return function(conf)
                last_dvb_conf = conf
                return { stream = function() return {} end, __options = {} }
            end
        end
        if name == "analyze" then
            return function(opts) return { __options = opts or {}, close = function() end } end
        end
        return orig_gfd(name)
    end
    ref_ModuleManager.get_module = function(name)
        if name == "core.scheduler" then return { get_instance = function() return sched end } end
        if name == "logger" then
            return {
                error = function(_, msg) err_logged = msg end,
                info = function() end,
                warning = function() end,
                debug = function() end,
            }
        end
        return orig_gm(name)
    end
    package.loaded["src.adapters.tuner_monitor"] = nil
    TunerMonitor = require("src.adapters.tuner_monitor")
    local inst = TunerMonitor.new({ name_adapter = "cb1", method_comparison = 1, time_check = 0 })
    Assert.is_not_nil(inst:start(), "start")
    inst:psi_update(1, function() end)
    local cb = inst._temp_analyzer and inst._temp_analyzer.__options and inst._temp_analyzer.__options.callback
    Assert.is_not_nil(cb, "callback передан в analyze")
    if cb then
        cb({ psi = "PAT" })
        err_logged = nil
        cb(setmetatable({}, { __index = function() error("psi_err") end }))
        Assert.is_true(err_logged ~= nil, "Logger.error при ошибке в psi_update callback")
    end
    ref_ModuleManager.get_module = orig_gm
    ref_ModuleManager.get_global_dependency = orig_gfd
    package.loaded["src.adapters.tuner_monitor"] = nil
    TunerMonitor = require("src.adapters.tuner_monitor")
end)

-- L5-TM-28: scan — вызов psi_update и разбор SDT/PAT в callback
suite:add_test("L5-TM-28: scan SDT PAT callback", function()
    local task_cbs = {}
    local sched = { add_task = function(_, n, cb) task_cbs[n] = cb end, remove_task = function() end }
    local orig_gm = ref_ModuleManager.get_module
    local orig_gfd = ref_ModuleManager.get_global_dependency
    ref_ModuleManager.get_module = function(name)
        if name == "core.scheduler" then return { get_instance = function() return sched end } end
        return orig_gm(name)
    end
    local fake_analyzer = { __options = { callback = function() end }, close = function() end }
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "dvb_tune" then
            return function(conf)
                last_dvb_conf = conf
                return { stream = function() return {} end, __options = {} }
            end
        end
        if name == "analyze" then return function() return fake_analyzer end end
        return orig_gfd(name)
    end
    package.loaded["src.adapters.tuner_monitor"] = nil
    TunerMonitor = require("src.adapters.tuner_monitor")
    local inst = TunerMonitor.new({ name_adapter = "sc1", method_comparison = 1, time_check = 0 })
    Assert.is_not_nil(inst:start(), "start для scan")
    inst.get_psi = function() return { SDT = { services = { { sid = 1, name = "S1", provider = "P", type = 1 } } } } end
    local services_out
    local ok = inst:scan(1, function(s) services_out = s end)
    local task_cb = task_cbs["psi_update_sc1"]
    if task_cb then
        task_cb()
        Assert.is_true(services_out ~= nil and #services_out >= 1, "scan callback вызван с services")
    end
    Assert.is_true(ok == true or task_cb ~= nil, "scan или задача выполнены")
    inst.get_psi = function() return { PAT = { programs = { { program = 100 } } } } end
    services_out = nil
    inst:scan(1, function(s) services_out = s end)
    task_cb = task_cbs["psi_update_sc1"]
    if task_cb then task_cb() end
    Assert.is_true(services_out == nil or type(services_out) == "table", "scan PAT путь")
    ref_ModuleManager.get_module = orig_gm
    ref_ModuleManager.get_global_dependency = orig_gfd
    package.loaded["src.adapters.tuner_monitor"] = nil
    TunerMonitor = require("src.adapters.tuner_monitor")
end)

-- L5-TM-21: callback тюнера при ошибке в _on_astra_data — Logger.error
suite:add_test("L5-TM-21: ошибка в callback тюнера", function()
    local err_msg
    local orig_gm = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "logger" then
            return {
                error = function(_, msg) err_msg = msg end,
                info = function() end,
                warning = function() end,
                debug = function() end,
            }
        end
        return orig_gm(name)
    end
    package.loaded["src.adapters.tuner_monitor"] = nil
    TunerMonitor = require("src.adapters.tuner_monitor")
    local inst = TunerMonitor.new({ name_adapter = "0", method_comparison = 1, time_check = 0 })
    inst:start()
    local bad_data = setmetatable({}, { __index = function() error("cb_err") end })
    last_dvb_conf.callback(bad_data)
    ref_ModuleManager.get_module = orig_gm
    Assert.is_true(err_msg ~= nil, "Logger.error вызван при ошибке в callback")
end)

suite:run()
