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

-- Отключаем лишний вывод для чистоты замера
log.set({ debug = false, stdout = false })

local function get_mem()
    collectgarbage("collect")
    return collectgarbage("count")
end

local function run_test()
    print("\n--- STARTING RESOURCE USAGE TEST ---")
    
    local start_mem = get_mem()
    local start_clock = os.clock()
    
    print(string.format("Baseline Memory: %.2f KB", start_mem))

    local counts = {10, 50, 100}
    local results = {}

    for _, count in ipairs(counts) do
        print(string.format("\nTesting with %d monitors...", count))
        
        local step_start_mem = get_mem()
        local step_start_clock = os.clock()
        
        local created = 0
        for i = 1, count do
            local name = "Test_" .. count .. "_" .. i
            local success = Channel.make_stream({
                name = name,
                input = { "http://localhost/test" },
                output = { "udp://224.1.1." .. i .. ":1234" }
            })
            if success then created = created + 1 end
        end
        
        local step_end_clock = os.clock()
        local step_end_mem = get_mem()
        
        results[count] = {
            created = created,
            mem_delta = step_end_mem - step_start_mem,
            cpu_time = step_end_clock - step_start_clock
        }
        
        print(string.format("Created: %d", created))
        print(string.format("Memory Delta: %.2f KB (Avg: %.2f KB/mon)", results[count].mem_delta, results[count].mem_delta / created))
        print(string.format("CPU Time: %.4f sec (Avg: %.4f sec/mon)", results[count].cpu_time, results[count].cpu_time / created))
        
        -- Cleanup for next step
        for i = 1, count do
            Channel.kill_stream("Test_" .. count .. "_" .. i)
        end
        
        local after_cleanup_mem = get_mem()
        print(string.format("Memory after cleanup: %.2f KB (Leaked: %.2f KB)", after_cleanup_mem, after_cleanup_mem - step_start_mem))
    end

    print("\n--- FINAL REPORT ---")
    print("Count\tMem Delta (KB)\tAvg Mem (KB)\tCPU Time (s)\tAvg CPU (s)")
    for _, count in ipairs(counts) do
        local r = results[count]
        print(string.format("%d\t%.2f\t\t%.2f\t\t%.4f\t\t%.4f", 
            count, r.mem_delta, r.mem_delta / r.created, r.cpu_time, r.cpu_time / r.created))
    end

    local final_mem = get_mem()
    print(string.format("\nTotal Memory Leak: %.2f KB", final_mem - start_mem))
    print("--- RESOURCE USAGE TEST FINISHED ---")
    os.exit(0)
end

run_test()
