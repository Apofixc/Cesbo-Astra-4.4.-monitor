-- L0: Unit-тесты для модуля config.monitor_config
-- Изоляция через моки ModuleManager, json.load, json.save, Logger, EventDispatcher.

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
local Mock = require("tools.test_moc")

local mock
local local_mock
local ModuleUnderTest
-- Локальные переменные для моков (без _G — запрещено, избегаем утечки параметров)
local mock_json_load_result
local mock_json_save_fail
local mock_json_save_last
-- Ссылка на объект-мок ModuleManager для точечного mock_field без обращения к _G
local ref_ModuleManager

local suite = TestSuite:new("L0.monitor_config")

suite:setup(function()
    mock = Mock:new()
    local mock_log = {
        debug = function() end,
        info = function() end,
        warning = function() end,
        error = function() end,
    }
    local mock_ed_instance = { emit_safe = function() end }
    local mock_ed = { get_instance = function() return mock_ed_instance end }

    ref_ModuleManager = {
        get_module = function(name)
            if name == "logger" then return mock_log end
            if name == "core.event_dispatcher" then return mock_ed end
            return nil
        end,
        get_global_dependency = function(name)
            if name == "json.load" then
                return function(_path) return mock_json_load_result end
            end
            if name == "json.save" then
                return function(_path, data)
                    if mock_json_save_fail then error("simulated save error") end
                    mock_json_save_last = data
                    return true
                end
            end
            return nil
        end,
    }
    mock:mock_global("ModuleManager", ref_ModuleManager)
end)

