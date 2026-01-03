-- Тестирование ResourceMonitor V2 (Pull-модель, фильтрация и кэширование)
package.path = package.path .. ";;/opt/astra/lib-monitor/?.lua;;/opt/astra/lib-monitor/src/?.lua;;"

local ModuleManager = require "init_monitor"
local ResourceMonitor = ModuleManager.get_module("resource_monitor")
local Logger = ModuleManager.get_module("logger")
local json_encode = ModuleManager.get_global_dependency("json.encode")

log.set({ debug = true, stdout = true })

print("\n=== START RESOURCE MONITOR V2 TEST (ADVANCED) ===\n")

local function assert_test(condition, message)
    if not condition then
        print("FAILED: " .. message)
    else
        print("PASSED: " .. message)
    end
end

-- 1. Проверка начального состояния
print("--- 1. Initial State ---")
assert_test(ResourceMonitor.is_running() == false, "Monitor is not running by default")

-- 2. Запуск мониторинга
print("\n--- 2. Starting Monitor ---")
ResourceMonitor.start()
assert_test(ResourceMonitor.is_running() == true, "Monitor is running")
local first_report = ResourceMonitor.get_report()
assert_test(first_report ~= nil, "Report is available immediately")
local pid = first_report.pid
assert_test(pid ~= nil, "PID is present: " .. tostring(pid))

-- 3. Проверка расчета CPU и кэширования PID
print("\n--- 3. Testing CPU calculation and PID caching ---")
print("Waiting 2 seconds to accumulate stats...")
local start_time = os.time()
while os.time() - start_time < 2 do
    local x = 0
    for i=1,1000000 do x = x + i end
end

ResourceMonitor.check()
local report = ResourceMonitor.get_report()
assert_test(report.cpu.total > 0, "CPU usage detected: " .. string.format("%.2f%%", report.cpu.total))
assert_test(report.pid == pid, "PID is cached and remains the same")

-- 4. Проверка фильтрации
print("\n--- 4. Testing Filtering ---")

print("Filter: {'cpu'}")
local cpu_only = ResourceMonitor.get_report({"cpu"})
assert_test(cpu_only.cpu ~= nil, "CPU section present")
assert_test(cpu_only.memory == nil, "Memory section absent")
assert_test(cpu_only.pid == pid, "Base field PID still present")

print("Filter: 'memory,system'")
local mem_sys = ResourceMonitor.get_report("memory,system")
assert_test(mem_sys.memory ~= nil, "Memory section present")
assert_test(mem_sys.system ~= nil, "System section present")
assert_test(mem_sys.cpu == nil, "CPU section absent")

-- 5. Остановка мониторинга
print("\n--- 5. Stopping Monitor ---")
ResourceMonitor.stop()
assert_test(ResourceMonitor.is_running() == false, "Monitor stopped")

print("\n=== RESOURCE MONITOR V2 TEST FINISHED ===\n")
os.exit(0)
