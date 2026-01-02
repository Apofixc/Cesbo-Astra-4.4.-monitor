package.path = package.path .. ";;/opt/astra/lib-monitor/?.lua;;/opt/astra/lib-monitor/src/?.lua;;/opt/astra/lib-monitor/http/?.lua;;/opt/astra/lib-monitor/config/?.lua;;"

-- 1. Стандартные Lua функции
local collectgarbage = collectgarbage
local os = os
local print = print
local string = string

-- 2. Функции из ModuleManager.get_module()
local monitor = require "init_monitor"
local Channel = monitor.get_module("channel")

-- Отключаем лишний вывод
log.set({ debug = false, stdout = false })

local function get_mem()
    collectgarbage("collect")
    collectgarbage("collect")
    collectgarbage("collect")
    return collectgarbage("count")
end

local function run_tv3_test()
    print("\n--- STARTING TV3 LIFECYCLE TEST ---")
    
    local stream_conf = {
        name = "TV3_Test",
        input = { "http://31.130.202.110/httpts/tv3by/avchigh.ts" },
        output = { "udp://224.100.100.119:1234#sync" }
    }

    local iterations = 50
    local results = {}

    for i = 1, iterations do
        print(string.format("\nIteration %d:", i))
        
        local mem_before = get_mem()
        print(string.format("  Memory before creation: %.2f KB", mem_before))
        
        local success = Channel.make_stream(stream_conf)
        if not success then
            print("  FAILED to create stream")
            break
        end
        
        local mem_after_create = get_mem()
        print(string.format("  Memory after creation:  %.2f KB (Delta: +%.2f KB)", mem_after_create, mem_after_create - mem_before))
        
        Channel.kill_stream("TV3_Test")
        
        local mem_after_kill = get_mem()
        print(string.format("  Memory after deletion:  %.2f KB (Residual: %.2f KB)", mem_after_kill, mem_after_kill - mem_before))
        
        table.insert(results, {
            before = mem_before,
            after_create = mem_after_create,
            after_kill = mem_after_kill
        })
    end

    print("\n--- SUMMARY REPORT ---")
    print("Iter\tBefore\tCreated\tDeleted\tResidual")
    for i, r in ipairs(results) do
        print(string.format("%d\t%.2f\t%.2f\t%.2f\t%.2f", 
            i, r.before, r.after_create, r.after_kill, r.after_kill - r.before))
    end

    print("--- TV3 LIFECYCLE TEST FINISHED ---")
    os.exit(0)
end

run_tv3_test()