suite:before_each(function()
    mock_json_load_result = nil
    mock_json_save_fail = false
    mock_json_save_last = nil
    package.loaded["src.config.monitor_config"] = nil
    ModuleUnderTest = require("src.config.monitor_config")
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

-- Позитивные сценарии
suite:add_test("reload: при отсутствии файла применяет дефолты и возвращает true", function()
    local ok = ModuleUnderTest.reload()
    Assert.is_true(ok, "reload должен вернуть true при отсутствии файла")
    Assert.is_not_nil(ModuleUnderTest.Logger, "Секция Logger должна быть инициализирована")
    Assert.are_equal("INFO", ModuleUnderTest.Logger.LogLevel, "Дефолтный LogLevel = INFO")
end)

suite:add_test("reload: при успешной загрузке файла применяет данные и возвращает true", function()
    mock_json_load_result = {
        Logger = { LogLevel = "DEBUG" },
    }
    local ok = ModuleUnderTest.reload()
    Assert.is_true(ok, "reload должен вернуть true")
    Assert.are_equal("DEBUG", ModuleUnderTest.Logger.LogLevel, "Должен применить LogLevel из файла")
end)

suite:add_test("update: валидная таблица применяется и возвращает true", function()
    ModuleUnderTest.reload()
    local ok, err = ModuleUnderTest.update({
        Logger = { LogLevel = "WARN" },
    })
    Assert.is_true(ok, "update должен вернуть true")
    Assert.is_nil(err, "Ошибка должна быть nil")
    Assert.are_equal("WARN", ModuleUnderTest.Logger.LogLevel, "LogLevel должен обновиться")
end)

suite:add_test("update: неизвестная секция игнорируется без ошибки", function()
    ModuleUnderTest.reload()
    local ok = ModuleUnderTest.update({
        UnknownSection = { Foo = 1 },
    })
    Assert.is_true(ok, "update должен вернуть true")
end)

suite:add_test("get_cached: возвращает значение из кэша при повторном вызове", function()
    local call_count = 0
    local gen = function()
        call_count = call_count + 1
        return "cached_" .. call_count
    end
    local v1 = ModuleUnderTest.get_cached("key1", gen)
    local v2 = ModuleUnderTest.get_cached("key1", gen)
    Assert.are_equal("cached_1", v1, "Первый вызов — генератор вызван")
    Assert.are_equal("cached_1", v2, "Второй вызов — значение из кэша, генератор не вызывается")
    Assert.are_equal(1, call_count, "Генератор вызван один раз")
end)

suite:add_test("get_stream_name_cached: возвращает имя по IP из STREAM или IP", function()
    ModuleUnderTest.reload()
    local name = ModuleUnderTest.get_stream_name_cached("127.0.0.1")
    Assert.are_equal("Узда", name, "Должно вернуть имя потока из STREAM")
    local ip_unknown = ModuleUnderTest.get_stream_name_cached("192.168.1.1")
    Assert.are_equal("192.168.1.1", ip_unknown, "Неизвестный IP возвращается как есть")
end)

suite:add_test("get_stream_name_cached: при STREAM не таблица возвращает IP", function()
    ModuleUnderTest.reload()
    local orig = ModuleUnderTest.STREAM
    ModuleUnderTest.STREAM = nil
    local name = ModuleUnderTest.get_stream_name_cached("10.0.0.1")
    Assert.are_equal("10.0.0.1", name, "При не-таблице STREAM возвращается IP")
    ModuleUnderTest.STREAM = orig
end)

suite:add_test("save: при доступном json.save сохраняет конфиг и возвращает true", function()
    ModuleUnderTest.reload()
    ModuleUnderTest.update({ Logger = { LogLevel = "ERROR" } })
    local ok = ModuleUnderTest.save()
    Assert.is_true(ok, "save должен вернуть true")
    Assert.is_not_nil(mock_json_save_last, "Данные должны быть переданы в json.save")
    Assert.are_equal("ERROR", mock_json_save_last.Logger.LogLevel, "Сохранённые данные должны соответствовать конфигу")
end)

-- Негативные сценарии
suite:add_test("update: не таблица — возвращает false и сообщение об ошибке", function()
    local ok, err = ModuleUnderTest.update("not a table")
    Assert.is_false(ok, "update должен вернуть false")
    Assert.is_not_nil(err, "Должно быть сообщение об ошибке")
    Assert.string_starts_with(tostring(err), "Параметры", "Ошибка про тип параметров")
end)

suite:add_test("update: невалидное значение enum — параметр игнорируется, возврат true", function()
    ModuleUnderTest.reload()
    local ok = ModuleUnderTest.update({
        Logger = { LogLevel = "INVALID_LEVEL" },
    })
    Assert.is_true(ok, "update возвращает true, невалидный параметр игнорируется")
    Assert.are_equal("INFO", ModuleUnderTest.Logger.LogLevel, "LogLevel остаётся дефолтным")
end)

suite:add_test("update: число вне min/max — параметр игнорируется", function()
    ModuleUnderTest.reload()
    local ok = ModuleUnderTest.update({
        Network = { MaxPayloadSize = 1 },
    })
    Assert.is_true(ok, "update возвращает true")
    Assert.are_equal(1024 * 1024, ModuleUnderTest.Network.MaxPayloadSize, "Остаётся дефолт (min 1024)")
end)

suite:add_test("update: число больше max — параметр игнорируется", function()
    ModuleUnderTest.reload()
    local ok = ModuleUnderTest.update({
        Network = { HttpTimeout = 9999 },
    })
    Assert.is_true(ok, "update возвращает true")
    Assert.are_equal(10, ModuleUnderTest.Network.HttpTimeout, "Остаётся дефолт (max 300)")
end)

suite:add_test("update: неверный тип параметра (number вместо string) — игнорируется", function()
    ModuleUnderTest.reload()
    local ok = ModuleUnderTest.update({
        Logger = { LogLevel = 123 },
    })
    Assert.is_true(ok, "update возвращает true")
    Assert.are_equal("INFO", ModuleUnderTest.Logger.LogLevel, "Остаётся дефолт")
end)

suite:add_test("update: неизвестный ключ в известной секции — игнорируется", function()
    ModuleUnderTest.reload()
    local ok = ModuleUnderTest.update({
        Logger = { UnknownKeyInLogger = "value" },
    })
    Assert.is_true(ok, "update возвращает true")
    Assert.is_nil(ModuleUnderTest.Logger.UnknownKeyInLogger, "Ключ не добавлен")
end)

suite:add_test("reload: при ошибке json.load (pcall) применяет дефолты и возвращает true", function()
    local_mock = Mock:new()
    local orig_gd = ref_ModuleManager.get_global_dependency
    local_mock:mock_field(ref_ModuleManager, "get_global_dependency", function(name)
        if name == "json.load" then return function() error("simulated parse error") end end
        return orig_gd(name)
    end)
    package.loaded["src.config.monitor_config"] = nil
    local M = require("src.config.monitor_config")
    local ok = M.reload()
    Assert.is_true(ok, "reload при ошибке загрузки всё равно возвращает true (дефолты)")
    Assert.are_equal("INFO", M.Logger.LogLevel, "Дефолтная конфигурация применена")
end)

suite:add_test("save: при ошибке json.save возвращает false", function()
    ModuleUnderTest.reload()
    mock_json_save_fail = true
    local ok = ModuleUnderTest.save()
    Assert.is_false(ok, "save должен вернуть false при ошибке сохранения")
end)

suite:add_test("save: при недоступном json.save возвращает false", function()
    local_mock = Mock:new()
    -- Модуль уже загружен в before_each с json_save = function; подменяем upvalue в save()
    local patched = local_mock:mock_module_upvalue(ModuleUnderTest, "json_save", nil)
    Assert.is_true(patched, "upvalue json_save найден в модуле")
    Assert.is_false(ModuleUnderTest.save(), "save должен вернуть false при недоступном json.save")
end)

-- Покрытие: _load_from_file при json_load == nil (строки 229-230). Патчим upvalue в _load_from_file.
suite:add_test("reload: при недоступном json.load применяет дефолты (upvalue)", function()
    local_mock = Mock:new()
    local reload_fn = ModuleUnderTest.reload
    local load_fn
    for i = 1, 20 do
        local name, val = debug.getupvalue(reload_fn, i)
        if not name then break end
        if name == "_load_from_file" then load_fn = val break end
    end
    Assert.is_not_nil(load_fn, "_load_from_file найдена в upvalue reload")
    local patched = local_mock:mock_upvalue(load_fn, "json_load", nil)
    Assert.is_true(patched, "json_load замокан в _load_from_file")
    local ok = ModuleUnderTest.reload()
    Assert.is_true(ok, "reload при nil json.load возвращает true (дефолты)")
end)

-- Покрытие: _load_from_file при не-таблице от json.load (строки 241-242)
suite:add_test("reload: при возврате не-таблицы от json.load применяет дефолты", function()
    local_mock = Mock:new()
    local reload_fn = ModuleUnderTest.reload
    local load_fn
    for i = 1, 20 do
        local name, val = debug.getupvalue(reload_fn, i)
        if not name then break end
        if name == "_load_from_file" then load_fn = val break end
    end
    Assert.is_not_nil(load_fn, "_load_from_file найдена")
    local patched = local_mock:mock_upvalue(load_fn, "json_load", function() return "invalid" end)
    Assert.is_true(patched, "json_load замокан")
    local ok = ModuleUnderTest.reload()
    Assert.is_true(ok, "reload при не-таблице от json.load возвращает true (дефолты)")
end)

-- Покрытие: update при schema == nil (защитная ветка)
suite:add_test("update: при отсутствии схемы валидации возвращает false", function()
    local_mock = Mock:new()
    local orig_schema = ModuleUnderTest.ValidationSchema
    local_mock:mock_field(ModuleUnderTest, "ValidationSchema", nil)
    local ok, err = ModuleUnderTest.update({ Logger = { LogLevel = "INFO" } })
    Assert.is_false(ok, "update должен вернуть false")
    Assert.are_equal("Схема валидации отсутствует", err, "Сообщение об ошибке")
end)

suite:add_test("get_cached: разные ключи вызывают генератор отдельно", function()
    local a_calls, b_calls = 0, 0
    local a = ModuleUnderTest.get_cached("a", function() a_calls = a_calls + 1 return "A" end)
    local b = ModuleUnderTest.get_cached("b", function() b_calls = b_calls + 1 return "B" end)
    Assert.are_equal("A", a, "Ключ a")
    Assert.are_equal("B", b, "Ключ b")
    Assert.are_equal(1, a_calls, "Генератор a вызван один раз")
    Assert.are_equal(1, b_calls, "Генератор b вызван один раз")
end)

-- Поиск приватного _state по структуре (cache, cache_ttl, cache_timestamp)
local function find_monitor_config_state()
    local mock_read = Mock:new()
    local module_up = mock_read:get_module_upvalues(ModuleUnderTest)
    for _, up in pairs(module_up) do
        for _, val in pairs(up) do
            if type(val) == "table" and val.cache ~= nil and val.cache_ttl ~= nil and val.cache_timestamp ~= nil then
                return val
            end
        end
    end
    return nil
end

-- Проверка приватного кэша _state: заполнение при get_cached и сброс при update
suite:add_test("get_cached и update: приватный _state.cache заполняется и сбрасывается", function()
    ModuleUnderTest.reload()
    local state = find_monitor_config_state()
    Assert.is_not_nil(state, "приватный _state доступен через upvalue")
    Assert.is_not_nil(state.cache, "_state.cache есть")
    ModuleUnderTest.get_cached("priv_key", function() return "priv_value" end)
    Assert.are_equal("priv_value", state.cache["priv_key"], "_state.cache[key] после get_cached")
    ModuleUnderTest.update({ Logger = { LogLevel = "ERROR" } })
    Assert.is_not_nil(state.cache, "_state.cache остаётся таблицей")
    Assert.is_nil(state.cache["priv_key"], "кэш сброшен после update")
end)

-- Граничные значения: cache_ttl и cache_timestamp в _state (после reload дефолты)
suite:add_test("reload: приватный _state имеет корректные cache_ttl и cache_timestamp", function()
    ModuleUnderTest.reload()
    local state = find_monitor_config_state()
    Assert.is_not_nil(state, "_state найден")
    Assert.is_true(state.cache_ttl > 0, "cache_ttl положительный")
    Assert.is_true(state.cache_timestamp >= 0, "cache_timestamp неотрицательный")
end)

suite:run()
