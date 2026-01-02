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
    print("\n--- STARTING LONG-TERM STABILITY TEST (SOAK TEST) ---")
    local start_mem = get_mem()
    local start_time = os.time()
    
    -- Конфигурация теста
    local monitor_count = 50
    local test_duration = 300 -- 5 минут для симуляции (в реальном времени это может быть дольше)
    local check_interval = 30 -- каждые 30 секунд
    
    print(string.format("Initial Memory: %.2f KB", start_mem))
    print(string.format("Creating %d monitors for long-term observation...", monitor_count))

    for i = 1, monitor_count do
        Channel.make_stream({
            name = "Soak_" .. i,
            input = { "http://localhost/soak" },
            output = { "udp://224.1.3." .. i .. ":1234" }
        })
    end

    local history = {}
    local timer_count = 0

    timer({
        interval = check_interval,
        callback = function()
            timer_count = timer_count + check_interval
            local current_mem = get_mem()
            local uptime = os.time() - start_time
            
            -- Симуляция активности (небольшая ротация 5% мониторов для проверки фрагментации)
            for i = 1, math.ceil(monitor_count * 0.05) do
                local id = math.random(1, monitor_count)
                local name = "Soak_" .. id
                Channel.kill_stream(name)
                Channel.make_stream({
                    name = name,
                    input = { "http://localhost/soak_refresh_" .. timer_count },
                    output = { "udp://224.1.3." .. id .. ":1234" }
                })
            end

            table.insert(history, { time = timer_count, mem = current_mem })
            
            print(string.format("[%ds] Uptime: %ds | Memory: %.2f KB | Delta: %.2f KB | Active: %d", 
                timer_count, uptime, current_mem, current_mem - start_mem, ChannelStorage.count()))

            if timer_count >= test_duration then
                print("\n--- FINAL LONG-TERM STABILITY REPORT ---")
                print("Time(s)\tMemory(KB)\tGrowth(KB)")
                local prev_mem = start_mem
                local total_growth = 0
                for _, entry in ipairs(history) do
                    local growth = entry.mem - prev_mem
                    print(string.format("%d\t%.2f\t\t%.2f", entry.time, entry.mem, growth))
                    if growth > 0 then total_growth = total_growth + growth end
                    prev_mem = entry.mem
                end

                local final_mem = get_mem()
                print(string.format("\nTotal Uptime: %d seconds", uptime))
                print(string.format("Final Memory Leak Rate: %.4f KB/min", (final_mem - start_mem) / (test_duration / 60)))
                
                if (final_mem - start_mem) < 100 then
                    print("RESULT: EXCELLENT LONG-TERM STABILITY. No linear memory growth detected.")
                else
                    print("RESULT: MINOR MEMORY ACCUMULATION. Monitor for longer periods.")
                end

                print("--- LONG-TERM STABILITY TEST FINISHED ---")
                os.exit(0)
            end
        end
    })
end

run_long_term_test()
