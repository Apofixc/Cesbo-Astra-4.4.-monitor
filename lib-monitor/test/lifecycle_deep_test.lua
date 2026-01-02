-- Глубокое тестирование жизненного цикла: остановка, пересоздание, миграция
package.path = package.path .. ";;/opt/astra/lib-monitor/?.lua;;/opt/astra/lib-monitor/http/?.lua;;/opt/astra/lib-monitor/config/?.lua;;"

local ModuleManager = require "init_monitor"
local Logger = ModuleManager.get_module("logger")
local Adapter = ModuleManager.get_module("adapter")
local Channel = ModuleManager.get_module("channel")
local ChannelStorage = ModuleManager.get_module("channel_storage")
local DvbStorage = ModuleManager.get_module("dvb_storage")
local timer = ModuleManager.get_global_dependency("timer")

log.set({ debug = true, stdout = true })

local function assert_test(condition, message)
    if not condition then
        print("\nFAILED: " .. message)
    else
        print("\nPASSED: " .. message)
    end
end

print("\n=== START DEEP LIFECYCLE TEST ===\n")

local tuner_name = "lifecycle_tuner"
local ch_name = "LIFECYCLE_CH"

-- 1. Создание тюнера и канала
print("--- 1. Initial Creation ---")
Adapter.dvb_tuner_monitor({
    name_adapter = tuner_name,
    adapter = 0,
    type = "C",
    frequency = 506,
    symbolrate = 6900,
    modulation = "QAM256"
})

Channel.make_stream({
    name = ch_name,
    input = { string.format("dvb://%s#pnr=1660", tuner_name) },
    monitor = { analyze = true }
})

assert_test(DvbStorage.find(tuner_name) ~= nil, "Tuner registered")
assert_test(ChannelStorage.find(ch_name) ~= nil, "Channel monitor registered")

-- 2. Тест остановки монитора без остановки канала
timer({
    interval = 5,
    callback = function(t)
        t:close()
        print("\n--- 2. Kill Monitor Only ---")
        Channel.kill_monitor(ch_name)
        assert_test(ChannelStorage.find(ch_name) == nil, "Monitor unregistered")
        -- Проверяем что канал в Astra все еще жив
        local astra_ch = ModuleManager.get_global_dependency("find_channel")(ch_name)
        assert_test(astra_ch ~= nil, "Astra channel still exists")
        
        -- 3. Пересоздание монитора для существующего канала
        print("\n--- 3. Recreate Monitor for Existing Channel ---")
        Channel.make_monitor({
            name = ch_name,
            monitor_type = "output",
            analyze = true
        }, astra_ch)
        assert_test(ChannelStorage.find(ch_name) ~= nil, "Monitor recreated")
    end
})

-- 4. Тест switch_transponder с проверкой пересоздания
timer({
    interval = 15,
    callback = function(t)
        t:close()
        print("\n--- 4. Switch Transponder Deep Check ---")
        Adapter.switch_transponder(tuner_name, {
            frequency = 506,
            symbolrate = 6900,
            modulation = "QAM256"
        }, {
            { name = ch_name, input = { string.format("dvb://%s#pnr=1680", tuner_name) } }
        })
        
        local new_monitor = ChannelStorage.find(ch_name)
        assert_test(new_monitor ~= nil, "Channel monitor exists after migration")
        -- Проверяем что вход обновился в конфиге монитора
        assert_test(new_monitor._config.stream_json[1].addr == tuner_name, "Monitor config updated")
    end
})

-- 5. Тест полного удаления и пересоздания
timer({
    interval = 30,
    callback = function(t)
        t:close()
        print("\n--- 5. Full Kill and Recreate ---")
        Channel.kill_stream(ch_name)
        assert_test(ChannelStorage.find(ch_name) == nil, "Monitor killed")
        
        -- Даем Astra время на очистку ресурсов
        timer({
            interval = 10,
            callback = function(t2)
                t2:close()
                local astra_ch = ModuleManager.get_global_dependency("find_channel")(ch_name)
                assert_test(astra_ch == nil, "Astra channel killed")
                
                print("Recreating stream with NEW name...")
                local new_ch_name = ch_name .. "_NEW"
                
                -- Используем pcall для вызова make_channel
                local make_channel = ModuleManager.get_global_dependency("make_channel")
                local success, ch_data = pcall(make_channel, {
                    name = new_ch_name,
                    input = { string.format("dvb://%s#pnr=1660", tuner_name) }
                })
                
                if success and ch_data then
                    print("Astra channel recreated, now adding monitor...")
                    -- Используем pcall для make_monitor
                    local m_success, m_res = pcall(Channel.make_monitor, {
                        name = new_ch_name,
                        monitor_type = "output",
                        analyze = true
                    }, ch_data)
                    
                    if m_success and m_res then
                        assert_test(ChannelStorage.find(new_ch_name) ~= nil, "Stream and monitor recreated with new name")
                        Channel.kill_stream(new_ch_name)
                    else
                        print("Failed to add monitor: " .. tostring(m_res))
                    end
                else
                    print("Failed to recreate Astra channel: " .. tostring(ch_data))
                end
            end
        })
    end
})

-- Завершение
timer({
    interval = 45,
    callback = function()
        print("\n=== CLEANUP ===")
        Channel.kill_stream(ch_name)
        Adapter.stop_dvb_monitor(tuner_name, true)
        print("=== DEEP LIFECYCLE TEST COMPLETED ===")
        os.exit(0)
    end
})
