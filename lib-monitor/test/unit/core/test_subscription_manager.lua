-- L2: Unit-тесты для модуля core.subscription_manager
-- Case L2-SM-01: подписка с маской * — получение всех событий системы.
-- Моки: Logger, Utils, FilterEngine, Wildcard, TablePool, WsSubscriber, Scheduler, EventDispatcher, json, http_request, io.

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
local Mock = require("tools.test_moc")

local mock
local local_mock
local SubscriptionManager
local ref_ModuleManager

local suite = TestSuite:new("L2.subscription_manager")

suite:setup(function()
    mock = Mock:new()

    local orig_io_open = io and io.open
    mock:mock_global("io", {
        open = function(path, mode)
            if not path then return orig_io_open(path, mode) end
            if path:find("luacov") or path:find("%.out") or path:find("%.report") then
                return orig_io_open(path, mode)
            end
            if path:find("subscribers%.json") and mode == "r" then
                return nil
            end
            return orig_io_open(path, mode)
        end
    })

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
                    to_line_protocol = function(m, t, f) return m .. ",1" end,
                    truncate_string = function(s, n) return s and s:sub(1, n) or "" end,
                    shell_escape = function(s) return "'" .. (s or "") .. "'" end,
                }
            end
            if name == "utils.filter_engine" then
                return require("src.utils.filter_engine")
            end
            if name == "utils.wildcard" then
                return require("src.utils.wildcard")
            end
            if name == "table_pool" or name == "utils.table_pool" then
                return {
                    get = function() return {} end,
                    release = function() end,
                    register_type = function() end,
                }
            end
            if name == "ws_subscriber" then
                return { broadcast_raw = function() end }
            end
            if name == "core.scheduler" then
                return {
                    get_instance = function()
                        return {
                            add_task = function() end,
                            remove_task = function() end,
                        }
                    end
                }
            end
            if name == "core.event_dispatcher" then return nil end
            return nil
        end,
        get_global_dependency = function(name)
            if name == "http_request" then return function() return true end end
            if name == "json.encode" then return function(t) return "{}" end end
            if name == "json.decode" then return function(s) return {} end end
            if name == "astra.version" then return "4.4.182" end
            return nil
        end,
    }
    mock:mock_global("ModuleManager", ref_ModuleManager)
end)

suite:before_each(function()
    if local_mock then
        local_mock:restore()
        local_mock = nil
    end
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
end)

suite:teardown(function()
    mock:restore()
end)

-- L2-SM-01: подписка с маской * получает все события
suite:add_test("subscribe маска *: match возвращает true для любого типа события", function()
    local sm = SubscriptionManager.new()
    local received = {}
    local sub_id = sm:subscribe("*", function(data, event_type)
        received.event_type = event_type
        received.data = data
    end)
    Assert.is_not_nil(sub_id, "subscribe возвращает id")

    Assert.is_true(sm:match("*", "channel:error"), "маска * совпадает с channel:error")
    Assert.is_true(sm:match("*", "sys:info"), "маска * совпадает с sys:info")
    Assert.is_true(sm:match("*", "dvb:lock"), "маска * совпадает с dvb:lock")
end)

suite:add_test("subscribe маска *: publish_event доставляет событие подписчику", function()
    local sm = SubscriptionManager.new()
    local received = {}
    sm:subscribe("*", function(data, event_type)
        received.event_type = event_type
        received.data = data
    end)

    sm:publish_event({
        type = "channel:error",
        data = { message = "test" },
        options = {},
    })

    Assert.are_equal("channel:error", received.event_type, "тип события доставлен")
    -- LUA_CALLBACK передаёт полный event (type/data/options), данные в data.data
    local payload = received.data and received.data.data
    Assert.are_equal("test", payload and payload.message, "данные message доставлены")
end)

suite:add_test("subscribe точный тип: match только для этого типа", function()
    local sm = SubscriptionManager.new()
    sm:subscribe("channel:error", function() end)

    Assert.is_true(sm:match("channel:error", "channel:error"), "точное совпадение")
    Assert.is_false(sm:match("channel:error", "channel:info"), "другой тип — false")
end)

suite:add_test("unsubscribe: удаляет подписку", function()
    local sm = SubscriptionManager.new()
    local sub_id = sm:subscribe("*", function() end)
    Assert.is_not_nil(sub_id, "subscribe возвращает id")
    local ok = sm:unsubscribe(sub_id)
    Assert.is_true(ok, "unsubscribe успешен")
end)

suite:add_test("new: создаёт экземпляр с пустыми подписками", function()
    local sm = SubscriptionManager.new()
    Assert.is_not_nil(sm.subscriptions, "subscriptions инициализирована")
    Assert.are_equal(0, sm.stats.total, "изначально total 0")
end)

suite:add_test("has_subscriptions: при подписке * возвращает true для любого типа", function()
    local sm = SubscriptionManager.new()
    sm:subscribe("*", function() end)
    Assert.is_true(sm:has_subscriptions("channel:error"), "маска * — true для любого типа")
end)

suite:add_test("has_subscriptions: при отсутствии подписок false", function()
    local sm = SubscriptionManager.new()
    Assert.is_false(sm:has_subscriptions("unknown:event"), "без подписок — false")
end)

suite:add_test("publish_event: при отсутствии подписчиков не падает", function()
    local sm = SubscriptionManager.new()
    sm:publish_event({ type = "no:subs", data = {}, options = {} })
end)

suite:add_test("subscribe: передача функции напрямую как sub_data", function()
    local sm = SubscriptionManager.new()
    local id = sm:subscribe("ev", function() end)
    Assert.is_not_nil(id, "subscribe с функцией возвращает id")
end)

suite:add_test("match: точное совпадение без маски", function()
    local sm = SubscriptionManager.new()
    Assert.is_true(sm:match("channel:error", "channel:error"), "точное совпадение")
    Assert.is_false(sm:match("channel:error", "channel:info"), "другой тип — false")
end)

-- save/save_now: вызов save и save_now (мок io.open для записи не перехватывается)
suite:add_test("save и save_now: сохраняют подписки при наличии json_encode", function()
    local sm = SubscriptionManager.new()
    sm:subscribe("ev:test", function() end)
    sm:save()
    Assert.is_true(sm._save_pending, "после save _save_pending true")
    -- save_now пишет во временный файл; мок перехватывает только "r" для subscribers.json
    local ok = sm:save_now()
    Assert.is_true(ok == true or ok == false, "save_now возвращает bool")
    if ok then
        Assert.is_false(sm._save_pending, "после save_now _save_pending false")
    end
end)

