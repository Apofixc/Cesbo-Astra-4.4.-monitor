-- Тестирование ResourceMonitor
package.path = package.path .. ";;/opt/astra/lib-monitor/?.lua;;/opt/astra/lib-monitor/src/?.lua;;"

local ModuleManager = require "init_monitor"
local ResourceMonitor = ModuleManager.get_module("resource_monitor")
local Logger = ModuleManager.get_module("logger")
local timer = ModuleManager.get_global_dependency("timer")

log.set({ debug = true, stdout = true })

print("\n=== START RESOURCE MONITOR TEST ===\n")

local function assert_test(condition, message)
    if not condition then
        print("FAILED: " .. message)
    else
        print("PASSED: " .. message)
    end
end

-- 1. Проверка инициализации
print("--- 1. Testing Initialization ---")
ResourceMonitor.init()
assert_test(ResourceMonitor._timer ~= nil, "ResourceMonitor timer created")

-- 2. Проверка ручного запуска сбора данных
print("\n--- 2. Testing Manual Check ---")
-- Подменяем HttpSubscriber.publish чтобы увидеть данные в логе
local HttpSubscriber = ModuleManager.get_module("http_subscriber")
if HttpSubscriber then
    local original_publish = HttpSubscriber.publish
    HttpSubscriber.publish = function(topic, data)
        print("Published to " .. topic .. ": " .. data)
    end
end

-- Первый запуск (инициализация дельт)
ResourceMonitor.check()
print("First check done (baseline)")

-- Небольшая пауза для появления дельты CPU
local start_time = os.time()
while os.time() - start_time < 2 do
    -- busy loop to consume some CPU
    local x = 0
    for i=1,1000000 do x = x + i end
end

-- Второй запуск (расчет метрик)
print("Second check (with data):")
ResourceMonitor.check()

-- 3. Проверка остановки
print("\n--- 3. Testing Stop ---")
ResourceMonitor.stop()
assert_test(ResourceMonitor._timer == nil, "ResourceMonitor timer cleared")

print("\n=== RESOURCE MONITOR TEST FINISHED ===\n")
os.exit(0)
