-- L2: Unit-тесты для модуля utils (src.utils.utils)
-- Моки: ModuleManager (logger, monitor_config, utils.hostname, parse_url).

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
local Mock = require("tools.test_moc")

local mock
local local_mock
local Utils
local ref_ModuleManager
local log_errors
local mock_monitor_config

local suite = TestSuite:new("L2.utils")

suite:setup(function()
    mock = Mock:new()
    log_errors = {}

    mock_monitor_config = {
        STREAM = { ["192.168.1.1"] = "stream_a" },
        Monitor = { MaxMonitorNameLength = 64 },
        ValidationSchema = {
            Instance = {
                time_check = { type = "number", default = 5, min = 1, max = 60 },
                name = { type = "string", default = "" },
            }
        }
    }

    ref_ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return {
                    error = function(_, ...) log_errors[#log_errors + 1] = { ... } end,
                    info = function() end,
                }
            end
            if name == "monitor_config" then return mock_monitor_config end
            return nil
        end,
        get_global_dependency = function(name)
            if name == "utils.hostname" then return function() return "testhost" end end
            if name == "parse_url" then
                return function(url)
                    if url == "http://host/path" then
                        return { host = "host", path = "/path", scheme = "http" }
                    end
                    return nil
                end
            end
            return nil
        end,
    }
    mock:mock_global("ModuleManager", ref_ModuleManager)
end)

suite:before_each(function()
    log_errors = {}
    package.loaded["src.utils.utils"] = nil
    Utils = require("src.utils.utils")
end)

suite:after_each(function()
    if local_mock then
        local_mock:restore()
        local_mock = nil
    end
end)

suite:teardown(function()
    mock:restore()
end)

