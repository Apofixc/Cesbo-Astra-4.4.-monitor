-- INT: WebSocket Heartbeat Chain (ПМИ 1.2 п.33)
-- WS_Subscriber ↔ Client: механизм Ping/Pong для поддержания соединений.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local WsSubscriber

local suite = TestSuite:new("INT.chains.websocket_heartbeat")

suite:setup(function()
    _G.ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return { error = function() end, info = function() end, warning = function() end, debug = function() end }
            end
            if name == "core.scheduler" then
                return {
                    get_instance = function()
                        return { add_task = function() end, remove_task = function() end }
                    end,
                }
            end
            return nil
        end,
        get_global_dependency = function() return nil end,
    }
    WsSubscriber = require("src.utils.ws_subscriber")
end)

suite:teardown(function()
    if WsSubscriber and WsSubscriber.shutdown then pcall(WsSubscriber.shutdown) end
    package.loaded["src.utils.ws_subscriber"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-WSHB-01: WebSocket Heartbeat Chain — ping возвращает pong", function()
    local send_calls = {}
    local mock_server = {
        send = function(_, client, msg)
            table.insert(send_calls, { client = client, msg = msg })
        end,
        close = function() end,
    }

    WsSubscriber.init(mock_server)
    WsSubscriber.on_message(mock_server, "client1", "ping")
    Assert.is_true(#send_calls >= 1, "send вызван")
    local has_pong = false
    for i = 1, #send_calls do
        if send_calls[i].msg == "pong" then has_pong = true break end
    end
    Assert.is_true(has_pong, "при ping отправлен pong")
end)

suite:run()
