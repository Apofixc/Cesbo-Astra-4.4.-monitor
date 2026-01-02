package.path = package.path .. ";;/opt/astra/lib-monitor/?.lua;;/opt/astra/lib-monitor/src/?.lua;;/opt/astra/lib-monitor/http/?.lua;;/opt/astra/lib-monitor/config/?.lua;;"

-- 1. Стандартные Lua функции
local collectgarbage = collectgarbage
local os = os
local print = print
local string = string

-- 2. Функции из ModuleManager.get_module()
local monitor = require "init_monitor"
local Channel = monitor.get_module("channel")
local ChannelStorage = monitor.get_module("channel_storage")
local Logger = monitor.get_module("logger")

-- Включаем логирование для отслеживания событий
log.set({ debug = true, stdout = true })

local function get_mem()
    collectgarbage("collect")
    return collectgarbage("count")
end

local function run_real_data_test()
    print("\n--- STARTING REAL DATA PERFORMANCE TEST ---")
    
    local start_mem = get_mem()
    print(string.format("Initial Memory: %.2f KB", start_mem))

    -- Создаем канал с реальным потоком
    local stream_name = "RealDataTest"
    local stream_url = "http://31.130.202.110/httpts/tv3by/avchigh.ts"
    
    print(string.format("Creating stream: %s (%s)", stream_name, stream_url))
    
    local success = make_stream({
        name = stream_name,
        input = { stream_url },
        output = { "udp://224.100.200.1:1234#sync" },
        -- Включаем мониторинг через параметры, если библиотека это поддерживает автоматически
        -- или через явный вызов функций мониторинга
    })

    if not success then
        print("Failed to create stream")
        os.exit(1)
    end

    -- Ждем накопления данных и работы мониторинга
    local test_duration = 30 -- секунд
    print(string.format("Monitoring for %d seconds...", test_duration))
    
    local timer_count = 0
    timer({
        interval = 5,
        callback = function()
            timer_count = timer_count + 5
            local current_mem = get_mem()
            local monitor_inst = ChannelStorage.find(stream_name)
            
            print(string.format("[%ds] Memory: %.2f KB (Delta: %.2f KB)", 
                timer_count, current_mem, current_mem - start_mem))
            
            if monitor_inst then
                -- Здесь можно вывести специфические данные мониторинга, если они доступны
                -- Например: monitor_inst:get_status()
                print("Monitor instance found and active")
            end

            if timer_count >= test_duration then
                print("\n--- FINAL REAL DATA REPORT ---")
                local final_mem = get_mem()
                print(string.format("Final Memory: %.2f KB", final_mem))
                print(string.format("Total Memory Delta: %.2f KB", final_mem - start_mem))
                
                -- Очистка
                print("Cleaning up...")
                -- В Astra 4.4.182 для удаления потока может потребоваться специфический вызов
                -- Но в рамках теста мы просто завершим процесс
                print("--- REAL DATA TEST FINISHED ---")
                os.exit(0)
            end
        end
    })
end

run_real_data_test()
