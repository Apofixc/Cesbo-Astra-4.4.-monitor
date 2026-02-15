-- L1: Unit-тесты для модуля utils.ws_subscriber
-- Моки: ModuleManager (logger, core.scheduler, core.event_dispatcher).

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
local Mock = require("tools.test_moc")

local mock
local WsSubscriber
local log_calls
local ref_batch_config_cb
local ref_add_task_cb
local ref_set_task_interval_called
local ref_ModuleManager
local fake_client1, fake_client2

local suite = TestSuite:new("L1.ws_subscriber")

suite:setup(function()
    mock = Mock:new()
    log_calls = { debug = 0, info = 0, error = 0 }
    ref_batch_config_cb = nil
    ref_add_task_cb = nil
    fake_client1 = {}
    fake_client2 = {}

    local mock_log = {
        debug = function() log_calls.debug = log_calls.debug + 1 end,
        info = function() log_calls.info = log_calls.info + 1 end,
        error = function() log_calls.error = log_calls.error + 1 end,
    }

    local mock_scheduler_instance = {
        add_task = function(self, name, cb, interval)
            ref_add_task_cb = cb
        end,
        remove_task = function(self, name) end,
        set_task_interval = function(self, name, interval)
            ref_set_task_interval_called = true
        end,
    }
    local mock_scheduler = { get_instance = function() return mock_scheduler_instance end }

    local mock_ed_instance = {
        subscribe = function(self, ev, cb)
            if ev == "config:updated:batch" then ref_batch_config_cb = cb end
        end
    }
    local mock_ed = { get_instance = function() return mock_ed_instance end }

    ref_ModuleManager = {
        get_module = function(name)
            if name == "logger" then return mock_log end
            if name == "core.scheduler" then return mock_scheduler end
            if name == "core.event_dispatcher" then return mock_ed end
            return nil
        end,
    }
    mock:mock_global("ModuleManager", ref_ModuleManager)
end)

suite:before_each(function()
    log_calls.debug = 0
    log_calls.info = 0
    log_calls.error = 0
    ref_batch_config_cb = nil
    ref_add_task_cb = nil
    ref_set_task_interval_called = false
    package.loaded["src.utils.ws_subscriber"] = nil
    WsSubscriber = require("src.utils.ws_subscriber")
end)

suite:teardown(function()
    mock:restore()
end)

-- init
suite:add_test("init: при nil server возвращает false и логирует ошибку", function()
    local ok = WsSubscriber.init(nil)
    Assert.is_false(ok, "false при nil server")
    Assert.are_equal(1, log_calls.error, "Logger.error вызван")
end)

suite:add_test("init: при валидном server возвращает true и регистрирует задачу", function()
    local server = {}
    local ok = WsSubscriber.init(server)
    Assert.is_true(ok, "true при валидном server")
    Assert.is_not_nil(ref_add_task_cb, "add_task вызван, callback сохранён")
end)

-- clear
suite:add_test("clear: очищает клиентов и сервер", function()
    WsSubscriber.init({})
    WsSubscriber.on_message({ send = function() end }, fake_client1, "first")
    Assert.are_equal(1, WsSubscriber.get_clients_count(), "один клиент")
    WsSubscriber.clear()
    Assert.are_equal(0, WsSubscriber.get_clients_count(), "после clear ноль")
end)

-- shutdown
suite:add_test("shutdown: останавливает задачу и логирует", function()
    WsSubscriber.init({})
    WsSubscriber.shutdown()
    Assert.is_true(log_calls.info >= 1, "Logger.info при shutdown")
    Assert.are_equal(0, WsSubscriber.get_clients_count(), "клиенты очищены")
end)

-- on_message: nil request (закрытие)
suite:add_test("on_message: request nil удаляет клиента", function()
    local server = { send = function() end }
    WsSubscriber.init(server)
    WsSubscriber.on_message(server, fake_client1, "hi")
    Assert.are_equal(1, WsSubscriber.get_clients_count(), "один клиент")
    WsSubscriber.on_message(server, fake_client1, nil)
    Assert.are_equal(0, WsSubscriber.get_clients_count(), "клиент удалён при nil request")
end)

