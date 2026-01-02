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

-- Включаем логирование ошибок
log.set({ debug = false, stdout = true })

local function get_mem()
    collectgarbage("collect")
    collectgarbage("collect") -- Двойной вызов для более точного замера
    return collectgarbage("count")
end

local function run_long_term_test()
    print("\n--- STARTING LONG-TERM STABILITY TEST V3 (FIXED ROTATION) ---")
    local start_mem = get_mem()
    local start_time = os.time()
    
    local monitor_count = 40
    local test_duration = 300 -- 5 минут
    local check_interval = 30
    local version_counter = {} -- Счетчики версий для уникальности имен
    
    print(string.format("Initial Memory: %.2f KB", start_mem))
    print(string.format("Creating %d monitors...", monitor_count))

    for i = 1, monitor_count do
        version_counter[i] = 1
        local name = string.format("SoakV3_%d_v%d", i, version_counter[i])
        Channel.make_stream({
            name = name,
            input = { "http://localhost/soak" },
            output = { "udp://224.1.5." .. i .. ":1234" }
        })
    end

    local history = {}
    local timer_count = 0

    timer({
        interval = check_interval,
        callback = function()
            timer_count = timer_count + check_interval
            local uptime = os.time() - start_time
            
            -- Ротация с использованием уникальных имен для исключения конфликтов Astra
            local rotation_count = 5
            for _ = 1, rotation_count do
                local id = math.random(1, monitor_count)
                local old_name = string.format("SoakV3_%d_v%d", id, version_counter[id])
                
                Channel.kill_stream(old_name)
                
                version_counter[id] = version_counter[id] + 1
                local new_name = string.format("SoakV3_%d_v%d", id, version_counter[id])
                
                Channel.make_stream({
                    name = new_name,
                    input = { "http://localhost/soak_refresh_" .. uptime },
                    output = { "udp://224.1.5." .. id .. ":1234" }
                })
            end

            local current_mem = get_mem()
            local active_count = ChannelStorage.count()
            table.insert(history, { time = timer_count, mem = current_mem, active = active_count })
            
            print(string.format("[%ds] Memory: %.2f KB | Delta: %.2f KB | Active: %d", 
                timer_count, current_mem, current_mem - start_mem, active_count))

            if timer_count >= test_duration then
                print("\n--- FINAL LONG-TERM STABILITY REPORT V3 ---")
                print("Time(s)\tActive\tMemory(KB)\tGrowth(KB)")
                local prev_mem = start_mem
                for _, entry in ipairs(history) do
                    print(string.format("%d\t%d\t%.2f\t\t%.2f", entry.time, entry.active, entry.mem, entry.mem - prev_mem))
                    prev_mem = entry.mem
                end

                local final_mem = get_mem()
                print(string.format("\nTotal Memory Delta: %.2f KB", final_mem - start_mem))
                print(string.format("Leak Rate: %.4f KB/rotation", (final_mem - start_mem) / (timer_count / check_interval * rotation_count)))
                
                if (final_mem - start_mem) < 100 then
                    print("RESULT: STABLE. Memory usage is under control.")
                else
                    print("RESULT: POTENTIAL LEAK. Memory increased significantly.")
                end

                print("--- LONG-TERM STABILITY TEST V3 FINISHED ---")
                os.exit(0)
            end
        end
    })
end

run_long_term_test()
