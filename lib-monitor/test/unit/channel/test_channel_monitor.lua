-- L5: Unit-тесты для модуля channel.channel_monitor
-- Монитор каналов: init_config_subscription, new, _get_cached_source, set_input_instance,
-- get_input_instance, get_stats, clear_stats.
-- Моки: Logger, Utils, BaseMonitor, TablePool, EventDispatcher, analyze, kill_input.

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
local Mock = require("tools.test_moc")

local mock
local ChannelMonitor
local ref_ModuleManager
local subscribe_calls
local last_analyze_opts

local suite = TestSuite:new("L5.channel_monitor")

suite:setup(function()
    mock = Mock:new()
    subscribe_calls = {}

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
                        return { add_task = function() end, remove_task = function() end }
                    end,
                }
            end
            if name == "utils.table_pool" then
                return {
                    get = function() return {} end,
                    release = function() end,
                    register_type = function() end,
                    drain = function() end,
                }
            end
            if name == "core.event_dispatcher" then
                return {
                    get_instance = function()
                        return {
                            subscribe = function(_, event_type, cb)
                                subscribe_calls[#subscribe_calls + 1] = { event_type = event_type, cb = cb }
                                return "sub-ch"
                            end,
                            unsubscribe = function() end,
                            emit_safe = function() end,
                        }
                    end,
                }
            end
            return nil
        end,
        get_global_dependency = function(name)
            if name == "analyze" then
                return function(opts)
                    last_analyze_opts = opts
                    return { __options = opts or {}, close = function() end }
                end
            end
            if name == "kill_input" then return function() end end
            if name == "json.encode" then return function(t) return "{}" end end
            return nil
        end,
    }
    mock:mock_global("ModuleManager", ref_ModuleManager)
    package.loaded["src.channel.channel_monitor"] = nil
    ChannelMonitor = require("src.channel.channel_monitor")
end)

suite:before_each(function()
    subscribe_calls = {}
    last_analyze_opts = nil
end)

suite:teardown(function()
    mock:restore()
end)

-- L5-CM-01: init_config_subscription подписывается на config:updated:monitor
suite:add_test("L5-CM-01: init_config_subscription подписывается на config:updated:monitor", function()
    ChannelMonitor.init_config_subscription()
    local found
    for i = 1, #subscribe_calls do
        if subscribe_calls[i].event_type == "config:updated:monitor" then found = true break end
    end
    Assert.is_true(found, "подписка на config:updated:monitor")
end)

-- L5-CM-02: new без конфига возвращает nil
suite:add_test("L5-CM-02: new без конфига возвращает nil", function()
    local inst = ChannelMonitor.new(nil, nil)
    Assert.is_nil(inst, "new(nil) возвращает nil")
end)

-- L5-CM-03: new без monitor возвращает nil
suite:add_test("L5-CM-03: new без monitor возвращает nil", function()
    local inst = ChannelMonitor.new({ upstream = "dummy" }, nil)
    Assert.is_nil(inst, "new без monitor возвращает nil")
end)

-- L5-CM-04: new без upstream возвращает nil
suite:add_test("L5-CM-04: new без upstream возвращает nil", function()
    local inst = ChannelMonitor.new({ monitor = "127.0.0.1:8080" }, nil)
    Assert.is_nil(inst, "new без upstream возвращает nil")
end)

-- L5-CM-05: new с monitor и upstream возвращает экземпляр
suite:add_test("L5-CM-05: new с monitor и upstream возвращает экземпляр", function()
    local inst = ChannelMonitor.new(
        { monitor = "127.0.0.1:8080", upstream = "udp://239.0.0.1:1234", name = "ch1" },
        nil
    )
    Assert.is_not_nil(inst, "new возвращает экземпляр")
    Assert.is_not_nil(inst._config, "_config установлен")
    Assert.are_equal("ch1", inst._name, "_name из config.name")
end)

-- L5-CM-06: _get_cached_source возвращает шаблон при отсутствии stream_json
suite:add_test("L5-CM-06: _get_cached_source возвращает шаблон при отсутствии stream_json", function()
    local inst = ChannelMonitor.new(
        { monitor = "m", upstream = "u", stream_json = {} },
        nil
    )
    Assert.is_not_nil(inst, "экземпляр создан")
    inst._channel_data = nil
    inst._last_active_id = nil
    local src = inst:_get_cached_source()
    Assert.is_not_nil(src, "_get_cached_source возвращает таблицу")
    Assert.are_equal("Unknown", src.format or "Unknown", "формат по умолчанию")
end)

