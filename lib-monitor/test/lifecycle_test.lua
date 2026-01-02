-- Тест жизненного цикла мониторов для проверки корректной очистки ресурсов
-- Запуск: /opt/astra/astra4.4.182 /opt/astra/lib-monitor/test/lifecycle_test.lua

-- Эмуляция окружения Astra
if not _G.astra then
    _G.astra = { version = "4.4.182" }
    _G.log = {
        info = function(_, msg) print("INFO: " .. msg) end,
        error = function(_, msg) print("ERROR: " .. msg) end,
        debug = function(_, msg) print("DEBUG: " .. msg) end,
    }
    _G.analyze = function() return { callback = nil } end
    _G.kill_input = function() end
    _G.init_input = function() return { tail = {} } end
    _G.find_channel = function() return nil end
    _G.parse_url = function() return {} end
    _G.timer = function() end
    _G.dvb_tune = function() return { __options = { channels = 0 } } end
    _G.json = { encode = function() return "{}" end, decode = function() return {} end }
end

-- Загрузка ModuleManager и инициализация библиотеки
package.path = package.path .. ";/opt/astra/lib-monitor/?.lua;/opt/astra/lib-monitor/src/?.lua"
local ModuleManager = require "init_monitor"

local function get_mem()
    collectgarbage("collect")
    return collectgarbage("count")
end

local function test_lifecycle()
    local Channel = ModuleManager.get_module("channel")
    
    print("--- Starting Lifecycle Test ---")
    local initial_mem = get_mem()
    print(string.format("Initial memory: %.2f KB", initial_mem))

    for i = 1, 10 do
        print(string.format("\nIteration %d", i))
        
        local config = {
            name = "test_channel_" .. i,
            monitor = "udp://239.0.0.1:1234",
            upstream = {
                stream = function() return {
                    stream = function() return {} end
                } end
            }
        }
        
        local monitor_instance = Channel.make_monitor(config, { name = config.name })
        if monitor_instance then
            print("Monitor created")
            Channel.kill_monitor(config.name)
            print("Monitor killed")
        else
            print("Failed to create monitor")
        end

        local current_mem = get_mem()
        print(string.format("Memory after iteration: %.2f KB (diff: %.2f KB)", current_mem, current_mem - initial_mem))
    end

    local final_mem = get_mem()
    print("\n--- Test Finished ---")
    print(string.format("Final memory: %.2f KB", final_mem))
    print(string.format("Total memory diff: %.2f KB", final_mem - initial_mem))
    
    if (final_mem - initial_mem) > 100 then
        print("WARNING: Possible memory leak detected!")
    else
        print("Memory usage is stable.")
    end
end

test_lifecycle()

if _G.astra then
    os.exit(0)
end