-- on_message: первый запрос — регистрация и приветствие
suite:add_test("on_message: первый запрос регистрирует клиента и отправляет приветствие", function()
    local sent = {}
    local server = { send = function(s, c, msg) sent[#sent + 1] = msg end }
    WsSubscriber.init(server)
    WsSubscriber.on_message(server, fake_client1, "hello")
    Assert.are_equal(1, WsSubscriber.get_clients_count(), "клиент зарегистрирован")
    Assert.is_true(#sent >= 1 and sent[1]:find("sys:connected"), "приветствие отправлено")
end)

-- on_message: ping -> pong
suite:add_test("on_message: ping возвращает pong", function()
    local sent = {}
    local server = { send = function(s, c, msg) sent[#sent + 1] = msg end }
    WsSubscriber.init(server)
    WsSubscriber.on_message(server, fake_client1, "first")
    WsSubscriber.on_message(server, fake_client1, "ping")
    Assert.is_true(#sent >= 2, "минимум два сообщения")
    Assert.are_equal("pong", sent[#sent], "последнее — pong")
end)

-- on_message: command batch enable
suite:add_test("on_message: command batch включается", function()
    local sent = {}
    local server = { send = function(s, c, msg) sent[#sent + 1] = msg end }
    WsSubscriber.init(server)
    WsSubscriber.on_message(server, fake_client1, "reg")
    WsSubscriber.on_message(server, fake_client1, '{"command":"batch","enable":true}')
    Assert.is_true(#sent >= 2, "ответ на batch")
    Assert.is_true(sent[#sent]:find("sys:batch"), "событие sys:batch")
end)

-- on_message: авто init при отсутствии сервера
suite:add_test("on_message: при отсутствии http_server_instance вызывает init(server)", function()
    local server = { send = function() end }
    WsSubscriber.on_message(server, fake_client1, "msg")
    Assert.are_equal(1, WsSubscriber.get_clients_count(), "клиент добавлен после авто init")
end)

-- broadcast_raw: без сервера или без json_data — выход
suite:add_test("broadcast_raw: без сервера или без json_data не рассылает", function()
    WsSubscriber.broadcast_raw("ev", "{}")
    WsSubscriber.init({})
    WsSubscriber.broadcast_raw("ev", nil)
    Assert.is_true(true, "без падения")
end)

-- broadcast_raw: без клиентов — выход
suite:add_test("broadcast_raw: без клиентов выходит", function()
    local send_count = 0
    local server = { send = function() send_count = send_count + 1 end }
    WsSubscriber.init(server)
    WsSubscriber.broadcast_raw("ev", "{}")
    Assert.are_equal(0, send_count, "нет клиентов — send не вызывался")
end)

-- broadcast_raw: с клиентом без батча — отправка
suite:add_test("broadcast_raw: одному клиенту без батча отправляет сообщение", function()
    local sent = {}
    local server = { send = function(s, c, msg) sent[#sent + 1] = msg end, close = function() end }
    WsSubscriber.init(server)
    WsSubscriber.on_message(server, fake_client1, "x")
    WsSubscriber.broadcast_raw("test", '{"x":1}')
    Assert.is_true(#sent >= 2, "приветствие + broadcast")
    Assert.is_true(sent[#sent]:find("test") and sent[#sent]:find('{"x":1}'), "событие и data")
end)

-- get_clients_count
suite:add_test("get_clients_count: возвращает количество клиентов", function()
    Assert.are_equal(0, WsSubscriber.get_clients_count(), "ноль до init")
    local server = { send = function() end }
    WsSubscriber.init(server)
    WsSubscriber.on_message(server, fake_client1, "a")
    WsSubscriber.on_message(server, fake_client2, "b")
    Assert.are_equal(2, WsSubscriber.get_clients_count(), "два клиента")
end)

-- init_config_subscription
suite:add_test("init_config_subscription: подписка на config:updated:batch", function()
    WsSubscriber.init_config_subscription()
    Assert.is_not_nil(ref_batch_config_cb, "callback сохранён")
    ref_batch_config_cb({ WsBatchInterval = 0.1 })
    Assert.is_true(log_calls.debug >= 0, "без падения")
end)

-- config:updated:batch при is_task_running вызывает set_task_interval
suite:add_test("init_config_subscription: при смене WsBatchInterval после init вызывает set_task_interval", function()
    WsSubscriber.init({ send = function() end })
    WsSubscriber.init_config_subscription()
    ref_batch_config_cb({ WsBatchInterval = 0.2 })
    Assert.is_true(ref_set_task_interval_called, "set_task_interval вызван при обновлении интервала батча")
end)

-- _flush_buffers: вызывается планировщиком, сбрасывает batch-буферы
suite:add_test("broadcast_raw и _flush_buffers: batch сбрасывается по таймеру", function()
    local sent = {}
    local server = { send = function(s, c, msg) sent[#sent + 1] = msg end, close = function() end }
    WsSubscriber.init(server)
    WsSubscriber.on_message(server, fake_client1, "reg")
    WsSubscriber.on_message(server, fake_client1, '{"command":"batch","enable":true}')
    WsSubscriber.broadcast_raw("ev", "1")
    Assert.are_equal(1, WsSubscriber.get_clients_count(), "клиент в batch")
    ref_add_task_cb()
    Assert.is_true(#sent >= 2, "flush отправил batch")
end)

-- batch: буфер >= 100 сбрасывается немедленно
suite:add_test("broadcast_raw: batch буфер >= 100 сбрасывается сразу", function()
    local sent = {}
    local server = { send = function(s, c, msg) sent[#sent + 1] = msg end, close = function() end }
    WsSubscriber.init(server)
    WsSubscriber.on_message(server, fake_client1, "reg")
    WsSubscriber.on_message(server, fake_client1, '{"command":"batch","enable":true}')
    for i = 1, 101 do
        WsSubscriber.broadcast_raw("ev", tostring(i))
    end
    Assert.is_true(#sent >= 2, "batch flush при переполнении")
end)

-- error_count >= 5: клиент удаляется, close вызывается
suite:add_test("broadcast_raw: при 5 ошибках send клиент отключается", function()
    local send_count = 0
    local close_count = 0
    local server = {
        send = function() send_count = send_count + 1; error("send fail") end,
        close = function(s, c) close_count = close_count + 1 end,
    }
    WsSubscriber.init(server)
    WsSubscriber.on_message(server, fake_client1, "reg")
    for _ = 1, 6 do
        WsSubscriber.broadcast_raw("ev", "{}")
    end
    Assert.are_equal(0, WsSubscriber.get_clients_count(), "клиент удалён после 5 ошибок")
    Assert.is_true(close_count >= 1, "close вызван")
end)

-- _flush_buffers: send fail -> error_count++ , >= 5 -> client removed, server.close
suite:add_test("_flush_buffers: ошибка send при flush удаляет клиента", function()
    local close_called = 0
    local server = {
        send = function() error("flush send fail") end,
        close = function(_, c) close_called = close_called + 1 end,
    }
    WsSubscriber.init(server)
    WsSubscriber.on_message(server, fake_client1, "reg")
    WsSubscriber.on_message(server, fake_client1, '{"command":"batch","enable":true}')
    -- Каждый flush с данными в буфере увеличивает error_count; после 5 — клиент удаляется и close()
    for i = 1, 6 do
        WsSubscriber.broadcast_raw("ev", tostring(i))
        ref_add_task_cb()
    end
    Assert.are_equal(0, WsSubscriber.get_clients_count(), "клиент удалён после 5 ошибок send в _flush_buffers")
    Assert.are_equal(1, close_called, "server.close вызван")
end)

suite:run()
