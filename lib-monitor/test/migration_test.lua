-- Тест массовой миграции (switch_transponder) и Failover
package.path = package.path .. ";;/opt/astra/lib-monitor/?.lua;;/opt/astra/lib-monitor/http/?.lua;;/opt/astra/lib-monitor/config/?.lua;;"

local ModuleManager = require "init_monitor"
local Logger = ModuleManager.get_module("logger")
local Adapter = ModuleManager.get_module("adapter")
local Channel = ModuleManager.get_module("channel")
local ResourceMonitor = ModuleManager.get_module("resource_monitor")
local HttpSubscriber = ModuleManager.get_module("http_subscriber")
local timer = ModuleManager.get_global_dependency("timer")

log.set({ debug = true, stdout = true })

-- Перехватываем публикации
HttpSubscriber.publish = function(event, data)
    print(string.format("\n>>> PUBLISH [%s]: %s", event, data))
end

print("\n=== START MIGRATION & FAILOVER TEST ===\n")

ResourceMonitor.init()

local tuner_name = "migration_tuner"
Adapter.dvb_tuner_monitor({
    name_adapter = tuner_name,
    adapter = 0,
    type = "C",
    frequency = 506,
    symbolrate = 6900,
    modulation = "QAM256"
})

-- Запускаем 2 канала
local ch1 = "CH_RETRO"
local ch2 = "CH_DRIVE"

timer({
    interval = 2,
    callback = function(t)
        t:close()
        print("--- Starting Channels ---")
        Channel.make_stream({
            name = ch1,
            input = { string.format("dvb://%s#pnr=1660", tuner_name) },
            monitor = { analyze = true }
        })
        Channel.make_stream({
            name = ch2,
            input = { string.format("dvb://%s#pnr=1680", tuner_name) },
            monitor = { analyze = true }
        })
    end
})

-- Через 15 секунд делаем миграцию на ту же частоту (имитация смены параметров)
timer({
    interval = 15,
    callback = function(t)
        t:close()
        print("\n--- Testing switch_transponder (Migration) ---")
        -- Передаем reserve_input, чтобы каналы были пересозданы на новом транспондере
        Adapter.switch_transponder(tuner_name, {
            frequency = 506,
            symbolrate = 6900,
            modulation = "QAM256"
        }, {
            { name = ch1, input = { string.format("dvb://%s#pnr=1660", tuner_name) } },
            { name = ch2, input = { string.format("dvb://%s#pnr=1680", tuner_name) } }
        })
    end
})

-- Через 30 секунд проверяем Pause/Resume
timer({
    interval = 30,
    callback = function(t)
        t:close()
        print("\n--- Testing Pause/Resume ---")
        if Channel.find_monitor(ch1) then
            Channel.pause_monitor(ch1)
            print("CH_RETRO monitor paused")
            
            timer({
                interval = 5,
                callback = function(t2)
                    t2:close()
                    Channel.resume_monitor(ch1)
                    print("CH_RETRO monitor resumed")
                end
            })
        else
            print("CH_RETRO monitor not found for pause test")
        end
    end
})

-- Завершение через 50 секунд
timer({
    interval = 50,
    callback = function()
        print("\n=== CLEANUP ===")
        if Channel.find_monitor(ch1) then Channel.kill_stream(ch1) end
        if Channel.find_monitor(ch2) then Channel.kill_stream(ch2) end
        Adapter.stop_dvb_monitor(tuner_name, true)
        ResourceMonitor.stop()
        os.exit(0)
    end
})