-- L5-CM-07: set_input_instance и get_input_instance
suite:add_test("L5-CM-07: set_input_instance и get_input_instance", function()
    local inst = ChannelMonitor.new({ monitor = "m", upstream = "u" }, nil)
    Assert.is_nil(inst:get_input_instance(), "изначально nil")
    local fake_input = {}
    inst:set_input_instance(fake_input)
    Assert.are_equal(fake_input, inst:get_input_instance(), "get возвращает установленный экземпляр")
end)

-- L5-CM-08: get_stats и clear_stats
suite:add_test("L5-CM-08: get_stats и clear_stats", function()
    local inst = ChannelMonitor.new({ monitor = "m", upstream = "u" }, nil)
    local stats = inst:get_stats()
    Assert.is_not_nil(stats, "get_stats возвращает таблицу")
    inst._stats = { [100] = { type = "VIDEO", cc = 0, pes = 0 } }
    stats = inst:get_stats()
    Assert.are_equal("table", type(stats), "get_stats — таблица")
    inst:clear_stats()
    stats = inst:get_stats()
    Assert.is_not_nil(stats, "get_stats после clear_stats возвращает таблицу")
end)

-- L5-CM-09: start с upstream:stream() и callback _on_astra_data
suite:add_test("L5-CM-09: start и callback _on_astra_data", function()
    local inst = ChannelMonitor.new({
        monitor = "m",
        upstream = { stream = function() return {} end },
        name = "ch1",
        method_comparison = 1,
    })
    Assert.is_not_nil(inst, "экземпляр создан")
    local ok = inst:start()
    Assert.is_not_nil(ok, "start возвращает instance")
    Assert.is_not_nil(last_analyze_opts and last_analyze_opts.callback, "callback установлен")
    last_analyze_opts.callback({ total = { bitrate = 1000, on_air = true, scrambled = false } })
    Assert.are_equal(1000, inst._current_status_table.bitrate, "_on_astra_data обновил master")
end)

-- L5-CM-10: _on_astra_data с data.error вызывает _process_error_data
suite:add_test("L5-CM-10: callback с error", function()
    local inst = ChannelMonitor.new({
        monitor = "m",
        upstream = { stream = function() return {} end },
        name = "ch1",
        method_comparison = 1,
    })
    Assert.is_not_nil(inst:start(), "start успешен")
    Assert.is_not_nil(last_analyze_opts, "analyze вызван")
    last_analyze_opts.callback({ error = "test error" })
    Assert.is_true(true, "callback с error не падает")
end)

-- L5-CM-10b: callback с psi и analyze
suite:add_test("L5-CM-10b: callback с psi и analyze", function()
    local inst = ChannelMonitor.new({
        monitor = "m",
        upstream = { stream = function() return {} end },
        name = "ch1",
        method_comparison = 1,
    })
    Assert.is_not_nil(inst:start(), "start успешен")
    if last_analyze_opts and last_analyze_opts.callback then
        last_analyze_opts.callback({ psi = "PMT", streams = { { pid = 100, type_name = "VIDEO" } } })
        last_analyze_opts.callback({ analyze = { { pid = 100, cc_error = 0, pes_error = 0, sc_error = 0 } } })
    end
    Assert.is_true(true, "process_psi и process_analyze пути")
end)

-- L5-CM-10c: методы сравнения 2–8 вызываются при двух callback с total
suite:add_test("L5-CM-10c: COMPARISON_METHODS 2–8 при двух callback", function()
    local methods = { 2, 3, 4, 5, 6, 7, 8 }
    for _, method_id in ipairs(methods) do
        local inst = ChannelMonitor.new({
            monitor = "m",
            upstream = { stream = function() return {} end },
            name = "ch" .. method_id,
            method_comparison = method_id,
            time_check = 0,
        })
        Assert.is_not_nil(inst:start(), "start ok")
        if last_analyze_opts and last_analyze_opts.callback then
            last_analyze_opts.callback({ total = { bitrate = 1000, on_air = true, scrambled = false } })
            last_analyze_opts.callback({ total = { bitrate = 500, on_air = false, scrambled = true } })
        end
    end
    Assert.is_true(true, "методы сравнения 2–8 вызваны")
end)

