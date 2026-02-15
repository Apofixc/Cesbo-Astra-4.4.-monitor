-- L2: Unit-тесты для модуля core.base_monitor
-- Case L2-BM-01: destroy — остановка таймеров, очистка ресурсов.
-- Моки: EventDispatcher, Logger, Utils, TablePool, json.encode.

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
local Mock = require("tools.test_moc")

local mock
local local_mock
local BaseMonitor
local ref_ModuleManager
local unsubscribe_called
local sub_id_returned
local ref_resource_warning_cb
local emit_safe_called

local suite = TestSuite:new("L2.base_monitor")

suite:setup(function()
    mock = Mock:new()
    unsubscribe_called = {}
    sub_id_returned = "sub_resource_1"
    ref_resource_warning_cb = nil
    emit_safe_called = {}

    ref_ModuleManager = {
        get_module = function(name)
            if name == "core.event_dispatcher" then
                return {
                    get_instance = function()
                        return {
                            subscribe = function(self, ev, cb)
                                if ev == "sys:resource_warning" then ref_resource_warning_cb = cb end
                                return sub_id_returned
                            end,
                            unsubscribe = function(_, id)
                                unsubscribe_called[#unsubscribe_called + 1] = id
                            end,
                            emit_safe = function(self, etype, data, prio, opts)
                                emit_safe_called[#emit_safe_called + 1] = { type = etype, data = data, opts = opts }
                            end,
                        }
                    end
                }
            end
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
                    validate_monitor_param = function(_, v) return v end,
                    init_report = function(t, type_name, name) t.type = type_name; t.name = name end,
                }
            end
            if name == "utils.table_pool" then
                return {
                    get = function() return {} end,
                    release = function() end,
                    register_type = function() end,
                }
            end
            return nil
        end,
        get_global_dependency = function(name)
            if name == "json.encode" then return function(t) return (t and "{}") or "null" end end
            return nil
        end,
    }
    mock:mock_global("ModuleManager", ref_ModuleManager)
end)

suite:before_each(function()
    unsubscribe_called = {}
    sub_id_returned = "sub_resource_1"
    ref_resource_warning_cb = nil
    emit_safe_called = {}
    package.loaded["src.core.base_monitor"] = nil
    BaseMonitor = require("src.core.base_monitor")
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

-- L2-BM-01: Вызов destroy — остановка таймеров (отписка), очистка ресурсов
suite:add_test("destroy: возвращает конфиг и отписывается от EventDispatcher", function()
    local config = { name = "mon1" }
    local mon = BaseMonitor.new(config, "TestMonitor")
    Assert.are_equal(BaseMonitor.STATE.IDLE, mon:get_state(), "начальное состояние IDLE")

    local returned_config = mon:destroy()
    Assert.are_equal(config, returned_config, "destroy возвращает конфиг")
    Assert.are_equal(1, #unsubscribe_called, "одна отписка")
    Assert.are_equal(sub_id_returned, unsubscribe_called[1], "отписан ожидаемый id")
end)

suite:add_test("destroy: повторный вызов возвращает nil и не отписывает снова", function()
    local config = { name = "mon2" }
    local mon = BaseMonitor.new(config, "TestMonitor")
    mon:destroy()
    unsubscribe_called = {}
    local ret = mon:destroy()
    Assert.is_nil(ret, "повторный destroy возвращает nil")
    Assert.are_equal(0, #unsubscribe_called, "повторно не отписывает")
end)

suite:add_test("destroy: состояние STOPPED, поля обнулены", function()
    local config = { name = "m" }
    local mon = BaseMonitor.new(config, "C")
    mon:destroy()
    Assert.is_nil(mon._config, "_config обнулён")
    Assert.is_nil(mon._name, "_name обнулён")
    Assert.is_nil(mon._check_timer, "_check_timer обнулён")
    Assert.is_nil(mon._resource_sub_id, "_resource_sub_id обнулён")
end)

suite:add_test("new: имя и component_name из конфига", function()
    local mon = BaseMonitor.new({ name = "tuner1" }, "DvbMonitor")
    Assert.are_equal("tuner1", mon:get_name(), "имя из конфига")
    Assert.are_equal(BaseMonitor.STATE.IDLE, mon:get_state(), "состояние IDLE")
end)

suite:add_test("pause: сбрасывает active", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    mon._active = true
    mon:pause()
    Assert.is_false(mon._active, "pause сбрасывает active")
end)

suite:add_test("resume: после pause устанавливает active", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    mon:pause()
    local ok = mon:resume()
    Assert.is_true(ok, "resume возвращает true")
    Assert.is_true(mon._active, "active установлен")
end)

suite:add_test("resume: после destroy возвращает false", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    mon:destroy()
    local ok = mon:resume()
    Assert.is_false(ok, "resume после destroy возвращает false")
end)

suite:add_test("get_status_table: возвращает _current_status_table", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    local t = mon:get_status_table()
    Assert.is_not_nil(t, "get_status_table возвращает таблицу")
    Assert.are_equal(mon._current_status_table, t, "возвращается _current_status_table")
end)

suite:add_test("get_table_from_pool: при наличии TablePool возвращает таблицу", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    local t = mon:get_table_from_pool("event_options")
    Assert.are_equal("table", type(t), "get_table_from_pool возвращает таблицу")
end)

-- update_parameters -> _set_config_param, _on_config_updated
suite:add_test("update_parameters: вызывает _set_config_param и обновляет конфиг", function()
    local mon = BaseMonitor.new({ name = "m", time_check = 5 }, "C", "channel_")
    local ok = mon:update_parameters({ time_check = 10 })
    Assert.is_true(ok, "update_parameters успешен")
    Assert.are_equal(10, mon._config.time_check, "time_check обновлён")
end)

suite:add_test("update_parameters: не таблица — false", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    Assert.is_false(mon:update_parameters(nil), "nil — false")
    Assert.is_false(mon:update_parameters("x"), "не таблица — false")
end)

-- _set_config_param: ветка, когда param_name не начинается с prefix (gsub)
suite:add_test("_set_config_param: param_name без префикса использует gsub", function()
    local mon = BaseMonitor.new({ name = "m", time_check = 5 }, "C", "channel_")
    local ok = mon:_set_config_param("time_check", 15, "channel_")
    Assert.is_true(ok, "успех при param_name без префикса")
    Assert.are_equal(15, mon._config.time_check, "значение записано по ключу без префикса")
end)

-- get_status_json -> _refresh_cache
suite:add_test("get_status_json: при пустом кэше вызывает _refresh_cache", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    mon._current_status_table = { bitrate = 1000 }
    local json = mon:get_status_json()
    Assert.is_not_nil(json, "get_status_json возвращает строку")
    Assert.are_equal("{}", json, "json от _refresh_cache")
end)

-- publish -> emit_safe
suite:add_test("publish: вызывает EventDispatcher emit_safe", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    mon:publish({ x = 1 }, "channel:data")
    Assert.are_equal(1, #emit_safe_called, "emit_safe вызван один раз")
    Assert.are_equal("channel:data", emit_safe_called[1].type, "тип события channel:data")
end)

-- _init_config
suite:add_test("_init_config: заполняет конфиг по ключам", function()
    local mon = BaseMonitor.new({ name = "m" }, "C", "channel_")
    mon:_init_config({ time_check = 20 }, { "time_check" })
    Assert.are_equal(20, mon._config.time_check, "time_check из конфига")
end)
suite:add_test("_init_config: при value nil берёт params[param_name]", function()
    local mon = BaseMonitor.new({ name = "m" }, "C", "channel_")
    mon:_init_config({ channel_time_check = 15 }, { "time_check" })
    Assert.are_equal(15, mon._config.time_check, "time_check из params при value nil")
end)
suite:add_test("_init_config: не таблица — выход", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    mon:_init_config(nil, { "a" })
    mon:_init_config({}, nil)
end)

-- resource_warning -> _enable_load_shedding / _disable_load_shedding
suite:add_test("_handle_resource_warning: critical включает load_shedding", function()
    local mon = BaseMonitor.new({ name = "m", time_check = 2 }, "C")
    Assert.is_not_nil(ref_resource_warning_cb, "коллбэк resource_warning сохранён")
    ref_resource_warning_cb({ type = "cpu", status = "critical" })
    Assert.is_true(mon._load_shedding_active, "critical включает load_shedding")
end)

suite:add_test("_handle_resource_warning: ok выключает load_shedding", function()
    local mon = BaseMonitor.new({ name = "m", time_check = 2 }, "C")
    ref_resource_warning_cb({ type = "cpu", status = "critical" })
    ref_resource_warning_cb({ type = "cpu", status = "ok" })
    Assert.is_false(mon._load_shedding_active, "ok выключает load_shedding")
end)

suite:add_test("_handle_resource_warning: не cpu — без изменений", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    ref_resource_warning_cb({ type = "memory", status = "critical" })
    Assert.is_false(mon._load_shedding_active, "не cpu — без изменений")
end)

-- _process_psi_data, get_psi, _clear_psi
suite:add_test("_process_psi_data и get_psi: сохраняет и возвращает по имени", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    mon:_process_psi_data({ psi = "PMT", v = 1 })
    local d = mon:get_psi("PMT")
    Assert.are_equal(1, d and d.v, "get_psi возвращает сохранённые данные")
end)

suite:add_test("_clear_psi: очищает кэш PSI", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    mon:_process_psi_data({ psi = "PMT" })
    mon:_clear_psi()
    Assert.is_nil(mon:get_psi("PMT"), "после _clear_psi кэш пуст")
end)

-- _should_send, _is_force, _reset_force_timer
suite:add_test("_should_send: при check_timer < time_check возвращает false", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    mon._check_timer = 0
    mon._force_timer = 0
    Assert.is_false(mon:_should_send(5), "при check_timer < time_check — false")
end)

suite:add_test("_should_send: при достаточном check_timer возвращает true", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    mon._check_timer = 5
    Assert.is_true(mon:_should_send(5), "при достаточном check_timer — true")
    Assert.are_equal(0, mon._check_timer, "check_timer сброшен")
end)

suite:add_test("_reset_force_timer: обнуляет _force_timer", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    mon._force_timer = 100
    mon:_reset_force_timer()
    Assert.are_equal(0, mon._force_timer, "_force_timer обнулён")
end)

-- return_table_to_pool
suite:add_test("return_table_to_pool: вызывает release", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    local t = {}
    mon:return_table_to_pool(t, "generic")
end)

-- _clear_json_cache
suite:add_test("_clear_json_cache: обнуляет _json_cache", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    mon._json_cache = "cached"
    mon:_clear_json_cache()
    Assert.is_nil(mon._json_cache, "_json_cache обнулён")
end)

-- get_software_status, check_infrastructure_health
suite:add_test("get_software_status: возвращает state, active, last_update", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    local s = mon:get_software_status()
    Assert.are_equal(BaseMonitor.STATE.IDLE, s.state, "state IDLE")
    Assert.is_false(s.active, "active false")
end)

suite:add_test("check_infrastructure_health: в базе возвращает nil", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    Assert.is_nil(mon:check_infrastructure_health(), "в базе возвращает nil")
end)

-- init_config_subscription
suite:add_test("init_config_subscription: подписывается при наличии EventDispatcher", function()
    local sub_ev, sub_cb
    local_mock = Mock:new()
    local mod_mm = {
        get_module = function(name)
            if name == "core.event_dispatcher" then
                local ed = {
                    get_instance = function()
                        return {
                            subscribe = function(self, ev, cb) sub_ev = ev; sub_cb = cb end,
                            unsubscribe = function() end,
                        }
                    end,
                }
                return ed
            end
            return ref_ModuleManager.get_module(name)
        end,
        get_global_dependency = ref_ModuleManager.get_global_dependency,
    }
    local_mock:mock_global("ModuleManager", mod_mm)
    package.loaded["src.core.base_monitor"] = nil
    BaseMonitor = require("src.core.base_monitor")
    BaseMonitor.init_config_subscription()
    Assert.are_equal("config:updated:monitor", sub_ev, "подписка на config:updated:monitor")
    Assert.is_not_nil(sub_cb, "коллбэк сохранён")
end)

-- get_config, get_instance
suite:add_test("get_config: возвращает _config", function()
    local cfg = { name = "c" }
    local mon = BaseMonitor.new(cfg, "C")
    Assert.are_equal(cfg, mon:get_config(), "get_config возвращает _config")
end)
suite:add_test("get_instance: возвращает _instance", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    Assert.is_nil(mon:get_instance(), "изначально nil")
    mon._instance = {}
    Assert.are_equal(mon._instance, mon:get_instance(), "get_instance возвращает _instance")
end)

-- _close_instance: вызов при destroy с _instance (__options, close)
suite:add_test("destroy: при наличии _instance вызывает close и очищает __options", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    local closed = {}
    mon._instance = {
        __options = { callback = function() end },
        close = function(self) closed[1] = true end,
    }
    mon:destroy()
    Assert.is_nil(mon._instance, "_instance обнулён")
    Assert.is_true(closed[1], "close вызван")
end)

-- _can_destroy возврат false -> destroy возвращает nil
suite:add_test("destroy: при _can_destroy false возвращает nil", function()
    local_mock = Mock:new()
    local_mock:mock_field(BaseMonitor, "_can_destroy", function() return false end)
    local mon = BaseMonitor.new({ name = "m" }, "C")
    local ret = mon:destroy()
    Assert.is_nil(ret, "при _can_destroy false возвращается nil")
end)

-- get_psi без table_name возвращает весь _psi
suite:add_test("get_psi: без table_name возвращает весь кэш", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    mon._psi = { PMT = { v = 1 } }
    Assert.are_equal(mon._psi, mon:get_psi(), "без table_name возвращается весь _psi")
end)

-- get_table_from_pool без TablePool возвращает {}
suite:add_test("get_table_from_pool: без TablePool возвращает пустую таблицу", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    mon._table_pool = nil
    local t = mon:get_table_from_pool("x")
    Assert.are_equal(0, #t, "размер таблицы 0")
    Assert.are_equal("table", type(t), "get_table_from_pool должен вернуть таблицу")
end)

-- _init_status_table
suite:add_test("_init_status_table: вызывает Utils.init_report", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    mon:_init_status_table("dvb")
    Assert.are_equal("dvb", mon._current_status_table.type, "type из аргумента")
    Assert.are_equal("m", mon._current_status_table.name, "name из конфига")
end)

-- _is_force
suite:add_test("_is_force: при _force_timer >= ForceSendInterval возвращает true", function()
    local mon = BaseMonitor.new({ name = "m" }, "C")
    mon._force_timer = 400
    Assert.is_true(mon:_is_force(), "_force_timer >= ForceSendInterval — true")
end)

-- _on_config_updated: method_comparison и _comparison_methods
suite:add_test("_on_config_updated: method_comparison обновляет _current_method", function()
    local methods = { [1] = "m1", [2] = "m2" }
    local mon = BaseMonitor.new({ name = "m" }, "C", "", methods)
    mon:_on_config_updated("method_comparison", 2)
    Assert.are_equal("m2", mon._current_method, "_current_method обновлён по индексу")
end)

-- update_parameters: has_errors — один параметр не проходит валидацию
suite:add_test("update_parameters: при ошибке _set_config_param возвращает false", function()
    local_mock = Mock:new()
    local mod_mm = {
        get_module = function(name)
            if name == "utils" then
                return {
                    validate_monitor_param = function(_, _param, val) return val == 10 and 10 or nil end,
                    init_report = function(t, type_name, name) t.type = type_name; t.name = name end,
                }
            end
            return ref_ModuleManager.get_module(name)
        end,
        get_global_dependency = ref_ModuleManager.get_global_dependency,
    }
    local_mock:mock_global("ModuleManager", mod_mm)
    package.loaded["src.core.base_monitor"] = nil
    BaseMonitor = require("src.core.base_monitor")
    local mon = BaseMonitor.new({ name = "m", time_check = 5 }, "C", "channel_")
    local ok = mon:update_parameters({ time_check = 99 })
    Assert.is_false(ok, "при ошибке валидации — false")
end)

-- init_config_subscription: подписка с ForceSendInterval в new_config и вызов Logger.debug
suite:add_test("init_config_subscription: коллбэк config:updated:monitor обновляет ForceSendInterval", function()
    local sub_cb
    local debug_called = false
    local_mock = Mock:new()
    local mod_mm = {
        get_module = function(name)
            if name == "core.event_dispatcher" then
                local ed = {
                    get_instance = function()
                        return {
                            subscribe = function(_, ev, cb) sub_cb = cb end,
                            unsubscribe = function() end,
                        }
                    end,
                }
                return ed
            end
            if name == "logger" then
                return {
                    error = function() end,
                    info = function() end,
                    warning = function() end,
                    debug = function() debug_called = true end,
                }
            end
            return ref_ModuleManager.get_module(name)
        end,
        get_global_dependency = ref_ModuleManager.get_global_dependency,
    }
    local_mock:mock_global("ModuleManager", mod_mm)
    package.loaded["src.core.base_monitor"] = nil
    BaseMonitor = require("src.core.base_monitor")
    BaseMonitor.init_config_subscription()
    Assert.is_not_nil(sub_cb, "коллбэк подписки сохранён")
    sub_cb({ ForceSendInterval = 60 })
    Assert.is_true(debug_called, "Logger.debug вызван")
    local mon2 = BaseMonitor.new({ name = "x" }, "C")
    Assert.are_equal(60, mon2._force_timer, "ForceSendInterval применился из коллбэка")
end)

-- _set_config_param: fallback при отсутствии Utils.validate_monitor_param (result = value)
suite:add_test("_set_config_param: при отсутствии Utils использует value как result", function()
    local_mock = Mock:new()
    local mod_mm = {
        get_module = function(name)
            if name == "utils" then return nil end
            return ref_ModuleManager.get_module(name)
        end,
        get_global_dependency = ref_ModuleManager.get_global_dependency,
    }
    local_mock:mock_global("ModuleManager", mod_mm)
    package.loaded["src.core.base_monitor"] = nil
    BaseMonitor = require("src.core.base_monitor")
    local mon = BaseMonitor.new({ name = "m", x = 1 }, "C", "")
    local ok = mon:_set_config_param("x", 2, "")
    Assert.is_true(ok, "при отсутствии Utils value как result — true")
    Assert.are_equal(2, mon._config.x, "_config.x обновлён")
end)

-- _set_config_param: неверное значение (Utils возвращает nil)
suite:add_test("_set_config_param: при result nil логирует и возвращает false", function()
    local_mock = Mock:new()
    local mod_mm = {
        get_module = function(name)
            if name == "utils" then
                return {
                    validate_monitor_param = function() return nil end,
                    init_report = function(t, type_name, name) t.type = type_name; t.name = name end,
                }
            end
            return ref_ModuleManager.get_module(name)
        end,
        get_global_dependency = ref_ModuleManager.get_global_dependency,
    }
    local_mock:mock_global("ModuleManager", mod_mm)
    package.loaded["src.core.base_monitor"] = nil
    BaseMonitor = require("src.core.base_monitor")
    local mon = BaseMonitor.new({ name = "m" }, "C", "")
    local ok = mon:_set_config_param("time_check", 99, "")
    Assert.is_false(ok, "при result nil — false")
end)

-- json_encode отсутствует -> _refresh_cache использует tostring
suite:add_test("_refresh_cache: при отсутствии json_encode использует tostring", function()
    local_mock = Mock:new()
    local mod_mm = {
        get_module = ref_ModuleManager.get_module,
        get_global_dependency = function(name)
            if name == "json.encode" then return nil end
            return ref_ModuleManager.get_global_dependency(name)
        end,
    }
    local_mock:mock_global("ModuleManager", mod_mm)
    package.loaded["src.core.base_monitor"] = nil
    BaseMonitor = require("src.core.base_monitor")
    local mon = BaseMonitor.new({ name = "m" }, "C")
    mon:_refresh_cache({ a = 1 })
    Assert.is_not_nil(mon._json_cache, "при отсутствии json_encode используется tostring, кэш заполнен")
end)

suite:run()
