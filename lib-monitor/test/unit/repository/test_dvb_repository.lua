-- L4: Unit-тесты для модуля repository.dvb_repository
-- Репозиторий DVB-адаптеров: конфиг-подписка, хук _on_before_recreate (watchdog/silence).
-- Моки: Logger, BaseRepository, EventDispatcher.

local test_helper = require("tools.test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
local Mock = require("tools.test_moc")

local mock
local DvbRepository
local ref_ModuleManager
local ref_base
local ref_ed
local subscribe_calls
local emit_calls

local suite = TestSuite:new("L4.dvb_repository")

suite:setup(function()
    mock = Mock:new()
    subscribe_calls = {}
    emit_calls = {}

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
                    error = function() end,
                    info = function() end,
                    warning = function() end,
                    debug = function() end,
                }
            end
            if name == "core.base_repository" then return ref_base end
            if name == "core.event_dispatcher" then return ref_ed end
            return nil
        end,
        get_global_dependency = function() return nil end,
    }
    mock:mock_global("ModuleManager", ref_ModuleManager)
end)

suite:before_each(function()
    subscribe_calls = {}
    emit_calls = {}
    package.loaded["src.repository.dvb_repository"] = nil
    DvbRepository = require("src.repository.dvb_repository")
end)

suite:teardown(function()
    mock:restore()
end)

-- L4-DVB-01: init_config_subscription подписывается на config:updated:monitor и вызывает init_base_config
suite:add_test("L4-DVB-01: init_config_subscription подписывается и обновляет лимит", function()
    local repo = DvbRepository
    repo:init_config_subscription()
    local monitor_sub
    for i = 1, #subscribe_calls do
        if subscribe_calls[i].event_type == "config:updated:monitor" then
            monitor_sub = subscribe_calls[i].cb
            break
        end
    end
    Assert.is_not_nil(monitor_sub, "подписка на config:updated:monitor")
    repo._limit = nil
    monitor_sub({ DvbMonitorLimit = 10 })
    Assert.are_equal(10, repo._limit, "set_limit вызван с DvbMonitorLimit")
end)

-- L4-DVB-02: _on_before_recreate при reason watchdog/silence эмитит adapter:action:restart
suite:add_test("L4-DVB-02: _on_before_recreate watchdog эмитит adapter:action:restart", function()
    local ok = DvbRepository:_on_before_recreate("adapter0", "watchdog")
    Assert.is_true(ok, "возвращает true")
    Assert.is_true(#emit_calls == 1, "emit вызван один раз")
    Assert.are_equal("adapter:action:restart", emit_calls[1].event_type, "тип события")
    Assert.are_equal("adapter0", emit_calls[1].name, "имя адаптера")
    Assert.are_equal("watchdog", emit_calls[1].reason, "причина")
end)

suite:add_test("L4-DVB-02: _on_before_recreate silence эмитит adapter:action:restart", function()
    local ok = DvbRepository:_on_before_recreate("adapter1", "silence")
    Assert.is_true(ok, "возвращает true")
    Assert.is_true(#emit_calls == 1, "emit вызван")
    Assert.are_equal("silence", emit_calls[1].reason, "причина silence")
end)

-- L4-DVB-03: _on_before_recreate при другой причине не эмитит
suite:add_test("L4-DVB-03: _on_before_recreate при другой причине не эмитит", function()
    local ok = DvbRepository:_on_before_recreate("x", "other")
    Assert.is_true(ok, "возвращает true")
    Assert.are_equal(0, #emit_calls, "emit не вызывается")
end)

suite:run()
