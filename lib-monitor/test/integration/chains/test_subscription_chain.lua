-- INT: Subscription Chain (ПМИ 1.2 п.6)
-- SubscriptionManager ↔ FilterEngine ↔ Wildcard: корректное применение JIT-фильтров и масок при доставке.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local SubscriptionManager
local ref_ModuleManager

local suite = TestSuite:new("INT.chains.subscription")

suite:setup(function()
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
                    to_line_protocol = function() return "" end,
                    truncate_string = function(s, n) return (s or ""):sub(1, n or 0) end,
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
                        return { add_task = function() end, remove_task = function() end }
                    end,
                }
            end
            if name == "core.event_dispatcher" then return nil end
            return nil
        end,
        get_global_dependency = function(name)
            if name == "http_request" then return function() return true end end
            if name == "json.encode" then return function() return "{}" end end
            if name == "json.decode" then return function() return {} end end
            if name == "astra.version" then return "4.4.182" end
            return nil
        end,
    }
    _G.ModuleManager = ref_ModuleManager
    SubscriptionManager = require("src.core.subscription_manager")
end)

suite:teardown(function()
    package.loaded["src.core.subscription_manager"] = nil
    package.loaded["src.utils.filter_engine"] = nil
    package.loaded["src.utils.wildcard"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-SUB-01: Subscription Chain — Wildcard маска channel:* совпадает с channel:error", function()
    local sm = SubscriptionManager.new()
    Assert.is_not_nil(sm, "SubscriptionManager.new()")
    local ok = sm:match("channel:*", "channel:error")
    Assert.is_true(ok == true, "match(channel:*, channel:error) должен быть true")
end)

suite:add_test("INT-SUB-02: Subscription Chain — маска sys:* не совпадает с channel:error", function()
    local sm = SubscriptionManager.new()
    local ok = sm:match("sys:*", "channel:error")
    Assert.is_true(ok ~= true, "match(sys:*, channel:error) должен быть false")
end)

suite:add_test("INT-SUB-03: Subscription Chain — точное имя совпадает", function()
    local sm = SubscriptionManager.new()
    Assert.is_true(sm:match("channel:error", "channel:error") == true, "точное совпадение")
    Assert.is_true(sm:match("channel:error", "channel:ok") ~= true, "разные имена не совпадают")
end)

suite:run()
