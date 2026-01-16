--- @class CpuMetrics
--- @field usage number Суммарное использование CPU (%)
--- @field user number Использование CPU пользователем (%)
--- @field system number Использование CPU системой (%)
--- @field threads number Количество потоков процесса

--- @class MemoryMetrics
--- @field lua number Использование памяти Lua (КБ)
--- @field resident number Резидентная память (RSS, КБ)
--- @field virtual number Виртуальная память (VSZ, КБ)

--- @class NetworkItem
--- @field interface string Имя интерфейса
--- @field ip string IP-адрес

--- @class SystemReport
--- @field pid number Идентификатор процесса
--- @field uptime number Время работы процесса (сек)
--- @field cpu CpuMetrics Метрики процессора
--- @field memory MemoryMetrics Метрики памяти
--- @field network NetworkItem[] Список сетевых интерфейсов

--- @class ResourceMonitor
local ResourceMonitor = {}

-- 1. Стандартные Lua функции
local collectgarbage = collectgarbage
local io_open = io.open
local ipairs = ipairs
local os_clock = os.clock
local os_time = os.time
local pairs = pairs
local table_insert = table.insert
local table_remove = table.remove
local tonumber = tonumber
local type = type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local Scheduler = ModuleManager.get_module("core.scheduler")
local TablePool = ModuleManager.get_module("table_pool")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local utils_ifaddrs = ModuleManager.get_global_dependency("utils.ifaddrs")

-- 4. Константы и конфигурации
local PROC_STAT = "/proc/self/stat"
local PROC_STATUS = "/proc/self/status"
local TICK_RATE = 100 -- Стандарт для Linux (USER_HZ)

-- 5. Инициализация объектов и внутреннего состояния
local log = Logger and Logger.new("resource-monitor")
ResourceMonitor._start_time = os_time()
ResourceMonitor._last_clock = 0
ResourceMonitor._last_utime = 0
ResourceMonitor._last_stime = 0
ResourceMonitor._pid = nil
ResourceMonitor._report = nil
ResourceMonitor._cpu_buffer = {} -- Кольцевой буфер для Moving Average

-- Инициализация PID при загрузке
local f_pid = io_open(PROC_STAT, "r")
if f_pid then
    local content = f_pid:read(64)
    if content then
        ResourceMonitor._pid = tonumber(content:match("^(%d+)"))
    end
    f_pid:close()
end

-- 6. Приватные функции

--- Парсит /proc/self/status с ранним выходом
--- @return table|nil
local function _parse_status()
    local f = io_open(PROC_STATUS, "r")
    if not f then return nil end

    local status = {}
    local found = 0
    for line in f:lines() do
        local key, val = line:match("^(%w+):%s+(%d+)")
        if key == "VmRSS" then
            status.resident = tonumber(val) or 0
            found = found + 1
        elseif key == "VmSize" then
            status.virtual = tonumber(val) or 0
            found = found + 1
        elseif key == "Threads" then
            status.threads = tonumber(val) or 0
            found = found + 1
        end
        -- Ранний выход, если все 3 поля найдены
        if found >= 3 then break end
    end
    f:close()
    return status
end

--- Парсит /proc/self/stat для получения тиков CPU
--- @return number, number
local function _parse_stat()
    local f = io_open(PROC_STAT, "r")
    if not f then return 0, 0 end

    local content = f:read("*a")
    f:close()
    if not content then return 0, 0 end

    local utime, stime = 0, 0
    local count = 0
    for val in content:gmatch("[^%s]+") do
        count = count + 1
        if count == 14 then
            utime = tonumber(val) or 0
        elseif count == 15 then
            stime = tonumber(val) or 0
            break
        end
    end
    return utime, stime
end

--- Рассчитывает среднее значение CPU из буфера
--- @param val number Новое значение
--- @return number
local function _moving_average(val)
    local window = (MonitorConfig and MonitorConfig.CpuMovingAverageWindow) or 0
    if window <= 1 then return val end

    table_insert(ResourceMonitor._cpu_buffer, val)
    while #ResourceMonitor._cpu_buffer > window do
        table_remove(ResourceMonitor._cpu_buffer, 1)
    end

    local sum = 0
    for _, v in ipairs(ResourceMonitor._cpu_buffer) do
        sum = sum + v
    end
    return sum / #ResourceMonitor._cpu_buffer