-- get_stream_name
suite:add_test("get_stream_name: по IP возвращает имя из STREAM", function()
    Assert.are_equal("stream_a", Utils.get_stream_name("192.168.1.1"), "по IP возвращается имя из STREAM")
end)
suite:add_test("get_stream_name: неизвестный IP возвращает тот же IP", function()
    Assert.are_equal("10.0.0.1", Utils.get_stream_name("10.0.0.1"), "неизвестный IP как есть")
end)
suite:add_test("get_stream_name: не строка логирует и возвращает nil", function()
    Assert.is_nil(Utils.get_stream_name(123), "не строка — nil")
    Assert.is_nil(Utils.get_stream_name(nil), "nil — nil")
    Assert.is_true(#log_errors >= 1, "ошибка логируется при некорректном ip_address")
end)

-- ratio
suite:add_test("ratio: одинаковые числа 0", function()
    Assert.are_equal(0, Utils.ratio(5, 5), "одинаковые числа — 0")
end)
suite:add_test("ratio: различие при max_abs > 0", function()
    local r = Utils.ratio(10, 20)
    Assert.is_true(r > 0 and r <= 1, "ratio в (0, 1]")
end)
suite:add_test("ratio: один ноль возвращает 1", function()
    Assert.are_equal(1, Utils.ratio(0, 100), "один ноль — 1")
end)
suite:add_test("ratio: оба нуля max_abs == 0 возвращает 0", function()
    Assert.are_equal(0, Utils.ratio(0, 0), "оба нуля — 0")
end)

-- table_copy, table_merge
suite:add_test("table_copy: поверхностная копия", function()
    local t = { a = 1, b = 2 }
    local c = Utils.table_copy(t)
    Assert.are_equal(1, c.a, "копия поля a")
    Assert.are_equal(2, c.b, "копия поля b")
    c.a = 99
    Assert.are_equal(1, t.a, "оригинал не изменён")
end)
suite:add_test("table_merge: слияние в dst", function()
    local dst = { x = 1 }
    Utils.table_merge(dst, { y = 2, z = 3 })
    Assert.are_equal(1, dst.x, "merge x")
    Assert.are_equal(2, dst.y, "merge y")
    Assert.are_equal(3, dst.z, "merge z")
end)
suite:add_test("table_merge: не таблица — выход", function()
    local dst = { a = 1 }
    Utils.table_merge(dst, "not table")
    Assert.are_equal(1, dst.a, "dst не изменён")
end)

-- split
suite:add_test("split: по разделителю", function()
    local parts = Utils.split("a,b,c", ",")
    Assert.are_equal(3, #parts, "три части")
    Assert.are_equal("a", parts[1], "часть 1")
    Assert.are_equal("b", parts[2], "часть 2")
    Assert.are_equal("c", parts[3], "часть 3")
end)
suite:add_test("split: не строка nil", function()
    Assert.is_nil(Utils.split(123, ","), "не строка — nil")
end)

-- deep_copy
suite:add_test("deep_copy: вложенная таблица", function()
    local t = { a = { b = 2 } }
    local c = Utils.deep_copy(t)
    Assert.are_equal(2, c.a.b, "вложенное поле копии")
    c.a.b = 0
    Assert.are_equal(2, t.a.b, "вложенная копия")
end)
suite:add_test("deep_copy: не таблица возвращает значение", function()
    Assert.are_equal(42, Utils.deep_copy(42), "число как есть")
end)
suite:add_test("deep_copy: циклическая ссылка возвращается из cache", function()
    local t = {}
    t.self = t
    local c = Utils.deep_copy(t)
    Assert.are_equal(c, c.self, "цикл через cache")
end)

-- shallow_compare
suite:add_test("shallow_compare: одинаковые таблицы true", function()
    Assert.is_true(Utils.shallow_compare({ a = 1 }, { a = 1 }), "одинаковые — true")
end)
suite:add_test("shallow_compare: разный ключ false", function()
    Assert.is_false(Utils.shallow_compare({ a = 1 }, { b = 1 }), "разный ключ — false")
end)

-- validate_monitor_param
suite:add_test("validate_monitor_param: валидное число", function()
    Assert.are_equal(10, Utils.validate_monitor_param("time_check", 10), "валидное число возвращается")
end)
suite:add_test("validate_monitor_param: nil возвращает default", function()
    Assert.are_equal(5, Utils.validate_monitor_param("time_check", nil), "nil — default")
end)
suite:add_test("validate_monitor_param: неизвестный параметр логирует и nil", function()
    Assert.is_nil(Utils.validate_monitor_param("unknown_param", 1), "неизвестный параметр — nil")
    Assert.are_equal(1, #log_errors, "неизвестный параметр логируется")
end)
suite:add_test("validate_monitor_param: строка для number приводится через tonumber", function()
    Assert.are_equal(15, Utils.validate_monitor_param("time_check", "15"), "строка приводится к number")
end)
suite:add_test("validate_monitor_param: значение < min возвращает default и логирует", function()
    Assert.are_equal(5, Utils.validate_monitor_param("time_check", 0), "default при < min")
    Assert.is_true(#log_errors >= 1, "значение < min логируется")
end)
suite:add_test("validate_monitor_param: значение > max возвращает default и логирует", function()
    Assert.are_equal(5, Utils.validate_monitor_param("time_check", 100), "default при > max")
    Assert.is_true(#log_errors >= 1, "значение > max логируется")
end)
suite:add_test("validate_monitor_param: неверный тип возвращает default и логирует", function()
    Assert.are_equal(5, Utils.validate_monitor_param("time_check", "not_number"), "default при неверном типе")
    Assert.is_true(#log_errors >= 1, "неверный тип логируется")
end)

-- validate_monitor_name
suite:add_test("validate_monitor_name: валидное имя", function()
    Assert.is_true(Utils.validate_monitor_name("monitor_1"), "валидное имя — true")
end)
suite:add_test("validate_monitor_name: пустая строка false", function()
    Assert.is_false(Utils.validate_monitor_name(""), "пустая строка — false")
end)
suite:add_test("validate_monitor_name: спецсимволы false", function()
    Assert.is_false(Utils.validate_monitor_name("monitor@"), "спецсимволы — false")
end)
suite:add_test("validate_monitor_name: длина больше MaxMonitorNameLength false", function()
    mock_monitor_config.Monitor.MaxMonitorNameLength = 5
    Assert.is_false(Utils.validate_monitor_name("longname"), "длина > max — false")
    mock_monitor_config.Monitor.MaxMonitorNameLength = 64
end)

-- get_server_name
suite:add_test("get_server_name: возвращает hostname из зависимости", function()
    Assert.are_equal("testhost", Utils.get_server_name(), "hostname из зависимости")
end)

-- parse_url
suite:add_test("parse_url: валидный URL", function()
    local r = Utils.parse_url("http://host/path")
    Assert.is_not_nil(r, "parse_url возвращает таблицу")
    Assert.are_equal("host", r.host, "host из URL")
end)
suite:add_test("parse_url: пустая строка nil", function()
    Assert.is_nil(Utils.parse_url(""), "пустая строка — nil")
end)
suite:add_test("parse_url: при отсутствии parse_url логирует и nil", function()
    local_mock = Mock:new()
    local orig_gd = ref_ModuleManager.get_global_dependency
    local mod_mm = {
        get_module = ref_ModuleManager.get_module,
        get_global_dependency = function(name)
            if name == "parse_url" then return nil end
            return orig_gd(name)
        end
    }
    local_mock:mock_global("ModuleManager", mod_mm)
    package.loaded["src.utils.utils"] = nil
    local U = require("src.utils.utils")
    Assert.is_nil(U.parse_url("http://x/y"), "parse_url должен вернуть nil при отсутствии зависимости")
    Assert.is_true(#log_errors >= 1, "должна быть запись в log_errors при отсутствии parse_url")
end)

-- init_report
suite:add_test("init_report: заполняет type, name, server", function()
    local t = {}
    Utils.init_report(t, "dvb", "tuner1")
    Assert.are_equal("dvb", t.type, "init_report type")
    Assert.are_equal("tuner1", t.name, "init_report name")
    Assert.are_equal("testhost", t.server, "init_report server")
end)
suite:add_test("init_report: не таблица — выход", function()
    Utils.init_report(123, "dvb", "x")
end)

-- table_clear
suite:add_test("table_clear: очищает ключи", function()
    local t = { a = 1, b = 2 }
    Utils.table_clear(t)
    Assert.is_nil(t.a, "лишние поля nil")
    Assert.is_nil(t.b, "лишние поля nil")
end)

-- shell_escape
suite:add_test("shell_escape: кавычки экранируются", function()
    local s = Utils.shell_escape("a'b")
    Assert.is_true(#s > 0, "shell_escape не пустой")
    Assert.is_true(s:find("'"), "кавычки экранированы")
end)

-- truncate_string
suite:add_test("truncate_string: длинная строка обрезается", function()
    local long = string.rep("x", 20)
    Assert.are_equal(10, #Utils.truncate_string(long, 10), "длина обрезанной строки 10")
    Assert.are_equal("xxxxxxx...", Utils.truncate_string(long, 10), "суффикс ...")
end)

-- to_line_protocol
suite:add_test("to_line_protocol: measurement и fields", function()
    local line = Utils.to_line_protocol("cpu", { host = "h1" }, { value = 42 })
    Assert.is_not_nil(line, "to_line_protocol возвращает строку")
    Assert.is_true(line:find("cpu") ~= nil, "measurement в строке")
    Assert.is_true(line:find("42") ~= nil, "поле в строке")
end)
suite:add_test("to_line_protocol: не таблица fields nil", function()
    Assert.is_nil(Utils.to_line_protocol("m", nil, "not table"), "не таблица fields — nil")
end)
suite:add_test("to_line_protocol: поле string и boolean", function()
    local line = Utils.to_line_protocol("m", nil, { s = "v", b = true })
    Assert.is_true(line:find('"v"') ~= nil, "string поле в кавычках")
    Assert.is_true(line:find("=t") ~= nil or line:find("=f") ~= nil, "boolean в строке")
end)
suite:add_test("to_line_protocol: с timestamp", function()
    local line = Utils.to_line_protocol("m", nil, { x = 1 }, 1234567890)
    Assert.is_true(line:find("000000000") ~= nil, "timestamp в строке")
end)

-- measure_time, get_performance_stats
suite:add_test("measure_time: выполняет функцию и возвращает результат", function()
    local r = Utils.measure_time("op1", function(a, b) return a + b end, 2, 3)
    Assert.are_equal(5, r, "возврат результата функции")
end)
suite:add_test("get_performance_stats: возвращает копию статистики", function()
    Utils.measure_time("op2", function() end)
    local stats = Utils.get_performance_stats()
    Assert.is_not_nil(stats.op2, "операция op2 в статистике")
    Assert.are_equal(1, stats.op2.count, "count вызовов 1")
end)
suite:add_test("measure_time: при ошибке в func пробрасывает ошибку после _update_stats", function()
    local ok, err = pcall(Utils.measure_time, "err_op", function() error("fail") end)
    Assert.is_false(ok, "ошибка в func — false")
    Assert.is_true(tostring(err):find("fail") ~= nil, "сообщение об ошибке")
    local stats = Utils.get_performance_stats()
    Assert.is_not_nil(stats.err_op, "ошибка записана в статистику")
end)
suite:add_test("measure_time: несколько вызовов обновляют stats (min/max/avg)", function()
    Utils.measure_time("multi_op", function() end)
    Utils.measure_time("multi_op", function() end)
    local stats = Utils.get_performance_stats()
    Assert.is_not_nil(stats.multi_op, "операция multi_op в статистике")
    Assert.are_equal(2, stats.multi_op.count, "count == 2")
    Assert.is_true(stats.multi_op.total_time >= 0, "total_time задана")
    Assert.is_true(stats.multi_op.avg_time >= 0, "avg_time задана")
    Assert.is_true(stats.multi_op.max_time >= 0, "max_time задана")
    Assert.is_true(type(stats.multi_op.min_time) == "number", "min_time задана")
end)
suite:add_test("truncate_string: короткая строка возвращается целиком", function()
    Assert.are_equal("ab", Utils.truncate_string("ab", 10), "короткая без обрезки")
end)
suite:add_test("truncate_string: не строка возвращает пустую строку", function()
    Assert.are_equal("", Utils.truncate_string(nil, 5), "nil — пустая строка")
end)

-- is_port_busy / free_port: с моком io.popen для покрытия веток
suite:add_test("is_port_busy: nil port false", function()
    Assert.is_false(Utils.is_port_busy(nil), "nil port — false")
end)
suite:add_test("is_port_busy: popen возвращает nil — false", function()
    local_mock = Mock:new()
    local_mock:mock_global("io", { popen = function() return nil end })
    package.loaded["src.utils.utils"] = nil
    local U = require("src.utils.utils")
    Assert.is_false(U.is_port_busy(65432), "popen nil — false")
end)
suite:add_test("is_port_busy: popen читает пусто — false", function()
    local_mock = Mock:new()
    local_mock:mock_global("io", {
        popen = function()
            return { read = function() return "" end, close = function() end }
        end
    })
    package.loaded["src.utils.utils"] = nil
    local U = require("src.utils.utils")
    Assert.is_false(U.is_port_busy(65432), "popen пусто — false")
end)
suite:add_test("is_port_busy: popen читает данные — true", function()
    local_mock = Mock:new()
    local_mock:mock_global("io", {
        popen = function()
            return { read = function() return "LISTEN" end, close = function() end }
        end
    })
    package.loaded["src.utils.utils"] = nil
    local U = require("src.utils.utils")
    Assert.is_true(U.is_port_busy(80), "popen с данными — true")
end)
suite:add_test("free_port: nil port false", function()
    Assert.is_false(Utils.free_port(nil), "nil port — false")
end)
suite:add_test("free_port: порт свободен — true без ожидания", function()
    local_mock = Mock:new()
    local_mock:mock_global("io", {
        popen = function()
            return { read = function() return "" end, close = function() end }
        end
    })
    package.loaded["src.utils.utils"] = nil
    local U = require("src.utils.utils")
    Assert.is_true(U.free_port(65333), "свободный порт — true")
end)
suite:add_test("free_port: порт был занят, после ожидания свободен — true", function()
    local_mock = Mock:new()
    local read_count = 0
    local_mock:mock_global("io", {
        popen = function()
            return {
                read = function()
                    read_count = read_count + 1
                    return (read_count == 1) and "LISTEN" or ""
                end,
                close = function() end
            }
        end
    })
    local_mock:mock_global("os", { clock = function() return read_count * 1.0 end })
    package.loaded["src.utils.utils"] = nil
    local U = require("src.utils.utils")
    Assert.is_true(U.free_port(65400), "после ожидания порт свободен — true")
end)
suite:add_test("free_port: порт остаётся занят — false и логирование ошибки", function()
    local_mock = Mock:new()
    local clock_calls = 0
    local_mock:mock_global("io", {
        popen = function()
            return { read = function() return "LISTEN" end, close = function() end }
        end
    })
    local_mock:mock_global("os", {
        clock = function()
            clock_calls = clock_calls + 1
            return clock_calls > 1 and 5 or 0
        end
    })
    package.loaded["src.utils.utils"] = nil
    local U = require("src.utils.utils")
    Assert.is_false(U.free_port(65401), "порт занят — false")
    Assert.is_true(#log_errors >= 1, "free_port при занятом порте логирует")
end)

suite:run()
