-- ===========================================================================
-- Модуль `system.resource_monitor`
--
-- Высокопроизводительный мониторинг системных ресурсов процесса Astra.
-- Сбор метрик CPU, RAM, потоков и сетевых интерфейсов из /proc.
-- ===========================================================================

-- 1. Стандартные Lua функции
local collectgarbage = _G.collectgarbage
local io_open = _G.io.open
local ipairs = _G.ipairs
local os_clock = _G.os.clock
local os_time = _G.os.time
local pairs = _G.pairs
local table_insert = _G.table.insert
local table_remove = _G.table.remove
local tonumber = _G.tonumber
local type = _G.type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local Scheduler = ModuleManager.get_module("core.scheduler")
local TablePool = ModuleManager.get_module("table_pool")

-- 3. Глобальные зависимости Astra
local utils_ifaddrs = ModuleManager.get_global_dependency("utils.ifaddrs")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ResourceMonitor"
local PROC_STAT = "/proc/self/stat"
local PROC_STATUS = "/proc/self/status"
local TICK_RATE = 100 -- Стандарт для Linux (USER_HZ)

-- 5. Внутреннее состояние (Private State)
local state = {
    log = nil,
    start_time = os_time(),
    last_clock = 0,
    last_utime = 0,
    last_stime = 0,
    pid = nil,
    report = nil,
    cpu_buffer = {} -- Кольцевой буфер для Moving Average
}

-- ===========================================================================
-- Внутренние функции (Private)
-- ===========================================================================

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

    table_insert(state.cpu_buffer, val)
    while #state.cpu_buffer > window do
        table_remove(state.cpu_buffer, 1)
    end

    local sum = 0
    for _, v in ipairs(state.cpu_buffer) do
        sum = sum + v
    end
    return sum / #state.cpu_buffer
end

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

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

--- Собирает актуальные метрики системы
--- @return SystemReport|nil
function ResourceMonitor.check()
    local now_clock = os_clock()
    local utime, stime = _parse_stat()
    local status = _parse_status() or {}

    -- Освобождение старого отчета в пул
    if state.report and TablePool then
        TablePool.release(state.report, "report_sys", true)
    end

    -- Получение нового отчета из пула
    local report = TablePool and TablePool.get("report_sys") or {}
    report.pid = state.pid
    report.uptime = os_time() - state.start_time

    -- Метрики CPU
    report.cpu = report.cpu or (TablePool and TablePool.get("sys_cpu") or {})
    report.cpu.threads = status.threads or 0
    report.cpu.user = 0
    report.cpu.system = 0
    report.cpu.usage = 0

    if state.last_clock > 0 then
        local delta_clock = now_clock - state.last_clock
        if delta_clock > 0 then
            local u_usage = ((utime - state.last_utime) / TICK_RATE / delta_clock) * 100
            local s_usage = ((stime - state.last_stime) / TICK_RATE / delta_clock) * 100
            
            report.cpu.user = u_usage
            report.cpu.system = s_usage
            report.cpu.usage = _moving_average(u_usage + s_usage)
        end
    end

    state.last_clock = now_clock
    state.last_utime = utime
    state.last_stime = stime

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

    state.report = report
    return report
end

--- Возвращает последний собранный отчет
--- @return SystemReport|nil
function ResourceMonitor.get_report()
    if not state.report then
        return ResourceMonitor.check()
    end
    return state.report
end

--- Запускает периодический мониторинг
--- @param interval number|nil Интервал в секундах
function ResourceMonitor.start(interval)
    local scheduler = Scheduler and Scheduler.get_instance()
    if not scheduler then
        if state.log then state.log:error(COMPONENT_NAME, "Scheduler not available") end
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

-- ===========================================================================
-- Инициализация модуля
-- ===========================================================================

-- Инициализация логгера
state.log = Logger and Logger.new("resource-monitor")

-- Инициализация PID
local f_pid = io_open(PROC_STAT, "r")
if f_pid then
    local content = f_pid:read(64)
    if content then
        state.pid = tonumber(content:match("^(%d+)"))
    end
    f_pid:close()
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
