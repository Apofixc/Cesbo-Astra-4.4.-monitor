-- Проверка, что тесты запущены через run_test.lua
if not _G.RUN_TEST_ACTIVE then
    io.stderr:write("Ошибка: Тестовые файлы должны быть запущены через 'run_test.lua'. Прямой запуск запрещен.\n")
    os.exit(1)
end

--- @class TestSuite
--- @field name string
--- @field tests table<string, function>
--- @field setup_func function|nil
--- @field before_each_func function|nil
--- @field before_each_map table<string, function>
--- @field after_each_func function|nil
--- @field after_each_map table<string, function>
--- @field teardown_func function|nil
--- @field total_tests number
--- @field passed_tests number
--- @field failed_tests number
local TestSuite = {}
TestSuite.__index = TestSuite

local _global_state_before_test = {}

--- Сохраняет текущее состояние глобальной таблицы _G.
function _G.save_global_state()
    _global_state_before_test = {}
    for k, v in pairs(_G) do
        _global_state_before_test[k] = true
    end
end

--- Проверяет наличие новых глобальных переменных после выполнения теста.
--- @param test_name string Имя текущего теста для логирования.
function _G.check_global_leak(test_name)
    local new_globals = {}
    for k, v in pairs(_G) do
        if not _global_state_before_test[k] then
            table.insert(new_globals, tostring(k))
        end
    end
    if #new_globals > 0 then
        error(string.format("Тест '%s' создал новые глобальные переменные: %s", test_name, table.concat(new_globals, ", ")))
    end
end

--- @param name string
--- @return TestSuite
function TestSuite:new(name)
    local self = setmetatable({}, TestSuite)
    self.name = name
    self.tests = {}
    self.setup_func = nil
    self.before_each_func = nil
    self.before_each_map = {}
    self.after_each_func = nil
    self.after_each_map = {}
    self.teardown_func = nil
    self.total_tests = 0
    self.passed_tests = 0
    self.failed_tests = 0
    return self
end

--- @param func function
function TestSuite:setup(func)
    self.setup_func = func
end

--- @param test_name string|function
--- @param func function|nil
function TestSuite:before_each(test_name, func)
    if type(test_name) == "function" then
        self.before_each_func = test_name
    elseif type(test_name) == "string" and type(func) == "function" then
        self.before_each_map[test_name] = func
    end
end

--- @param test_name string|function
--- @param func function|nil
function TestSuite:after_each(test_name, func)
    if type(test_name) == "function" then
        self.after_each_func = test_name
    elseif type(test_name) == "string" and type(func) == "function" then
        self.after_each_map[test_name] = func
    end
end

--- @param func function
function TestSuite:teardown(func)
    self.teardown_func = func
end

--- @param test_name string
--- @param func function
function TestSuite:add_test(test_name, func)
    self.tests[test_name] = func
end

