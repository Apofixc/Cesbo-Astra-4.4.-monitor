-- Тест логики адаптеров и проверки на утечки памяти
package.path = package.path .. ";;/opt/astra/lib-monitor/?.lua;"

-- 1. Моки для Astra API
local mock_astra = {
    dvb_tune = function(conf)
        local instance = {
            __options = {
                adapter = conf.adapter or "0",
                device = conf.device or "0",
                channels = 0
            },
            stream = function() return {} end,
            close = function(self) 
                self.__closed = true
            end
        }
        return instance
    end,
    timer = function(opts)
        return {
            close = function() end
        }
    end,
    analyze = function() return {} end,
    ["json.encode"] = function(t) return "{}" end,
    ["json.decode"] = function(s) return {} end,
    log = {
        info = function() end,
        error = function() end,
        debug = function() end,
        warn = function() end,
    },
    dvb_input_instance_list = {}
}

-- 2. Инициализация ModuleManager и моков
local ModuleManager = require "src.module_manager"

local function setup_modules(custom_deps)
    -- Очистка кэша require для модулей библиотеки (более агрессивная)
    for k, _ in pairs(package.loaded) do
        if k:find("src.") or k:find("src/") or k == "init_monitor" or k == "src.module_manager" then
            package.loaded[k] = nil
        end
    end

    -- Перезагружаем ModuleManager, чтобы гарантировать чистое состояние
    ModuleManager = require "src.module_manager"
    ModuleManager.reset()
    
    local deps = {
        ["analyze"] = mock_astra.analyze,
        ["astra.reload"] = function() end,
        ["astra.version"] = "4.4.182",
        ["channel_list"] = function() return {} end,
        ["dvb_tune"] = mock_astra.dvb_tune,
        ["find_channel"] = function() return nil end,
        ["http_request"] = function() end,
        ["http_server"] = function() end,
        ["init_input"] = function() return { tail = {} } end,
        ["json.decode"] = mock_astra["json.decode"],
        ["json.encode"] = mock_astra["json.encode"],
        ["kill_channel"] = function() end,
        ["kill_input"] = function() end,
        ["make_channel"] = function() return { tail = {} } end,
        ["parse_url"] = function() return { host = "localhost" } end,
        ["string.split"] = function(s, d) return {s} end,
        ["timer"] = mock_astra.timer,
        ["utils.hostname"] = function() return "test-host" end,
        ["log"] = mock_astra.log,
        ["dvb_input_instance_list"] = mock_astra.dvb_input_instance_list
    }
    
    if custom_deps then
        for k, v in pairs(custom_deps) do
            deps[k] = v
        end
    end
    
    ModuleManager.set_global_dependencies(deps)

    -- Регистрация модулей
    ModuleManager.register_module("monitor_config", "src.config.monitor_config")
    ModuleManager.register_module("logger", "src.utils.logger", {"monitor_config"})
    ModuleManager.register_module("utils", "src.utils.utils", {"logger", "monitor_config"})
    ModuleManager.register_module("http_subscriber", "src.utils.http_subscriber", {"logger", "monitor_config"})
    ModuleManager.register_module("dvb_tuner", "src.adapters.dvb_tuner", {"logger", "utils", "monitor_config", "http_subscriber"})
    ModuleManager.register_module("dvb_storage", "src.storage.dvb_storage", {"logger"})
    ModuleManager.register_module("adapter", "src.adapters.adapter", {"logger", "monitor_config", "dvb_tuner", "dvb_storage"})
    ModuleManager.register_module("channel_monitor", "src.channel.channel_monitor", {"logger", "utils", "monitor_config", "http_subscriber"})
    ModuleManager.register_module("channel_storage", "src.storage.channel_storage", {"logger"})
    ModuleManager.register_module("channel", "src.channel.channel", {"logger", "utils", "monitor_config", "channel_monitor", "channel_storage", "adapter"})

    local ok = ModuleManager.load_modules()
    if not ok then
        print("Failed to load modules")
        -- Не выходим сразу, чтобы увидеть ошибки в консоли если они были напечатаны
        os.exit(1)
    end

    -- Принудительно загружаем зависимые модули, если они не загрузились автоматически
    -- (хотя load_modules должен это делать)
    local ChannelMonitor = ModuleManager.get_module("channel_monitor")
    local ChannelStorage = ModuleManager.get_module("channel_storage")

    local Adapter = ModuleManager.get_module("adapter")
    local DvbStorage = ModuleManager.get_module("dvb_storage")
    local Logger = ModuleManager.get_module("logger")

    -- Оставляем Logger.error для отладки тестов
    Logger.info = function() end
    Logger.error = function(comp, fmt, ...) print(string.format("[ERR][%s] "..fmt, comp, ...)) end
    Logger.debug = function() end
    Logger.warn = function(comp, fmt, ...) print(string.format("[WRN][%s] "..fmt, comp, ...)) end
    
    return Adapter, DvbStorage
end

local Adapter, DvbStorage = setup_modules()

-- 3. Тесты

local function assert_test(cond, msg)
    if not cond then
        print("FAILED: " .. msg)
        os.exit(1)
    end
end

print("--- Starting Adapter Logic Tests ---")

-- Тест 1: Создание и удаление монитора
print("Test 1: Basic Lifecycle...")
local conf = {
    name_adapter = "adapter_0",
    adapter = "0",
    type = "S2",
    tp = "11044:V:43200"
}

