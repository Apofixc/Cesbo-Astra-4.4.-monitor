-- INT: Logging Chain (ПМИ 1.2 п.7)
-- Logger ↔ MonitorConfig/EventDispatcher: динамическое изменение уровня логирования (DEBUG/INFO).

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local Logger
local config_callback

local suite = TestSuite:new("INT.chains.logging")

suite:setup(function()
    config_callback = nil
    local log_calls = {}
    _G.ModuleManager = {
        get_module = function(name)
            if name == "monitor_config" then
                return { get = function() return {} end }
            end
            if name == "core.event_dispatcher" then
                return {
                    get_instance = function()
                        return {
                            subscribe = function(_, event_type, cb)
                                if event_type == "config:updated:logger" then config_callback = cb end
                                return "log-sub"
                            end,
                            unsubscribe = function() end,
                        }
                    end,
                }
            end
            if name == "table_pool" then
                return { get = function() return {} end, release = function() end, register_type = function() end }
            end
            return nil
        end,
        get_global_dependency = function(n)
            if n == "log" then
                return {
                    debug = function(msg) table.insert(log_calls, { level = "debug", msg = msg }) end,
                    info = function(msg) table.insert(log_calls, { level = "info", msg = msg }) end,
                    warning = function(msg) table.insert(log_calls, { level = "warning", msg = msg }) end,
                    error = function(msg) table.insert(log_calls, { level = "error", msg = msg }) end,
                }
            end
            if n == "json.encode" then return function() return "{}" end end
            return nil
        end,
    }
    _G.log_calls_for_logging_test = log_calls
    Logger = require("src.utils.logger")
end)

suite:teardown(function()
    _G.log_calls_for_logging_test = nil
    package.loaded["src.utils.logger"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-LOG-01: Logging Chain — config:updated:logger меняет уровень", function()
    Logger.init_config_subscription()
    Assert.is_not_nil(config_callback, "подписка на config:updated:logger")

    local log_calls = _G.log_calls_for_logging_test
    while #log_calls > 0 do table.remove(log_calls) end

    config_callback({ LogLevel = "DEBUG" })
    Logger.debug("TestLog", "debug message after config update")
    local has_debug = false
    for i = 1, #log_calls do
        if log_calls[i] and log_calls[i].level == "debug" then has_debug = true break end
    end
    Assert.is_true(has_debug, "Logger.debug записывает при LogLevel=DEBUG")
end)

suite:run()
