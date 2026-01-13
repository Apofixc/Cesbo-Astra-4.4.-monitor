--- @class ResourceMonitor
local ResourceMonitor = {}

-- 1. Стандартные Lua функции
local os_time = _G.os.time
local tonumber = _G.tonumber
local io_open = _G.io.open
local collectgarbage = _G.collectgarbage
local pairs = _G.pairs

-- 2. Глобальные зависимости Astra
local utils_ifaddrs = ModuleManager.get_global_dependency("utils.ifaddrs")
local Scheduler = ModuleManager.get_module("core.scheduler")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local TablePool = ModuleManager.get_module("table_pool")

-- Внутреннее состояние
ResourceMonitor._pid = nil
ResourceMonitor._start_time = os_time()
ResourceMonitor._last_utime = 0
ResourceMonitor._last_stime = 0
ResourceMonitor._last_cpu_check = 0
ResourceMonitor._report = {}

-- Кэширование путей
local PROC_STAT = "/proc/self/stat"
local PROC_STATUS = "/proc/self/status"

-- Инициализация PID
local f = io_open(PROC_STAT, "r")
if f then
    local content = f:read(64) -- PID всегда в начале
    if content then ResourceMonitor._pid = content:match("^(%d+)") end
    f:close()
end

--- Собирает актуальные метрики процесса
--- @return table
function ResourceMonitor.check()
    local now = os_time()

    -- Чтение /proc/self/status
    local status = {}
    local f_status = io_open(PROC_STATUS, "r")
    if f_status then
        -- Оптимизированное чтение: ищем только нужные поля
        for line in f_status:lines() do
            local key, val = line:match("^(%w+):%s+(.+)$")
            if key == "VmRSS" or key == "VmSize" or key == "Threads" then
                status[key] = val
            end
        end
        f_status:close()
    end

    -- Чтение /proc/self/stat для CPU
    local utime, stime = 0, 0
    local f_stat = io_open(PROC_STAT, "r")
    if f_stat then
        local content = f_stat:read("*a")
        f_stat:close()

        -- Оптимизированный парсинг: utime и stime - это 14-й и 15-й параметры
        local count = 0
        for val in content:gmatch("[^%s]+") do
            count = count + 1
            if count == 14 then utime = tonumber(val) or 0
            elseif count == 15 then
                stime = tonumber(val) or 0
                break -- Дальше парсить не нужно
            end
        end
    end

    -- Используем пул для отчета
    if ResourceMonitor._report and TablePool then
        -- Используем стандартный механизм вложенного высвобождения
        TablePool.release(ResourceMonitor._report, "report_sys", "sys_nested")
    end

    local report = TablePool and TablePool.get("report_sys") or {}
    report.pid = tonumber(ResourceMonitor._pid)
    report.uptime = now - ResourceMonitor._start_time
    
    -- Вложенные таблицы переиспользуются или берутся из пула
    report.cpu = report.cpu or (TablePool and TablePool.get("sys_cpu") or {})
    report.cpu.usage = 0
    report.cpu.user = 0
    report.cpu.system = 0
    report.cpu.threads = tonumber(status.Threads) or 0

    report.memory = report.memory or (TablePool and TablePool.get("sys_mem") or {})
    report.memory.lua = collectgarbage("count")
    report.memory.resident = tonumber(status.VmRSS and status.VmRSS:match("%d+")) or 0
    report.memory.virtual = tonumber(status.VmSize and status.VmSize:match("%d+")) or 0

    report.network = report.network or (TablePool and TablePool.get("sys_net") or {})

    -- Расчет CPU (на основе 100 тиков в секунду)
    if ResourceMonitor._last_cpu_check > 0 then
        local delta_time = now - ResourceMonitor._last_cpu_check
        if delta_time > 0 then
            report.cpu.user = ((utime - ResourceMonitor._last_utime) / 100 / delta_time) * 100
            report.cpu.system = ((stime - ResourceMonitor._last_stime) / 100 / delta_time) * 100
            report.cpu.usage = report.cpu.user + report.cpu.system
        end
    end

    ResourceMonitor._last_utime = utime
    ResourceMonitor._last_stime = stime
    ResourceMonitor._last_cpu_check = now

    -- Сетевые интерфейсы
    if utils_ifaddrs and type(utils_ifaddrs) == "function" then
        for name, addrs in pairs(utils_ifaddrs()) do
            if addrs.ipv4 and addrs.ipv4[1] then
                local item = TablePool and TablePool.get("sys_net_item") or {}
                item.interface = name
                item.ip = addrs.ipv4[1]
                table.insert(report.network, item)
            end
        end
    end

    ResourceMonitor._report = report
    return report
end

--- Возвращает последний отчет
--- @return table
function ResourceMonitor.get_report()
    return ResourceMonitor.check()
end

--- Запускает периодический мониторинг ресурсов через планировщик
function ResourceMonitor.start()
    local scheduler = Scheduler.get_instance()
    local interval = (MonitorConfig and MonitorConfig.SchedulerInterval) or 1

    scheduler:add_task("resource_monitor", function()
        ResourceMonitor.check()
    end, interval)
end

--- Останавливает мониторинг ресурсов
function ResourceMonitor.stop()
    local scheduler = Scheduler.get_instance()
    scheduler:remove_task("resource_monitor")
end

--- Заглушка для совместимости
--- @return boolean
function ResourceMonitor.is_running()
    return true
end

-- Регистрация пулов при загрузке модуля
if TablePool then
    TablePool.register_type("report_sys", function(t, nested_type)
        t.pid = nil
        t.uptime = nil
        t.server = nil
        
        if nested_type == "sys_nested" then
            -- Глубокая очистка с возвратом вложенных таблиц в их пулы
            if t.cpu then TablePool.release(t.cpu, "sys_cpu") end
            if t.memory then TablePool.release(t.memory, "sys_mem") end
            if t.network then TablePool.release(t.network, "sys_net", "sys_net_item") end
            t.cpu = nil
            t.memory = nil
            t.network = nil
        else
            -- Поверхностная очистка для переиспользования структуры (быстрый путь)
            if t.cpu then
                t.cpu.usage = nil
                t.cpu.user = nil
                t.cpu.system = nil
                t.cpu.threads = nil
            end
            if t.memory then
                t.memory.lua = nil
                t.memory.resident = nil
                t.memory.virtual = nil
            end
            if t.network then
                for i = 1, #t.network do
                    TablePool.release(t.network[i], "sys_net_item")
                    t.network[i] = nil
                end
            end
        end
    end)

    TablePool.register_type("sys_cpu", function(t)
        t.usage = nil
        t.user = nil
        t.system = nil
        t.threads = nil
    end)

    TablePool.register_type("sys_mem", function(t)
        t.lua = nil
        t.resident = nil
        t.virtual = nil
    end)

    TablePool.register_type("sys_net", function(t, nested_type)
        for i = 1, #t do
            if nested_type == "sys_net_item" then
                TablePool.release(t[i], "sys_net_item")
            end
            t[i] = nil
        end
    end)

    TablePool.register_type("sys_net_item", function(t)
        t.interface = nil
        t.ip = nil
    end)
end

-- Автоматический запуск при загрузке модуля
ResourceMonitor.start()

return ResourceMonitor
