-- Тест жизненного цикла DVB тюнера и каналов
-- Запуск: /opt/astra/astra4.4.182 /opt/astra/lib-monitor/test/test_dvb_lifecycle.lua

-- Эмуляция окружения Astra
package.path = package.path .. ";/opt/astra/lib-monitor/?.lua;/opt/astra/lib-monitor/src/?.lua"

-- Инициализация библиотеки
local ModuleManager = require("init_monitor")

-- Инициализация базовых модулей
local Logger = ModuleManager.get_module("logger")
local Adapter = ModuleManager.get_module("adapter")
local Channel = ModuleManager.get_module("channel")
local ChannelStorage = ModuleManager.get_module("channel_storage")

Logger.info("TEST", "Starting DVB Lifecycle Test")

-- Эмуляция системного списка каналов Astra
local system_channel_list = {}
ModuleManager.set_global_dependencies({ channel_list = system_channel_list })

-- 1. Запускаем мониторинг тюнера
local tuner_conf = {
    name_adapter = "tuner_0",
    adapter = 0,
    device = 0,
    type = "S2",
    tp = "11044:V:44950",
    method_comparison = 1,
    time_check = 1
}

local success_tuner = Adapter.dvb_tuner_monitor(tuner_conf)
if success_tuner then
    Logger.info("TEST", "Tuner monitor started")
else
    Logger.error("TEST", "Failed to start tuner monitor")
    return
end

local tuner_instance = _G["tuner_0"]
Logger.info("TEST", "Initial channels counter: " .. tostring(tuner_instance.__options.channels))

-- 2. Запускаем канал на этом тюнере с выходными данными
local channel_conf = {
    name = "TestChannel",
    input = {
        {
            config = {
                format = "dvb",
                addr = "tuner_0",
                adapter = 0,
                device = 0
            }
        }
    },
    output = { "udp://239.0.0.1:1234" }, -- Настройка вещания
    monitor = {
        monitor_type = "output"
    }
}

-- Эмулируем наличие канала в системе Astra (без монитора)
local external_channel = {
    config = { name = "ExternalChannel" },
    input = { { config = { format = "dvb", addr = "tuner_0" } } }
}
table.insert(system_channel_list, external_channel)

local success_ch, ch_data = Channel.make_stream(channel_conf)
if success_ch then
    Logger.info("TEST", "Channel started")
    table.insert(system_channel_list, ch_data) -- Добавляем в системный список
else
    Logger.error("TEST", "Failed to start channel")
end

Logger.info("TEST", "Channels counter after channel start: " .. tostring(tuner_instance.__options.channels))

-- 3. Пробуем сменить частоту (должно быть запрещено)
Logger.info("TEST", "Attempting to change frequency while channel is active...")
local success_retune = Adapter.update_dvb_monitor_parameters("tuner_0", { tp = "12345:H:27500" })
if not success_retune then
    Logger.info("TEST", "Retune correctly blocked")
else
    Logger.warn("TEST", "Retune was NOT blocked (unexpected)")
end

-- Проверка поиска каналов
Logger.info("TEST", "Checking find_by_adapter...")
local found = ChannelStorage.find_by_adapter("tuner_0")
local count = 0
for name, _ in pairs(found) do 
    Logger.info("TEST", "Found channel on adapter: " .. name)
    count = count + 1
end
if count >= 1 then
    Logger.info("TEST", "find_by_adapter works correctly")
else
    Logger.error("TEST", "find_by_adapter failed to find channels")
end

-- 4. Сценарий переключения транспондера (Гибридный: DVB + HTTP)
Logger.info("TEST", "Starting hybrid switch_transponder scenario...")
local new_tuner_params = { tp = "11111:H:22222" }
local reserve_input = {
    { name = "TestChannel", pnr = 201 }, -- Тот же канал, но новый PNR (выходы должны наследоваться)
    { name = "BackupChannel", input = "http://server.com/backup.ts" } -- Новый канал по HTTP
}

local success_switch, old_state = Adapter.switch_transponder("tuner_0", new_tuner_params, reserve_input)
if success_switch then
    Logger.info("TEST", "Switch transponder successful")
    Logger.info("TEST", "New channels counter: " .. tostring(tuner_instance.__options.channels))
else
    Logger.error("TEST", "Switch transponder failed")
end

-- 5. Остановка всего
Logger.info("TEST", "Cleaning up...")
Channel.kill_stream("NewChannel")
Logger.info("TEST", "Counter after NewChannel kill: " .. tostring(tuner_instance.__options.channels))

Adapter.stop_dvb_monitor("tuner_0")
Logger.info("TEST", "Test finished")

astra.exit()
