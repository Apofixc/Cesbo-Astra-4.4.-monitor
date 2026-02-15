-- L6: Unit-тесты для модуля adapters.adapter
-- Высокоуровневый API управления DVB-адаптерами: dvb_tuner_monitor, stop_dvb_monitor, switch_transponder.
-- Моки: Logger, TunerMonitor, DvbRepository, Utils, EventDispatcher, Channel.

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
local Mock = require("tools.test_moc")

local mock
local Adapter
local ref_ModuleManager
local subscribe_calls
local dvb_repo_monitors = {}
local dvb_repo_classes = {}
local tuner_start_result
local tuner_instance

local suite = TestSuite:new("L6.adapter")

suite:setup(function()
    mock = Mock:new()
    subscribe_calls = {}
    dvb_repo_monitors = {}
    dvb_repo_classes = {}
    tuner_start_result = true
    tuner_instance = { tail = {} }

    local DvbRepository = {
        find = function(_, name) return dvb_repo_monitors[name] end,
        register = function(_, name, tuner, cls)
            dvb_repo_monitors[name] = tuner
            dvb_repo_classes[name] = cls
        end,
        unregister = function(_, name, force)
            local t = dvb_repo_monitors[name]
            if t then
                dvb_repo_monitors[name] = nil
                dvb_repo_classes[name] = nil
                return { name_adapter = name }
            end
            return nil
        end,
        get_all = function(_) return dvb_repo_monitors end,
    }

    local TunerMonitor = {
        new = function(conf)
            if not conf or not conf.name_adapter then return nil end
            return {
                start = function()
                    return tuner_start_result and tuner_instance or nil
                end,
                pause = function() return true end,
                resume = function() return true end,
                update_parameters = function(_, p) return p ~= nil end,
                psi_update = function() return true end,
                get_psi = function() return {} end,
                scan = function(_, t, cb) if cb then cb() end return true end,
                get_config = function() return { name_adapter = "0" } end,
                set_backup = function() end,
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
            if name == "tuner_monitor" then return TunerMonitor end
            if name == "dvb_repository" then return DvbRepository end
            if name == "utils" then
                return {
                    table_copy = function(t)
                        local c = {}
                        for k, v in pairs(t or {}) do c[k] = v end
                        return c
                    end,
                }
            end
            if name == "core.event_dispatcher" then
                return {
                    get_instance = function()
                        return {
                            subscribe = function(_, event_type, cb)
                                subscribe_calls[#subscribe_calls + 1] = { event_type = event_type, cb = cb }
                                return "sub-id"
                            end,
                        }
                    end,
                }
            end
            if name == "channel" then
                return {
                    reconfigure_streams = function(adapter_list, callback, updates)
                        if type(adapter_list) ~= "table" or type(callback) ~= "function" then
                            return false
                        end
                        return callback()
                    end,
                }
            end
            return nil
        end,
        get_global_dependency = function() return nil end,
    }
    mock:mock_global("ModuleManager", ref_ModuleManager)

    package.loaded["src.adapters.adapter"] = nil
    Adapter = require("src.adapters.adapter")
end)

suite:before_each(function()
    subscribe_calls = {}
    dvb_repo_monitors = {}
    dvb_repo_classes = {}
    tuner_start_result = true
    tuner_instance = { tail = {} }
end)

suite:teardown(function()
    mock:restore()
end)

-- L6-AD-01: init_events подписывается на adapter:action:restart
suite:add_test("L6-AD-01: init_events подписывается на adapter:action:restart", function()
    Adapter.init_events()
    local found
    for i = 1, #subscribe_calls do
        if subscribe_calls[i].event_type == "adapter:action:restart" then found = true break end
    end
    Assert.is_true(found, "подписка на adapter:action:restart")
end)

-- L6-AD-01b: init_events callback вызывается при adapter:action:restart
suite:add_test("L6-AD-01b: init_events callback при adapter:action:restart", function()
    dvb_repo_monitors["cb_tuner"] = {
        get_config = function() return { name_adapter = "cb_tuner", freq = 1000 } end,
        set_backup = function() end,
    }
    local cb_called, cb_name, cb_reason
    ref_ModuleManager.get_module = function(name)
        if name == "channel" then
            return {
                reconfigure_streams = function(adapter_list, callback, updates)
                    return type(callback) == "function" and callback()
                end,
            }
        end
        if name == "dvb_repository" then
            return {
                find = function(_, n) return dvb_repo_monitors[n] end,
                register = function(_, n, t) dvb_repo_monitors[n] = t end,
                unregister = function(_, n) local c = dvb_repo_monitors[n]; if c then dvb_repo_monitors[n] = nil return { name_adapter = n } end return nil end,
                get_all = function(_) return dvb_repo_monitors end,
            }
        end
        if name == "tuner_monitor" then
            return {
                new = function(conf)
                    return conf and conf.name_adapter and {
                        start = function() return tuner_instance end,
                        pause = function() return true end,
                        resume = function() return true end,
                        update_parameters = function() return true end,
                        psi_update = function() return true end,
                        get_psi = function() return {} end,
                        scan = function(_, t, cb) if cb then cb() end return true end,
                        get_config = function() return conf end,
                        set_backup = function() end,
                    }
                end,
            }
        end
        if name == "logger" then
            return {
                error = function() end,
                info = function(_, fmt, n, r) cb_name, cb_reason = n, r end,
                warning = function() end,
                debug = function() end,
            }
        end
        if name == "utils" then return { table_copy = function(t) local c = {} for k, v in pairs(t or {}) do c[k] = v end return c end } end
        if name == "core.event_dispatcher" then
            return {
                get_instance = function()
                    return {
                        subscribe = function(_, ev, cb)
                            subscribe_calls[#subscribe_calls + 1] = { event_type = ev, cb = cb }
                            return "sub-id"
                        end,
                    }
                end,
            }
        end
        return nil
    end
    package.loaded["src.adapters.adapter"] = nil
    Adapter = require("src.adapters.adapter")
    Adapter.init_events()
    local sub
    for i = 1, #subscribe_calls do
        if subscribe_calls[i].event_type == "adapter:action:restart" then sub = subscribe_calls[i] break end
    end
    Assert.is_not_nil(sub, "подписка найдена")
    sub.cb("cb_tuner", "test_reason")
    Assert.are_equal("cb_tuner", cb_name, "callback вызван с name")
    Assert.are_equal("test_reason", cb_reason, "callback вызван с reason")
    _G.cb_tuner = nil
end)

-- L6-AD-02: dvb_tuner_monitor без conf возвращает false
suite:add_test("L6-AD-02: dvb_tuner_monitor без conf возвращает false", function()
    local ok = Adapter.dvb_tuner_monitor(nil)
    Assert.is_false(ok, "dvb_tuner_monitor(nil) возвращает false")
end)

-- L6-AD-03: dvb_tuner_monitor без name_adapter возвращает false
suite:add_test("L6-AD-03: dvb_tuner_monitor без name_adapter возвращает false", function()
    local ok = Adapter.dvb_tuner_monitor({})
    Assert.is_false(ok, "dvb_tuner_monitor без name_adapter возвращает false")
end)

-- L6-AD-04: dvb_tuner_monitor при существующем тюнере возвращает false
suite:add_test("L6-AD-04: dvb_tuner_monitor при существующем тюнере возвращает false", function()
    dvb_repo_monitors["0"] = {}
    local ok = Adapter.dvb_tuner_monitor({ name_adapter = "0" })
    Assert.is_false(ok, "dvb_tuner_monitor при существующем тюнере возвращает false")
end)

-- L6-AD-05: dvb_tuner_monitor успешно создаёт и регистрирует тюнер
suite:add_test("L6-AD-05: dvb_tuner_monitor успешно создаёт тюнер", function()
    local name = "test_tuner_l6"
    local ok = Adapter.dvb_tuner_monitor({ name_adapter = name, type = "DVB-S2" })
    Assert.is_true(ok, "dvb_tuner_monitor успешно")
    Assert.is_not_nil(dvb_repo_monitors[name], "тюнер зарегистрирован")
    Assert.are_equal(_G[name], tuner_instance, "_G[name_adapter] установлен")
    Adapter.stop_dvb_monitor(name)
    _G[name] = nil
end)

-- L6-AD-06: dvb_tuner_monitor при start nil возвращает false
suite:add_test("L6-AD-06: dvb_tuner_monitor при start nil возвращает false", function()
    local orig_get = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "tuner_monitor" then
            return {
                new = function(conf)
                    if not conf or not conf.name_adapter then return nil end
                    return {
                        start = function() return nil end,
                        pause = function() return true end,
                        resume = function() return true end,
                        update_parameters = function() return true end,
                        psi_update = function() return true end,
                        get_psi = function() return {} end,
                        scan = function(_, t, cb) if cb then cb() end return true end,
                        get_config = function() return conf end,
                        set_backup = function() end,
                    }
                end,
            }
        end
        return orig_get(name)
    end
    package.loaded["src.adapters.adapter"] = nil
    Adapter = require("src.adapters.adapter")
    local ok = Adapter.dvb_tuner_monitor({ name_adapter = "t6_nostart" })
    Assert.is_false(ok, "dvb_tuner_monitor при start nil возвращает false")
end)

-- L6-AD-06b: dvb_tuner_monitor при TunerMonitor.new nil возвращает false
suite:add_test("L6-AD-06b: dvb_tuner_monitor при TunerMonitor.new nil", function()
    local orig_get = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "tuner_monitor" then
            return { new = function() return nil end }
        end
        return orig_get(name)
    end
    package.loaded["src.adapters.adapter"] = nil
    Adapter = require("src.adapters.adapter")
    local ok = Adapter.dvb_tuner_monitor({ name_adapter = "nil_tuner" })
    Assert.is_false(ok, "dvb_tuner_monitor при TunerMonitor.new nil возвращает false")
end)

-- L6-AD-07: find_dvb_monitor возвращает тюнер или nil
suite:add_test("L6-AD-07: find_dvb_monitor возвращает тюнер", function()
    dvb_repo_monitors["x"] = { id = 1 }
    local t = Adapter.find_dvb_monitor("x")
    Assert.are_equal(dvb_repo_monitors["x"], t, "find_dvb_monitor возвращает тюнер")
    local nil_t = Adapter.find_dvb_monitor("nonexistent")
    Assert.is_nil(nil_t, "find_dvb_monitor(nonexistent) возвращает nil")
end)

-- L6-AD-08: stop_dvb_monitor останавливает и удаляет тюнер
suite:add_test("L6-AD-08: stop_dvb_monitor останавливает тюнер", function()
    dvb_repo_monitors["0"] = {}
    _G["0"] = {}
    local config = Adapter.stop_dvb_monitor("0")
    Assert.is_not_nil(config, "stop_dvb_monitor возвращает config")
    Assert.is_nil(dvb_repo_monitors["0"], "тюнер удалён из репозитория")
    Assert.is_nil(_G["0"], "_G[name_adapter] очищен")
end)

-- L6-AD-09: stop_dvb_monitor при отсутствующем тюнере возвращает nil
suite:add_test("L6-AD-09: stop_dvb_monitor при отсутствующем тюнере возвращает nil", function()
    local config = Adapter.stop_dvb_monitor("nonexistent")
    Assert.is_nil(config, "stop_dvb_monitor(nonexistent) возвращает nil")
end)

-- L6-AD-10: get_all_dvb_monitors возвращает список
suite:add_test("L6-AD-10: get_all_dvb_monitors возвращает список", function()
    dvb_repo_monitors["a"] = {}
    dvb_repo_monitors["b"] = {}
    local all = Adapter.get_all_dvb_monitors()
    Assert.is_not_nil(all, "get_all возвращает таблицу")
    Assert.is_true(all["a"] ~= nil and all["b"] ~= nil, "список содержит тюнеры")
end)

-- L6-AD-11: update_dvb_monitor_parameters при наличии тюнера
suite:add_test("L6-AD-11: update_dvb_monitor_parameters", function()
    dvb_repo_monitors["0"] = { update_parameters = function(_, p) return p ~= nil end }
    local ok = Adapter.update_dvb_monitor_parameters("0", { rate = 1 })
    Assert.is_true(ok, "update_dvb_monitor_parameters возвращает true")
end)

-- L6-AD-12: update_dvb_monitor_parameters при отсутствующем тюнере
suite:add_test("L6-AD-12: update_dvb_monitor_parameters при отсутствующем тюнере", function()
    local ok = Adapter.update_dvb_monitor_parameters("x", {})
    Assert.is_false(ok, "update_dvb_monitor_parameters(nonexistent) возвращает false")
end)

-- L6-AD-13: pause_dvb_monitor и resume_dvb_monitor
suite:add_test("L6-AD-13: pause_dvb_monitor и resume_dvb_monitor", function()
    dvb_repo_monitors["0"] = { pause = function() return true end, resume = function() return true end }
    Assert.is_true(Adapter.pause_dvb_monitor("0"), "pause возвращает true")
    Assert.is_true(Adapter.resume_dvb_monitor("0"), "resume возвращает true")
    Assert.is_false(Adapter.pause_dvb_monitor("x"), "pause(nonexistent) возвращает false")
end)

-- L6-AD-14: update_dvb_psi и get_dvb_psi
suite:add_test("L6-AD-14: update_dvb_psi и get_dvb_psi", function()
    local psi_data = { tables = {} }
    dvb_repo_monitors["0"] = { psi_update = function() return true end, get_psi = function() return psi_data end }
    Assert.is_true(Adapter.update_dvb_psi("0"), "update_dvb_psi возвращает true")
    Assert.are_equal(psi_data, Adapter.get_dvb_psi("0"), "get_dvb_psi возвращает psi")
    Assert.is_nil(Adapter.get_dvb_psi("x"), "get_dvb_psi(nonexistent) возвращает nil")
    Assert.is_false(Adapter.update_dvb_psi("nonexistent"), "update_dvb_psi(nonexistent) возвращает false")
end)

-- L6-AD-15: scan_dvb
suite:add_test("L6-AD-15: scan_dvb", function()
    local cb_called
    dvb_repo_monitors["0"] = { scan = function(_, t, cb) cb_called = true if cb then cb() end return true end }
    local ok = Adapter.scan_dvb("0", 5, function() end)
    Assert.is_true(ok, "scan_dvb возвращает true")
    Assert.is_true(cb_called, "callback вызван")
    Assert.is_false(Adapter.scan_dvb("x", 5, function() end), "scan_dvb(nonexistent) возвращает false")
end)

-- L6-AD-16: reconfigure при некорректном adapter_list
suite:add_test("L6-AD-16: reconfigure при некорректном adapter_list", function()
    local ok = Adapter.reconfigure(nil, {})
    Assert.is_false(ok, "reconfigure(nil) возвращает false")
end)

-- L6-AD-16b: reconfigure при Channel == nil возвращает false
suite:add_test("L6-AD-16b: reconfigure при Channel nil", function()
    local orig_get = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "channel" then return nil end
        return orig_get(name)
    end
    package.loaded["src.adapters.adapter"] = nil
    Adapter = require("src.adapters.adapter")
    local ok = Adapter.reconfigure({ "a" }, {})
    Assert.is_false(ok, "reconfigure при Channel nil возвращает false")
end)

-- L6-AD-16c: reconfigure callback при _perform_restart false (unregister nil)
suite:add_test("L6-AD-16c: reconfigure при ошибке _perform_restart", function()
    dvb_repo_monitors["fail_tuner"] = {
        get_config = function() return { name_adapter = "fail_tuner" } end,
        set_backup = function() end,
    }
    local orig_get = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "channel" then
            return { reconfigure_streams = function(adapter_list, callback) return type(callback) == "function" and callback() end }
        end
        if name == "dvb_repository" then
            return {
                find = function(_, n) return dvb_repo_monitors[n] end,
                register = function(_, n, t) dvb_repo_monitors[n] = t end,
                unregister = function(_, n) return nil end,
                get_all = function(_) return dvb_repo_monitors end,
            }
        end
        return orig_get(name)
    end
    package.loaded["src.adapters.adapter"] = nil
    Adapter = require("src.adapters.adapter")
    local ok = Adapter.reconfigure({ "fail_tuner" }, { adapter_params = { ["fail_tuner"] = { freq = 2000 } } })
    Assert.is_false(ok, "reconfigure при unregister nil возвращает false")
end)

-- L6-AD-16d: reconfigure callback при dvb_tuner_monitor false (после успешного stop)
suite:add_test("L6-AD-16d: reconfigure при dvb_tuner_monitor false", function()
    dvb_repo_monitors["fail2_tuner"] = {
        get_config = function() return { name_adapter = "fail2_tuner", freq = 1000 } end,
        set_backup = function() end,
    }
    local orig_get = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "channel" then
            return { reconfigure_streams = function(adapter_list, callback) return type(callback) == "function" and callback() end }
        end
        if name == "dvb_repository" then
            return {
                find = function(_, n) return dvb_repo_monitors[n] end,
                register = function(_, n, t) dvb_repo_monitors[n] = t end,
                unregister = function(_, n)
                    local c = dvb_repo_monitors[n]
                    if c then dvb_repo_monitors[n] = nil return { name_adapter = n } end
                    return nil
                end,
                get_all = function(_) return dvb_repo_monitors end,
            }
        end
        if name == "tuner_monitor" then
            return {
                new = function(conf)
                    return conf and conf.name_adapter and {
                        start = function() return nil end,
                        get_config = function() return conf end,
                        set_backup = function() end,
                    } or nil
                end,
            }
        end
        return orig_get(name)
    end
    package.loaded["src.adapters.adapter"] = nil
    Adapter = require("src.adapters.adapter")
    local ok = Adapter.reconfigure({ "fail2_tuner" }, { adapter_params = { ["fail2_tuner"] = { freq = 2000 } } })
    Assert.is_false(ok, "reconfigure при dvb_tuner_monitor false возвращает false")
end)

-- L6-AD-17: switch_transponder при отсутствующем тюнере возвращает nil
suite:add_test("L6-AD-17: switch_transponder при отсутствующем тюнере возвращает nil", function()
    local snapshot = Adapter.switch_transponder("nonexistent", { freq = 2000 }, nil)
    Assert.is_nil(snapshot, "switch_transponder(nonexistent) возвращает nil")
end)

-- L6-AD-17b: restart_dvb_monitor при отсутствующем тюнере возвращает false
suite:add_test("L6-AD-17b: restart_dvb_monitor при отсутствующем тюнере", function()
    local ok = Adapter.restart_dvb_monitor("nonexistent", nil, true)
    Assert.is_false(ok, "restart_dvb_monitor(nonexistent) возвращает false")
end)

-- L6-AD-17c: restart_dvb_monitor debounce при force=false
suite:add_test("L6-AD-17c: restart_dvb_monitor debounce", function()
    dvb_repo_monitors["deb_t"] = { get_config = function() return { name_adapter = "deb_t" } end, set_backup = function() end }
    local orig_os_time = _G.os.time
    _G.os.time = function() return 100 end
    ref_ModuleManager.get_module = function(name)
        if name == "channel" then return { reconfigure_streams = function(al, cb) return type(cb) == "function" and cb() end } end
        if name == "dvb_repository" then
            return {
                find = function(_, n) return dvb_repo_monitors[n] end,
                register = function(_, n, t) dvb_repo_monitors[n] = t end,
                unregister = function(_, n) local c = dvb_repo_monitors[n]; if c then dvb_repo_monitors[n] = nil return { name_adapter = n } end return nil end,
                get_all = function(_) return dvb_repo_monitors end,
            }
        end
        if name == "tuner_monitor" then
            return { new = function(conf) return conf and conf.name_adapter and { start = function() return tuner_instance end, get_config = function() return conf end, set_backup = function() end } end }
        end
        if name == "logger" then return { error = function() end, info = function() end, warning = function() end, debug = function() end } end
        if name == "utils" then return { table_copy = function(t) local c = {} for k, v in pairs(t or {}) do c[k] = v end return c end } end
        if name == "core.event_dispatcher" then return { get_instance = function() return { subscribe = function() return "id" end } end } end
        return nil
    end
    package.loaded["src.adapters.adapter"] = nil
    Adapter = require("src.adapters.adapter")
    local ok1 = Adapter.restart_dvb_monitor("deb_t", nil, true)
    Assert.is_true(ok1, "первый restart success")
    _G.os.time = function() return 102 end
    local ok2 = Adapter.restart_dvb_monitor("deb_t", nil, false)
    Assert.is_true(ok2, "debounce возвращает true")
    _G.os.time = orig_os_time
    _G.deb_t = nil
end)

-- L6-AD-17d: restart_dvb_monitor success (force=true)
suite:add_test("L6-AD-17d: restart_dvb_monitor success", function()
    local old_conf = { name_adapter = "rst_t", freq = 1000 }
    dvb_repo_monitors["rst_t"] = { get_config = function() return old_conf end, set_backup = function() end }
    ref_ModuleManager.get_module = function(name)
        if name == "channel" then return { reconfigure_streams = function(al, cb) return type(cb) == "function" and cb() end } end
        if name == "dvb_repository" then
            return {
                find = function(_, n) return dvb_repo_monitors[n] end,
                register = function(_, n, t) dvb_repo_monitors[n] = t end,
                unregister = function(_, n) local c = dvb_repo_monitors[n]; if c then dvb_repo_monitors[n] = nil return { name_adapter = n } end return nil end,
                get_all = function(_) return dvb_repo_monitors end,
            }
        end
        if name == "tuner_monitor" then
            return { new = function(conf) return conf and conf.name_adapter and { start = function() return tuner_instance end, get_config = function() return conf end, set_backup = function() end } end }
        end
        if name == "logger" then return { error = function() end, info = function() end, warning = function() end, debug = function() end } end
        if name == "utils" then return { table_copy = function(t) local c = {} for k, v in pairs(t or {}) do c[k] = v end return c end } end
        if name == "core.event_dispatcher" then return { get_instance = function() return { subscribe = function() return "id" end } end } end
        return nil
    end
    package.loaded["src.adapters.adapter"] = nil
    Adapter = require("src.adapters.adapter")
    local ok = Adapter.restart_dvb_monitor("rst_t", { freq = 2000 }, true)
    Assert.is_true(ok, "restart_dvb_monitor success")
    _G.rst_t = nil
end)

-- L6-AD-13b: resume_dvb_monitor при отсутствующем тюнере возвращает false
suite:add_test("L6-AD-13b: resume_dvb_monitor при отсутствующем тюнере", function()
    Assert.is_false(Adapter.resume_dvb_monitor("nonexistent"), "resume(nonexistent) возвращает false")
end)

-- L6-AD-18b: switch_transponder с reserve_input и при неуспешном reconfigure
suite:add_test("L6-AD-18b: switch_transponder reserve_input и failure", function()
    dvb_repo_monitors["sw_t"] = {
        get_config = function() return { name_adapter = "sw_t", freq = 1000 } end,
        set_backup = function() end,
    }
    local orig_get = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "channel" then
            return {
                reconfigure_streams = function(adapter_list, callback, updates)
                    Assert.is_not_nil(updates, "channel_updates передан")
                    Assert.are_equal("in1", updates["ch1"], "channel_updates[ch1]")
                    return false
                end,
            }
        end
        if name == "dvb_repository" then
            return {
                find = function(_, n) return dvb_repo_monitors[n] end,
                register = function(_, n, t) dvb_repo_monitors[n] = t end,
                unregister = function(_, n) return nil end,
                get_all = function(_) return dvb_repo_monitors end,
            }
        end
        return orig_get(name)
    end
    package.loaded["src.adapters.adapter"] = nil
    Adapter = require("src.adapters.adapter")
    local snapshot = Adapter.switch_transponder("sw_t", { freq = 2000 }, { { name = "ch1", input = "in1" } })
    Assert.is_nil(snapshot, "switch_transponder при reconfigure false возвращает nil")
end)

-- L6-AD-18: switch_transponder — reconfigure_streams callback выполняется
suite:add_test("L6-AD-18: switch_transponder при успешном reconfigure", function()
    local old_conf = { freq = 1000, name_adapter = "tuner_sw" }
    dvb_repo_monitors["tuner_sw"] = {
        get_config = function() return old_conf end,
        set_backup = function() end,
    }
    local callback_ran
    ref_ModuleManager.get_module = function(name)
        if name == "channel" then
            return {
                reconfigure_streams = function(adapter_list, callback, updates)
                    if type(callback) == "function" then
                        callback_ran = true
                        return callback()
                    end
                    return false
                end,
            }
        end
        if name == "dvb_repository" then
            return {
                find = function(_, n) return dvb_repo_monitors[n] end,
                register = function(_, n, t) dvb_repo_monitors[n] = t end,
                unregister = function(_, n, force)
                    local c = dvb_repo_monitors[n]
                    if c then dvb_repo_monitors[n] = nil return { name_adapter = n } end
                    return nil
                end,
                get_all = function(_) return dvb_repo_monitors end,
            }
        end
        if name == "tuner_monitor" then
            return {
                new = function(conf)
                    if not conf or not conf.name_adapter then return nil end
                    return {
                        start = function() return tuner_instance end,
                        pause = function() return true end,
                        resume = function() return true end,
                        update_parameters = function() return true end,
                        psi_update = function() return true end,
                        get_psi = function() return {} end,
                        scan = function(_, t, cb) if cb then cb() end return true end,
                        get_config = function() return conf end,
                        set_backup = function() end,
                    }
                end,
            }
        end
        if name == "utils" then
            return { table_copy = function(t) local c = {} for k, v in pairs(t or {}) do c[k] = v end return c end }
        end
        if name == "logger" then
            return { error = function() end, info = function() end, warning = function() end, debug = function() end }
        end
        return nil
    end
    package.loaded["src.adapters.adapter"] = nil
    Adapter = require("src.adapters.adapter")
    local snapshot = Adapter.switch_transponder("tuner_sw", { freq = 2000, name_adapter = "tuner_sw" }, nil)
    Assert.is_true(callback_ran, "reconfigure_streams callback выполнен")
    Assert.is_true(snapshot == nil or (type(snapshot) == "table" and snapshot.tuner_params), "switch_transponder")
    _G.tuner_sw = nil
end)

suite:run()
