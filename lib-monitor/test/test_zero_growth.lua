package.path = package.path .. ";;/opt/astra/lib-monitor/?.lua;;/opt/astra/lib-monitor/src/?.lua;;/opt/astra/lib-monitor/http/?.lua;;/opt/astra/lib-monitor/config/?.lua;;"

local monitor = require "init_monitor"
local Channel = monitor.get_module("channel")
local ChannelStorage = monitor.get_module("channel_storage")

log.set({ debug = false, stdout = false })

local function get_mem()
    collectgarbage("collect")
    collectgarbage("collect")
    collectgarbage("collect")
    return collectgarbage("count")
end

local function run_test()
    print("\n--- STARTING ZERO GROWTH TEST ---")
    
    -- Baseline after some warm-up to stabilize Lua VM and Astra internals
    print("Warming up...")
    for i = 1, 20 do
        local name = "Warmup"
        Channel.make_stream({ name = name, input = {"http://localhost"}, output = {"udp://224.1.1.1:1234"} })
        Channel.kill_stream(name)
    end
    
    local start_mem = get_mem()
    print(string.format("Start Memory: %.2f KB", start_mem))

    local iterations = 500
    local name = "ConstantName"
    local config = {
        name = name,
        input = { "http://localhost/constant" },
        output = { "udp://224.1.1.1:1234" }
    }

    print(string.format("Running %d iterations with constant strings...", iterations))
    for i = 1, iterations do
        Channel.make_stream(config)
        Channel.kill_stream(name)
        
        if i % 100 == 0 then
            print(string.format("Iteration %d, Mem: %.2f KB (Delta: %.2f KB)", i, get_mem(), get_mem() - start_mem))
        end
    end

    local end_mem = get_mem()
    print(string.format("\nEnd Memory: %.2f KB", end_mem))
    print(string.format("Total Memory Delta: %.2f KB", end_mem - start_mem))
    print(string.format("Delta per iteration: %.6f KB", (end_mem - start_mem) / iterations))

    if end_mem - start_mem < 0.5 then
        print("RESULT: PERFECT STABILITY. The 1.5 KB growth in previous tests was likely due to string interning (unique names/URLs).")
    else
        print("RESULT: MEASURABLE GROWTH. There might be a tiny leak in Astra or Library internals.")
    end
    
    print("--- ZERO GROWTH TEST FINISHED ---")
    os.exit(0)
end

run_test()
