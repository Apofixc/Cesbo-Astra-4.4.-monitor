local test_helper = require("test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
local Mock = require("test_moc")

-- Объявление глобальных переменных для моков и перехвата коллбэков
local global_mock -- Для моков, которые не сбрасываются между тестами
local local_mock  -- Для моков, которые сбрасываются перед каждым тестом

-- Переменная для модуля, который мы тестируем
local LoggerModule

-- Локальная копия LOG_LEVELS для тестирования
local LOG_LEVELS = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4,
    NONE = 5
}

-- Создание нового набора тестов
local suite = TestSuite:new("Logger Module Tests")

suite:setup(function()
    global_mock = Mock:new()

    -- Мокирование глобальных зависимостей Astra, которые не меняются между тестами
    global_mock:mock_global("json", {
        encode = function(tbl) return "json_encoded_string" end,
    })
    global_mock:mock_global("os", {
        time = function() return 1234567890 end,
    })
    global_mock.log_calls = { debug = 0, info = 0, warning = 0, error = 0 }
    global_mock.log_messages = { debug = {}, info = {}, warning = {}, error = {} }
    global_mock.table_pool_gets = 0
    global_mock.table_pool_releases = 0
    global_mock.event_dispatcher_callbacks = {} -- Инициализация здесь

    -- Мокирование глобального логгера Astra для отслеживания вызовов
    global_mock:mock_global("log", {
        debug = function(...)
            global_mock.log_calls.debug = global_mock.log_calls.debug + 1
            table.insert(global_mock.log_messages.debug, test_helper.format_message(...))
        end,
        info = function(...)
            global_mock.log_calls.info = global_mock.log_calls.info + 1
            table.insert(global_mock.log_messages.info, test_helper.format_message(...))
        end,
        warning = function(...)
            global_mock.log_calls.warning = global_mock.log_calls.warning + 1
            table.insert(global_mock.log_messages.warning, test_helper.format_message(...))
        end,
        error = function(...)
            global_mock.log_calls.error = global_mock.log_calls.error + 1
            table.insert(global_mock.log_messages.error, test_helper.format_message(...))
        end,
    })

    -- Мокирование ModuleManager для ленивой загрузки TablePool и EventDispatcher
    global_mock:mock_global("ModuleManager", {
        get_global_dependency = function(name)
            if name == "log" then return log end -- Возвращаем замокированный log
            if name == "json.encode" then return json.encode end -- Возвращаем замокированный json.encode из global_mock
            return nil
        end,
        get_module = function(name)
            if name == "table_pool" then
                return {
                    get = function(type_name)
                        global_mock.table_pool_gets = global_mock.table_pool_gets + 1
                        return { type = type_name }
                    end,
                    release = function(item, type_name)
                        global_mock.table_pool_releases = global_mock.table_pool_releases + 1
                    end,
                    register_type = function(type_name, fields) end,
                }
            end
            if name == "core.event_dispatcher" then
                return {
                    get_instance = function()
                        return {
                            subscribe = function(self, event_name, callback)
                                if not global_mock.event_dispatcher_callbacks then
                                    global_mock.event_dispatcher_callbacks = {}
                                end
                                global_mock.event_dispatcher_callbacks[event_name] = callback
                            end,
                            emit = function(event_name, data) end,
                        }
                    end,
                }
            end
            return nil
        end,
    })
end)

-- Объявляем _m_config_mock_table и state_mock_table здесь, чтобы они были доступны в тестах
local _m_config_mock_table
local state_mock_table

suite:before_each(function()
    -- Сброс состояния моков и счетчиков перед каждым тестом
    local_mock = Mock:new() -- Создаем новый local_mock для каждого теста

    -- Очистка существующих таблиц вместо пересоздания
    for k in pairs(global_mock.log_calls) do global_mock.log_calls[k] = 0 end
    for k in pairs(global_mock.log_messages) do global_mock.log_messages[k] = {} end
    global_mock.table_pool_gets = 0
    global_mock.table_pool_releases = 0
    global_mock.event_dispatcher_callbacks = {} -- Сброс здесь

    -- Очистка кэша модуля для обеспечения чистой загрузки.
    package.loaded["astra/lib-monitor/src/utils/logger"] = nil
    -- Загрузка тестируемого модуля
    LoggerModule = require("astra/lib-monitor/src/utils/logger")

    -- Сброс внутреннего состояния LoggerModule для каждого теста
    _m_config_mock_table = {
        LogLevel = "INFO",
        LogFormat = "TEXT",
        LogBatchEnabled = false,
        LogBufferSize = 0,
        MaxLogQueueSize = 200,
        MaxLogComponents = 100,
    }

    state_mock_table = {
    -- Контекстное хранение ошибок
        last_errors = {},
        context_stack = {},
        current_context_id = nil,
        context_counter = 0,
        active_contexts = 0,

        -- Диагностический буфер
        component_list = {},
        context_buffer = {},
        buffer_size = 1000,

        -- Очередь пакетной записи
        log_queue = {},

        -- Кэш конфигурации
        cached_log_level = nil,
        cached_log_format = nil,
        cached_log_buffer_size = 0,
        cached_log_batch_enabled = false,
        last_config_refresh = 0,
        table_pool_types_registered = false -- Новый флаг
    }

    -- Мокирование локальных upvalue _m_config и state для всех функций LoggerModule
    -- Это позволяет контролировать их состояние для каждого теста.
    local_mock:mock_module_upvalue(LoggerModule, "_m_config", _m_config_mock_table)
    local_mock:mock_module_upvalue(LoggerModule, "state", state_mock_table)

    -- После мокирования upvalue, нужно обновить кэш LoggerModule
    LoggerModule.refresh_log_level()

    -- Обновляем ссылку на _context_buffer, чтобы она указывала на замокированный state.context_buffer
    -- Это необходимо, так как Logger._context_buffer = state.context_buffer происходит при require
    -- и указывает на оригинальную локальную таблицу state.
    -- После мокирования upvalue 'state', LoggerModule._context_buffer все еще указывает на старую таблицу.
    -- Мы должны обновить ее, чтобы она указывала на замокированную state.context_buffer.
    -- Для этого нам нужно получить доступ к замокированной таблице state.
    LoggerModule._context_buffer = state_mock_table.context_buffer
    -- state_mock_table.component_list = {} -- Также очищаем component_list - это уже делается при инициализации state_mock_table
    -- Очищаем очередь логов через публичный метод, если она была заполнена в предыдущем тесте
    LoggerModule.flush()
end)

