-- INT: JSON Encoding Chain (ПМИ 1.2 п.23)
-- WS_Subscriber ↔ json.encode: сериализация данных в JSON при доставке в WebSocket.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local EventDispatcher
local json_encode_calls
local broadcast_calls
local dispatcher_tick_cb

local suite = TestSuite:new("INT.chains.json_encoding")

suite:setup(function()
    json_encode_calls = {}
    broadcast_calls = {}
    dispatcher_tick_cb = nil
    if not _G.os then _G.os = {} end
    if not _G.os.clock then _G.os.clock = function() return 0 end end

    local ws_mock = {
        broadcast_raw = function(et, json_data)
            table.insert(broadcast_calls, { event_type = et, json_data = json_data })
        end,
    }
    local real_table_pool = nil
    local ref_sub_mgr = nil
    _G.ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return { error = function() end, info = function() end, warning = function() end, debug = function() end }
            end
            if name == "core.scheduler" then
                return {
                    get_instance = function()
                        return {
                            add_task = function(_, id, cb)
                                if id == "event_dispatcher_queue" then dispatcher_tick_cb = cb end
                            end,
                            remove_task = function() end,
                        }
                    end,
                }
            end
            if name == "core.subscription_manager" then
                if not ref_sub_mgr then ref_sub_mgr = require("src.core.subscription_manager").new() end
                return { new = function() return ref_sub_mgr end }
            end
            if name == "table_pool" or name == "utils.table_pool" then return real_table_pool end
            if name == "ws_subscriber" then return ws_mock end
            if name == "utils.filter_engine" then return require("src.utils.filter_engine") end
            if name == "utils.wildcard" then return require("src.utils.wildcard") end
            if name == "utils" then
                return {
                    to_line_protocol = function() return "" end,
                    truncate_string = function(s, n) return (s or ""):sub(1, n or 0) end,
                    shell_escape = function(s) return "'" .. (s or "") .. "'" end,
                }
            end
            return nil
        end,
        get_global_dependency = function(n)
            if n == "json.encode" then
                return function(t)
                    table.insert(json_encode_calls, { data = t })
                    return (t and type(t) == "table") and "{}" or tostring(t)
                end
            end
            if n == "json.decode" then return function() return {} end end
            if n == "http_request" then return function() return true end end
            return nil
        end,
    }
    real_table_pool = require("src.utils.table_pool")
    EventDispatcher = require("src.core.event_dispatcher")
    local ed = EventDispatcher.get_instance()
    local sm = ref_sub_mgr
    if sm then sm:subscribe("test:json_enc", { callback = { type = "WS" } }) end
end)

suite:teardown(function()
    if EventDispatcher and EventDispatcher.get_instance and EventDispatcher.get_instance().shutdown then
        pcall(function() EventDispatcher.get_instance():shutdown() end)
    end
    package.loaded["src.core.event_dispatcher"] = nil
    package.loaded["src.core.subscription_manager"] = nil
    package.loaded["src.utils.table_pool"] = nil
    package.loaded["src.utils.filter_engine"] = nil
    package.loaded["src.utils.wildcard"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-JSON-01: JSON Encoding Chain - доставка в WS вызывает json.encode", function()
    local ed = EventDispatcher.get_instance()
    local before_encode = #json_encode_calls
    ed:emit("test:json_enc", { key = "value" })
    for _ = 1, 10 do if dispatcher_tick_cb then dispatcher_tick_cb() end end
    Assert.is_true(#json_encode_calls > before_encode, "json.encode вызван при доставке в WebSocket")
    Assert.is_true(#broadcast_calls >= 1, "broadcast_raw вызван")
end)

suite:run()