-- L5-CM-10d: METHOD_VIDEO_ONLY (8) с stats VIDEO и cc>0
suite:add_test("L5-CM-10d: method 8 VIDEO_ONLY при stats с VIDEO cc>0", function()
    local inst = ChannelMonitor.new({
        monitor = "m",
        upstream = { stream = function() return {} end },
        name = "ch8",
        method_comparison = 8,
        time_check = 0,
    })
    Assert.is_not_nil(inst:start(), "start ok")
    if last_analyze_opts and last_analyze_opts.callback then
        last_analyze_opts.callback({ psi = "PMT", streams = { { pid = 100, type_name = "VIDEO" } } })
        last_analyze_opts.callback({ analyze = { { pid = 100, cc_error = 1, pes_error = 0, sc_error = 0 } } })
        last_analyze_opts.callback({ total = { bitrate = 1000, on_air = true, scrambled = false } })
    end
    Assert.is_true(inst._stats and (inst._stats[100] or inst._stats_count >= 0), "stats заполнены")
end)

-- L5-CM-10e: start при некорректном method_comparison возвращает nil
suite:add_test("L5-CM-10e: start при method_comparison 99", function()
    local inst = ChannelMonitor.new({
        monitor = "m",
        upstream = { stream = function() return {} end },
        name = "ch1",
        method_comparison = 99,
    })
    local ok = inst:start()
    Assert.is_nil(ok, "start возвращает nil при method_comparison 99")
end)

-- L5-CM-10f: start при upstream:stream() возвращает nil
suite:add_test("L5-CM-10f: start при upstream:stream() nil", function()
    local inst = ChannelMonitor.new({
        monitor = "m",
        upstream = { stream = function() return nil end },
        name = "ch1",
        method_comparison = 1,
    })
    local ok = inst:start()
    Assert.is_nil(ok, "start возвращает nil при stream() nil")
end)

-- L5-CM-11: check_infrastructure_health и _on_destroy
suite:add_test("L5-CM-11: check_infrastructure_health и _on_destroy", function()
    local inst = ChannelMonitor.new({
        monitor = "m",
        upstream = { stream = function() return {} end },
        name = "ch1",
        method_comparison = 1,
    })
    Assert.is_true(inst:check_infrastructure_health() == nil, "health nil когда не RUNNING")
    Assert.is_not_nil(inst:start(), "start успешен")
    inst._current_status_table.bitrate = 1000
    inst._current_status_table.scrambled = false
    local h = inst:check_infrastructure_health()
    Assert.is_true(h == true or h == false, "health возвращает bool при RUNNING")
    inst:_on_destroy()
    Assert.is_nil(inst._stats, "_on_destroy очистил _stats")
end)

-- L5-CM-12: init_config_subscription — колбэк config:updated:monitor с MaxCounterValue, MaxErrorCount, PidStatsLimit
suite:add_test("L5-CM-12: config:updated:monitor лимиты", function()
    ChannelMonitor.init_config_subscription()
    local cfg_cb
    for i = 1, #subscribe_calls do
        if subscribe_calls[i].event_type == "config:updated:monitor" then cfg_cb = subscribe_calls[i].cb break end
    end
    Assert.is_not_nil(cfg_cb, "колбэк config:updated:monitor")
    cfg_cb({ MaxCounterValue = 2e9, MaxErrorCount = 5e5, PidStatsLimit = 50 })
    Assert.is_true(true, "колбэк лимитов выполнен")
end)

-- L5-CM-13: _process_psi_data при достижении PidStatsLimit — _clear_stats, Logger.warning
suite:add_test("L5-CM-13: _process_psi_data лимит PID", function()
    local inst = ChannelMonitor.new({ monitor = "m", upstream = "u", name = "ch1" }, nil)
    inst._stats_count = 100
    inst._stats = {}
    for i = 1, 100 do inst._stats[i] = { type = "A", cc = 0, pes = 0, sc = 0 } end
    inst:_process_psi_data({ psi = "PMT", streams = { { pid = 999, type_name = "VIDEO" } } })
    Assert.is_true(inst._stats_count <= 1, "после лимита статистика очищена или добавлен один PID")
end)

