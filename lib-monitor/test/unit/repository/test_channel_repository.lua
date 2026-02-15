-- L4: Unit-тесты для модуля repository.channel_repository
-- Репозиторий каналов: конфиг-подписка, _on_before_recreate, find_by_adapter.
-- Моки: Logger, Utils, BaseRepository, EventDispatcher, channel_list.

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
local Mock = require("tools.test_moc")

local mock
local ChannelRepository
local ref_ModuleManager
local ref_base
local ref_ed
local subscribe_calls
local emit_calls
local log_error_msg
-- Переопределяемый channel_list для find_by_adapter (модуль вызывает get_global_dependency при каждом вызове)
local channel_list_override

local suite = TestSuite:new("L4.channel_repository")

suite:setup(function()
    mock = Mock:new()
    subscribe_calls = {}
    emit_calls = {}
    log_error_msg = nil
    channel_list_override = nil

    ref_base = {
        new = function(component_name)
            return setmetatable({
                _state = {},
                _component_name = component_name,
                set_limit = function(self, n) self._limit = n end,
                init_base_config_subscription = function() end,
            }, { __index = {} })
            end,
    }

    ref_ed = {
        get_instance = function()
            return {
                subscribe = function(_, event_type, cb)
                    subscribe_calls[#subscribe_calls + 1] = { event_type = event_type, cb = cb }
                    return "sub-id"
                end,
                emit = function(_, event_type, name, reason)
                    emit_calls[#emit_calls + 1] = { event_type = event_type, name = name, reason = reason }
                end,
            }
        end,
    }

    ref_ModuleManager = {
        get_module = function(name)
            if name == "logger" then
                return {
                    error = function(_, msg) log_error_msg = msg end,
                    info = function() end,
                    warning = function() end,
                    debug = function() end,
                }
            end
            if name == "utils" then
                return {
                    parse_url = function(url)
                        if url == "dvb://0.1" then return { format = "dvb", addr = "0.1" } end
                        if url == "dvb://0" then return { format = "dvb", addr = "0" } end
                        return nil
                    end,
                }
            end
            if name == "core.base_repository" then return ref_base end
            if name == "core.event_dispatcher" then return ref_ed end
            return nil
        end,
        get_global_dependency = function(name)
            if name == "channel_list" then return channel_list_override end
            return nil
        end,
    }
    mock:mock_global("ModuleManager", ref_ModuleManager)
end)

suite:before_each(function()
    subscribe_calls = {}
    emit_calls = {}
    log_error_msg = nil
    channel_list_override = nil
    package.loaded["src.repository.channel_repository"] = nil
    ChannelRepository = require("src.repository.channel_repository")
end)

suite:teardown(function()
    mock:restore()
end)

-- L4-CH-01: init_config_subscription подписывается на config:updated:monitor, set_limit при ChannelMonitorLimit
suite:add_test("L4-CH-01: init_config_subscription подписывается и обновляет лимит", function()
    ChannelRepository:init_config_subscription()
    local monitor_sub
    for i = 1, #subscribe_calls do
        if subscribe_calls[i].event_type == "config:updated:monitor" then
            monitor_sub = subscribe_calls[i].cb
            break
        end
    end
    Assert.is_not_nil(monitor_sub, "подписка на config:updated:monitor")
    ChannelRepository._limit = nil
    monitor_sub({ ChannelMonitorLimit = 100 })
    Assert.are_equal(100, ChannelRepository._limit, "set_limit вызван с ChannelMonitorLimit")
end)

-- L4-CH-02: _on_before_recreate watchdog/silence эмитит channel:action:recreate
suite:add_test("L4-CH-02: _on_before_recreate эмитит channel:action:recreate", function()
    local ok = ChannelRepository:_on_before_recreate("ch1", "watchdog")
    Assert.is_true(ok, "возвращает true")
    Assert.is_true(#emit_calls == 1, "emit вызван")
    Assert.are_equal("channel:action:recreate", emit_calls[1].event_type, "тип события")
    Assert.are_equal("ch1", emit_calls[1].name, "имя канала")
end)

-- L4-CH-03: find_by_adapter при отсутствии channel_list возвращает {} и логирует ошибку
suite:add_test("L4-CH-03: find_by_adapter без channel_list возвращает пустой результат", function()
    local result = ChannelRepository:find_by_adapter("0")
    Assert.is_true(type(result) == "table" and next(result) == nil, "пустая таблица")
    Assert.is_true(log_error_msg and log_error_msg:find("channel_list"), "Logger.error о зависимости")
end)

-- L4-CH-04: find_by_adapter с channel_list: input как таблица (config.format, config.addr)
suite:add_test("L4-CH-04: find_by_adapter находит канал по input-table с dvb addr", function()
    channel_list_override = {
        ch1 = {
            config = { name = "ch1" },
            input = {
                { config = { format = "dvb", addr = "0" } },
            },
        },
    }
    local result = ChannelRepository:find_by_adapter("0")
    Assert.is_not_nil(result["ch1"], "канал ch1 найден")
    Assert.are_equal(channel_list_override.ch1, result["ch1"], "данные канала")
end)

-- L4-CH-05: find_by_adapter с input как строка (parse_url)
suite:add_test("L4-CH-05: find_by_adapter находит канал по input-string (parse_url)", function()
    channel_list_override = {
        ch2 = {
            config = { name = "ch2" },
            input = { "dvb://0.1" },
        },
    }
    local result = ChannelRepository:find_by_adapter("0.1")
    Assert.is_not_nil(result["ch2"], "канал ch2 найден по parse_url")
end)

-- L4-CH-06: find_by_adapter без совпадений возвращает пустой результат
suite:add_test("L4-CH-06: find_by_adapter без совпадений возвращает пустой результат", function()
    channel_list_override = {
        ch3 = {
            config = { name = "ch3" },
            input = { { config = { format = "dvb", addr = "1" } } },
        },
    }
    local result = ChannelRepository:find_by_adapter("0")
    Assert.is_true(next(result) == nil, "нет совпадений для адаптера 0")
end)

suite:run()