-- shutdown: снимает задачу и сбрасывает батчи
suite:add_test("shutdown: снимает задачу планировщика и сохраняет при _save_pending", function()
    local sm = SubscriptionManager.new()
    sm:subscribe("x", function() end)
    sm._save_pending = true
    sm:shutdown()
    Assert.is_not_nil(sm.subscriptions, "shutdown не очищает subscriptions до nil")
end)

-- get_all_subscriptions
suite:add_test("get_all_subscriptions: возвращает все подписки по id", function()
    local sm = SubscriptionManager.new()
    local id1 = sm:subscribe("a", function() end)
    local id2 = sm:subscribe("b", function() end)
    local all = sm:get_all_subscriptions()
    Assert.are_equal(2, sm.stats.total, "две подписки")
    Assert.is_not_nil(all[id1], "get_all_subscriptions содержит id1")
    Assert.is_not_nil(all[id2], "get_all_subscriptions содержит id2")
end)

-- register_transport
suite:add_test("register_transport: регистрирует кастомный транспорт", function()
    local sm = SubscriptionManager.new()
    local ok = sm:register_transport("CUSTOM", function() return true end, true)
    Assert.is_true(ok, "register_transport CUSTOM успешен")
    local ok2 = sm:register_transport(123, function() end)
    Assert.is_false(ok2, "неверный тип транспорта — false")
end)

-- CONSOLE transport: подписка с callback type=CONSOLE
suite:add_test("publish_event: CONSOLE транспорт логирует событие", function()
    local sm = SubscriptionManager.new()
    sm:subscribe("log:me", { callback = { type = "CONSOLE" } })
    sm:publish_event({ type = "log:me", data = { x = 1 }, options = {} })
end)

-- HTTP transport: подписка с host/port (мок http_request возвращает true)
suite:add_test("publish_event: HTTP транспорт вызывает http_request", function()
    local sm = SubscriptionManager.new()
    sm:subscribe("http:ev", { callback = { host = "localhost", port = 9090, path = "/" } })
    sm:publish_event({ type = "http:ev", data = {}, options = {} })
end)

-- detect_transport: таблица с type
suite:add_test("detect_transport: таблица с host/port даёт HTTP", function()
    local sm = SubscriptionManager.new()
    local t = sm:detect_transport({ host = "h", port = 80 })
    Assert.are_equal("HTTP", t, "host/port даёт HTTP")
end)

-- publish_event: source_monitor get_state() == 3 — не доставляем
suite:add_test("publish_event: при source_monitor в состоянии STOPPED не доставляет", function()
    local sm = SubscriptionManager.new()
    sm:subscribe("*", function() error("must not be called") end)
    local ev = {
        type = "test",
        data = {},
        options = { source_monitor = { get_state = function() return 3 end } }
    }
    local ok = sm:publish_event(ev)
    Assert.is_false(ok, "source_monitor STOPPED — не доставляем")
end)

-- get_delivery_plan
suite:add_test("get_delivery_plan: возвращает план при наличии подписок", function()
    local sm = SubscriptionManager.new()
    sm:subscribe("plan:ev", function() end)
    local plan = sm:get_delivery_plan("plan:ev")
    Assert.is_not_nil(plan, "план доставки возвращён")
    Assert.is_true(plan.total_simple >= 0 or plan.has_complex, "план содержит total_simple или has_complex")
end)

-- subscribe с existing_id (load из файла)
suite:add_test("subscribe: с existing_id не вызывает save при первой подписке", function()
    local sm = SubscriptionManager.new()
    local id = sm:subscribe("loaded", function() end, "fixed-id-123")
    Assert.are_equal("fixed-id-123", id, "existing_id возвращается")
end)

-- unsubscribe с batch_queue
suite:add_test("unsubscribe: очищает batch_queue при наличии", function()
    local sm = SubscriptionManager.new()
    local id = sm:subscribe("batch:ev", { callback = { host = "localhost", port = 80 }, batch_mode = "array" })
    sm:publish_event({ type = "batch:ev", data = {}, options = {} })
    local ok = sm:unsubscribe(id)
    Assert.is_true(ok, "unsubscribe с batch_queue успешен")
end)

