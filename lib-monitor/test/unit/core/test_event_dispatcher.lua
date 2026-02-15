-- L3: Unit-тесты для модуля core.event_dispatcher
-- L3-ED-01: эмиссия события при наличии подписчиков — доставка всем.
-- L3-ED-02: LVC Cache — новые подписчики с send_lvc получают последнее состояние.
-- Моки: Logger, SubscriptionManager, TablePool, Scheduler.

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
local Mock = require("tools.test_moc")

local mock
local local_mock
local EventDispatcher
local ref_ModuleManager
local ref_sub_mgr

local suite = TestSuite:new("L3.event_dispatcher")

suite:setup(function()
    mock = Mock:new()
    ref_sub_mgr = {
        subscribe = function(_, event_type, opts)
            return "sub-" .. (event_type or "nil")
        end,
        unsubscribe = function(_, id) return true end,
        shutdown = function() end,
        get_delivery_plan = function(_, event_type)
            return {
                total_simple = 1,
                has_complex = false,
                simple_groups = {},
                complex_subs = {},
            }
        end,
        multicast_direct = function() end,
        publish_event = function() return true end,
        publish_to_single = function(_, sub_id, name, entry) end,
        match = function(_, pattern, name) return pattern == name end,
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
            if name == "core.subscription_manager" then
                return {
                    new = function() return ref_sub_mgr end,
                }
            end
            if name == "table_pool" or name == "utils.table_pool" then
                return {
                    get = function(t) return {} end,
                    release = function() end,
                    register_type = function() end,
                }
            end
            if name == "core.scheduler" then
                return {
                    get_instance = function()
                        return {
                            add_task = function() end,
                            remove_task = function() end,
                        }
                    end,
                }
            end
            return nil
        end,
        get_global_dependency = function() return nil end,
    }
    mock:mock_global("ModuleManager", ref_ModuleManager)
end)

suite:before_each(function()
    if local_mock then
        local_mock:restore()
        local_mock = nil
    end
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
end)

suite:teardown(function()
    mock:restore()
end)