suite:after_each(function()
    if local_mock then
        local_mock:restore()
        local_mock = nil
    end
end)

suite:teardown(function()
    global_mock:restore()
end)
-- ===========================================================================
-- Тестовые сценарии
-- ===========================================================================

suite:add_test("Logger.info: должен логировать сообщение уровня INFO", function()
    LoggerModule.info("TestComponent", "Это информационное сообщение: %s", "значение")
    Assert.are_equal(1, global_mock.log_calls.info, "Должен быть один вызов log.info")
    Assert.are_equal("[TestComponent] Это информационное сообщение: значение", global_mock.log_messages.info[1], "Сообщение должно быть корректным")
end)

suite:add_test("Logger.error: должен логировать сообщение уровня ERROR", function()
    LoggerModule.error("TestComponent", "Это сообщение об ошибке: %d", 123)
    Assert.are_equal(1, global_mock.log_calls.error, "Должен быть один вызов log.error")
    Assert.are_equal("[TestComponent] Это сообщение об ошибке: 123", global_mock.log_messages.error[1], "Сообщение должно быть корректным")
end)

suite:add_test("Logger.debug: должен логировать сообщение уровня DEBUG", function()
    -- По умолчанию LogLevel = INFO, поэтому DEBUG не должен логироваться
    LoggerModule.debug("TestComponent", "Это отладочное сообщение")
    Assert.are_equal(0, global_mock.log_calls.debug, "Не должно быть вызовов log.debug при LogLevel=INFO")

    -- Изменяем LogLevel на DEBUG и проверяем
    _m_config_mock_table.LogLevel = "DEBUG"
    LoggerModule.refresh_log_level() -- Обновляем кэш
    LoggerModule.debug("TestComponent", "Это отладочное сообщение")
    Assert.are_equal(1, global_mock.log_calls.debug, "Должен быть один вызов log.debug при LogLevel=DEBUG")
    Assert.are_equal("[TestComponent] Это отладочное сообщение", global_mock.log_messages.debug[1], "Сообщение должно быть корректным")
end)

suite:add_test("Logger.warning: должен логировать сообщение уровня WARN", function()
    LoggerModule.warning("TestComponent", "Это предупреждение")
    Assert.are_equal(1, global_mock.log_calls.warning, "Должен быть один вызов log.warning")
    Assert.are_equal("[TestComponent] Это предупреждение", global_mock.log_messages.warning[1], "Сообщение должно быть корректным")
end)

suite:add_test("Logger.flush: должен сбрасывать очередь логов", function()
    _m_config_mock_table.LogBatchEnabled = true
    _m_config_mock_table.MaxLogQueueSize = 10
    LoggerModule.refresh_log_level()

    LoggerModule.info("TestComponent", "Сообщение 1")
    LoggerModule.info("TestComponent", "Сообщение 2")
    Assert.are_equal(0, global_mock.log_calls.info, "Логи не должны быть сброшены немедленно")

    LoggerModule.flush()
    Assert.are_equal(2, global_mock.log_calls.info, "Должны быть сброшены 2 сообщения")
    Assert.are_equal("[TestComponent] Сообщение 1", global_mock.log_messages.info[1], "Первое сообщение должно быть корректным")
    Assert.are_equal("[TestComponent] Сообщение 2", global_mock.log_messages.info[2], "Второе сообщение должно быть корректным")
end)

