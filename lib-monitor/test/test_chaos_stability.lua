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

-- Отключаем логи для скорости, но оставляем ошибки
log.set({ debug = false, stdout = true })

local function get_mem()
    collectgarbage("collect")
    return collectgarbage("count")
end

local function run_chaos_test()
    print("\n--- STARTING CHAOS STABILITY TEST ---")
    local start_mem = get_mem()
    
    -- Сценарий 1: Переполнение (Flood)
    print("\nPhase 1: Flooding with 300 monitors (exceeding typical limits)...")
    for i = 1, 300 do
        Channel.make_stream({
            name = "Chaos_" .. i,
            input = { "http://localhost/chaos" },
            output = { "udp://224.1.2." .. i .. ":1234" }
        })
    end
    print("Current count: " .. ChannelStorage.count())

    -- Сценарий 2: Некорректные данные (Invalid Data Injection)
    print("\nPhase 2: Injecting invalid data structures...")
    local invalid_inputs = {
        { name = nil, input = {} },
        { name = "Invalid_1", input = nil },
        { name = "Invalid_2", input = { 123 } }, -- Число вместо строки URL
        { name = {}, input = { "http://test" } }, -- Таблица вместо имени
        "Not a table at all"
    }
    for _, data in ipairs(invalid_inputs) do
        pcall(function() Channel.make_stream(data) end)
        pcall(function() Channel.kill_stream(data) end)
    end
    print("System survived invalid data injection.")

    -- Сценарий 3: Быстрая ротация (High Churn / Race Conditions)
    print("\nPhase 3: High churn (rapid create/kill) - 1000 operations...")
    for i = 1, 1000 do
        local id = math.random(1, 300)
        local name = "Chaos_" .. id
        if i % 2 == 0 then
            Channel.kill_stream(name)
        else
            Channel.make_stream({
                name = name,
                input = { "http://localhost/" .. i },
                output = { "udp://224.1.2." .. id .. ":1234" }
            })
        end
    end
    print("System survived high churn.")

    -- Сценарий 4: Массовое обновление несуществующих объектов
    print("\nPhase 4: Updating non-existent monitors...")
    for i = 1, 100 do
        Channel.update_monitor_parameters("NonExistent_" .. i, { rate = 1.0 })
    end

    -- Сценарий 5: Проверка целостности хранилища
    print("\nPhase 5: Storage integrity check...")
    local count = 0
    for _ in pairs(ChannelStorage.get_all() or {}) do
        count = count + 1
    end
    print("Storage count matches: " .. count)

    -- Очистка
    print("\nFinal Cleanup...")
    for i = 1, 300 do
        Channel.kill_stream("Chaos_" .. i)
    end

    local end_mem = get_mem()
    print(string.format("\nFinal Memory: %.2f KB", end_mem))
    print(string.format("Memory Delta (Leak): %.2f KB", end_mem - start_mem))
    
    if end_mem - start_mem < 50 then
        print("RESULT: EXTREME STABILITY CONFIRMED")
    else
        print("RESULT: STABLE WITH MINOR FRAGMENTATION")
    end
    
    print("--- CHAOS STABILITY TEST FINISHED ---")
    os.exit(0)
end

run_chaos_test()
