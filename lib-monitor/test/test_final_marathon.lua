package.path = package.path .. ";;/opt/astra/lib-monitor/?.lua;;/opt/astra/lib-monitor/src/?.lua;;/opt/astra/lib-monitor/http/?.lua;;/opt/astra/lib-monitor/config/?.lua;;"

-- 1. Стандартные Lua функции
local collectgarbage = collectgarbage
local os = os
local print = print
local string = string
local math = math
local setmetatable = setmetatable

-- 2. Функции из ModuleManager.get_module()
local monitor = require "init_monitor"
local Channel = monitor.get_module("channel")
local ChannelStorage = monitor.get_module("channel_storage")
local Logger = monitor.get_module("logger")

-- Отключаем логи для чистоты вывода, оставляем только критические
log.set({ debug = false, stdout = true })

-- Слабая таблица для отслеживания объектов в памяти
local object_tracker = setmetatable({}, { __mode = "v" })
local tracker_index = 0

local function track_object(obj)
    tracker_index = tracker_index + 1
    object_tracker[tracker_index] = obj
end

local function get_live_objects_count()
    collectgarbage("collect")
    collectgarbage("collect")
    local count = 0
    for _ in pairs(object_tracker) do
        count = count + 1
    end
    return count
end

local function get_mem()
    collectgarbage("collect")
    collectgarbage("collect")
    return collectgarbage("count")
end

local function run_marathon()
    print("\n--- STARTING FINAL MARATHON STABILITY TEST (10 MIN) ---")
    local start_mem = get_mem()
    local start_time = os.time()
    
    local monitor_count = 30
    local test_duration = 600 -- 10 минут
    local check_interval = 60 -- каждую минуту
    local rotation_per_step = 10 -- 10 замен в минуту
    
    print(string.format("Initial Memory: %.2f KB", start_mem))
    
    -- Перехватываем создание мониторов для трекинга
    local original_new = monitor.get_module("channel_monitor").new
    monitor.get_module("channel_monitor").new = function(...)
        local obj = original_new(...)
        if obj then track_object(obj) end
        return obj
    end

    print(string.format("Initializing %d monitors...", monitor_count))
    for i = 1, monitor_count do
        Channel.make_stream({
            name = "Marathon_" .. i .. "_v1",
            input = { "http://localhost/marathon" },
            output = { "udp://224.1.6." .. i .. ":1234" }
        })
    end

    local history = {}
    local timer_count = 0
    local version_map = {}
    for i = 1, monitor_count do version_map[i] = 1 end

    timer({
        interval = check_interval,
        callback = function()
            timer_count = timer_count + check_interval
            local uptime = os.time() - start_time
            
            -- Интенсивная ротация
            for _ = 1, rotation_per_step do
                local id = math.random(1, monitor_count)
                local old_name = string.format("Marathon_%d_v%d", id, version_map[id])
                Channel.kill_stream(old_name)
                
                version_map[id] = version_map[id] + 1
                local new_name = string.format("Marathon_%d_v%d", id, version_map[id])
                Channel.make_stream({
                    name = new_name,
                    input = { "http://localhost/marathon_rot_" .. uptime },
                    output = { "udp://224.1.6." .. id .. ":1234" }
                })
            end

            local current_mem = get_mem()
            local live_objects = get_live_objects_count()
            local active_monitors = ChannelStorage.count()
            
            table.insert(history, { 
                time = timer_count, 
                mem = current_mem, 
                live = live_objects,
                active = active_monitors
            })
            
            print(string.format("[%dm] Mem: %.2f KB | Live Objs: %d | Active: %d", 
                timer_count/60, current_mem, live_objects, active_monitors))

            if timer_count >= test_duration then
                print("\n--- FINAL MARATHON REPORT ---")
                print("Min\tActive\tLive\tMemory(KB)\tGrowth(KB)")
                local prev_mem = start_mem
                for _, entry in ipairs(history) do
                    print(string.format("%d\t%d\t%d\t%.2f\t\t%.2f", 
                        entry.time/60, entry.active, entry.live, entry.mem, entry.mem - prev_mem))
                    prev_mem = entry.mem
                end

                local final_mem = get_mem()
                print(string.format("\nTotal Memory Delta: %.2f KB", final_mem - start_mem))
                print(string.format("Objects in memory: %d (Expected around %d)", live_objects, active_monitors))
                
                if live_objects > active_monitors + 5 then
                    print("WARNING: Some ChannelMonitor objects are not being GC'ed!")
                else
                    print("SUCCESS: Object lifecycle is correctly managed.")
                end

                if (final_mem - start_mem) < 200 then
                    print("RESULT: MARATHON PASSED. System is rock solid.")
                else
                    print("RESULT: MARATHON FINISHED. Slight memory growth observed.")
                end

                print("--- MARATHON TEST FINISHED ---")
                os.exit(0)
            end
        end
    })
end

run_marathon()
