-- Тест Failover: переключение на резервный вход при потере битрейта
package.path = package.path .. ";;/opt/astra/lib-monitor/?.lua;;/opt/astra/lib-monitor/http/?.lua;;/opt/astra/lib-monitor/config/?.lua;;"

local ModuleManager = require "init_monitor"
local Logger = ModuleManager.get_module("logger")
local Channel = ModuleManager.get_module("channel")
local HttpSubscriber = ModuleManager.get_module("http_subscriber")
local timer = ModuleManager.get_global_dependency("timer")

log.set({ debug = true, stdout = true })

-- Перехватываем публикации
HttpSubscriber.publish = function(event, data)
    print(string.format("\n>>> PUBLISH [%s]: %s", event, data))
end

print("\n=== START FAILOVER TEST ===\n")

-- Создаем канал с двумя входами: 
-- 1. Несуществующий UDP (для имитации ошибки)
-- 2. Рабочий файл (для имитации переключения на резерв)
local ch_name = "FAILOVER_CH"
Channel.make_stream({
    name = ch_name,
    input = { 
        "udp://127.0.0.1:9999", -- Основной (битый)
        "file:///opt/astra/cesbo-astra/scripts/examples/http/test.ts#loop" -- Резервный
    },
    monitor = {
        analyze = true,
        timeout = 5 -- Таймаут переключения 5 секунд
    }
})

-- Тест идет 30 секунд
timer({
    interval = 30,
    callback = function()
        print("\n=== CLEANUP ===")
        Channel.kill_stream(ch_name)
        os.exit(0)
    end
})