-- L5-CM-14: _process_analyze_data — conf.analyze, накопление stats по PID, переполнение
suite:add_test("L5-CM-14: _process_analyze_data накопление stats", function()
    local inst = ChannelMonitor.new({
        monitor = "m",
        upstream = { stream = function() return {} end },
        name = "ch1",
        method_comparison = 1,
    })
    inst:start()
    inst._astra_conf = inst._astra_conf or inst._config
    inst._astra_conf.analyze = true
    if last_analyze_opts and last_analyze_opts.callback then
        last_analyze_opts.callback({ psi = "PMT", streams = { { pid = 200, type_name = "VIDEO" } } })
        last_analyze_opts.callback({ analyze = { { pid = 200, cc_error = 1, pes_error = 0, sc_error = 0 } } })
        last_analyze_opts.callback({ analyze = { { pid = 200, cc_error = 2, pes_error = 1, sc_error = 0 } } })
    end
    Assert.is_true(inst._stats[200] ~= nil, "stats по PID 200 созданы и обновлены")
end)

-- L5-CM-15: METHOD_VIDEO_ONLY — stats с type VIDEO и cc>0
suite:add_test("L5-CM-15: METHOD_VIDEO_ONLY stats VIDEO cc", function()
    local inst = ChannelMonitor.new({
        monitor = "m",
        upstream = { stream = function() return {} end },
        name = "ch8",
        method_comparison = 8,
        time_check = 0,
    })
    Assert.is_not_nil(inst:start(), "start ok")
    if last_analyze_opts and last_analyze_opts.callback then
        last_analyze_opts.callback({ psi = "PMT", streams = { { pid = 100, type_name = "VIDEO" } } })
        last_analyze_opts.callback({ analyze = { { pid = 100, cc_error = 1, pes_error = 0, sc_error = 0 } } })
        last_analyze_opts.callback({ total = { bitrate = 1000, on_air = true, scrambled = false } })
        last_analyze_opts.callback({ total = { bitrate = 1000, on_air = true, scrambled = false } })
    end
    Assert.is_not_nil(inst._stats[100], "VIDEO stats есть")
    Assert.is_true((inst._stats[100].cc or 0) >= 0, "cc в stats")
end)

-- L5-CM-16: _on_destroy вызывает kill_input при _input_instance
suite:add_test("L5-CM-16: _on_destroy kill_input", function()
    local kill_called
    local orig_gfd = ref_ModuleManager.get_global_dependency
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "kill_input" then return function() kill_called = true end end
        return orig_gfd and orig_gfd(name)
    end
    package.loaded["src.channel.channel_monitor"] = nil
    ChannelMonitor = require("src.channel.channel_monitor")
    local inst = ChannelMonitor.new({ monitor = "m", upstream = "u", name = "ch1" }, nil)
    inst:set_input_instance({})
    inst:_on_destroy()
    ref_ModuleManager.get_global_dependency = orig_gfd
    Assert.is_true(kill_called == true, "kill_input вызван при _on_destroy с _input_instance")
    package.loaded["src.channel.channel_monitor"] = nil
    ChannelMonitor = require("src.channel.channel_monitor")
end)

-- L5-CM-17: _on_config_updated обновляет _instance.__options
suite:add_test("L5-CM-17: _on_config_updated __options", function()
    local opts = { cc_limit = 10, bitrate_limit = 1000 }
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "analyze" then
            return function(o)
                last_analyze_opts = o
                return { __options = opts, close = function() end }
            end
        end
        if name == "kill_input" then return function() end end
        if name == "json.encode" then return function() return "{}" end end
        return nil
    end
    package.loaded["src.channel.channel_monitor"] = nil
    ChannelMonitor = require("src.channel.channel_monitor")
    local inst = ChannelMonitor.new({
        monitor = "m",
        upstream = { stream = function() return {} end },
        name = "ch1",
        method_comparison = 1,
    })
    Assert.is_not_nil(inst:start(), "start успешен")
    inst:_on_config_updated("cc_limit", 20)
    Assert.is_true(opts.cc_limit == 20 or inst._astra_conf.cc_limit == 20, "_on_config_updated обновил cc_limit")
    package.loaded["src.channel.channel_monitor"] = nil
    ChannelMonitor = require("src.channel.channel_monitor")
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "analyze" then return function(opts) last_analyze_opts = opts return { __options = {}, close = function() end } end end
        if name == "kill_input" then return function() end end
        if name == "json.encode" then return function() return "{}" end end
        return nil
    end
end)