end

-- 7. Публичный API

--- Собирает актуальные метрики системы
--- @return SystemReport|nil
function ResourceMonitor.check()
    local now_clock = os_clock()
    local utime, stime = _parse_stat()
    local status = _parse_status() or {}

    -- Освобождение старого отчета в пул
    if ResourceMonitor._report and TablePool then
        TablePool.release(ResourceMonitor._report, "report_sys", true)
    end

    -- Получение нового отчета из пула
    local report = TablePool and TablePool.get("report_sys") or {}
    report.pid = ResourceMonitor._pid
    report.uptime = os_time() - ResourceMonitor._start_time

    -- Метрики CPU
    report.cpu = report.cpu or (TablePool and TablePool.get("sys_cpu") or {})
    report.cpu.threads = status.threads or 0
    report.cpu.user = 0
    report.cpu.system = 0
    report.cpu.usage = 0

    if ResourceMonitor._last_clock > 0 then
        local delta_clock = now_clock - ResourceMonitor._last_clock
        if delta_clock > 0 then
            local u_usage = ((utime - ResourceMonitor._last_utime) / TICK_RATE / delta_clock) * 100
            local s_usage = ((stime - ResourceMonitor._last_stime) / TICK_RATE / delta_clock) * 100
            
            report.cpu.user = u_usage
            report.cpu.system = s_usage
            report.cpu.usage = _moving_average(u_usage + s_usage)
        end
    end

    ResourceMonitor._last_clock = now_clock
    ResourceMonitor._last_utime = utime
    ResourceMonitor._last_stime = stime

    -- Метрики памяти
    report.memory = report.memory or (TablePool and TablePool.get("sys_mem") or {})
    report.memory.lua = collectgarbage("count")
    report.memory.resident = status.resident or 0
    report.memory.virtual = status.virtual or 0

    -- Метрики сети
    report.network = report.network or (TablePool and TablePool.get("sys_net") or {})
    if utils_ifaddrs and type(utils_ifaddrs) == "function" then
        local interfaces = utils_ifaddrs()
        for name, addrs in pairs(interfaces) do
            if addrs.ipv4 and addrs.ipv4[1] then
                local item = TablePool and TablePool.get("sys_net_item") or {}
                item.interface = name
                item.ip = addrs.ipv4[1]
                table_insert(report.network, item)
            end
        end
    end

    ResourceMonitor._report = report
    return report
end

--- Возвращает последний собранный отчет
--- @return SystemReport|nil
function ResourceMonitor.get_report()
    if not ResourceMonitor._report then
        return ResourceMonitor.check()
    end
    return ResourceMonitor._report
end

--- Запускает периодический мониторинг
--- @param interval number|nil Интервал в секундах
function ResourceMonitor.start(interval)
    local scheduler = Scheduler and Scheduler.get_instance()
    if not scheduler then
        if log then log:error("ResourceMonitor", "Scheduler not available") end
        return
    end

    local run_interval = interval or (MonitorConfig and MonitorConfig.SchedulerInterval) or 1
    scheduler:add_task("resource_monitor", function()
        ResourceMonitor.check()
    end, run_interval)
end

--- Останавливает периодический мониторинг
function ResourceMonitor.stop()
    local scheduler = Scheduler and Scheduler.get_instance()
    if scheduler then
        scheduler:remove_task("resource_monitor")
    end
end

--- Проверяет, запущен ли мониторинг (заглушка для совместимости)
--- @return boolean
function ResourceMonitor.is_running()
    return true
end

-- Регистрация типов в TablePool
if TablePool then
    TablePool.register_type("report_sys", { "pid", "uptime", "cpu", "memory", "network" }, 10, 2)
    TablePool.register_type("sys_cpu", { "usage", "user", "system", "threads" }, 10, 2)
    TablePool.register_type("sys_mem", { "lua", "resident", "virtual" }, 10, 2)
    TablePool.register_type("sys_net", nil, 10, 2)
    TablePool.register_type("sys_net_item", { "interface", "ip" }, 20, 5)
end

-- Автоматический запуск при загрузке
ResourceMonitor.start()

return ResourceMonitor
