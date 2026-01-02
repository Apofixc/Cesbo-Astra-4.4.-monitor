-- Стресс-тест: 8+ каналов на одном транспондере с замером ресурсов
package.path = package.path .. ";;/opt/astra/lib-monitor/?.lua;;/opt/astra/lib-monitor/http/?.lua;;/opt/astra/lib-monitor/config/?.lua;;"

local ModuleManager = require "init_monitor"
local Logger = ModuleManager.get_module("logger")
local Adapter = ModuleManager.get_module("adapter")
local Channel = ModuleManager.get_module("channel")
local ResourceMonitor = ModuleManager.get_module("resource_monitor")
local HttpSubscriber = ModuleManager.get_module("http_subscriber")
local timer = ModuleManager.get_global_dependency("timer")

log.set({ debug = true, stdout = true })

-- Перехватываем публикации для вывода в консоль
local original_publish = HttpSubscriber.publish
HttpSubscriber.publish = function(event, data)
    print(string.format("\n>>> PUBLISH [%s]: %s", event, data))
    original_publish(event, data)
end

print("\n=== START STRESS TEST (8+ CHANNELS) ===\n")

-- 1. Инициализация мониторинга ресурсов
ResourceMonitor.init()

-- 2. Запуск тюнера (используем 506 МГц, где точно есть каналы)
local tuner_name = "stress_tuner"
local tuner_success = Adapter.dvb_tuner_monitor({
    name_adapter = tuner_name,
    adapter = 0,
    type = "C",
    frequency = 506,
    symbolrate = 6900,
    modulation = "QAM256",
    time_check = 5,
    method_comparison = 2 -- STRICT
})

if not tuner_success then
    print("Failed to start tuner monitor")
    os.exit(1)
end

-- 3. Список PNR для запуска (на основе предыдущих сканирований на 506 МГц)
local programs = { 1610, 1620, 1630, 1640, 1650, 1660, 1670, 1680, 1690 }
local active_channels = {}

local function start_channels()
    for i, pnr in ipairs(programs) do
        local ch_name = "CH_" .. pnr
        print(string.format("Starting channel: %s (PNR: %d)", ch_name, pnr))
        
        local ch_data = Channel.make_stream({
            name = ch_name,
            input = { string.format("dvb://%s#pnr=%d", tuner_name, pnr) },
            monitor = {
                monitor_type = "input",
                analyze = true,
                method_comparison = 2 -- STRICT
            }
        })
        
        if ch_data then
            table.insert(active_channels, ch_name)
        end
    end
    print(string.format("\nTotal channels started: %d", #active_channels))
end

-- Запускаем каналы через 2 секунды после тюнера
timer({
    interval = 2,
    callback = function(t)
        t:close()
        start_channels()
    end
})

-- Тест идет 60 секунд
timer({
    interval = 60,
    callback = function()
        print("\n=== STRESS TEST FINISHING (CLEANUP) ===")
        for _, name in ipairs(active_channels) do
            Channel.kill_stream(name)
        end
        Adapter.stop_dvb_monitor(tuner_name, true)
        ResourceMonitor.stop()
        print("=== STRESS TEST COMPLETED ===")
        os.exit(0)
    end
})
