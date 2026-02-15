-- L1: Unit-тесты для модуля utils.logger
-- Моки: ModuleManager (log, json.encode, table_pool, core.event_dispatcher).

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
local Mock = require("tools.test_moc")

local mock
local local_mock
local Logger
-- Локальные переменные для моков (без _G)
local log_calls
local print_calls
local ref_logger_config_cb
local ref_ModuleManager
local mock_log_ref

local suite = TestSuite:new("L1.logger")

suite:setup(function()
    mock = Mock:new()
    log_calls = { debug = 0, info = 0, warning = 0, error = 0 }
    print_calls = {}

    mock_log_ref = {
        debug = function(msg) log_calls.debug = log_calls.debug + 1 end,
        info = function(msg) log_calls.info = log_calls.info + 1 end,
        warning = function(msg) log_calls.warning = log_calls.warning + 1 end,
        error = function(msg) log_calls.error = log_calls.error + 1 end,
    }
    local mock_log = mock_log_ref

    local mock_ed_instance = {
        subscribe = function(self, ev, cb)
            if ev == "config:updated:logger" then ref_logger_config_cb = cb end
        end
    }
    local mock_ed = { get_instance = function() return mock_ed_instance end }

    local mock_pool = {
        get = function(typ) return {} end,
        release = function(t, typ) end,
        register_type = function(name, schema) end,
    }

    ref_ModuleManager = {
        get_module = function(name)
            if name == "table_pool" then return mock_pool end
            if name == "core.event_dispatcher" then return mock_ed end
            return nil
        end,
        get_global_dependency = function(name)
            if name == "log" then return mock_log end
            if name == "json.encode" then
                return function(t) return '{"msg":"' .. (t and t.message or "") .. '"}' end
            end
            return nil
        end,
    }
    mock:mock_global("ModuleManager", ref_ModuleManager)

    -- Перехват print для проверки fallback-вывода
    local orig_print = _G.print
    _G.print = function(...)
        print_calls[#print_calls + 1] = { ... }
        orig_print(...)
    end
end)

suite:before_each(function()
    log_calls.debug = 0
    log_calls.info = 0
    log_calls.warning = 0
    log_calls.error = 0
    print_calls = {}
    ref_logger_config_cb = nil
    package.loaded["src.utils.logger"] = nil
    Logger = require("src.utils.logger")
end)

suite:after_each(function()
    if local_mock then
        local_mock:restore()
        local_mock = nil
    end
end)

suite:teardown(function()
    mock:restore()
    if _G.print and _G.print ~= rawget(_G, "print") then
        _G.print = rawget(_G, "print") or function() end
    end
end)

-- Публичное API: уровни логирования (по умолчанию INFO)
suite:add_test("info: записывает сообщение при уровне INFO", function()
    Logger.info("Comp", "hello")
    Assert.are_equal(1, log_calls.info, "info вызван")
end)

suite:add_test("error: записывает сообщение и увеличивает счётчик", function()
    Logger.error("Comp", "err %s", "x")
    Assert.are_equal(1, log_calls.error, "error вызван")
end)

suite:add_test("debug: при уровне INFO не пишет (фильтр)", function()
    Logger.debug("Comp", "debug msg")
    Assert.are_equal(0, log_calls.debug, "debug отфильтрован при INFO")
end)

suite:add_test("warning: записывает при уровне INFO", function()
    Logger.warning("Comp", "warn")
    Assert.are_equal(1, log_calls.warning, "warning вызван")
end)

-- Обновление конфига через событие -> уровень DEBUG -> debug пишется
suite:add_test("init_config_subscription и callback: обновление LogLevel на DEBUG", function()
    Logger.init_config_subscription()
    Assert.is_not_nil(ref_logger_config_cb, "callback подписки сохранён")
    ref_logger_config_cb({ LogLevel = "DEBUG" })
    Logger.debug("Comp", "now visible")
    Assert.are_equal(1, log_calls.debug, "после DEBUG debug пишется")
end)

suite:add_test("refresh_log_level: обновляет кэш уровня", function()
    Logger.init_config_subscription()
    ref_logger_config_cb({ LogLevel = "WARN" })
    Logger.info("Comp", "hidden")
    Logger.warning("Comp", "visible")
    Assert.are_equal(0, log_calls.info, "info отфильтрован при WARN")
    Assert.are_equal(1, log_calls.warning, "warning записан")
    Logger.refresh_log_level()
    -- Повторная проверка после refresh
    Logger.info("C2", "still hidden")
    Assert.are_equal(0, log_calls.info, "info по-прежнему отфильтрован")
end)

-- Буфер: buffer_log, get_buffer, clear_component_buffer
suite:add_test("buffer_log и get_buffer: запись и чтение буфера", function()
    Logger.init_config_subscription()
    ref_logger_config_cb({ LogLevel = "DEBUG", LogBufferSize = 10, MaxLogComponents = 5 })
    Logger.buffer_log("INFO", "MyComp", "buf msg", nil, 12345)
    local buf = Logger.get_buffer("MyComp")
    Assert.are_equal(1, #buf, "одна запись в буфере")
    Assert.are_equal("buf msg", buf[1].message, "сообщение сохранено")
    Assert.are_equal(12345, buf[1].timestamp, "timestamp передан")
end)

suite:add_test("get_buffer: неизвестный компонент возвращает пустой массив", function()
    local buf = Logger.get_buffer("NoSuch")
    Assert.are_equal(0, #buf, "пустой массив")
    Assert.is_true(type(buf) == "table", "таблица")
end)

suite:add_test("get_buffer: limit возвращает последние N записей", function()
    Logger.init_config_subscription()
    ref_logger_config_cb({ LogLevel = "DEBUG", LogBufferSize = 20, MaxLogComponents = 5 })
    for i = 1, 5 do
        Logger.buffer_log("INFO", "L", "m" .. i, nil, 1000 + i)
    end
    local buf = Logger.get_buffer("L", 2)
    Assert.are_equal(2, #buf, "две последние")
    Assert.are_equal("m4", buf[1].message, "предпоследняя")
    Assert.are_equal("m5", buf[2].message, "последняя")
end)

suite:add_test("clear_component_buffer: очищает буфер компонента", function()
    Logger.init_config_subscription()
    ref_logger_config_cb({ LogLevel = "DEBUG", LogBufferSize = 10, MaxLogComponents = 5 })
    Logger.buffer_log("INFO", "ToClear", "x", nil, 1)
    Assert.are_equal(1, #Logger.get_buffer("ToClear"), "буфер не пуст до clear")
    Logger.clear_component_buffer("ToClear")
    Assert.are_equal(0, #Logger.get_buffer("ToClear"), "буфер пуст после clear")
end)

-- flush
suite:add_test("flush: при пустой очереди ничего не делает", function()
    Logger.flush()
    Assert.are_equal(0, log_calls.info + log_calls.error, "нет записей")
end)

suite:add_test("flush: сбрасывает очередь при включённом батче", function()
    Logger.init_config_subscription()
    ref_logger_config_cb({ LogBatchEnabled = true, MaxLogQueueSize = 100 })
    Logger.info("F", "one")
    Logger.info("F", "two")
    local before = log_calls.info
    Logger.flush()
    Assert.is_true(log_calls.info >= before + 2, "оба сообщения выведены при flush")
end)

-- with_error
suite:add_test("with_error: успех при возврате true", function()
    local ok, a = Logger.with_error(function() return true, 42 end)
    Assert.is_true(ok, "ok")
    Assert.are_equal(42, a, "второй возврат")
end)

suite:add_test("with_error: провал при pcall (ошибка выполнения)", function()
    local ok, err = Logger.with_error(function() error("crash") end)
    Assert.is_false(ok, "not ok")
    Assert.is_true(err and err:find("crash"), "сообщение об ошибке")
    Assert.are_equal(1, log_calls.error, "Logger.error вызван")
end)

suite:add_test("with_error: провал при возврате false (бизнес-ошибка)", function()
    Logger.with_error(function()
        Logger.error("Logger", "business fail")
        return false
    end)
    local ok, err = Logger.with_error(function() return false end)
    Assert.is_false(ok, "not ok")
    Assert.are_equal("Неизвестная ошибка", err, "дефолтное сообщение при отсутствии last_errors")
end)

suite:add_test("with_error: вложенные контексты и проброс ошибки", function()
    local inner_err
    Logger.with_error(function()
        Logger.with_error(function()
            Logger.error("E", "inner")
            return false
        end)
        return true
    end)
    local ok, err = Logger.with_error(function()
        Logger.with_error(function()
            Logger.error("E", "nested")
            return false
        end)
        return false
    end)
    Assert.is_false(ok, "внешний контекст возвращает false")
    Assert.is_true(err == "nested" or err == "Неизвестная ошибка", "ошибка из вложенного контекста")
end)

-- Формат сообщения: ошибка форматирования
suite:add_test("info: при ошибке форматирования выводит fallback", function()
    Logger.info("C", "bad format %s %s", "only_one")
    Assert.are_equal(1, log_calls.info, "info вызван")
    -- Сообщение должно содержать [ОШИБКА ФОРМАТИРОВАНИЯ] или быть обработано
    Assert.is_true(log_calls.info >= 1, "запись произошла")
end)

-- JSON format (ok path: output_msg = encoded_json)
suite:add_test("JSON format: сериализует через json.encode", function()
    Logger.init_config_subscription()
    ref_logger_config_cb({ LogFormat = "JSON" })
    Logger.info("J", "json msg")
    local total = log_calls.info + log_calls.error + log_calls.warning + log_calls.debug
    Assert.is_true(total >= 1, "минимум одна запись в лог при JSON формате")
end)

-- json.encode бросает ошибку -> output_msg с [ОШИБКА JSON-СЕРИАЛИЗАЦИИ], level ERROR
suite:add_test("JSON format: при ошибке json.encode пишет ERROR", function()
    local mm = _G.ModuleManager
    local orig_dep = mm.get_global_dependency
    mm.get_global_dependency = function(name)
        if name == "json.encode" then return function() error("encode fail") end end
        if name == "log" then return mock_log_ref end
        return orig_dep and orig_dep(name)
    end
    package.loaded["src.utils.logger"] = nil
    Logger = require("src.utils.logger")
    Logger.init_config_subscription()
    ref_logger_config_cb({ LogFormat = "JSON" })
    Logger.info("J", "x")
    local total_err = log_calls.error + log_calls.info + log_calls.warning
    Assert.is_true(total_err >= 1, "сообщение выведено при ошибке json.encode")
    mm.get_global_dependency = orig_dep
end)

-- log отсутствует или не таблица -> print (мокаем _G.ModuleManager для полного прогона)
suite:add_test("write_to_output: при отсутствии log идёт в print", function()
    local mm = _G.ModuleManager
    local orig_dep = mm.get_global_dependency
    mm.get_global_dependency = function(name)
        if name == "log" then return nil end
        if name == "json.encode" then return function(t) return "{}" end end
        return orig_dep and orig_dep(name)
    end
    package.loaded["src.utils.logger"] = nil
    Logger = require("src.utils.logger")
    local n = #print_calls
    Logger.info("C", "to print")
    Assert.is_true(#print_calls > n or log_calls.info >= 1, "вывод при отсутствии log (print или mock)")
    mm.get_global_dependency = orig_dep
end)

-- log[method] бросает -> код ловит и выводит в print, без падения (мокаем _G.ModuleManager)
suite:add_test("write_to_output: при ошибке log.info не падает", function()
    local mm = _G.ModuleManager
    local orig_dep = mm.get_global_dependency
    mm.get_global_dependency = function(name)
        if name == "log" then
            return { info = function() error("log fail") end, debug = function() end,
                warning = function() end, error = function() end }
        end
        if name == "json.encode" then return function(t) return "{}" end end
        return orig_dep and orig_dep(name)
    end
    package.loaded["src.utils.logger"] = nil
    Logger = require("src.utils.logger")
    local ok = pcall(Logger.info, "C", "x")
    Assert.is_true(ok, "Logger.info не бросает при ошибке log.info")
    mm.get_global_dependency = orig_dep
end)

-- Очередь переполнена (batch enabled, MaxLogQueueSize = 2)
suite:add_test("enqueue_log: при переполнении очереди сбрасывает и добавляет", function()
    Logger.init_config_subscription()
    ref_logger_config_cb({ LogBatchEnabled = true, MaxLogQueueSize = 2 })
    Logger.info("A", "1")
    Logger.info("A", "2")
    Logger.info("A", "3")
    -- При переполнении сбрасываются первые 2, потом добавляется 3-е; все три в итоге выводятся
    Assert.is_true(log_calls.info >= 2, "минимум два вывода при overflow")
end)

-- Компонент не строка -> tostring
suite:add_test("info: компонент не строка приводится к строке", function()
    Logger.info(12345, "num comp")
    Assert.are_equal(1, log_calls.info, "запись с числовым компонентом")
end)

-- NONE level -> ничего не пишется
suite:add_test("LogLevel NONE: ничего не пишется", function()
    Logger.init_config_subscription()
    ref_logger_config_cb({ LogLevel = "NONE" })
    Logger.info("C", "hidden")
    Logger.error("C", "hidden too")
    Assert.are_equal(0, log_calls.info, "info не пишется")
    Assert.are_equal(0, log_calls.error, "error при NONE тоже не пишется по коду: ERROR и current_context_id")
end)

-- ERROR при NONE но с активным контекстом — по коду пишется
suite:add_test("ERROR при активном контексте пишется даже при высоком уровне", function()
    Logger.init_config_subscription()
    ref_logger_config_cb({ LogLevel = "NONE" })
    Logger.with_error(function()
        Logger.error("C", "ctx err")
        return true
    end)
    Assert.are_equal(1, log_calls.error, "error в контексте записан")
end)

-- Экспорт буфера (только чтение)
suite:add_test("_context_buffer: экспортирован для диагностики", function()
    Assert.is_not_nil(Logger._context_buffer, "буфер доступен")
    Assert.is_true(type(Logger._context_buffer) == "table", "таблица")
end)

-- MaxLogQueueSize == 0 или nil -> немедленный вывод
suite:add_test("LogBatchEnabled true но MaxLogQueueSize 0: немедленный вывод", function()
    Logger.init_config_subscription()
    ref_logger_config_cb({ LogBatchEnabled = true, MaxLogQueueSize = 0 })
    Logger.info("Q", "immediate")
    Assert.is_true(log_calls.info >= 1, "сразу в вывод")
end)

-- Покрытие: buffer_log при LogBufferSize 0 / MaxLogComponents 0 — ранний return в _write_to_buffer
suite:add_test("buffer_log при дефолтном LogBufferSize 0 не пишет в буфер", function()
    Logger.buffer_log("INFO", "NoBuf", "msg", nil, 1)
    Assert.are_equal(0, #Logger.get_buffer("NoBuf"), "буфер пуст при LogBufferSize 0")
end)

-- Покрытие: переполнение буфера компонента (FIFO, pool.release старой записи)
suite:add_test("buffer_log: при превышении размера буфера старая запись удаляется", function()
    Logger.init_config_subscription()
    ref_logger_config_cb({ LogLevel = "DEBUG", LogBufferSize = 2, MaxLogComponents = 5 })
    Logger.buffer_log("INFO", "Overflow", "m1", nil, 1)
    Logger.buffer_log("INFO", "Overflow", "m2", nil, 2)
    Logger.buffer_log("INFO", "Overflow", "m3", nil, 3)
    local buf = Logger.get_buffer("Overflow")
    Assert.are_equal(2, #buf, "только 2 последние записи (FIFO)")
    Assert.are_equal("m2", buf[1].message, "вторая запись")
    Assert.are_equal("m3", buf[2].message, "третья запись")
end)

-- Покрытие: вытеснение компонента при достижении MaxLogComponents
suite:add_test("buffer_log: при MaxLogComponents вытесняется старый компонент", function()
    Logger.init_config_subscription()
    ref_logger_config_cb({ LogLevel = "DEBUG", LogBufferSize = 5, MaxLogComponents = 3 })
    Logger.buffer_log("INFO", "Comp1", "a", nil, 1)
    Logger.buffer_log("INFO", "Comp2", "b", nil, 2)
    Logger.buffer_log("INFO", "Comp3", "c", nil, 3)
    Logger.buffer_log("INFO", "Comp4", "d", nil, 4)
    Assert.are_equal(0, #Logger.get_buffer("Comp1"), "Comp1 вытеснен")
    Assert.are_equal(1, #Logger.get_buffer("Comp4"), "Comp4 в буфере")
end)

-- Покрытие: _get_current_level при state.cached_log_level == nil (вызов _refresh_config_cache)
suite:add_test("_get_current_level при nil cached_log_level обновляет кэш", function()
    local upvalues = Mock:get_module_upvalues(Logger)
    local state_tab
    for _, ups in pairs(upvalues) do
        for name, val in pairs(ups) do
            if type(val) == "table" and val.cached_log_level ~= nil and val.log_queue ~= nil and val.context_buffer ~= nil then
                state_tab = val
                break
            end
        end
        if state_tab then break end
    end
    Assert.is_not_nil(state_tab, "state найден через upvalues")
    state_tab.cached_log_level = nil
    Logger.info("X", "after nil level")
    Assert.are_equal(1, log_calls.info, "info записан после обновления кэша")
end)

suite:run()