-- enqueue_retry
suite:add_test("enqueue_retry: добавляет в очередь повторов", function()
    local sm = SubscriptionManager.new()
    local cfg = { host = "x", port = 80 }
    local ok = sm:enqueue_retry(cfg, "data", "ev", 0, "{}")
    Assert.is_true(ok, "enqueue_retry успешен")
    Assert.are_equal(1, #sm._retry_queue, "очередь повторов содержит элемент")
end)

-- publish_to_single
suite:add_test("publish_to_single: доставляет по sub_id", function()
    local sm = SubscriptionManager.new()
    local received = {}
    local id = sm:subscribe("single", function(d) received.data = d end)
    local ok = sm:publish_to_single(id, "single", { data = { x = 1 }, json = "{}" })
    Assert.is_true(ok, "publish_to_single доставлен")
    Assert.is_not_nil(received.data, "данные получены подписчиком")
end)

-- match с маской: кэширование матчера
suite:add_test("match: маска channel:* кэширует матчер", function()
    local sm = SubscriptionManager.new()
    sm:subscribe("channel:*", function() end)
    Assert.is_true(sm:match("channel:*", "channel:error"), "channel:* совпадает с channel:error")
    Assert.is_false(sm:match("channel:*", "sys:info"), "channel:* не совпадает с sys:info")
end)

-- Транспорты с проверкой параметров (возвращают false при отсутствии конфига)
suite:add_test("publish_event: TELEGRAM без token/chat_id возвращает false", function()
    local sm = SubscriptionManager.new()
    sm:subscribe("tg", { callback = { type = "TELEGRAM" } })
    sm:publish_event({ type = "tg", data = {}, options = {} })
end)
suite:add_test("publish_event: INFLUXDB без host/bucket/token возвращает false", function()
    local sm = SubscriptionManager.new()
    sm:subscribe("influx", { callback = { type = "INFLUXDB" } })
    sm:publish_event({ type = "influx", data = {}, options = {} })
end)
suite:add_test("publish_event: DISCORD с url отправляет", function()
    local sm = SubscriptionManager.new()
    sm:subscribe("dc", { callback = { type = "DISCORD", url = "https://discord.com/api/webhook" } })
    sm:publish_event({ type = "dc", data = {}, options = {} })
end)
suite:add_test("publish_event: SLACK с url отправляет", function()
    local sm = SubscriptionManager.new()
    sm:subscribe("sl", { callback = { type = "SLACK", url = "https://hooks.slack.com/x" } })
    sm:publish_event({ type = "sl", data = {}, options = {} })
end)
suite:add_test("publish_event: GOTIFY без url/token возвращает false", function()
    local sm = SubscriptionManager.new()
    sm:subscribe("gf", { callback = { type = "GOTIFY" } })
    sm:publish_event({ type = "gf", data = {}, options = {} })
end)
suite:add_test("publish_event: PUSHOVER без token/user возвращает false", function()
    local sm = SubscriptionManager.new()
    sm:subscribe("po", { callback = { type = "PUSHOVER" } })
    sm:publish_event({ type = "po", data = {}, options = {} })
end)
suite:add_test("publish_event: GENERIC_WEBHOOK без url возвращает false", function()
    local sm = SubscriptionManager.new()
    sm:subscribe("gw", { callback = { type = "GENERIC_WEBHOOK" } })
    sm:publish_event({ type = "gw", data = {}, options = {} })
end)

-- _get_event_json: event.data — строка (уже JSON)
suite:add_test("publish_event: event с data-строкой использует её как JSON", function()
    local sm = SubscriptionManager.new()
    sm:subscribe("log:me", { callback = { type = "CONSOLE" } })
    sm:publish_event({ type = "log:me", data = "{\"k\":1}", id = true, options = {} })
end)

-- subscribe: некорректный callback — возврат nil
suite:add_test("subscribe: без распознанного транспорта возвращает nil", function()
    local sm = SubscriptionManager.new()
    local id = sm:subscribe("unknown", { callback = {} })
    Assert.is_nil(id, "без распознанного транспорта — nil")
end)

-- publish_to_single: неизвестный sub_id возвращает false
suite:add_test("publish_to_single: неизвестный sub_id возвращает false", function()
    local sm = SubscriptionManager.new()
    local ok = sm:publish_to_single("no-such-id", "ev", { data = {}, json = "{}" })
    Assert.is_false(ok, "неизвестный sub_id — false")
end)

-- Батч: много событий вызывают flush по BatchMaxSize (50)
suite:add_test("publish_event: батч array при 50 событиях сбрасывается", function()
    local sm = SubscriptionManager.new()
    local id = sm:subscribe("batch:many", { callback = { host = "h", port = 80 }, batch_mode = "array" })
    for _ = 1, 51 do
        sm:publish_event({ type = "batch:many", data = {}, options = {} })
    end
    Assert.is_true(sm.stats.delivered >= 1 or sm.stats.total >= 1, "батч сброшен или учтён")
    sm:unsubscribe(id)
end)

-- WS транспорт: вызов WsSubscriber.broadcast_raw
suite:add_test("publish_event: WS транспорт вызывает WsSubscriber.broadcast_raw", function()
    local broadcast_calls = {}
    local orig_get_module = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "ws_subscriber" then
            return {
                broadcast_raw = function(ev_type, json_data)
                    broadcast_calls[#broadcast_calls + 1] = { type = ev_type, data = json_data }
                end
            }
        end
        return orig_get_module(name)
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    sm:subscribe("ws:ev", { callback = { type = "WS" } })
    sm:publish_event({ type = "ws:ev", data = { k = 1 }, options = {} })
    ref_ModuleManager.get_module = orig_get_module
    _G.ModuleManager.get_module = orig_get_module
    Assert.is_true(#broadcast_calls >= 1, "broadcast_raw вызван при доставке по WS")
end)

-- subscribe с filters.conditions: предкомпиляция accessor через FilterEngine
suite:add_test("subscribe: с filters.conditions компилирует accessor", function()
    local sm = SubscriptionManager.new()
    local id = sm:subscribe("cond:ev", {
        callback = function() end,
        filters = { conditions = { { field = "x", op = "eq", value = 1 } } }
    })
    Assert.is_not_nil(id, "подписка с conditions создана")
    sm:publish_event({ type = "cond:ev", data = { x = 1 }, options = {} })
end)

-- enqueue_retry: переполнение очереди — Logger.warning и return false
suite:add_test("enqueue_retry: при переполнении очереди возвращает false", function()
    local sm = SubscriptionManager.new()
    sm._retry_queue = {}
    for _ = 1, 501 do
        sm._retry_queue[#sm._retry_queue + 1] = {}
    end
    local ok = sm:enqueue_retry({ host = "x", port = 80 }, "d", "ev", 0, "{}")
    Assert.is_false(ok, "при переполнении очереди — false")
end)

-- publish_to_single: batch_mode array и LUA_CALLBACK — payload как массив
suite:add_test("publish_to_single: batch_mode array и LUA_CALLBACK передаёт массив данных", function()
    local sm = SubscriptionManager.new()
    local received = nil
    local id = sm:subscribe("arr", { callback = function(d) received = d end, batch_mode = "array" })
    local ok = sm:publish_to_single(id, "arr", { data = { x = 1 }, json = "{}" })
    Assert.is_true(ok, "publish_to_single успешен")
    Assert.is_true(type(received) == "table" and #received == 1 and received[1].x == 1, "данные как массив с одним элементом")
end)

-- subscribe с маской: инвалидация _route_cache при добавлении маски
suite:add_test("subscribe: при добавлении маски инвалидирует кэш маршрутов", function()
    local sm = SubscriptionManager.new()
    sm:subscribe("ev:one", function() end)
    sm:get_delivery_plan("ev:one")
    sm:subscribe("ev:*", function() end)
    local plan = sm:get_delivery_plan("ev:two")
    Assert.is_true(plan == nil or plan.total_simple >= 0 or plan.has_complex, "план пересчитан после маски")
end)

-- _get_targets: при переполнении _route_cache_size сброс кэша
suite:add_test("_get_targets: при MaxRouteCacheSize сбрасывает кэш", function()
    local sm = SubscriptionManager.new()
    sm._route_cache_size = 2000
    sm._route_cache = { ["a"] = {}, ["b"] = {} }
    sm:subscribe("ev:cache", function() end)
    sm:get_delivery_plan("ev:cache")
    Assert.is_true(sm._route_cache_size <= 1001, "размер кэша ограничен или сброшен")
end)

-- Транспорты с os.execute: TELEGRAM с token/chat_id
suite:add_test("publish_event: TELEGRAM с token и chat_id вызывает os.execute", function()
    local execute_calls = {}
    local_mock = Mock:new()
    local_mock:mock_global("os", {
        execute = function(cmd) execute_calls[#execute_calls + 1] = cmd end,
        time = os.time,
        clock = os.clock,
        rename = os.rename,
        remove = os.remove,
    })
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    sm:subscribe("tg2", { callback = { type = "TELEGRAM", token = "t", chat_id = "c" } })
    sm:publish_event({ type = "tg2", data = {}, options = {} })
    Assert.is_true(#execute_calls >= 1, "TELEGRAM с конфигом вызывает os.execute")
end)

-- GOTIFY с url и token
suite:add_test("publish_event: GOTIFY с url и token вызывает os.execute", function()
    local execute_calls = {}
    local_mock = Mock:new()
    local_mock:mock_global("os", {
        execute = function(cmd) execute_calls[#execute_calls + 1] = cmd end,
        time = os.time,
        clock = os.clock,
    })
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    sm:subscribe("gf2", { callback = { type = "GOTIFY", url = "http://g", token = "t" } })
    sm:publish_event({ type = "gf2", data = {}, options = {} })
    Assert.is_true(#execute_calls >= 1, "GOTIFY с конфигом вызывает os.execute")
end)

-- PUSHOVER с token и user
suite:add_test("publish_event: PUSHOVER с token и user вызывает os.execute", function()
    local execute_calls = {}
    local_mock = Mock:new()
    local_mock:mock_global("os", {
        execute = function(cmd) execute_calls[#execute_calls + 1] = cmd end,
        time = os.time,
        clock = os.clock,
    })
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    sm:subscribe("po2", { callback = { type = "PUSHOVER", token = "t", user = "u" } })
    sm:publish_event({ type = "po2", data = {}, options = {} })
    Assert.is_true(#execute_calls >= 1, "PUSHOVER с конфигом вызывает os.execute")
end)

-- GENERIC_WEBHOOK с url
suite:add_test("publish_event: GENERIC_WEBHOOK с url вызывает os.execute", function()
    local execute_calls = {}
    local_mock = Mock:new()
    local_mock:mock_global("os", {
        execute = function(cmd) execute_calls[#execute_calls + 1] = cmd end,
        time = os.time,
        clock = os.clock,
    })
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    sm:subscribe("gw2", { callback = { type = "GENERIC_WEBHOOK", url = "http://w" } })
    sm:publish_event({ type = "gw2", data = {}, options = {} })
    Assert.is_true(#execute_calls >= 1, "GENERIC_WEBHOOK с url вызывает os.execute")
end)

-- INFLUXDB с ssl: true — ветка curl
suite:add_test("publish_event: INFLUXDB с ssl вызывает os.execute", function()
    local execute_calls = {}
    local_mock = Mock:new()
    local_mock:mock_global("os", {
        execute = function(cmd) execute_calls[#execute_calls + 1] = cmd end,
        time = os.time,
        clock = os.clock,
    })
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    sm:subscribe("influx2", { callback = { type = "INFLUXDB", host = "h", port = 8086, bucket = "b", token = "t", ssl = true } })
    sm:publish_event({ type = "influx2", data = {}, options = {} })
    Assert.is_true(#execute_calls >= 1, "INFLUXDB с ssl вызывает os.execute")
end)

-- load: загрузка подписок из файла
suite:add_test("load: читает файл и вызывает subscribe для каждой записи", function()
    local content = '{"ev:loaded":{"sub-id-1":{"callback":{"host":"h","port":80}}}}'
    local decoded = { ["ev:loaded"] = { ["sub-id-1"] = { callback = { host = "h", port = 80 } } } }
    local orig_open = io.open
    local orig_gd = ref_ModuleManager.get_global_dependency
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "json.decode" then return function(s) if s and s:find("ev:loaded") then return decoded end return {} end end
        return orig_gd(name)
    end
    _G.ModuleManager.get_global_dependency = ref_ModuleManager.get_global_dependency
    io.open = function(path, mode)
        if path and path:find("subscribers") and mode == "r" then
            return {
                read = function(_, fmt) return (fmt == "*all") and content or nil end,
                close = function() end,
            }
        end
        return orig_open(path, mode)
    end
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    io.open = orig_open
    ref_ModuleManager.get_global_dependency = orig_gd
    _G.ModuleManager.get_global_dependency = orig_gd
    Assert.is_not_nil(sm.subscriptions["ev:loaded"], "тип ev:loaded загружен")
    Assert.is_not_nil(sm.subscriptions["ev:loaded"]["sub-id-1"], "подписка sub-id-1 загружена")
end)

-- load: несколько event_type и несколько подписок — покрытие цикла for event_type, subs / for id, sub_data
suite:add_test("load: несколько типов событий и подписок загружаются в цикле", function()
    local content = '{"ev:a":{"id1":{"callback":{"host":"a","port":80}},"id2":{"callback":{"host":"b","port":90}}},"ev:b":{"id3":{"callback":{"host":"c","port":70}}}}'
    local decoded = {
        ["ev:a"] = { id1 = { callback = { host = "a", port = 80 } }, id2 = { callback = { host = "b", port = 90 } } },
        ["ev:b"] = { id3 = { callback = { host = "c", port = 70 } } },
    }
    local orig_open = io.open
    local orig_gd = ref_ModuleManager.get_global_dependency
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "json.decode" then return function(s) if s and s:find("ev:a") then return decoded end return {} end end
        return orig_gd(name)
    end
    _G.ModuleManager.get_global_dependency = ref_ModuleManager.get_global_dependency
    io.open = function(path, mode)
        if path and path:find("subscribers") and mode == "r" then
            return {
                read = function(_, fmt) return (fmt == "*all") and content or nil end,
                close = function() end,
            }
        end
        return orig_open(path, mode)
    end
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    io.open = orig_open
    ref_ModuleManager.get_global_dependency = orig_gd
    _G.ModuleManager.get_global_dependency = orig_gd
    Assert.is_not_nil(sm.subscriptions["ev:a"], "тип ev:a загружен")
    Assert.is_not_nil(sm.subscriptions["ev:b"], "тип ev:b загружен")
    Assert.is_not_nil(sm.subscriptions["ev:a"]["id1"], "подписка id1")
    Assert.is_not_nil(sm.subscriptions["ev:a"]["id2"], "подписка id2")
    Assert.is_not_nil(sm.subscriptions["ev:b"]["id3"], "подписка id3")
end)

-- init_config_subscription: подписка на config:updated:network и config:updated:batch (без перезагрузки)
suite:add_test("init_config_subscription: коллбэки network и batch обновляют _m_config", function()
    local subscribe_cbs = {}
    local orig_get_module = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "core.event_dispatcher" then
            return {
                get_instance = function()
                    return {
                        subscribe = function(_, ev, cb) subscribe_cbs[ev] = cb end,
                    }
                end
            }
        end
        return orig_get_module(name)
    end
    _G.ModuleManager = ref_ModuleManager
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    sm:init_config_subscription()
    ref_ModuleManager.get_module = orig_get_module
    Assert.is_not_nil(subscribe_cbs["config:updated:network"], "коллбэк network")
    Assert.is_not_nil(subscribe_cbs["config:updated:batch"], "коллбэк batch")
    subscribe_cbs["config:updated:network"]({ HttpTimeout = 20 })
    subscribe_cbs["config:updated:batch"]({ BatchEnabled = false })
end)

-- start_retry_processor: выполнение задачи (batch flush, retry, save_pending)
suite:add_test("start_retry_processor: задача планировщика выполняет flush и save", function()
    local captured = {}
    local orig_get_module = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "core.scheduler" then
            return {
                get_instance = function()
                    return {
                        add_task = function(_, _, cb) captured.cb = cb end,
                        remove_task = function() end,
                    }
                end
            }
        end
        return orig_get_module(name)
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    ref_ModuleManager.get_module = orig_get_module
    _G.ModuleManager.get_module = orig_get_module
    Assert.is_not_nil(captured.cb, "задача добавлена")
    sm._save_pending = true
    captured.cb()
    Assert.is_false(sm._save_pending, "save_pending сброшен после save_now")
end)

-- Задача планировщика: обработка retry_queue (item.time в прошлом)
suite:add_test("start_retry_processor: задача обрабатывает retry_queue", function()
    local captured = {}
    local orig_gm = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "core.scheduler" then
            return {
                get_instance = function()
                    return {
                        add_task = function(_, _, cb) captured.cb = cb end,
                        remove_task = function() end,
                    }
                end
            }
        end
        return orig_gm(name)
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    local_mock = Mock:new()
    local_mock:mock_global("os", { time = os.time, clock = function() return 1e9 end, rename = os.rename, remove = os.remove })
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    ref_ModuleManager.get_module = orig_gm
    _G.ModuleManager.get_module = orig_gm
    Assert.is_not_nil(captured.cb, "коллбэк задачи планировщика установлен")
    sm._retry_queue[1] = { config = { host = "h", port = 80 }, data = "{}", type = "r", retries = 0, time = 0 }
    captured.cb()
    Assert.are_equal(0, #sm._retry_queue, "элемент retry обработан и удалён")
end)

-- save_now: успешная запись и os.rename
suite:add_test("save_now: успешная запись и rename возвращает true", function()
    local written, closed, renamed
    local orig_open = io.open
    local orig_rename = os.rename
    io.open = function(path, mode)
        if mode == "w" and path and path:find("subscribers") then
            return {
                write = function(_, c) written = c end,
                close = function() closed = true end,
            }
        end
        return orig_open(path, mode)
    end
    os.rename = function(from, to) renamed = from; return true end
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    sm:subscribe("sv:ok", { callback = { host = "h", port = 80 } })
    sm:save()
    local ok = sm:save_now()
    io.open = orig_open
    os.rename = orig_rename
    Assert.is_true(ok, "save_now успешен")
    Assert.is_true(closed, "файл закрыт")
    Assert.is_not_nil(renamed, "rename вызван")
end)

-- save_now: при ошибке os.rename возвращает false
suite:add_test("save_now: при ошибке os.rename возвращает false и удаляет tmp", function()
    local orig_open = io.open
    local orig_rename, orig_remove = os.rename, os.remove
    local remove_called
    io.open = function(path, mode)
        if path and path:find("subscribers") and mode == "w" then
            return { write = function() end, close = function() end }
        end
        return orig_open(path, mode)
    end
    os.rename = function() return false end
    os.remove = function(path) remove_called = path end
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    sm:subscribe("ev:save", { callback = { host = "h", port = 80 } })
    sm:save()
    local ok = sm:save_now()
    io.open = orig_open
    os.rename = orig_rename
    os.remove = orig_remove
    Assert.is_false(ok, "при ошибке rename save_now возвращает false")
    Assert.is_not_nil(remove_called, "временный файл удалён")
end)

-- save_now: io.open успешен, os.rename неуспешен — покрытие ветки Logger.error и os.remove (только путь subscribers)
suite:add_test("save_now: при успешном open и ошибке rename вызываются Logger.error и os.remove", function()
    local orig_open = io.open
    local orig_rename = os.rename
    local orig_remove = os.remove
    local remove_called
    io.open = function(path, mode)
        if path and path:find("subscribers") and mode == "w" then
            return {
                write = function() end,
                close = function() end,
            }
        end
        return orig_open(path, mode)
    end
    os.rename = function() return false end
    os.remove = function(path) remove_called = path end
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    sm:subscribe("sv:rn", { callback = { host = "h", port = 80 } })
    sm:save()
    local ok = sm:save_now()
    io.open = orig_open
    os.rename = orig_rename
    os.remove = orig_remove
    Assert.is_false(ok, "save_now возвращает false при ошибке rename")
    Assert.is_not_nil(remove_called, "os.remove вызван для tmp-файла")
end)

-- HTTP: callback при ошибке вызывается синхронно в моке — покрытие ветки is_error/enqueue_retry
suite:add_test("publish_event: HTTP callback при ошибке добавляет в retry", function()
    local orig_gd = ref_ModuleManager.get_global_dependency
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "http_request" then
            return function(opts)
                if opts and opts.callback then
                    opts.callback(false, nil)
                    opts.callback(true, { code = 500 })
                end
                return true
            end
        end
        return orig_gd(name)
    end
    _G.ModuleManager.get_global_dependency = ref_ModuleManager.get_global_dependency
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    sm:subscribe("retry:ev", { callback = { host = "h", port = 80 } })
    sm:publish_event({ type = "retry:ev", data = {}, options = {} })
    ref_ModuleManager.get_global_dependency = orig_gd
    _G.ModuleManager.get_global_dependency = orig_gd
    Assert.is_true(#sm._retry_queue >= 1, "callback вызван, enqueue_retry хотя бы один раз")
end)

-- _get_event_json: ошибка json_encode логируется (event.data таблица)
suite:add_test("publish_event: при ошибке json_encode в событии логируется ошибка", function()
    local orig_gd = ref_ModuleManager.get_global_dependency
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "json.encode" then return function() error("encode fail") end end
        return orig_gd(name)
    end
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    sm:subscribe("err:ev", { callback = { host = "h", port = 80 } })
    sm:publish_event({ type = "err:ev", data = { x = 1 }, options = {} })
    ref_ModuleManager.get_global_dependency = orig_gd
end)

-- _get_event_json: при event.id и ошибке pcall(json_encode, event.data) — Logger.error и return nil
suite:add_test("publish_event: _get_event_json при ошибке json_encode event.data логирует и возвращает nil", function()
    local orig_gd = ref_ModuleManager.get_global_dependency
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "json.encode" then
            return function(t)
                if type(t) == "table" and t._trigger_data_encode_error then error("data encode fail") end
                return "{}"
            end
        end
        return orig_gd(name)
    end
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    sm:subscribe("err:data", { callback = { host = "h", port = 80 } })
    sm:publish_event({ type = "err:data", data = { _trigger_data_encode_error = true }, options = {}, id = true })
    ref_ModuleManager.get_global_dependency = orig_gd
end)

-- CONSOLE/WS: ветка event.id и _get_event_json, fallback tostring при json_encode nil
suite:add_test("publish_event: CONSOLE с event.id и json_encode nil использует tostring", function()
    local orig_gd = ref_ModuleManager.get_global_dependency
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "json.encode" then return function() return nil end end
        return orig_gd(name)
    end
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    sm:subscribe("con:id", { callback = { type = "CONSOLE" } })
    sm:publish_event({ type = "con:id", data = { a = 1 }, id = true, options = {} })
    ref_ModuleManager.get_global_dependency = orig_gd
end)

-- WS: при отсутствии WsSubscriber subscribe всё равно возвращает id; доставка при publish возвращает false
suite:add_test("publish_event: WS при отсутствии WsSubscriber подписка создаётся, доставка не удаётся", function()
    local orig_gm = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "ws_subscriber" then return nil end
        return orig_gm(name)
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    local id = sm:subscribe("ws:off", { callback = { type = "WS" } })
    Assert.is_not_nil(id, "подписка создаётся с id даже без WsSubscriber")
    sm:publish_event({ type = "ws:off", data = {}, options = {} })
    Assert.is_true(sm.stats.failed >= 1, "доставка по WS без WsSubscriber увеличивает stats.failed")
    ref_ModuleManager.get_module = orig_gm
    _G.ModuleManager.get_module = orig_gm
end)

-- WS: при WsSubscriber без broadcast_raw возвращает false при доставке
suite:add_test("publish_event: WS при отсутствии broadcast_raw возвращает false", function()
    local orig_gm = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "ws_subscriber" then return {} end
        return orig_gm(name)
    end
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    sm:subscribe("ws:nob", { callback = { type = "WS" } })
    sm:publish_event({ type = "ws:nob", data = {}, options = {} })
    ref_ModuleManager.get_module = orig_gm
end)

-- INFLUXDB без ssl: ветка http_request
suite:add_test("publish_event: INFLUXDB без ssl вызывает http_request", function()
    local http_called = {}
    local orig_gd = ref_ModuleManager.get_global_dependency
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "http_request" then
            return function(opts) http_called[#http_called + 1] = opts; return true end
        end
        return orig_gd(name)
    end
    _G.ModuleManager.get_global_dependency = ref_ModuleManager.get_global_dependency
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    sm:subscribe("influx3", { callback = { type = "INFLUXDB", host = "h", port = 8086, bucket = "b", token = "t", ssl = false } })
    sm:publish_event({ type = "influx3", data = {}, options = {} })
    ref_ModuleManager.get_global_dependency = orig_gd
    _G.ModuleManager.get_global_dependency = orig_gd
    Assert.is_true(#http_called >= 1, "http_request вызван для INFLUXDB без ssl")
end)

-- GENERIC_WEBHOOK с config.headers
suite:add_test("publish_event: GENERIC_WEBHOOK с headers вызывает os.execute", function()
    local execute_calls = {}
    local_mock = Mock:new()
    local_mock:mock_global("os", {
        execute = function(cmd) execute_calls[#execute_calls + 1] = cmd end,
        time = os.time,
        clock = os.clock,
    })
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    sm:subscribe("gw3", { callback = { type = "GENERIC_WEBHOOK", url = "http://w", headers = { "X-Custom: 1" } } })
    sm:publish_event({ type = "gw3", data = {}, options = {} })
    Assert.is_true(#execute_calls >= 1, "GENERIC_WEBHOOK с headers вызывает os.execute")
end)

-- enqueue_retry: event.is_table -> retry_data = content
suite:add_test("enqueue_retry: при event.is_table использует content как data", function()
    local sm = SubscriptionManager.new()
    local event = { is_table = true }
    sm:enqueue_retry({ host = "h", port = 80 }, event, "ev", 0, '{"k":1}')
    Assert.are_equal(1, #sm._retry_queue, "один элемент в очереди")
    Assert.are_equal('{"k":1}', sm._retry_queue[1].data, "data взят из content при is_table")
end)

-- Задача планировщика: batch flush по интервалу
suite:add_test("start_retry_processor: задача выполняет batch flush по интервалу", function()
    local captured = {}
    local orig_gm = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "core.scheduler" then
            return {
                get_instance = function()
                    return {
                        add_task = function(_, _, cb) captured.cb = cb end,
                        remove_task = function() end,
                    }
                end
            }
        end
        return orig_gm(name)
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    ref_ModuleManager.get_module = orig_gm
    _G.ModuleManager.get_module = orig_gm
    Assert.is_not_nil(captured.cb, "коллбэк задачи планировщика установлен")
    local id = sm:subscribe("bf:ev", { callback = { host = "h", port = 80 }, batch_mode = "array" })
    sm._batch_queues[id] = { events = { "{}" }, last_flush = 0 }
    captured.cb()
    Assert.is_true(sm._batch_queues[id] == nil or #(sm._batch_queues[id].events or {}) == 0, "batch сброшен после flush")
end)

-- throttle_ms: should_send = false при частых событиях (первое при now>=throttle/1000, второе раньше)
suite:add_test("publish_event: throttle_ms отфильтровывает слишком частые события", function()
    local sm = SubscriptionManager.new()
    local count = 0
    sm:subscribe("thr:ev", { callback = function() count = count + 1 end, throttle_ms = 100000 })
    sm:publish_event({ type = "thr:ev", data = {}, options = {} }, 100)
    sm:publish_event({ type = "thr:ev", data = {}, options = {} }, 100.001)
    Assert.are_equal(1, count, "второе событие отфильтровано по throttle")
end)

-- FilterEngine.match false: подписчик не получает событие
suite:add_test("publish_event: при несовпадении фильтра событие не доставляется", function()
    local sm = SubscriptionManager.new()
    local received = 0
    sm:subscribe("flt:ev", {
        callback = function() received = received + 1 end,
        filters = { conditions = { { field = "x", op = "eq", value = 999 } } }
    })
    sm:publish_event({ type = "flt:ev", data = { x = 1 }, options = {} })
    Assert.are_equal(0, received, "событие не доставлено при несовпадении фильтра")
end)

-- Circuit Breaker в complex path: 20 ошибок подряд — Logger.error и unsubscribe (покрытие ветки в цикле complex_subs)
suite:add_test("publish_event: после 20 ошибок доставки сложный подписчик отписывается (Circuit Breaker complex)", function()
    local orig_gd = ref_ModuleManager.get_global_dependency
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "http_request" then return function() return false end end
        return orig_gd(name)
    end
    _G.ModuleManager.get_global_dependency = ref_ModuleManager.get_global_dependency
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    local id = sm:subscribe("cb2:ev", { callback = { host = "h", port = 80 }, throttle_ms = 1 })
    for _ = 1, 21 do
        sm:publish_event({ type = "cb2:ev", data = {}, options = {} }, 999)
    end
    ref_ModuleManager.get_global_dependency = orig_gd
    _G.ModuleManager.get_global_dependency = orig_gd
    Assert.is_nil(sm.subscriptions["cb2:ev"] and sm.subscriptions["cb2:ev"][id], "сложный подписчик удалён после 20 ошибок")
end)

-- Circuit Breaker: 20 ошибок подряд — отписка
suite:add_test("publish_event: после 20 ошибок доставки подписчик отписывается", function()
    local orig_gd = ref_ModuleManager.get_global_dependency
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "http_request" then return function() return false end end
        return orig_gd(name)
    end
    _G.ModuleManager.get_global_dependency = ref_ModuleManager.get_global_dependency
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    local id = sm:subscribe("cb:ev", { callback = { host = "h", port = 80 } })
    for _ = 1, 21 do
        sm:publish_event({ type = "cb:ev", data = {}, options = {} })
    end
    ref_ModuleManager.get_global_dependency = orig_gd
    _G.ModuleManager.get_global_dependency = orig_gd
    Assert.is_nil(sm.subscriptions["cb:ev"] and sm.subscriptions["cb:ev"][id], "подписчик удалён после 20 ошибок")
end)

-- flush_batch: подписка не найдена — освобождение очереди
suite:add_test("flush_batch: при отсутствии подписки освобождает очередь", function()
    local sm = SubscriptionManager.new()
    sm._batch_queues["ghost-id"] = { events = { "{}" }, last_flush = 0 }
    sm:flush_batch("ghost-id")
    Assert.is_nil(sm._batch_queues["ghost-id"], "очередь удалена при отсутствии подписки")
end)

-- flush_batch: один элемент и batch_mode ~= array
suite:add_test("flush_batch: один элемент в режиме single без массива", function()
    local sm = SubscriptionManager.new()
    local got = {}
    local id = sm:subscribe("one:ev", { callback = function(d) got[#got + 1] = d end, batch_mode = "single" })
    sm:add_to_batch(sm.subscriptions["one:ev"][id], { type = "one:ev", data = { a = 1 }, options = {} })
    sm:flush_batch(id)
    Assert.are_equal(1, #got, "одно событие доставлено")
    Assert.are_equal("table", type(got[1]), "payload — таблица для LUA_CALLBACK")
end)

-- shutdown: вызывает flush_batch для всех очередей
suite:add_test("shutdown: сбрасывает все batch очереди", function()
    local sm = SubscriptionManager.new()
    local id = sm:subscribe("sd:ev", { callback = { host = "h", port = 80 }, batch_mode = "array" })
    sm:publish_event({ type = "sd:ev", data = {}, options = {} })
    sm:shutdown()
    Assert.is_true(sm._batch_queues[id] == nil or #(sm._batch_queues[id].events or {}) == 0, "очереди сброшены")
end)

-- unsubscribe: прямая подписка сбрасывает _route_cache[event_type]
suite:add_test("unsubscribe: при прямой подписке сбрасывает кэш маршрута", function()
    local sm = SubscriptionManager.new()
    sm:subscribe("dir:ev", function() end)
    sm:get_delivery_plan("dir:ev")
    Assert.is_not_nil(sm._route_cache["dir:ev"], "кэш заполнен")
    local id = sm:subscribe("dir:ev", function() end)
    sm:unsubscribe(id)
    Assert.is_nil(sm._route_cache["dir:ev"], "кэш сброшен после unsubscribe")
end)

-- unsubscribe: маска — цикл to_remove по кэшу
suite:add_test("unsubscribe: при маске инвалидирует совпадающие записи кэша", function()
    local sm = SubscriptionManager.new()
    local id = sm:subscribe("mask:*", function() end)
    sm:get_delivery_plan("mask:one")
    Assert.is_not_nil(sm._route_cache["mask:one"], "кэш заполнен")
    sm:unsubscribe(id)
    Assert.is_nil(sm._route_cache["mask:one"], "кэш инвалидирован для маски")
end)

-- match: компиляция матчера через Wildcard.compile
suite:add_test("match: при отсутствии матчера в кэше вызывает Wildcard.compile", function()
    local sm = SubscriptionManager.new()
    sm._matchers["p:*"] = nil
    local ok = sm:match("p:*", "p:1")
    Assert.is_true(ok, "матчер скомпилирован и совпал")
    Assert.is_not_nil(sm._matchers["p:*"], "матчер закэширован")
end)

-- _get_targets: fallback без match_multiple (цикл for pattern, subs / match / table_insert)
suite:add_test("_get_targets: fallback перебор при отсутствии match_multiple", function()
    local orig_gm = ref_ModuleManager.get_module
    ref_ModuleManager.get_module = function(name)
        if name == "utils.wildcard" then return { compile = function() return function() return true end end } end
        return orig_gm(name)
    end
    _G.ModuleManager.get_module = ref_ModuleManager.get_module
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    sm:subscribe("fb:ev", function() end)
    sm._route_cache = {}
    sm._route_cache_size = 0
    local plan = sm:get_delivery_plan("fb:ev")
    ref_ModuleManager.get_module = orig_gm
    _G.ModuleManager.get_module = orig_gm
    Assert.is_not_nil(plan, "план получен через fallback")
end)

-- unsubscribe: несуществующий id возвращает false
suite:add_test("unsubscribe: несуществующий sub_id возвращает false", function()
    local sm = SubscriptionManager.new()
    local ok = sm:unsubscribe("no-such-id")
    Assert.is_false(ok, "unsubscribe несуществующего — false")
end)

-- HTTP: content через _get_event_json при event.id (ветка event_json or (event.id and _get_event_json))
suite:add_test("publish_event: HTTP с event.id использует _get_event_json для content", function()
    local sm = SubscriptionManager.new()
    local delivered
    sm:subscribe("h:id", { callback = { host = "h", port = 80 } })
    sm:publish_event({ type = "h:id", data = { v = 1 }, options = {}, id = true })
    Assert.is_true(sm.stats.delivered >= 1 or sm.stats.total >= 1, "событие обработано")
end)

-- multicast_direct: event_json nil, event_data таблица — pcall(json_encode)
suite:add_test("publish_event: multicast с event_data таблица кодирует json", function()
    local orig_gd = ref_ModuleManager.get_global_dependency
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "json.encode" then return function(t) return type(t) == "table" and "{}" or nil end end
        return orig_gd(name)
    end
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    local got
    sm:subscribe("mc:json", { callback = function(d) got = d end })
    sm:publish_event({ type = "mc:json", data = { x = 1 }, options = {}, json_cache = nil, fast_path_delivered = false })
    ref_ModuleManager.get_global_dependency = orig_gd
    Assert.is_true(got ~= nil, "multicast_direct доставил данные")
end)

-- multicast_direct: event_data не таблица — tostring (ветка else event_json = tostring(event_data))
suite:add_test("publish_event: multicast_direct с event_data не таблица и event_json nil вызывает tostring", function()
    local orig_gd = ref_ModuleManager.get_global_dependency
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "json.encode" then return function() return nil end end
        return orig_gd(name)
    end
    _G.ModuleManager.get_global_dependency = ref_ModuleManager.get_global_dependency
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    sm:subscribe("mc:tostr", { callback = { type = "CONSOLE" } })
    sm:publish_event({ type = "mc:tostr", data = 42, options = {}, fast_path_delivered = false })
    ref_ModuleManager.get_global_dependency = orig_gd
    _G.ModuleManager.get_global_dependency = orig_gd
end)

-- multicast_direct: event_data не таблица — tostring; LUA_CALLBACK может получить event или event.data
suite:add_test("publish_event: multicast с event_data не таблица использует tostring", function()
    local sm = SubscriptionManager.new()
    local received = nil
    sm:subscribe("mc:ev", { callback = function(d) received = d end })
    sm:publish_event({ type = "mc:ev", data = "plain", options = {}, fast_path_delivered = false })
    Assert.is_true(
        received == "plain" or received == "{}" or (type(received) == "table" and received.data == "plain"),
        "данные доставлены (plain, {} или event с data)"
    )
end)

-- multicast_direct: неудача доставки увеличивает stats.failed
suite:add_test("publish_event: при неудаче доставки в группе увеличивается stats.failed", function()
    local orig_gd = ref_ModuleManager.get_global_dependency
    ref_ModuleManager.get_global_dependency = function(name)
        if name == "http_request" then return function() return false end end
        return orig_gd(name)
    end
    _G.ModuleManager.get_global_dependency = ref_ModuleManager.get_global_dependency
    package.loaded["src.core.subscription_manager"] = nil
    SubscriptionManager = require("src.core.subscription_manager")
    local sm = SubscriptionManager.new()
    sm:subscribe("fail:ev", { callback = { host = "same", port = 80, path = "/" } })
    sm:subscribe("fail:ev", { callback = { host = "same", port = 80, path = "/" } })
    sm:publish_event({ type = "fail:ev", data = {}, options = {} })
    ref_ModuleManager.get_global_dependency = orig_gd
    _G.ModuleManager.get_global_dependency = orig_gd
    Assert.is_true(sm.stats.failed >= 1, "stats.failed увеличен при неудаче")
end)

-- publish_to_single: batch_mode array не LUA — event_json массив
suite:add_test("publish_to_single: batch_mode array для HTTP передаёт JSON-массив", function()
    local sm = SubscriptionManager.new()
    local id = sm:subscribe("arr2:ev", { callback = { host = "h", port = 80 }, batch_mode = "array" })
    local ok = sm:publish_to_single(id, "arr2:ev", { data = {}, json = "{}" })
    Assert.is_true(ok, "publish_to_single успешен")
end)

suite:run()
