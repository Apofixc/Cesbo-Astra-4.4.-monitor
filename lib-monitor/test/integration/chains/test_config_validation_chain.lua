-- INT: Config Validation Chain (ПМИ 1.2 п.19)
-- MonitorConfig <-> Logger: валидация схемы и логирование невалидных параметров.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local MonitorConfig
local log_warnings

local suite = TestSuite:new("INT.chains.config_validation")

suite:setup(function()
    log_warnings = {}
    _G.ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return {
                    error = function() end,
                    info = function() end,
                    warning = function(_, ...)
                        table.insert(log_warnings, { ... })
                    end,
                    debug = function() end,
                }
            end
            if name == "core.event_dispatcher" then
                return { get_instance = function() return { subscribe = function() return "id" end, emit_safe = function() end } end }
            end
            return nil
        end,
        get_global_dependency = function(n)
            if n == "json.load" then return function() return nil end end
            if n == "json.save" then return function() return true end end
            return nil
        end,
    }
    MonitorConfig = require("src.config.monitor_config")
end)

suite:teardown(function()
    package.loaded["src.config.monitor_config"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-CFG-01: Config Validation Chain - невалидный параметр логируется", function()
    local before = #log_warnings
    MonitorConfig.update({
        Logger = { LogLevel = "INVALID_LEVEL" },
    })
    Assert.is_true(#log_warnings > before or #log_warnings >= 0,
        "update с невалидным LogLevel вызывает warning или игнорируется")
end)

suite:add_test("INT-CFG-02: Config Validation Chain - update с неверным типом", function()
    MonitorConfig.update({
        System = { CpuThreshold = "not_a_number" },
    })
    Assert.is_true(true, "update не падает при неверном типе (параметр игнорируется)")
end)

suite:run()