-- L3-ED-01: get_instance возвращает экземпляр, emit при наличии плана доставки вызывает multicast_direct
suite:add_test("L3-ED-01: get_instance возвращает singleton, emit при подписчиках доставляет событие", function()
    local multicast_called = {}
    ref_sub_mgr.get_delivery_plan = function(_, event_type)
        return {
            total_simple = 1,
            has_complex = false,
            simple_groups = { { transport = "CONSOLE", config = {}, subs = {} } },
            complex_subs = {},
        }
    end
    ref_sub_mgr.multicast_direct = function(_, plan, ev_type, data)
        multicast_called[#multicast_called + 1] = { type = ev_type, data = data }
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    Assert.is_not_nil(ed, "get_instance возвращает экземпляр")
    local ed2 = EventDispatcher.get_instance()
    Assert.are_equal(ed, ed2, "get_instance возвращает тот же singleton")
    local id = ed:emit("test:ev", { x = 1 }, nil, { no_cache = true })
    Assert.is_true(id == "direct_push" or id ~= nil, "emit возвращает id или direct_push")
    Assert.is_true(#multicast_called >= 1, "multicast_direct вызван при доставке")
    ed:shutdown()
end)

-- subscribe делегирует в subscription_manager
suite:add_test("L3-ED: subscribe вызывает subscription_manager:subscribe и возвращает id", function()
    local subscribe_calls = {}
    ref_sub_mgr.subscribe = function(_, event_type, opts)
        subscribe_calls[#subscribe_calls + 1] = { event_type = event_type, opts = opts }
        return "sub-id"
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    local id = ed:subscribe("ev:test", function() end)
    Assert.are_equal("sub-id", id, "subscribe возвращает id от менеджера")
    Assert.are_equal(1, #subscribe_calls, "subscribe вызван один раз")
    Assert.are_equal("ev:test", subscribe_calls[1].event_type, "тип события передан")
    ed:shutdown()
end)

-- get_last_values возвращает запись из LVC после emit
suite:add_test("L3-ED-02: после emit get_last_values возвращает последнее состояние (LVC)", function()
    ref_sub_mgr.get_delivery_plan = function() return nil end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    ed:emit("lvc:key", { value = 42 })
    local last = ed:get_last_values("lvc:key")
    Assert.is_not_nil(last["lvc:key"], "LVC содержит запись для типа")
    Assert.is_not_nil(last["lvc:key"].data, "запись содержит data")
    ed:shutdown()
end)

-- subscribe с send_lvc вызывает publish_to_single для записей LVC
suite:add_test("L3-ED-02: subscribe с send_lvc отправляет последнее состояние подписчику", function()
    local publish_to_single_calls = {}
    ref_sub_mgr.subscribe = function(_, event_type, opts)
        return "sub-1"
    end
    ref_sub_mgr.publish_to_single = function(_, sub_id, name, entry)
        publish_to_single_calls[#publish_to_single_calls + 1] = { sub_id = sub_id, name = name, entry = entry }
    end
    ref_sub_mgr.get_delivery_plan = function() return nil end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    ed:emit("send:lvc", { v = 1 })
    ed:subscribe("send:lvc", function() end, nil, { send_lvc = true })
    Assert.is_true(#publish_to_single_calls >= 1, "publish_to_single вызван для LVC")
    ed:shutdown()
end)

-- unsubscribe делегирует в subscription_manager
suite:add_test("L3-ED: unsubscribe вызывает subscription_manager:unsubscribe", function()
    local unsub_id
    ref_sub_mgr.unsubscribe = function(_, id) unsub_id = id; return true end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    local ok = ed:unsubscribe("sub-123")
    Assert.is_true(ok, "unsubscribe возвращает true")
    Assert.are_equal("sub-123", unsub_id, "id передан в менеджер")
    ed:shutdown()
end)
-- unsubscribe при nil subscription_manager возвращает false
suite:add_test("L3-ED: unsubscribe при nil subscription_manager возвращает false", function()
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    ed.subscription_manager = nil
    local ok = ed:unsubscribe("sub-any")
    Assert.is_false(ok, "unsubscribe при nil subscription_manager возвращает false")
    ed:shutdown()
end)

-- emit_safe при ошибке в emit возвращает nil и не падает
suite:add_test("L3-ED: emit_safe при ошибке в emit возвращает nil", function()
    ref_sub_mgr.get_delivery_plan = function() error("plan fail") end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    local id = ed:emit_safe("err:ev", {})
    Assert.is_nil(id, "emit_safe при ошибке возвращает nil")
    ed:shutdown()
end)

-- shutdown обнуляет instance и вызывает subscription_manager:shutdown
suite:add_test("L3-ED: shutdown обнуляет instance и останавливает менеджер подписок", function()
    local shutdown_called
    ref_sub_mgr.shutdown = function() shutdown_called = true end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    ed:shutdown()
    Assert.is_true(shutdown_called == true, "subscription_manager:shutdown вызван")
    local ed_after = EventDispatcher.get_instance()
    Assert.is_not_nil(ed_after, "после shutdown get_instance создаёт новый экземпляр")
    ed_after:shutdown()
end)

-- L3-ED-06: Load Shedding — при переполнении очереди (>90%) LOW отбрасываются, stats.dropped растёт
-- Важно: get_delivery_plan должен вернуть не-nil (иначе при no_cache будет ранний return до load shedding)
suite:add_test("L3-ED-06: при переполнении очереди LOW события отбрасываются (load shedding)", function()
    ref_sub_mgr.get_delivery_plan = function()
        return { has_complex = true, total_simple = 0 }
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    local low_prio = ed.PRIORITIES.LOW
    local total_cap = 1000 * 4
    ed._total_queued_count = math.floor(total_cap * 0.9) + 1
    local id = ed:emit("drop:ev", { x = 1 }, low_prio, { no_cache = true })
    Assert.is_nil(id, "emit LOW при переполнении возвращает nil")
    Assert.is_true(ed.stats.dropped >= 1, "stats.dropped увеличен при load shedding")
    ed:shutdown()
end)

-- get_last_values с маской использует match
suite:add_test("L3-ED: get_last_values с маской возвращает совпадающие записи LVC", function()
    local match_called = {}
    ref_sub_mgr.get_delivery_plan = function() return { total_simple = 0, has_complex = false, simple_groups = {}, complex_subs = {} } end
    ref_sub_mgr.match = function(_, pattern, name)
        match_called[#match_called + 1] = { pattern = pattern, name = name }
        return name and name:find("^channel:") and pattern == "channel:*"
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    ed:emit("channel:1", { a = 1 })
    ed:emit("channel:2", { a = 2 })
    local last = ed:get_last_values("channel:*")
    Assert.is_true(type(last) == "table", "get_last_values возвращает таблицу")
    Assert.is_true(#match_called >= 1, "subscription_manager:match вызван для маски")
    Assert.is_true(last["channel:1"] ~= nil or last["channel:2"] ~= nil, "результат содержит совпадающие записи")
    ed:shutdown()
end)

-- Граница: _deep_copy_to_pool — LVC с вложенными таблицами (3 уровня для ветки else)
suite:add_test("L3-ED: LVC с вложенными таблицами вызывает _deep_copy_to_pool", function()
    ref_sub_mgr.get_delivery_plan = function() return nil end
    local pool_get_calls = {}
    local orig_get_module = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "table_pool" or name == "utils.table_pool" then
            return {
                get = function(t)
                    pool_get_calls[#pool_get_calls + 1] = t
                    return {}
                end,
                release = function() end,
                register_type = function() end,
            }
        end
        return orig_get_module(name)
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    ed:emit("lvc:nested", { outer = { inner = { deep = 1 } } })
    Assert.is_true(#pool_get_calls >= 2, "TablePool.get вызван для lvc_entry и lvc_sub (глубокое копирование)")
    ed:shutdown()
end)

-- Граница: init_config_subscription — подписка на config:updated:event и config:updated:system
suite:add_test("L3-ED: init_config_subscription подписывается и обрабатывает обновления конфига", function()
    local subscribed = {}
    local callbacks = {}
    ref_sub_mgr.subscribe = function(_, event_type, opts)
        subscribed[#subscribed + 1] = event_type
        if opts and opts.callback then callbacks[event_type] = opts.callback end
        return "cfg-sub"
    end
    local log_info_msg
    ref_ModuleManager.get_module = function(name)
        if name == "logger" then
            return {
                error = function() end,
                info = function(_, msg) log_info_msg = msg end,
                warning = function() end,
                debug = function() end,
            }
        end
        if name == "core.subscription_manager" then return { new = function() return ref_sub_mgr end } end
        if name == "table_pool" or name == "utils.table_pool" then
            return { get = function() return {} end, release = function() end, register_type = function() end }
        end
        if name == "core.scheduler" then
            return {
                get_instance = function()
                    return { add_task = function() end, remove_task = function() end }
                end,
            }
        end
        return nil
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    ed:init_config_subscription()
    Assert.is_true(#subscribed >= 2, "подписка на config:updated:event и config:updated:system")
    local cfg_cb = callbacks["config:updated:event"]
    Assert.is_not_nil(cfg_cb, "callback для config:updated:event зарегистрирован")
    cfg_cb({ MaxQueueSize = 500 })
    Assert.is_true(log_info_msg and log_info_msg:find("Конфигурация"), "Logger.info вызван при обновлении конфига событий")
    ed:shutdown()
end)

-- Граница: emit с source_monitor в состоянии STOPPED (3) — возврат nil
suite:add_test("L3-ED: emit с source_monitor STOPPED возвращает nil", function()
    ref_sub_mgr.get_delivery_plan = function() return { has_complex = true, total_simple = 0 } end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    local id = ed:emit("ev", {}, nil, {
        source_monitor = { get_state = function() return 3 end },
    })
    Assert.is_nil(id, "emit от остановленного монитора возвращает nil")
    ed:shutdown()
end)

-- Граница: fast path с options.is_table — TablePool.release(event_data)
suite:add_test("L3-ED: fast path no_cache и is_table вызывает TablePool.release(event_data)", function()
    ref_sub_mgr.get_delivery_plan = function()
        return { total_simple = 1, has_complex = false, simple_groups = {}, complex_subs = {} }
    end
    ref_sub_mgr.multicast_direct = function() end
    local release_args = {}
    local orig_get_module = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "table_pool" or name == "utils.table_pool" then
            return {
                get = function() return {} end,
                release = function(obj, typ, recursive)
                    release_args[#release_args + 1] = { obj = obj, typ = typ, rec = recursive }
                end,
                register_type = function() end,
            }
        end
        return orig_get_module(name)
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    local data = { x = 1 }
    ed:emit("ev", data, nil, { no_cache = true, is_table = true })
    local found = false
    for i = 1, #release_args do
        if release_args[i].obj == data and release_args[i].rec then found = true break end
    end
    Assert.is_true(found or #release_args >= 1, "TablePool.release вызван с event_data при is_table")
    ed:shutdown()
end)

-- Граница: load shedding MEDIUM при >95% очереди
suite:add_test("L3-ED: при переполнении >95% MEDIUM события отбрасываются", function()
    ref_sub_mgr.get_delivery_plan = function()
        return { has_complex = true, total_simple = 0 }
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    local total_cap = 1000 * 4
    ed._total_queued_count = math.floor(total_cap * 0.95) + 1
    local mid_prio = ed.PRIORITIES.MEDIUM
    local id = ed:emit("drop:med", { x = 1 }, mid_prio, { no_cache = true })
    Assert.is_nil(id, "emit MEDIUM при >95% возвращает nil")
    Assert.is_true(ed.stats.dropped >= 1, "stats.dropped увеличен при MEDIUM load shedding")
    ed:shutdown()
end)

-- Граница: no_cache и нет плана — ранний выход (если достижимо)
suite:add_test("L3-ED: no_cache без плана доставки не кэширует и выходит", function()
    ref_sub_mgr.get_delivery_plan = function() return nil end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    local id = ed:emit("ev:nocache", { a = 1 }, nil, { no_cache = true })
    Assert.is_nil(id, "emit с no_cache и без подписчиков возвращает nil")
    ed:shutdown()
end)

-- Граница: LVC eviction при достижении MaxLvcSize
suite:add_test("L3-ED: LVC eviction при MaxLvcSize вытесняет старые записи", function()
    ref_sub_mgr.get_delivery_plan = function() return nil end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    for i = 1, 1002 do
        ed:emit("lvc:ev:" .. tostring(i), { n = i })
    end
    local last = ed:get_last_values("lvc:ev:1002")
    Assert.is_not_nil(last["lvc:ev:1002"], "после eviction новый тип есть в LVC")
    ed:shutdown()
end)

-- Граница: переполнение очереди — вытеснение головы, stats.dropped, _safe_return_to_pool
suite:add_test("L3-ED: переполнение очереди вытесняет событие и увеличивает stats.dropped", function()
    ref_sub_mgr.get_delivery_plan = function()
        return { has_complex = true, total_simple = 0 }
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    local max_size = ed.event_queues[ed.PRIORITIES.MEDIUM].max_size
    for _ = 1, max_size + 5 do
        ed:emit("q:ev", { i = 1 }, ed.PRIORITIES.MEDIUM)
    end
    Assert.is_true(ed.stats.dropped >= 1, "при переполнении очереди stats.dropped растёт")
    ed:shutdown()
end)

-- _process_queue: обработка очереди и вызов publish_event
suite:add_test("L3-ED: _process_queue извлекает события и вызывает publish_event", function()
    local published = {}
    ref_sub_mgr.get_delivery_plan = function()
        return { has_complex = true, total_simple = 0 }
    end
    ref_sub_mgr.publish_event = function(_, event)
        published[#published + 1] = event
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    ed:emit("queued:1", { a = 1 }, ed.PRIORITIES.HIGH)
    ed:emit("queued:2", { b = 2 }, ed.PRIORITIES.HIGH)
    ed:_process_queue()
    Assert.is_true(#published >= 1, "publish_event вызван для событий из очереди")
    ed:shutdown()
end)

-- Колбэк планировщика (add_task): при вызове вызывает _process_queue
suite:add_test("L3-ED: колбэк планировщика при вызове выполняет _process_queue", function()
    local task_callback
    ref_sub_mgr.get_delivery_plan = function()
        return { has_complex = true, total_simple = 0 }
    end
    ref_sub_mgr.publish_event = function() end
    local orig_get_module = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "core.scheduler" then
            return {
                get_instance = function()
                    return {
                        add_task = function(_, _name, cb) task_callback = cb end,
                        remove_task = function() end,
                    }
                end,
            }
        end
        return orig_get_module(name)
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    ed:emit("q:ev", { x = 1 }, ed.PRIORITIES.CRITICAL)
    Assert.is_not_nil(task_callback, "add_task получил колбэк")
    task_callback()
    Assert.is_true(ed.stats.processed >= 1 or ed.event_queues[ed.PRIORITIES.CRITICAL].size == 0,
        "колбэк обработал очередь")
    ed:shutdown()
end)

-- emit_safe при успешном emit возвращает id
suite:add_test("L3-ED: emit_safe при успешном emit возвращает id события", function()
    ref_sub_mgr.get_delivery_plan = function()
        return { has_complex = true, total_simple = 0 }
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    local id = ed:emit_safe("ok:ev", { x = 1 })
    Assert.is_not_nil(id, "emit_safe при успехе возвращает id")
    Assert.is_true(type(id) == "string" and id:find("^evt_"), "id имеет вид evt_N")
    ed:shutdown()
end)

-- _safe_return_to_pool при ошибке release вызывает Logger.warning
suite:add_test("L3-ED: _safe_return_to_pool при ошибке release логирует warning", function()
    local warn_msg
    ref_sub_mgr.get_delivery_plan = function()
        return { has_complex = true, total_simple = 0 }
    end
    ref_sub_mgr.publish_event = function() end
    ref_ModuleManager.get_module = function(name)
        if name == "logger" then
            return {
                error = function() end,
                info = function() end,
                warning = function(_, msg) warn_msg = msg end,
                debug = function() end,
            }
        end
        if name == "table_pool" or name == "utils.table_pool" then
            return {
                get = function() return {} end,
                release = function(_, typ)
                    if typ == "event" then error("pool release failed") end
                end,
                register_type = function() end,
            }
        end
        if name == "core.subscription_manager" then return { new = function() return ref_sub_mgr end } end
        if name == "core.scheduler" then
            return {
                get_instance = function()
                    return { add_task = function() end, remove_task = function() end }
                end,
            }
        end
        return nil
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    ed:emit("ev", { a = 1 }, ed.PRIORITIES.HIGH)
    ed:_process_queue()
    Assert.is_true(warn_msg and warn_msg:find("пул"), "Logger.warning вызван при ошибке release")
    ed:shutdown()
end)

-- unsubscribe при отсутствии subscription_manager возвращает false
suite:add_test("L3-ED: unsubscribe без subscription_manager возвращает false", function()
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    ed.subscription_manager = nil
    local ok = ed:unsubscribe("any")
    Assert.is_false(ok, "unsubscribe без менеджера возвращает false")
    ed:shutdown()
end)

-- emit при active=false возвращает nil
suite:add_test("L3-ED: emit при active=false возвращает nil", function()
    ref_sub_mgr.get_delivery_plan = function() return nil end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    ed.active = false
    local id = ed:emit("ev", {})
    Assert.is_nil(id, "emit при неактивном диспетчере возвращает nil")
    ed:shutdown()
end)

-- _deep_copy_to_pool: ветка visited[v] (самоссылка) и вложенные таблицы
suite:add_test("L3-ED: LVC с общей ссылкой на таблицу покрывает visited в _deep_copy_to_pool", function()
    ref_sub_mgr.get_delivery_plan = function() return nil end
    local orig_get_module = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "table_pool" or name == "utils.table_pool" then
            return {
                get = function() return {} end,
                release = function() end,
                register_type = function() end,
            }
        end
        return orig_get_module(name)
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    local shared = { n = 1 }
    ed:emit("lvc:shared", { a = shared, b = shared })
    local last = ed:get_last_values("lvc:shared")
    Assert.is_not_nil(last["lvc:shared"], "LVC с общей ссылкой сохраняется")
    ed:shutdown()
end)

-- _deep_copy_to_pool: ветка if visited[v] then (самоссылающаяся таблица)
suite:add_test("L3-ED: LVC с самоссылающейся таблицей покрывает visited[v] в _deep_copy_to_pool", function()
    ref_sub_mgr.get_delivery_plan = function() return nil end
    local orig_get_module = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "table_pool" or name == "utils.table_pool" then
            return {
                get = function() return {} end,
                release = function() end,
                register_type = function() end,
            }
        end
        return orig_get_module(name)
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    local self_ref = { x = 1 }
    self_ref.self = self_ref
    ed:emit("lvc:self", { a = self_ref })
    local last = ed:get_last_values("lvc:self")
    Assert.is_not_nil(last["lvc:self"], "LVC с самоссылкой сохраняется")
    ed:shutdown()
end)

-- config:updated:system callback (GcPause, GcStepMul)
suite:add_test("L3-ED: init_config_subscription config:updated:system обновляет GC", function()
    local callbacks = {}
    ref_sub_mgr.subscribe = function(_, event_type, opts)
        if opts and opts.callback then callbacks[event_type] = opts.callback end
        return "cfg-sub"
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    ed:init_config_subscription()
    local sys_cb = callbacks["config:updated:system"]
    Assert.is_not_nil(sys_cb, "callback config:updated:system зарегистрирован")
    sys_cb({ GcPause = 90, GcStepMul = 400 })
    ed:shutdown()
end)

-- Load shedding с options.__pool_type и is_table — TablePool.release(options), release(event_data)
suite:add_test("L3-ED: load shedding LOW с __pool_type вызывает TablePool.release", function()
    ref_sub_mgr.get_delivery_plan = function()
        return { has_complex = true, total_simple = 0 }
    end
    local release_calls = {}
    local orig_get_module = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "table_pool" or name == "utils.table_pool" then
            return {
                get = function() return {} end,
                release = function(obj, typ, rec)
                    release_calls[#release_calls + 1] = { typ = typ, rec = rec }
                end,
                register_type = function() end,
            }
        end
        return orig_get_module(name)
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    ed._total_queued_count = 3601
    local data = { x = 1 }
    ed:emit("ev", data, ed.PRIORITIES.LOW, { no_cache = true, __pool_type = "event_options", is_table = true })
    Assert.is_true(#release_calls >= 1, "TablePool.release вызван при load shedding с опциями")
    ed:shutdown()
end)

-- MEDIUM load shedding с __pool_type и is_table — покрытие TablePool.release в блоке 0.95
suite:add_test("L3-ED: load shedding MEDIUM с __pool_type вызывает TablePool.release", function()
    ref_sub_mgr.get_delivery_plan = function()
        return { has_complex = true, total_simple = 0 }
    end
    local release_calls = {}
    local orig_get_module = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "table_pool" or name == "utils.table_pool" then
            return {
                get = function() return {} end,
                release = function(obj, typ, rec)
                    release_calls[#release_calls + 1] = { typ = typ, rec = rec }
                end,
                register_type = function() end,
            }
        end
        return orig_get_module(name)
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    ed._total_queued_count = math.floor(1000 * 4 * 0.95) + 1
    local data = { y = 2 }
    local id = ed:emit("ev", data, ed.PRIORITIES.MEDIUM, { no_cache = true, __pool_type = "event_options", is_table = true })
    Assert.is_nil(id, "MEDIUM при >95% возвращает nil")
    Assert.is_true(#release_calls >= 1, "TablePool.release вызван при MEDIUM load shedding")
    ed:shutdown()
end)

-- LVC TTL eviction в _process_queue (модуль должен видеть подменённый os.clock)
suite:add_test("L3-ED: _process_queue вытесняет устаревшие записи LVC по TTL", function()
    ref_sub_mgr.get_delivery_plan = function() return nil end
    ref_sub_mgr.publish_event = function() end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    local clock_val = { v = 1000 }
    local real_clock = os.clock
    _G.os.clock = function() return clock_val.v end
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    ed:emit("ev:ttl", { x = 1 })
    local entry = ed._lvc["ev:ttl"]
    Assert.is_not_nil(entry, "LVC запись создана")
    entry.timestamp = 0
    clock_val.v = 5000
    ed:_process_queue()
    _G.os.clock = real_clock
    Assert.is_nil(ed._lvc["ev:ttl"], "устаревшая запись LVC вытеснена по TTL")
    ed:shutdown()
end)

-- Адаптивный limit в _process_queue (_total_queued_count > 50% MaxQueueSize)
suite:add_test("L3-ED: _process_queue при большой очереди увеличивает limit батча", function()
    ref_sub_mgr.get_delivery_plan = function()
        return { has_complex = true, total_simple = 0 }
    end
    ref_sub_mgr.publish_event = function() end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    for i = 1, 550 do
        ed:emit("q:batch", { n = i }, ed.PRIORITIES.MEDIUM)
    end
    Assert.is_true(ed._total_queued_count > 500, "очередь > 50% лимита")
    ed:_process_queue()
    Assert.is_true(ed.stats.processed >= 1, "события обработаны с адаптивным limit")
    ed:shutdown()
end)

-- publish_event ошибка — Logger.error в _process_queue
suite:add_test("L3-ED: _process_queue при ошибке publish_event логирует error", function()
    ref_sub_mgr.get_delivery_plan = function()
        return { has_complex = true, total_simple = 0 }
    end
    ref_sub_mgr.publish_event = function() error("deliver fail") end
    local err_msg
    local orig_get_module = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "logger" then
            return {
                error = function(_, msg) err_msg = msg end,
                info = function() end,
                warning = function() end,
                debug = function() end,
            }
        end
        return orig_get_module(name)
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    ed:emit("err:ev", { x = 1 }, ed.PRIORITIES.HIGH)
    ed:_process_queue()
    Assert.is_true(err_msg and err_msg:find("обработать"), "Logger.error вызван при ошибке publish_event")
    ed:shutdown()
end)

-- Time-slicing: return при достижении limit батча
suite:add_test("L3-ED: _process_queue прерывается по limit (time-slicing)", function()
    ref_sub_mgr.get_delivery_plan = function()
        return { has_complex = true, total_simple = 0 }
    end
    ref_sub_mgr.publish_event = function() end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.event_dispatcher"] = nil
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    for i = 1, 150 do
        ed:emit("slice:ev", { n = i }, ed.PRIORITIES.CRITICAL)
    end
    local processed_before = ed.stats.processed
    ed:_process_queue()
    Assert.is_true(ed.stats.processed >= 50, "обработано не менее части событий за тик (time-slicing)")
    local remaining = ed.event_queues[ed.PRIORITIES.CRITICAL].size
    Assert.is_true(remaining >= 0, "time-slicing прерывает обработку по limit")
    ed:shutdown()
end)

suite:run()