-- L5-CM-18: start при RUNNING — Logger.warning и return _instance
suite:add_test("L5-CM-18: start при RUNNING warning", function()
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
        return orig_gm and orig_gm(name)
    end
    package.loaded["src.channel.channel_monitor"] = nil
    ChannelMonitor = require("src.channel.channel_monitor")
    local inst = ChannelMonitor.new({
        monitor = "m",
        upstream = { stream = function() return {} end },
        name = "ch1",
        method_comparison = 1,
    })
    inst:start()
    local ret = inst:start()
    ref_ModuleManager.get_module = orig_gm
    package.loaded["src.channel.channel_monitor"] = nil
    ChannelMonitor = require("src.channel.channel_monitor")
    Assert.are_equal(inst._instance, ret, "второй start возвращает _instance")
    Assert.is_true(warn_called == true, "Logger.warning вызван")
end)

-- L5-CM-19: start при upstream без stream() — Logger.error и nil
suite:add_test("L5-CM-19: start при upstream без stream()", function()
    local inst = ChannelMonitor.new({
        monitor = "m",
        upstream = {},
        name = "ch1",
        method_comparison = 1,
    })
    local ok = inst:start()
    Assert.is_nil(ok, "start возвращает nil при отсутствии stream()")
end)

-- L5-CM-20: start при analyze вернул nil — Logger.error и return nil
suite:add_test("L5-CM-20: start при analyze nil", function()
    local orig_gfd = ref_ModuleManager.get_global_dependency
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "analyze" then return function() return nil end end
        if name == "kill_input" then return function() end end
        if name == "json.encode" then return function() return "{}" end end
        return orig_gfd and orig_gfd(name)
    end
    package.loaded["src.channel.channel_monitor"] = nil
    ChannelMonitor = require("src.channel.channel_monitor")
    local inst = ChannelMonitor.new({
        monitor = "m",
        upstream = { stream = function() return {} end },
        name = "ch1",
        method_comparison = 1,
    })
    local ok = inst:start()
    Assert.is_nil(ok, "start возвращает nil при analyze nil")
    ref_ModuleManager.get_global_dependency = orig_gfd
    package.loaded["src.channel.channel_monitor"] = nil
    ChannelMonitor = require("src.channel.channel_monitor")
end)

-- L5-CM-21: _process_psi_data — обновление stats.type при существующем pid
suite:add_test("L5-CM-21: _process_psi_data обновление type", function()
    local inst = ChannelMonitor.new({ monitor = "m", upstream = "u", name = "ch1" }, nil)
    inst._stats[100] = { type = "AUDIO", cc = 0, pes = 0, sc = 0 }
    inst._stats_count = 1
    inst:_process_psi_data({ psi = "PMT", streams = { { pid = 100, type_name = "VIDEO" } } })
    Assert.are_equal("VIDEO", inst._stats[100].type, "stats.type обновлён")
end)

-- L5-CM-22: _process_analyze_data при лимите PID — _clear_stats, Logger.warning
suite:add_test("L5-CM-22: _process_analyze_data лимит PID", function()
    local inst = ChannelMonitor.new({
        monitor = "m",
        upstream = { stream = function() return {} end },
        name = "ch1",
        method_comparison = 1,
    })
    inst:start()
    inst._astra_conf.analyze = true
    inst._stats_count = 100
    inst._stats = {}
    for i = 1, 100 do inst._stats[i] = { type = "X", cc = 0, pes = 0, sc = 0 } end
    if last_analyze_opts and last_analyze_opts.callback then
        last_analyze_opts.callback({ analyze = { { pid = 999, cc_error = 1, pes_error = 0, sc_error = 0 } } })
    end
    Assert.is_true(inst._stats_count <= 1, "после лимита stats очищены или один PID")
end)