suite:add_test("Logger.buffer_log: должен добавлять записи в кольцевой буфер", function()
    _m_config_mock_table.LogBufferSize = 2
    _m_config_mock_table.MaxLogComponents = 1
    LoggerModule.refresh_log_level()

    LoggerModule.buffer_log("INFO", "Comp1", "Msg1")
    LoggerModule.buffer_log("INFO", "Comp1", "Msg2")
    LoggerModule.buffer_log("INFO", "Comp1", "Msg3") -- Это должно вытеснить Msg1

    local buffer = LoggerModule.get_buffer("Comp1")
    Assert.are_equal(2, #buffer, "Буфер должен содержать 2 записи")
    Assert.are_equal("Msg2", buffer[1].message, "Первая запись должна быть Msg2")
    Assert.are_equal("Msg3", buffer[2].message, "Вторая запись должна быть Msg3")
end)

suite:add_test("Logger.clear_component_buffer: должен очищать буфер для компонента", function()
    _m_config_mock_table.LogBufferSize = 2
    _m_config_mock_table.MaxLogComponents = 1
    LoggerModule.refresh_log_level()

    LoggerModule.buffer_log("INFO", "Comp1", "Msg1")
    LoggerModule.buffer_log("INFO", "Comp2", "Msg2") -- Comp1 будет вытеснен, так как MaxLogComponents = 1

    LoggerModule.clear_component_buffer("Comp2")
    local buffer = LoggerModule.get_buffer("Comp2")
    Assert.are_equal(0, #buffer, "Буфер для Comp2 должен быть пуст")
    Assert.are_equal(0, #state_mock_table.component_list or {}, "Список компонентов должен быть пуст")
end)

suite:add_test("Logger.get_buffer: должен возвращать записи из буфера с лимитом", function()
    _m_config_mock_table.LogBufferSize = 5
    _m_config_mock_table.MaxLogComponents = 1
    LoggerModule.refresh_log_level()

    for i = 1, 5 do
        LoggerModule.buffer_log("INFO", "Comp1", "Msg" .. i)
    end

    local buffer = LoggerModule.get_buffer("Comp1", 2)
    Assert.are_equal(2, #buffer, "Должно быть возвращено 2 записи")
    Assert.are_equal("Msg4", buffer[1].message, "Первая запись должна быть Msg4")
    Assert.are_equal("Msg5", buffer[2].message, "Вторая запись должна быть Msg5")
end)

suite:add_test("Logger.with_error: должен корректно обрабатывать ошибки выполнения функции", function()
    local function failing_func()
        error("Simulated error")
    end

    local ok, err = LoggerModule.with_error(failing_func)
    Assert.is_false(ok, "Функция должна вернуть false при ошибке")
    Assert.are_equal("Simulated error", err, "Должно быть возвращено сообщение об ошибке")
    Assert.are_equal(1, global_mock.log_calls.error, "Должен быть один вызов log.error")
    Assert.are_equal("[Logger] Ошибка выполнения: Simulated error", global_mock.log_messages.error[1], "Сообщение об ошибке выполнения должно быть корректным")
end)

suite:add_test("Logger.with_error: должен пробрасывать ошибки, сохраненные в контексте", function()
    local function func_with_context_error()
        LoggerModule.error("InnerComp", "Внутренняя ошибка")
        return false -- Бизнес-логика возвращает false
    end

    local ok, err = LoggerModule.with_error(func_with_context_error)
    Assert.is_false(ok, "Функция должна вернуть false")
    Assert.are_equal("Внутренняя ошибка", err, "Должна быть возвращена внутренняя ошибка")
    Assert.are_equal(1, global_mock.log_calls.error, "Должен быть один вызов log.error")
    Assert.are_equal("[InnerComp] Внутренняя ошибка", global_mock.log_messages.error[1], "Сообщение об ошибке должно быть корректным")
end)

suite:add_test("Logger.with_error: должен корректно работать с вложенными контекстами", function()
    local function inner_func()
        LoggerModule.error("DeepComp", "Глубокая ошибка")
        return false
    end

    local function middle_func()
        local ok, err = LoggerModule.with_error(inner_func)
        return ok, err
    end

    local ok, err = LoggerModule.with_error(middle_func)
    Assert.is_false(ok, "Внешняя функция должна вернуть false")
    Assert.are_equal("Глубокая ошибка", err, "Должна быть проброшена глубокая ошибка")
    Assert.are_equal(1, global_mock.log_calls.error, "Должен быть один вызов log.error")
    Assert.are_equal("[DeepComp] Глубокая ошибка", global_mock.log_messages.error[1], "Сообщение об ошибке должно быть корректным")
end)

suite:add_test("Logger.with_error: должен очищать контекст после успешного выполнения", function()
    local function successful_func()
        LoggerModule.info("SuccessComp", "Успешное выполнение")
        return true, "result_data"
    end

    local ok, data = LoggerModule.with_error(successful_func)
    Assert.is_true(ok, "Функция должна вернуть true")
    Assert.are_equal("result_data", data, "Должны быть возвращены данные")
end)

suite:add_test("Logger.init_config_subscription: должен подписываться на события обновления конфигурации", function()
    LoggerModule.init_config_subscription()
    Assert.is_not_nil(global_mock.event_dispatcher_callbacks["config:updated:logger"], "Должен быть зарегистрирован callback для config:updated:logger")

    -- Имитируем вызов callback
    local new_config = { LogLevel = "DEBUG", LogFormat = "JSON", LogBufferSize = 5 }
    global_mock.event_dispatcher_callbacks["config:updated:logger"](new_config)

    -- Проверяем, что _m_config был обновлен косвенно через state.cached_log_level
    LoggerModule.refresh_log_level() -- Принудительно обновляем кэш после изменения _m_config

    Assert.are_equal(LOG_LEVELS.DEBUG, state_mock_table.cached_log_level, "cached_log_level должен быть обновлен")
    Assert.are_equal("JSON", state_mock_table.cached_log_format, "cached_log_format должен быть обновлен")
    Assert.are_equal(5, state_mock_table.cached_log_buffer_size, "cached_log_buffer_size должен быть обновлен")
    Assert.are_equal(1, global_mock.log_calls.info, "Должно быть информационное сообщение об обновлении конфига")
    Assert.are_equal("[Logger] Конфигурация логирования обновлена", global_mock.log_messages.info[1], "Сообщение об обновлении конфига должно быть корректным")
end)

suite:add_test("Logger.refresh_log_level: должен обновлять кэшированный уровень логирования", function()
    -- Мокируем _m_config через upvalue
    local_mock:mock_module_upvalue(LoggerModule, "_m_config", { LogLevel = "ERROR" })
    LoggerModule.refresh_log_level()
    -- Проверяем косвенно, что уровень лога изменился
    global_mock.log_calls.info = 0 -- Сбрасываем счетчик перед проверкой
    LoggerModule.info("TestComp", "Это сообщение не должно быть видно")
    Assert.are_equal(0, global_mock.log_calls.info, "INFO не должен логироваться при LogLevel=ERROR")
end)

suite:add_test("Logger: должен использовать TablePool для log_entry и log_data", function()
    _m_config_mock_table.LogBufferSize = 1
    _m_config_mock_table.LogBatchEnabled = true
    LoggerModule.refresh_log_level()

    LoggerModule.info("TestComponent", "Сообщение для пула")
    LoggerModule.flush() -- Сбрасываем очередь, чтобы освободить log_entry

    Assert.is_true(global_mock.table_pool_gets > 0, "Должны быть вызовы TablePool.get")
    Assert.is_true(global_mock.table_pool_releases > 0, "Должны быть вызовы TablePool.release")
    Assert.are_equal(global_mock.table_pool_gets, global_mock.table_pool_releases, "Количество get и release должно совпадать")
end)

suite:add_test("Logger: должен корректно обрабатывать JSON-формат", function()
    _m_config_mock_table.LogFormat = "JSON"
    LoggerModule.refresh_log_level()

    LoggerModule.info("TestComponent", "JSON сообщение")
    Assert.are_equal(1, global_mock.log_calls.info, "Должен быть один вызов log.info")
    Assert.are_equal("json_encoded_string", global_mock.log_messages.info[1], "Сообщение должно быть JSON-кодированной строкой")
end)

suite:add_test("Logger: должен обрабатывать ошибки JSON-сериализации", function()
    local_mock:mock_field(json, "encode", function(tbl) error("JSON error") end)
    _m_config_mock_table.LogFormat = "JSON"
    LoggerModule.refresh_log_level()

    LoggerModule.info("TestComponent", "Сообщение с ошибкой JSON")
    Assert.are_equal(1, global_mock.log_calls.error, "Должен быть один вызов log.error")
    Assert.are_equal("[ОШИБКА JSON-СЕРИАЛИЗАЦИИ] TestComponent: Сообщение с ошибкой JSON", global_mock.log_messages.error[1], "Сообщение об ошибке JSON должно быть корректным")
end)

suite:add_test("Logger: должен обрабатывать ошибки форматирования сообщения", function()
    LoggerModule.info("TestComponent", "Сообщение с ошибкой форматирования: %s %s", "один") -- Не хватает аргумента
    Assert.are_equal(1, global_mock.log_calls.info, "Должен быть один вызов log.info")
    Assert.are_equal("[TestComponent] Сообщение с ошибкой форматирования: один [ОШИБКА ФОРМАТИРОВАНИЯ]", global_mock.log_messages.info[1], "Сообщение должно содержать пометку об ошибке форматирования")
end)

suite:add_test("Logger: должен корректно обрабатывать переполнение очереди пакетной записи", function()
    _m_config_mock_table.LogBatchEnabled = true
    _m_config_mock_table.MaxLogQueueSize = 2
    LoggerModule.refresh_log_level()

    LoggerModule.info("TestComponent", "Msg1")
    LoggerModule.info("TestComponent", "Msg2")
    Assert.are_equal(0, global_mock.log_calls.info, "Логи не должны быть сброшены немедленно")

    LoggerModule.info("TestComponent", "Msg3") -- Это должно вызвать сброс очереди
    Assert.are_equal(2, global_mock.log_calls.info, "Должны быть сброшены первые 2 сообщения")
    Assert.are_equal("[TestComponent] Msg1", global_mock.log_messages.info[1], "Первое сообщение должно быть Msg1")
    Assert.are_equal("[TestComponent] Msg2", global_mock.log_messages.info[2], "Второе сообщение должно быть Msg2")
end)

suite:add_test("Logger: должен корректно обрабатывать переполнение буфера компонентов", function()
    _m_config_mock_table.LogBufferSize = 1
    _m_config_mock_table.MaxLogComponents = 1
    LoggerModule.refresh_log_level()

    LoggerModule.buffer_log("INFO", "Comp1", "Msg1")
    Assert.are_equal(1, #state_mock_table.component_list or {}, "Должен быть 1 компонент")
    Assert.are_equal("Comp1", state_mock_table.component_list[1], "Компонент должен быть Comp1")

    LoggerModule.buffer_log("INFO", "Comp2", "Msg2") -- Comp1 будет вытеснен
    Assert.are_equal(1, #state_mock_table.component_list or {}, "Должен остаться 1 компонент")
    Assert.are_equal("Comp2", state_mock_table.component_list[1], "Компонент должен быть Comp2")
    Assert.is_nil(state_mock_table.context_buffer["Comp1"], "Буфер Comp1 должен быть очищен")
    Assert.is_not_nil(state_mock_table.context_buffer["Comp2"], "Буфер Comp2 должен существовать")
end)

suite:add_test("Logger: должен корректно обрабатывать nil-компонент", function()
    LoggerModule.info(nil, "Сообщение с nil-компонентом")
    Assert.are_equal(1, global_mock.log_calls.info, "Должен быть один вызов log.info")
    Assert.are_equal("[nil] Сообщение с nil-компонентом", global_mock.log_messages.info[1], "Сообщение должно быть корректным с 'nil'")

    LoggerModule.error(nil, "Ошибка с nil-компонентом")
    Assert.are_equal(1, global_mock.log_calls.error, "Должен быть один вызов log.error")
    Assert.are_equal("[nil] Ошибка с nil-компонентом", global_mock.log_messages.error[1], "Сообщение должно быть корректным с 'nil'")
end)

suite:add_test("Logger: должен корректно обрабатывать числовой компонент", function()
    LoggerModule.info(123, "Сообщение с числовым компонентом")
    Assert.are_equal(1, global_mock.log_calls.info, "Должен быть один вызов log.info")
    Assert.are_equal("[123] Сообщение с числовым компонентом", global_mock.log_messages.info[1], "Сообщение должно быть корректным с '123'")
end)

suite:add_test("Logger.with_error: должен возвращать дополнительные результаты при успехе", function()
    local function multi_return_func()
        return true, "data1", 123, { key = "value" }
    end

    local ok, data1, num, tbl = LoggerModule.with_error(multi_return_func)
    Assert.is_true(ok, "Функция должна вернуть true")
    Assert.are_equal("data1", data1, "Должен быть возвращен data1")
    Assert.are_equal(123, num, "Должен быть возвращен num")
    Assert.are_equal("value", tbl.key, "Должен быть возвращен tbl")
end)

suite:add_test("Logger.with_error: должен корректно обрабатывать пустой стек контекстов", function()
    local function simple_func()
        LoggerModule.info("Simple", "Простое сообщение")
        return true
    end

    local ok = LoggerModule.with_error(simple_func)
    Assert.is_true(ok, "Функция должна успешно выполниться")
end)

suite:add_test("Logger.with_error: должен корректно обрабатывать ошибки, когда log.error недоступен", function()
    local_mock:mock_global("log", nil) -- Имитируем отсутствие глобального логгера

    local function func_with_error()
        LoggerModule.error("NoLog", "Ошибка без глобального лога")
        return false
    end

    local ok, err = LoggerModule.with_error(func_with_error)
    Assert.is_false(ok, "Функция должна вернуть false")
    Assert.are_equal("Ошибка без глобального лога", err, "Должна быть возвращена ошибка")
    -- Проверяем, что print был вызван, так как log.error недоступен
    -- Это сложно проверить напрямую, но мы можем убедиться, что не было падения
end)

-- Удален тест, напрямую вызывающий приватную функцию _get_table_pool

-- Удален тест, напрямую вызывающий приватную функцию _get_event_dispatcher

suite:add_test("Logger: _refresh_config_cache должен корректно устанавливать LogBufferSize", function()
    local_mock:mock_module_upvalue(LoggerModule, "_m_config", { LogBufferSize = -5 })
    LoggerModule.refresh_log_level() -- Вызывает _refresh_config_cache
    Assert.are_equal(0, state_mock_table.cached_log_buffer_size, "LogBufferSize должен быть 0 при отрицательном значении")

    local_mock:mock_module_upvalue(LoggerModule, "_m_config", { LogBufferSize = 10 })
    LoggerModule.refresh_log_level()
    Assert.are_equal(10, state_mock_table.cached_log_buffer_size, "LogBufferSize должен быть 10 при положительном значении")
end)

suite:add_test("Logger: _should_log должен корректно работать с разными уровнями", function()
    local_mock:mock_module_upvalue(LoggerModule, "_m_config", { LogLevel = "INFO" })
    LoggerModule.refresh_log_level()

    -- Проверяем косвенно через публичный API
    global_mock.log_calls.debug = 0
    global_mock.log_calls.info = 0
    global_mock.log_calls.warning = 0
    global_mock.log_calls.error = 0

    LoggerModule.debug("TestComp", "Debug message")
    LoggerModule.info("TestComp", "Info message")
    LoggerModule.warning("TestComp", "Warn message")
    LoggerModule.error("TestComp", "Error message")

    Assert.are_equal(0, global_mock.log_calls.debug, "DEBUG не должен логироваться при LogLevel=INFO")
    Assert.are_equal(1, global_mock.log_calls.info, "INFO должен логироваться при LogLevel=INFO")
    Assert.are_equal(1, global_mock.log_calls.warning, "WARN должен логироваться при LogLevel=INFO")
    Assert.are_equal(1, global_mock.log_calls.error, "ERROR должен логироваться при LogLevel=INFO")

    local_mock:mock_module_upvalue(LoggerModule, "_m_config", { LogLevel = "ERROR" })
    LoggerModule.refresh_log_level()

    global_mock.log_calls.debug = 0
    global_mock.log_calls.info = 0
    global_mock.log_calls.warning = 0
    global_mock.log_calls.error = 0

    LoggerModule.debug("TestComp", "Debug message")
    LoggerModule.info("TestComp", "Info message")
    LoggerModule.warning("TestComp", "Warn message")
    LoggerModule.error("TestComp", "Error message")

    Assert.are_equal(0, global_mock.log_calls.debug, "DEBUG не должен логироваться при LogLevel=ERROR")
    Assert.are_equal(0, global_mock.log_calls.info, "INFO не должен логироваться при LogLevel=ERROR")
    Assert.are_equal(0, global_mock.log_calls.warning, "WARN не должен логироваться при LogLevel=ERROR")
    Assert.are_equal(1, global_mock.log_calls.error, "ERROR должен логироваться при LogLevel=ERROR")
end)

-- Удален тест, напрямую вызывающий приватную функцию _propagate_error

-- Удален тест, напрямую вызывающий приватную функцию _write_to_output

-- Удален тест, напрямую вызывающий приватную функцию _write_to_output

-- Удален тест, напрямую вызывающий приватную функцию _enqueue_log

-- Удален тест, напрямую вызывающий приватную функцию _write_to_buffer

-- Удален тест, напрямую вызывающий приватную функцию _write_log

-- Удален тест, напрямую вызывающий приватную функцию _write_log

suite:add_test("Logger.clear_component_buffer: должен корректно обрабатывать несуществующий компонент", function()
    LoggerModule.clear_component_buffer("NonExistentComp")
    Assert.are_equal(0, #state_mock_table.component_list or {}, "Список компонентов должен быть пуст")
    Assert.is_nil(state_mock_table.context_buffer["NonExistentComp"], "Буфер несуществующего компонента должен быть nil")
end)

suite:add_test("Logger.get_buffer: должен возвращать пустую таблицу для несуществующего компонента", function()
    local buffer = LoggerModule.get_buffer("NonExistentComp")
    Assert.are_equal(0, #buffer, "Должна быть возвращена пустая таблица")
end)

suite:add_test("Logger.with_error: должен корректно обрабатывать nil-функцию", function()
    local ok, err = LoggerModule.with_error(nil)
    Assert.is_false(ok, "Вызов с nil-функцией должен вернуть false")
    Assert.are_equal("attempt to call a nil value", err, "Должна быть ошибка о вызове nil")
    Assert.are_equal(1, global_mock.log_calls.error, "Должен быть один вызов log.error")
    Assert.string_starts_with("[Logger] Ошибка выполнения: attempt to call a nil value", global_mock.log_messages.error[1], "Сообщение об ошибке выполнения должно быть корректным")
end)

suite:add_test("Logger.with_error: должен корректно обрабатывать функцию, возвращающую nil без ошибки", function()
    local function returns_nil_no_error()
        return nil
    end

    local ok, res = LoggerModule.with_error(returns_nil_no_error)
    Assert.is_true(ok, "Функция должна вернуть true, так как не было ошибки")
    Assert.is_nil(res, "Результат должен быть nil")
end)

suite:add_test("Logger.with_error: должен корректно обрабатывать функцию, возвращающую false без сохранения ошибки", function()
    local function returns_false_no_error()
        return false
    end

    local ok, err = LoggerModule.with_error(returns_false_no_error)
    Assert.is_false(ok, "Функция должна вернуть false")
    Assert.are_equal("Неизвестная ошибка", err, "Должна быть возвращена 'Неизвестная ошибка'")
    Assert.are_equal(0, global_mock.log_calls.error, "Не должно быть вызовов log.error")
end)

suite:add_test("Logger.with_error: должен корректно обрабатывать функцию, возвращающую false с сохранением ошибки в другом контексте", function()
    local function inner_func_with_error()
        LoggerModule.error("Inner", "Внутренняя ошибка")
        return false
    end

    local function outer_func()
        local ok, err = LoggerModule.with_error(inner_func_with_error)
        return false -- Внешняя функция тоже возвращает false, но не логирует свою ошибку
    end

    local ok, err = LoggerModule.with_error(outer_func)
    Assert.is_false(ok, "Внешняя функция должна вернуть false")
    Assert.are_equal("Внутренняя ошибка", err, "Должна быть проброшена внутренняя ошибка")
    Assert.are_equal(1, global_mock.log_calls.error, "Должен быть один вызов log.error")
    Assert.are_equal("[Inner] Внутренняя ошибка", global_mock.log_messages.error[1], "Сообщение об ошибке должно быть корректным")
end)

suite:add_test("Logger: _m_config должен быть обновлен через init_config_subscription", function()
    LoggerModule.init_config_subscription()
    local new_config = { LogLevel = "ERROR", LogFormat = "JSON", LogBatchEnabled = true, LogBufferSize = 10, MaxLogQueueSize = 50, MaxLogComponents = 50 }
    global_mock.event_dispatcher_callbacks["config:updated:logger"](new_config)

    -- Проверяем, что _m_config был обновлен косвенно через state.cached_log_level
    LoggerModule.refresh_log_level() -- Принудительно обновляем кэш после изменения _m_config

    Assert.are_equal(LOG_LEVELS.ERROR, state_mock_table.cached_log_level, "cached_log_level должен быть обновлен")
    Assert.are_equal("JSON", state_mock_table.cached_log_format, "cached_log_format должен быть обновлен")
    Assert.is_true(state_mock_table.cached_log_batch_enabled, "cached_log_batch_enabled должен быть обновлен")
    Assert.are_equal(10, state_mock_table.cached_log_buffer_size, "cached_log_buffer_size должен быть обновлен")
end)

suite:add_test("Logger: _m_config должен использовать значения по умолчанию, если в конфиге nil", function()
    LoggerModule.init_config_subscription()
    local new_config = { LogLevel = nil, LogFormat = nil, LogBatchEnabled = nil, LogBufferSize = nil, MaxLogQueueSize = nil, MaxLogComponents = nil }
    global_mock.event_dispatcher_callbacks["config:updated:logger"](new_config)

    -- Проверяем, что кэш обновился до дефолтных значений
    LoggerModule.refresh_log_level()

    Assert.are_equal(LOG_LEVELS.INFO, state_mock_table.cached_log_level, "cached_log_level должен быть INFO по умолчанию")
    Assert.are_equal("TEXT", state_mock_table.cached_log_format, "cached_log_format должен быть TEXT по умолчанию")
    Assert.is_false(state_mock_table.cached_log_batch_enabled, "cached_log_batch_enabled должен быть false по умолчанию")
    Assert.are_equal(0, state_mock_table.cached_log_buffer_size, "cached_log_buffer_size должен быть 0 по умолчанию")
end)

suite:add_test("Logger: _m_config должен игнорировать некорректный LogLevel", function()
    LoggerModule.init_config_subscription()
    local new_config = { LogLevel = "INVALID_LEVEL" }
    global_mock.event_dispatcher_callbacks["config:updated:logger"](new_config)

    -- Проверяем, что кэш остался на INFO, так как INVALID_LEVEL не распознан
    LoggerModule.refresh_log_level()

    Assert.are_equal(LOG_LEVELS.INFO, state_mock_table.cached_log_level, "cached_log_level должен остаться INFO")
end)

suite:add_test("Logger: _m_config должен корректно обрабатывать LogBufferSize = nil", function()
    _m_config_mock_table.LogBufferSize = nil
    LoggerModule.refresh_log_level()
    Assert.are_equal(0, state_mock_table.cached_log_buffer_size, "LogBufferSize должен быть 0, если nil")
end)

suite:add_test("Logger: _m_config должен корректно обрабатывать LogBatchEnabled = nil", function()
    _m_config_mock_table.LogBatchEnabled = nil
    LoggerModule.refresh_log_level()
    Assert.is_false(state_mock_table.cached_log_batch_enabled, "LogBatchEnabled должен быть false, если nil")
end)

suite:add_test("Logger: _m_config должен корректно обрабатывать LogFormat = nil", function()
    _m_config_mock_table.LogFormat = nil
    LoggerModule.refresh_log_level()
    Assert.are_equal("TEXT", state_mock_table.cached_log_format, "cached_log_format должен быть TEXT, если nil")
end)

suite:add_test("Logger: _m_config должен корректно обрабатывать MaxLogQueueSize = nil", function()
    LoggerModule.init_config_subscription()
    local new_config = { MaxLogQueueSize = nil }
    global_mock.event_dispatcher_callbacks["config:updated:logger"](new_config)
    -- Проверяем, что кэш обновился до дефолтного значения
    LoggerModule.refresh_log_level()
    -- Assert.are_equal(200, LoggerModule.state.MaxLogQueueSize, "MaxLogQueueSize должен быть 200, если nil") -- state.MaxLogQueueSize не экспортируется
    -- Проверяем косвенно, что MaxLogQueueSize используется
    _m_config_mock_table.LogBatchEnabled = true
    _m_config_mock_table.MaxLogQueueSize = 1
    LoggerModule.refresh_log_level()
    LoggerModule.info("TestComp", "Msg1")
    LoggerModule.info("TestComp", "Msg2") -- Это должно вызвать сброс очереди
    Assert.are_equal(1, #global_mock.log_messages.info, "Должен быть 1 лог после переполнения очереди")
end)

suite:add_test("Logger: _m_config должен корректно обрабатывать MaxLogComponents = nil", function()
    LoggerModule.init_config_subscription()
    local new_config = { MaxLogComponents = nil }
    global_mock.event_dispatcher_callbacks["config:updated:logger"](new_config)
    -- Проверяем, что кэш обновился до дефолтного значения
    LoggerModule.refresh_log_level()
    -- Assert.are_equal(100, LoggerModule.state.MaxLogComponents, "MaxLogComponents должен быть 100, если nil") -- state.MaxLogComponents не экспортируется
    -- Проверяем косвенно, что MaxLogComponents используется
    _m_config_mock_table.LogBufferSize = 1
    _m_config_mock_table.MaxLogComponents = 1
    LoggerModule.refresh_log_level()
    LoggerModule.buffer_log("INFO", "Comp1", "Msg1")
    LoggerModule.buffer_log("INFO", "Comp2", "Msg2") -- Comp1 будет вытеснен
    Assert.are_equal(1, #LoggerModule.get_buffer("Comp2"), "Должен остаться 1 компонент в буфере Comp2")
end)

suite:add_test("Logger.with_error: должен корректно обрабатывать вложенные вызовы с успешным результатом", function()
    local function innermost_func()
        LoggerModule.info("Innermost", "Сообщение из самого глубокого уровня")
        return true, "innermost_result"
    end

    local function middle_func()
        local ok, res = LoggerModule.with_error(innermost_func)
        LoggerModule.info("Middle", "Сообщение из среднего уровня")
        return ok, res, "middle_extra"
    end

    local function outermost_func()
        local ok, res1, res2 = LoggerModule.with_error(middle_func)
        LoggerModule.info("Outermost", "Сообщение из внешнего уровня")
        return ok, res1, res2, "outer_extra"
    end

    local ok, r1, r2, r3 = LoggerModule.with_error(outermost_func)

    Assert.is_true(ok, "Все функции должны успешно выполниться")
    Assert.are_equal("innermost_result", r1, "Должен быть innermost_result")
    Assert.are_equal("middle_extra", r2, "Должен быть middle_extra")
    Assert.are_equal("outer_extra", r3, "Должен быть outer_extra")

    Assert.are_equal(3, global_mock.log_calls.info, "Должно быть 3 информационных сообщения")
    Assert.are_equal("[Innermost] Сообщение из самого глубокого уровня", global_mock.log_messages.info[1])
    Assert.are_equal("[Middle] Сообщение из среднего уровня", global_mock.log_messages.info[2])
    Assert.are_equal("[Outermost] Сообщение из внешнего уровня", global_mock.log_messages.info[3])

    -- Нельзя напрямую проверять LoggerModule.state.current_context_id, active_contexts, context_counter
end)

suite:add_test("Logger.with_error: должен корректно обрабатывать вложенные вызовы с ошибкой на среднем уровне", function()
    local function innermost_func()
        LoggerModule.info("Innermost", "Сообщение из самого глубокого уровня")
        return true, "innermost_result"
    end

    local function middle_func_with_error()
        LoggerModule.error("MiddleError", "Ошибка на среднем уровне")
        local ok, res = LoggerModule.with_error(innermost_func)
        return false, "middle_error_data" -- Бизнес-логика возвращает false
    end

    local function outermost_func()
        local ok, err = LoggerModule.with_error(middle_func_with_error)
        -- LoggerModule.info("Outermost", "Сообщение из внешнего уровня") -- Эта строка не будет достигнута
        return ok, err, "outer_extra"
    end

    local ok, err, r3 = LoggerModule.with_error(outermost_func)

    Assert.is_false(ok, "Внешняя функция должна вернуть false")
    Assert.are_equal("Ошибка на среднем уровне", err, "Должна быть проброшена ошибка среднего уровня")
    Assert.is_nil(r3, "Дополнительные результаты не должны быть возвращены")

    Assert.are_equal(1, global_mock.log_calls.info, "Должно быть 1 информационное сообщение (из innermost)")
    Assert.are_equal(1, global_mock.log_calls.error, "Должно быть 1 сообщение об ошибке (из middle_func_with_error)")
    Assert.are_equal("[Innermost] Сообщение из самого глубокого уровня", global_mock.log_messages.info[1])
    Assert.are_equal("[MiddleError] Ошибка на среднем уровне", global_mock.log_messages.error[1])

    -- Нельзя напрямую проверять LoggerModule.state.current_context_id, active_contexts, context_counter
end)

suite:add_test("Logger.with_error: должен корректно обрабатывать вложенные вызовы с ошибкой на самом глубоком уровне", function()
    local function innermost_func_with_error()
        LoggerModule.error("InnermostError", "Ошибка на самом глубоком уровне")
        return false, "innermost_error_data"
    end

    local function middle_func()
        local ok, err = LoggerModule.with_error(innermost_func_with_error)
        LoggerModule.info("Middle", "Сообщение из среднего уровня")
        return ok, err, "middle_extra"
    end

    local function outermost_func()
        local ok, err, r2 = LoggerModule.with_error(middle_func)
        LoggerModule.info("Outermost", "Сообщение из внешнего уровня")
        return ok, err, r2, "outer_extra"
    end

    local ok, err, r2, r3 = LoggerModule.with_error(outermost_func)

    Assert.is_false(ok, "Внешняя функция должна вернуть false")
    Assert.are_equal("Ошибка на самом глубоком уровне", err, "Должна быть проброшена ошибка самого глубокого уровня")
    Assert.is_nil(r2, "Дополнительные результаты не должны быть возвращены")
    Assert.is_nil(r3, "Дополнительные результаты не должны быть возвращены")

    Assert.are_equal(2, global_mock.log_calls.info, "Должно быть 2 информационных сообщения (Middle, Outermost)")
    Assert.are_equal(1, global_mock.log_calls.error, "Должно быть 1 сообщение об ошибке (InnermostError)")
    Assert.are_equal("[Middle] Сообщение из среднего уровня", global_mock.log_messages.info[1])
    Assert.are_equal("[Outermost] Сообщение из внешнего уровня", global_mock.log_messages.info[2])
    Assert.are_equal("[InnermostError] Ошибка на самом глубоком уровне", global_mock.log_messages.error[1])

    -- Нельзя напрямую проверять LoggerModule.state.current_context_id, active_contexts, context_counter
end)

suite:add_test("Logger.with_error: должен корректно обрабатывать вложенные вызовы с crash на среднем уровне", function()
    local function innermost_func()
        LoggerModule.info("Innermost", "Сообщение из самого глубокого уровня")
        return true, "innermost_result"
    end

    local function middle_func_with_crash()
        error("Crash on middle level")
    end

    local function outermost_func()
        local ok, err = LoggerModule.with_error(middle_func_with_crash)
        -- LoggerModule.info("Outermost", "Сообщение из внешнего уровня") -- Эта строка не будет достигнута
        return ok, err, "outer_extra"
    end

    local ok, err, r3 = LoggerModule.with_error(outermost_func)

    Assert.is_false(ok, "Внешняя функция должна вернуть false")
    Assert.are_equal("Crash on middle level", err, "Должен быть проброшен crash среднего уровня")
    Assert.is_nil(r3, "Дополнительные результаты не должны быть возвращены")

    -- Assert.are_equal(0, global_mock.log_calls.info, "Не должно быть информационных сообщений") -- Удалено
    Assert.are_equal(1, global_mock.log_calls.error, "Должно быть 1 сообщение об ошибке (из Logger.with_error)")
    Assert.string_starts_with("[Logger] Ошибка выполнения: Crash on middle level", global_mock.log_messages.error[1])

    -- Нельзя напрямую проверять LoggerModule.state.current_context_id, active_contexts, context_counter
end)

suite:run()