assert_test(Adapter.dvb_tuner_monitor(conf), "Failed to create monitor")
local tuner = DvbStorage.find("adapter_0")
assert_test(tuner ~= nil, "Tuner not found in storage")
assert_test(_G["adapter_0"] ~= nil, "Tuner not found in _G")
assert_test(tuner.instance.__options.channels == 1, "Wrong channels count")

assert_test(Adapter.stop_dvb_monitor("adapter_0"), "Failed to stop monitor")
assert_test(DvbStorage.find("adapter_0") == nil, "Tuner still in storage")
assert_test(_G["adapter_0"] == nil, "Tuner still in _G")
print("Test 1: PASSED")

-- Тест 2: Проверка утечек памяти
print("Test 2: Memory Leak Check...")
collectgarbage("collect")
local mem_before = collectgarbage("count")

for i = 1, 100 do
    local name = "test_adapter_" .. i
    Adapter.dvb_tuner_monitor({ name_adapter = name, adapter = "0" })
    Adapter.stop_dvb_monitor(name)
end

collectgarbage("collect")
local mem_after = collectgarbage("count")
local diff = mem_after - mem_before
print(string.format("Memory diff after 100 cycles: %.2f KB", diff))
-- Допускаем небольшую разницу из-за фрагментации, но не мегабайты
assert_test(diff < 50, "Potential memory leak detected!")
print("Test 2: PASSED")

-- Тест 3: Рестарт и Rollback
print("Test 3: Restart and Rollback...")
Adapter.dvb_tuner_monitor({ name_adapter = "adapter_restart", adapter = "0" })

-- Имитируем ошибку при создании нового тюнера
Adapter, DvbStorage = setup_modules({ dvb_tune = function() return nil end })

-- Теперь создание должно упасть
assert_test(Adapter.dvb_tuner_monitor({ name_adapter = "adapter_fail", adapter = "0" }) == false, "Creation should fail with bad mock")

-- Возвращаем нормальный мок
Adapter, DvbStorage = setup_modules()

-- Проверяем восстановление
Adapter.dvb_tuner_monitor({ name_adapter = "adapter_restart", adapter = "0" })
assert_test(DvbStorage.find("adapter_restart") ~= nil, "Should be able to recover")

Adapter.stop_dvb_monitor("adapter_restart")
print("Test 3: PASSED")

-- Тест 4: Переключение транспондера (switch_transponder)
print("Test 4: Switch Transponder...")

-- 1. Подготовка: создаем адаптер и канал на нем
local mock_channels = {}
    Adapter, DvbStorage = setup_modules({
        channel_list = mock_channels,
        make_channel = function(conf)
            local ch = { 
                config = conf, 
                input = {
                    { config = { format = "dvb", addr = "adapter_sw" }, input = { tail = { stream = function() return {} end } } }
                },
                tail = { 
                    stream = function() return { stream = function() return {} end } end 
                } 
            }
            mock_channels[conf.name] = ch
            return ch
        end,
        find_channel = function(name) return mock_channels[name] end,
        kill_channel = function(ch) mock_channels[ch.config.name] = nil end,
        parse_url = function(url) return { host = "localhost" } end,
        init_input = function() return { tail = {} } end,
        kill_input = function() end,
        ["string.split"] = function(s, d) return {s} end
    })

Adapter.dvb_tuner_monitor({ name_adapter = "adapter_sw", adapter = "0" })
local Channel = ModuleManager.get_module("channel")
Channel.make_stream({
    name = "TestChannel",
    input = { "dvb://adapter_sw#pnr=100" },
    output = { "udp://239.0.0.1:1234" }
})

-- 2. Выполняем переключение
local reserve = {
    { name = "TestChannel", input = { "http://backup/stream.ts" } }
}

local old_state = Adapter.switch_transponder("adapter_sw", { tp = "new_tp" }, reserve)

assert_test(old_state ~= nil, "Switch transponder failed")
assert_test(mock_channels["TestChannel"] ~= nil, "Channel should be recreated")
assert_test(mock_channels["TestChannel"].config.input[1] == "http://backup/stream.ts", "Input should be updated")
assert_test(mock_channels["TestChannel"].config.output[1] == "udp://239.0.0.1:1234", "Output should be preserved")

Adapter.stop_dvb_monitor("adapter_sw", true)
print("Test 4: PASSED")

-- Тест 5: Счетчик каналов (Shared Tuner)
print("Test 5: Shared Tuner Channels Counter...")
-- Создаем первый монитор
Adapter.dvb_tuner_monitor({ name_adapter = "tuner_shared", adapter = "0" })
local t1 = DvbStorage.find("tuner_shared")
local inst = t1.instance

-- Имитируем использование этого же инстанса другим монитором (в реальности это делает Astra)
inst.__options.channels = inst.__options.channels + 1

-- Пытаемся удалить первый монитор без force
local success_stop = Adapter.stop_dvb_monitor("tuner_shared")
assert_test(success_stop == nil, "Should not stop shared tuner without force")
assert_test(DvbStorage.find("tuner_shared") ~= nil, "Tuner should remain in storage")

-- Удаляем с force
assert_test(Adapter.stop_dvb_monitor("tuner_shared", true) ~= nil, "Should stop with force")
assert_test(DvbStorage.find("tuner_shared") == nil, "Tuner should be removed")
print("Test 5: PASSED")

print("--- All Adapter Tests PASSED ---")
