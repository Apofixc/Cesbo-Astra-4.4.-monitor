package.path = package.path .. ";;/opt/astra/lib-monitor/?.lua;;/opt/astra/lib-monitor/src/?.lua;;/opt/astra/lib-monitor/http/?.lua;;/opt/astra/lib-monitor/config/?.lua;;"

-- 1. Стандартные Lua функции
local collectgarbage = collectgarbage
local os = os
local print = print
local string = string
local math = math

-- 2. Функции из ModuleManager.get_module()
local monitor = require "init_monitor"
local Channel = monitor.get_module("channel")
local ChannelStorage = monitor.get_module("channel_storage")
local Logger = monitor.get_module("logger")

-- Включаем логирование ошибок и важной информации
log.set({ debug = false, stdout = true })

local function get_mem()
    collectgarbage("collect")
    return collectgarbage("count")
end

local function run_long_term_test()
    print("\n--- STARTING LONG-TERM STABILITY TEST V2 (SOAK TEST) ---")
    local start_mem = get_mem()
    local start_time = os.time()
    
    -- Конфигурация теста
    local monitor_count = 50
    local test_duration = 300 -- 5 минут
    local check_interval = 30 -- каждые 30 секунд
    
    print(string.format("Initial Memory: %.2f KB", start_mem))
    print(string.format("Creating %d monitors for long-term observation...", monitor_count))

    for i = 1, monitor_count do
        Channel.make_stream({
            name = "SoakV2_" .. i,
            input = { "http://localhost/soak" },
            output = { "udp://224.1.4." .. i .. ":1234" }
        })
    end

    local history = {}
    local timer_count = 0

    timer({
        interval = check_interval,
        callback = function()
            timer_count = timer_count + check_interval
            local uptime = os.time() - start_time
            
            -- Исправленная логика ротации: убиваем и СРАЗУ создаем новый, 
            -- проверяя успех создания, чтобы количество не уменьшалось.
            local rotation_count = math.ceil(monitor_count * 0.1) -- 10% ротация
            for i = 1, rotation_count do
                local id = math.random(1, monitor_count)
                local name = "SoakV2_" .. id
                
                Channel.kill_stream(name)
                
                local success = Channel.make_stream({
                    name = name,
                    input = { "http://localhost/soak_refresh_" .. timer_count .. "_" .. i },
                    output = { "udp://224.1.4." .. id .. ":1234" }
                })
                
                if not success then
                    print(string.format("CRITICAL: Failed to recreate monitor %s during rotation!", name))
                end
            end

            local current_mem = get_mem()
            table.insert(history, { time = timer_count, mem = current_mem })
            
            print(string.format("[%ds] Uptime: %ds | Memory: %.2f KB | Delta: %.2f KB | Active: %d", 
                timer_count, uptime, current_mem, current_mem - start_mem, ChannelStorage.count()))

            if timer_count >= test_duration then
                print("\n--- FINAL LONG-TERM STABILITY REPORT V2 ---")
                print("Time(s)\tMemory(KB)\tGrowth(KB)")
                local prev_mem = start_mem
                for _, entry in ipairs(history) do
                    local growth = entry.mem - prev_mem
                    print(string.format("%d\t%.2f\t\t%.2f", entry.time, entry.mem, growth))
                    prev_mem = entry.mem
                end

                local final_mem = get_mem()
                print(string.format("\nTotal Uptime: %d seconds", uptime))
                print(string.format("Final Memory Leak Rate: %.4f KB/min", (final_mem - start_mem) / (test_duration / 60)))
                
                if (final_mem - start_mem) < 150 then
                    print("RESULT: EXCELLENT LONG-TERM STABILITY. Memory usage is stable under rotation.")
                else
                    print("RESULT: MEMORY GROWTH DETECTED. Analyze for leaks.")
                end

                print("--- LONG-TERM STABILITY TEST V2 FINISHED ---")
                os.exit(0)
            end
        end
    })
end

run_long_term_test()