--- @return boolean success
function TestSuite:run()
    local print = print
    
    print(string.format("--- Запуск тестового набора: %s ---", self.name))
    local all_passed = true

    if self.setup_func then
        local status, err = pcall(self.setup_func)
        if not status then
            print(string.format("  [ОШИБКА] Setup: %s", tostring(err)))
            return false
        end
    end

    -- Получаем и сортируем имена тестов
    local test_names = {}
    for name, _ in pairs(self.tests) do
        table.insert(test_names, name)
    end
    table.sort(test_names)

    for _, test_name in ipairs(test_names) do
        self.total_tests = self.total_tests + 1
        _G.save_global_state() -- Сохраняем состояние _G перед каждым тестом

        local current_before_each = self.before_each_map[test_name] or self.before_each_func
        if current_before_each then
            local status, err = pcall(current_before_each)
            if not status then
                all_passed = false
                self.failed_tests = self.failed_tests + 1
                print(string.format("  [ОШИБКА] BeforeEach для '%s': %s", test_name, tostring(err)))
                goto continue_test_loop
            end
        end

        local test_status, test_err = pcall(self.tests[test_name])
        local leak_status, leak_err = pcall(_G.check_global_leak, test_name) -- Всегда проверяем утечки

        if test_status and leak_status then
            self.passed_tests = self.passed_tests + 1
            print(string.format("  [УСПЕХ] %s", test_name))
        else
            all_passed = false
            self.failed_tests = self.failed_tests + 1
            if not test_status then
                print(string.format("  [ОШИБКА] %s: %s", test_name, tostring(test_err)))
            end
            if not leak_status then
                print(string.format("  [ОШИБКА] %s (утечка глобальных переменных): %s", test_name, tostring(leak_err)))
            end
        end

        local current_after_each = self.after_each_map[test_name] or self.after_each_func
        if current_after_each then
            local status, err = pcall(current_after_each)
            if not status then
                all_passed = false
                -- Если AfterEach падает, это не провал самого теста, но ошибка в тестовом фреймворке
                -- Можно считать это ошибкой в наборе, но не в конкретном тесте, если тест уже прошел
                print(string.format("  [ОШИБКА] AfterEach для '%s': %s", test_name, tostring(err)))
            end
        end
        ::continue_test_loop::
    end

    if self.teardown_func then
        local status, err = pcall(self.teardown_func)
        if not status then
            all_passed = false
            print(string.format("  [ОШИБКА] Teardown: %s", tostring(err)))
        end
    end

    print(string.format("--- Тестовый набор %s завершен ---", self.name))
    print(string.format("  Всего тестов: %d", self.total_tests))
    print(string.format("  Успешно: %d", self.passed_tests))
    print(string.format("  С ошибками: %d", self.failed_tests))
    return all_passed
end

--- @class Assert
local Assert = {}

local function require_message(message, method)
    if message == nil or type(message) ~= "string" or message == "" then
        error(string.format("Assert.%s: параметр message обязателен (строка, не пустая)", method))
    end
end

--- @param condition boolean
--- @param message string Обязателен.
function Assert.is_true(condition, message)
    require_message(message, "is_true")
    if not condition then
        error(message)
    end
end

--- @param condition boolean
--- @param message string Обязателен.
function Assert.is_false(condition, message)
    require_message(message, "is_false")
    if condition then
        error(message)
    end
end

--- @param expected any
--- @param actual any
--- @param message string Обязателен.
function Assert.are_equal(expected, actual, message)
    require_message(message, "are_equal")
    if expected ~= actual then
        error(message)
    end
end

--- @param expected any
--- @param actual any
--- @param message string Обязателен.
function Assert.are_not_equal(expected, actual, message)
    require_message(message, "are_not_equal")
    if expected == actual then
        error(message)
    end
end

--- @param value any
--- @param message string Обязателен.
function Assert.is_nil(value, message)
    require_message(message, "is_nil")
    if value ~= nil then
        error(message)
    end
end

--- @param value any
--- @param message string Обязателен.
function Assert.is_not_nil(value, message)
    require_message(message, "is_not_nil")
    if value == nil then
        error(message)
    end
end

--- @param func function
--- @param message string Обязателен.
function Assert.raises_error(func, message)
    require_message(message, "raises_error")
    local status, err = pcall(func)
    if status then
        error(message)
    end
end

--- @param str string
--- @param prefix string
--- @param message string
function Assert.string_starts_with(str, prefix, message)
    require_message(message, "string_starts_with")
    if not str or not prefix or string.sub(str, 1, #prefix) ~= prefix then
        error(message)
    end
end

--- Вспомогательная функция для проверки наличия элемента в таблице
--- @param tbl table
--- @param val any
--- @return boolean
local function contains(tbl, val)
    for _, v in ipairs(tbl) do
        if v == val then
            return true
        end
    end
    return false
end

--- Формирует текстовое сообщение лога с защитой от ошибок форматирования
--- @param format_str any
--- @param ... any
--- @return string
local function format_message(format_str, ...)
    local str = tostring(format_str)
    if select("#", ...) > 0 then
        local ok, res = pcall(string.format, str, ...)
        if ok then return res end
        return str .. " [ОШИБКА ФОРМАТИРОВАНИЯ]"
    end
    return str
end

return {
    TestSuite = TestSuite,
    Assert = Assert,
    contains = contains,
    format_message = format_message, -- Добавляем новую функцию
}
