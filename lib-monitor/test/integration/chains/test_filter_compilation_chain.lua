-- INT: Filter Compilation Chain (ПМИ 1.2 п.22)
-- FilterEngine ↔ Logger: логирование синтаксических ошибок в Lua-фильтрах и откат к false.

if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Запуск через run_test.lua обязателен.\n")
    os.exit(1)
end

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local FilterEngine
local ref_ModuleManager

local suite = TestSuite:new("INT.chains.filter_compilation")

suite:setup(function()
    package.loaded["src.utils.filter_engine"] = nil
    local log_errors = {}
    ref_ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return {
                    error = function(comp, fmt, ...)
                        table.insert(log_errors, { comp = comp, fmt = fmt, args = {...} })
                    end,
                    info = function() end,
                    warning = function() end,
                    debug = function() end,
                }
            end
            if name == "table_pool" or name == "utils.table_pool" then
                return {
                    get = function() return {} end,
                    release = function() end,
                    register_type = function() end,
                }
            end
            return nil
        end,
        get_global_dependency = function() return nil end,
    }

    _G.log_errors_for_filter_test = log_errors
    _G.ModuleManager = ref_ModuleManager
    FilterEngine = require("src.utils.filter_engine")
end)

suite:teardown(function()
    _G.log_errors_for_filter_test = nil
    package.loaded["src.utils.filter_engine"] = nil
    _G.ModuleManager = nil
end)

suite:add_test("INT-FIL-01: FilterEngine ↔ Logger — Script Error логируется при невалидном скрипте", function()
    local log_errors = _G.log_errors_for_filter_test
    Assert.is_not_nil(log_errors, "лог ошибок")
    Assert.is_true(type(log_errors) == "table", "лог — таблица")

    local filters = { script = "{{" }
    local result = FilterEngine.match({ x = 1 }, filters)

    Assert.is_false(result, "match должен вернуть false при ошибке скрипта")
    Assert.is_true(#log_errors >= 1, "Logger.error должен быть вызван")
    local last = log_errors[#log_errors]
    Assert.are_equal("FilterEngine", last.comp, "компонент FilterEngine")
    Assert.is_true(
        (last.fmt or ""):find("Script Error") ~= nil or (last.fmt or ""):find("Error") ~= nil,
        "сообщение должно содержать Script Error или Error"
    )
end)

suite:add_test("INT-FIL-02: FilterEngine ↔ Logger — при ошибке скрипта возврат false (откат)", function()
    local filters = { script = "syntax error ((" }
    local result = FilterEngine.match({ a = 1 }, filters)
    Assert.is_false(result, "откат к false при невалидном скрипте")
end)

suite:run()