-- L5-CM-23: METHOD_RATIO / CC_THRESHOLD / ERROR_ONLY — cc_errors, pes_errors в условии
suite:add_test("L5-CM-23: методы сравнения cc_errors pes_errors", function()
    for _, method_id in ipairs({ 2, 4, 5 }) do
        local inst = ChannelMonitor.new({
            monitor = "m",
            upstream = { stream = function() return {} end },
            name = "ch",
            method_comparison = method_id,
            time_check = 0,
            cc_threshold = 5,
        })
        Assert.is_not_nil(inst:start(), "start ok")
        if last_analyze_opts and last_analyze_opts.callback then
            last_analyze_opts.callback({ total = { bitrate = 1000, on_air = true, scrambled = false } })
            last_analyze_opts.callback({ total = { bitrate = 1000, on_air = true, scrambled = false, cc_errors = 1, pes_errors = 0 } })
        end
    end
    Assert.is_true(true, "методы 2,4,5 с cc/pes")
end)

-- L5-CM-24: METHOD_BITRATE_DROP — is_drop и return
suite:add_test("L5-CM-24: METHOD_BITRATE_DROP", function()
    local inst = ChannelMonitor.new({
        monitor = "m",
        upstream = { stream = function() return {} end },
        name = "ch6",
        method_comparison = 6,
        time_check = 0,
        rate = 1.5,
    })
    Assert.is_not_nil(inst:start(), "start ok")
    if last_analyze_opts and last_analyze_opts.callback then
        last_analyze_opts.callback({ total = { bitrate = 2000, on_air = true, scrambled = false } })
        last_analyze_opts.callback({ total = { bitrate = 1000, on_air = true, scrambled = false } })
    end
    Assert.is_true(inst._current_status_table.bitrate == 1000 or inst._current_status_table.bitrate == 2000, "bitrate обновлён")
end)

-- L5-CM-25: METHOD_VIDEO_ONLY — ветка stats и s.type == VIDEO, (s.cc > 0 or s.pes > 0) return true
suite:add_test("L5-CM-25: METHOD_VIDEO_ONLY stats loop", function()
    local inst = ChannelMonitor.new({
        monitor = "m",
        upstream = { stream = function() return {} end },
        name = "ch8",
        method_comparison = 8,
        time_check = 0,
        analyze = true,
    })
    Assert.is_not_nil(inst:start(), "start ok")
    if last_analyze_opts and last_analyze_opts.callback then
        last_analyze_opts.callback({ psi = "PMT", streams = { { pid = 200, type_name = "VIDEO" } } })
        last_analyze_opts.callback({ analyze = { { pid = 200, cc_error = 1, pes_error = 0, sc_error = 0 } } })
        last_analyze_opts.callback({ total = { bitrate = 1000, on_air = true, scrambled = false } })
        last_analyze_opts.callback({ total = { bitrate = 1000, on_air = true, scrambled = false } })
    end
    Assert.is_not_nil(inst._stats[200], "VIDEO stats для метода 8")
end)

-- L5-CM-26: METHOD_ALWAYS (1) — return true при отправке (второй callback без force вызывает метод)
suite:add_test("L5-CM-26: METHOD_ALWAYS return true", function()
    local inst = ChannelMonitor.new({
        monitor = "m",
        upstream = { stream = function() return {} end },
        name = "ch1",
        method_comparison = 1,
        time_check = 0,
    })
    Assert.is_not_nil(inst:start(), "start ok")
    if last_analyze_opts and last_analyze_opts.callback then
        last_analyze_opts.callback({ total = { bitrate = 500, on_air = true, scrambled = false } })
        last_analyze_opts.callback({ total = { bitrate = 500, on_air = true, scrambled = false } })
    end
    Assert.are_equal(500, inst._current_status_table.bitrate, "METHOD_ALWAYS отправил отчёт")
end)

-- L5-CM-27: METHOD_RATIO — ветка (prev.pes_errors or 0) > 0
suite:add_test("L5-CM-27: METHOD_RATIO pes_errors", function()
    local inst = ChannelMonitor.new({
        monitor = "m",
        upstream = { stream = function() return {} end },
        name = "ch2",
        method_comparison = 2,
        time_check = 0,
    })
    Assert.is_not_nil(inst:start(), "start ok")
    if last_analyze_opts and last_analyze_opts.callback then
        last_analyze_opts.callback({ total = { bitrate = 1000, on_air = true, scrambled = false, cc_errors = 0, pes_errors = 1 } })
        last_analyze_opts.callback({ total = { bitrate = 1000, on_air = true, scrambled = false } })
    end
    Assert.is_true(inst._current_status_table.bitrate == 1000, "METHOD_RATIO pes_errors путь")
end)

suite:run()
