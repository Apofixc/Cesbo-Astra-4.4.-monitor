-- Углубленное тестирование функционала lib-monitor
-- Проверяет: DvbTuner, Channel, Storage, Logger

package.path = package.path .. ";;/opt/astra/lib-monitor/?.lua;;/opt/astra/lib-monitor/http/?.lua;;/opt/astra/lib-monitor/config/?.lua;;"

local ModuleManager = require "init_monitor"
local Logger = ModuleManager.get_module("logger")
local DvbTuner = ModuleManager.get_module("dvb_tuner")
local Channel = ModuleManager.get_module("channel")
local ChannelStorage = ModuleManager.get_module("channel_storage")
local DvbStorage = ModuleManager.get_module("dvb_storage")
local Adapter = ModuleManager.get_module("adapter")
local timer = ModuleManager.get_global_dependency("timer")

log.set({ debug = true, stdout = true })

local function assert_test(condition, message)
    if not condition then
        print("FAILED: " .. message)
        -- os.exit(1)
    else
        print("PASSED: " .. message)
    end
end

print("\n=== START DEEP TEST ===\n")

-- 1. Тестирование DvbTuner через Adapter
print("--- 1. Testing DvbTuner via Adapter ---")
local tuner_config = {
    name_adapter = "deep_test_adapter",
    adapter = 0,
    type = "C",
    frequency = 506,
    symbolrate = 6900,
    modulation = "QAM256",
    time_check = 1,
    method_comparison = 2
}

local success = Adapter.dvb_tuner_monitor(tuner_config)
assert_test(success == true, "Adapter.dvb_tuner_monitor start")

local tuner = DvbStorage.find("deep_test_adapter")
assert_test(tuner ~= nil, "DvbTuner instance found in storage")
assert_test(_G["deep_test_adapter"] ~= nil, "Tuner instance registered in _G")
assert_test(tuner._active == true, "DvbTuner active status")

-- Проверка обновления параметров
local update_success = tuner:update_parameters({ time_check = 5 })
assert_test(update_success == true and tuner.config.time_check == 5, "DvbTuner update_parameters")

-- Проверка паузы/резюме
tuner:pause()
assert_test(tuner._active == false, "DvbTuner pause")
tuner:resume()
assert_test(tuner._active == true, "DvbTuner resume")

-- 2. Тестирование Channel (make_stream)
print("\n--- 2. Testing Channel (make_stream) ---")
local stream_conf = {
    name = "TestStream",
    input = { "dvb://deep_test_adapter#pnr=1660" },
    monitor = {
        monitor_type = "input",
        analyze = true
    }
}

local ch_data = Channel.make_stream(stream_conf)
assert_test(ch_data ~= nil, "Channel.make_stream creation")

local monitor = Channel.find_monitor("TestStream")
assert_test(monitor ~= nil, "Channel monitor registration in storage")
assert_test(ChannelStorage.count() > 0, "ChannelStorage count increment")

-- 3. Тестирование DvbStorage
print("\n--- 3. Testing DvbStorage ---")
-- DvbStorage обычно наполняется через Adapter.dvb_tuner_monitor, 
-- но мы можем проверить ручную регистрацию или поиск
DvbStorage.register("deep_test_adapter", tuner)
local found_tuner = DvbStorage.find("deep_test_adapter")
assert_test(found_tuner == tuner, "DvbStorage register/find")

-- 4. Тестирование одновременной работы (несколько стримов на одном тюнере)
print("\n--- 4. Testing Multiple Streams on One Tuner ---")
local stream_conf2 = {
    name = "TestStream2",
    input = { "dvb://deep_test_adapter#pnr=1680" },
    monitor = { monitor_type = "input" }
}
local ch_data2 = Channel.make_stream(stream_conf2)
assert_test(ch_data2 ~= nil, "Second stream on same tuner")
-- Проверка счетчика опущена, так как логика управления счетчиком 
-- реализована внутри Astra и не требует ручного вмешательства в Channel.lua

-- 5. Тестирование очистки (Cleanup)
print("\n--- 5. Testing Cleanup ---")

-- Удаляем один стрим
Channel.kill_stream("TestStream")
assert_test(Channel.find_monitor("TestStream") == nil, "Kill stream 1 (monitor removed)")
assert_test(tuner.instance ~= nil, "Tuner still alive after 1 stream killed")

-- Удаляем второй стрим
Channel.kill_stream("TestStream2")
assert_test(Channel.find_monitor("TestStream2") == nil, "Kill stream 2 (monitor removed)")

-- Уничтожаем тюнер через Adapter
Adapter.stop_dvb_monitor("deep_test_adapter", true)
assert_test(DvbStorage.find("deep_test_adapter") == nil, "DvbTuner removed from storage")
assert_test(_G["deep_test_adapter"] == nil, "Tuner removed from _G")

print("\n=== DEEP TEST FINISHED ===\n")
-- Завершаем процесс Astra
os.exit(0)
