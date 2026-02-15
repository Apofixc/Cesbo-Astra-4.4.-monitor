-- SYS: State & Persistence (ПМИ 2.3)
-- Целостность конфига: save/load, атомарность при ошибках.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local MonitorConfig
local save_calls

local suite = TestSuite:new("SYS.state_persistence")

suite:setup(function()
    save_calls = {}
    _G.ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return { error = function() end, info = function() end, warning = function() end, debug = function() end }
            end
            if name == "core.event_dispatcher" then
                return { get_instance = function() return { subscribe = function() return "id" end, emit_safe = function() end } end }
            end
            return nil
        end,
        get_global_dependency = function(n)
            if n == "json.load" then
                return function() return { Logger = { LogLevel = "INFO" }, System = {} } end
            end
            if n == "json.save" then
                return function(_, data) table.insert(save_calls, { data = data }) return true end
            end
            return nil
        end,
    }
    package.loaded["src.config.monitor_config"] = nil
    MonitorConfig = require("src.config.monitor_config")
end)

suite:teardown(function()
    package.loaded["src.config.monitor_config"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("SYS-PER-01: Persistence — save сохраняет все секции конфига", function()
    MonitorConfig.reload()
    save_calls = {}
    MonitorConfig.update({ Logger = { LogLevel = "DEBUG" } })
    local ok = MonitorConfig.save()
    Assert.is_true(ok, "save возвращает true")
    Assert.is_true(#save_calls >= 1, "json.save вызван")
    local data = save_calls[#save_calls].data
    Assert.is_true(data and data.Logger and data.Logger.LogLevel == "DEBUG", "Logger сохранён")
end)

suite:run()
