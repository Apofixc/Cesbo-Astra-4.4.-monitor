-- ===========================================================================
-- Модуль `system.resource_monitor`
--
-- Высокопроизводительный мониторинг системных ресурсов процесса Astra.
-- Сбор метрик CPU, RAM, потоков, FD и сетевых интерфейсов из /proc.
-- Интеграция с EventDispatcher для генерации предупреждений по порогам.
-- ===========================================================================

--- @class CpuMetrics
--- @field usage number Суммарное использование CPU (%)
--- @field user number Использование CPU пользователем (%)
--- @field system number Использование CPU системой (%)
--- @field threads number Количество потоков процесса

--- @class MemoryMetrics
--- @field lua number Использование памяти Lua (КБ)
--- @field lua_delta number Изменение памяти Lua с последней проверки (КБ)
--- @field lua_post_gc number Объем памяти после последней сборки мусора (КБ)
--- @field resident number Резидентная память (RSS, КБ)
--- @field virtual number Виртуальная память (VSZ, КБ)

--- @class NetworkItem
--- @field interface string Имя интерфейса
--- @field ip string IP-адрес

--- @class AstraInterfaceInfo
--- @field ipv4 string[]|nil Список IPv4 адресов
--- @field ipv6 string[]|nil Список IPv6 адресов
--- @field link { mac: string }|nil Информация о канальном уровне

--- @class SysStatusTemp
--- @field resident number|nil Резидентная память (КБ)
--- @field virtual number|nil Виртуальная память (КБ)
--- @field threads number|nil Количество потоков
--- @field fd_size number|nil Количество открытых дескрипторов
--- @field __pool_type string|nil Тип пула (для TablePool)

--- @class SystemReport
--- @field pid number Идентификатор процесса
--- @field uptime number Время работы процесса (сек)
--- @field cpu CpuMetrics Метрики процессора
--- @field memory MemoryMetrics Метрики памяти
--- @field network NetworkItem[] Список сетевых интерфейсов
--- @field fd_size number Количество открытых файловых дескрипторов

-- 1. Стандартные Lua функции
local collectgarbage = _G.collectgarbage
local io_open = _G.io.open
local os_clock = _G.os.clock
local os_time = _G.os.time
local pairs = _G.pairs
local table_insert = _G.table.insert
local table_remove = _G.table.remove
local tonumber = _G.tonumber
local type = _G.type
local math_min = _G.math.min
local string_find = _G.string.find
local string_sub = _G.string.sub
local string_match = _G.string.match
local string_format = _G.string.format

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local Scheduler = ModuleManager.get_module("core.scheduler")
local TablePool = ModuleManager.get_module("table_pool")

-- 3. Глобальные зависимости Astra
--- @type fun():table<string, AstraInterfaceInfo>
local utils_ifaddrs = ModuleManager.get_global_dependency("utils.ifaddrs")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ResourceMonitor"
local PROC_STAT = "/proc/self/stat"
local PROC_STATUS = "/proc/self/status"
local TICK_RATE = 100 -- Стандарт для Linux (USER_HZ)
local STAT_READ_BUFFER = 512
local STATUS_READ_BUFFER = 4096

-- Настройки по умолчанию
local DEFAULT_CPU_THRESHOLD = 90
local DEFAULT_RAM_THRESHOLD_PCT = 80
local HYSTERESIS_FACTOR = 0.95
local NETWORK_CHECK_INTERVAL = 30
local CONFIG_REFRESH_INTERVAL = 10
local ADAPTIVE_TICK_THRESHOLD_CPU = 50
local ADAPTIVE_TICK_THRESHOLD_RAM = 70
local TICK_INTERVAL_NORMAL = 5
local TICK_INTERVAL_FAST = 1

-- 5. Внутреннее состояние (Private State)
local state = {
    start_time = os_time(),
    last_clock = 0,
    last_utime = 0,
    last_stime = 0,
    last_lua_mem = 0,
    last_post_gc_mem = 0,
    pid = nil,
    report = nil,
    
    -- Moving Average O(1)
    cpu_buffer = {},
    cpu_sum = 0,
    cpu_index = 0,
    cpu_count = 0,
    last_cpu_usage = 0,
    
    -- Сеть
    last_network_check = 0,
    cached_network = nil,
    
    -- Гистерезис событий
    active_warnings = {
        cpu = false,
        ram = false
    },

    -- Кэш конфигурации
    config_cache = {
        cpu_threshold = DEFAULT_CPU_THRESHOLD,
        ram_threshold_pct = DEFAULT_RAM_THRESHOLD_PCT,
        last_refresh = 0
    },

    -- Адаптивный интервал
    current_tick_interval = TICK_INTERVAL_NORMAL
}

-- ===========================================================================
-- Внутренние функции (Private)
-- ===========================================================================

--- Обновляет кэш конфигурации (внутренняя версия с проверкой интервала)
local function _auto_refresh_config()
    local now = os_time()
    if now - state.config_cache.last_refresh < CONFIG_REFRESH_INTERVAL then return end
    
    if MonitorConfig then
        state.config_cache.cpu_threshold = MonitorConfig.CpuThreshold or DEFAULT_CPU_THRESHOLD
        state.config_cache.ram_threshold_pct = MonitorConfig.RamThresholdPct or DEFAULT_RAM_THRESHOLD_PCT
    end
    state.config_cache.last_refresh = now
end

--- Возвращает EventDispatcher (ленивая загрузка)
local function _get_event_dispatcher()
    return ModuleManager.get_module("core.event_dispatcher")
end

--- Парсит /proc/self/status (Zero-allocation parsing)
--- @return table|nil
local function _parse_status()
    local f = io_open(PROC_STATUS, "r")
    if not f then return nil end

    local content = f:read(STATUS_READ_BUFFER)
    f:close()
    if not content then return nil end

    --- @type SysStatusTemp
    local status = TablePool and TablePool.get("sys_status_temp") or {}
    
    -- Поиск VmRSS
    local s, e = string_find(content, "VmRSS:%s+")
    if s then
        local ns, ne = string_find(content, "%d+", e + 1)
        if ns then status.resident = tonumber(string_sub(content, ns, ne)) or 0 end
    end
    
    -- Поиск VmSize
    s, e = string_find(content, "VmSize:%s+")
    if s then
        local ns, ne = string_find(content, "%d+", e + 1)
        if ns then status.virtual = tonumber(string_sub(content, ns, ne)) or 0 end
    end
    
    -- Поиск Threads
    s, e = string_find(content, "Threads:%s+")
    if s then
        local ns, ne = string_find(content, "%d+", e + 1)
        if ns then status.threads = tonumber(string_sub(content, ns, ne)) or 0 end
    end

    -- Поиск FDSize
    s, e = string_find(content, "FDSize:%s+")
    if s then
        local ns, ne = string_find(content, "%d+", e + 1)
        if ns then status.fd_size = tonumber(string_sub(content, ns, ne)) or 0 end
    end

    return status
end

--- Парсит /proc/self/stat (Zero-allocation parsing)
--- @return number, number
local function _parse_stat()
    local f = io_open(PROC_STAT, "r")
    if not f then return 0, 0 end

    local content = f:read(STAT_READ_BUFFER)
    f:close()
    if not content then return 0, 0 end

    -- Находим конец имени процесса (может содержать пробелы)
    local _, last_paren = string_find(content, ".*%)")
    if not last_paren then return 0, 0 end
    
    -- utime и stime - это 14-й и 15-й параметры.
    -- После имени процесса (2-й параметр) идет еще 11 параметров до utime.
    local pos = last_paren + 2
    for i = 1, 11 do
        local s, e = string_find(content, "%s+", pos)
        if not s then return 0, 0 end
        pos = e + 1
    end

    -- Читаем 14-й параметр (utime)
    local s, e = string_find(content, "%d+", pos)
    if not s then return 0, 0 end
    local utime = tonumber(string_sub(content, s, e)) or 0
    pos = e + 1

    -- Читаем 15-й параметр (stime)
    s, e = string_find(content, "%d+", pos)
    if not s then return utime, 0 end
    local stime = tonumber(string_sub(content, s, e)) or 0

    return utime, stime
end

--- Рассчитывает среднее значение CPU из буфера (O(1))
--- @param val number Новое значение
--- @return number
local function _moving_average(val)
    local window = (MonitorConfig and MonitorConfig.CpuMovingAverageWindow) or 0
    if window <= 1 then return val end

    state.cpu_index = (state.cpu_index % window) + 1
    local old_val = state.cpu_buffer[state.cpu_index] or 0
    state.cpu_buffer[state.cpu_index] = val
    state.cpu_sum = state.cpu_sum - old_val + val
    
    state.cpu_count = math_min(state.cpu_count + 1, window)
    return state.cpu_sum / state.cpu_count
end

--- Проверяет пороги и генерирует события при необходимости (с гистерезисом)
--- @param report SystemReport
local function _check_thresholds(report)
    local ed = _get_event_dispatcher()
    if not ed then return end

    _auto_refresh_config()
    local cpu_threshold = state.config_cache.cpu_threshold
    local ram_threshold_pct = state.config_cache.ram_threshold_pct

    -- Адаптивный интервал опроса
    local ram_limit_mb = (MonitorConfig and MonitorConfig.MemoryLimitMb) or 50
    local ram_limit_kb = ram_limit_mb * 1024
    local ram_usage_pct = (report.memory.lua / ram_limit_kb) * 100
    local cpu_val = report.cpu.usage

    local target_interval = TICK_INTERVAL_NORMAL
    if cpu_val > ADAPTIVE_TICK_THRESHOLD_CPU or ram_usage_pct > ADAPTIVE_TICK_THRESHOLD_RAM then
        target_interval = TICK_INTERVAL_FAST
    end

    if target_interval ~= state.current_tick_interval then
        state.current_tick_interval = target_interval
        local scheduler = Scheduler and Scheduler.get_instance()
        if scheduler and scheduler.set_task_interval then
            scheduler:set_task_interval("resource_monitor", target_interval)
        end
    end
    
    -- 1. Проверка CPU
    local cpu_val = report.cpu.usage
    if not state.active_warnings.cpu then
        if cpu_val > cpu_threshold then
            state.active_warnings.cpu = true
            ed:emit("sys:resource_warning", {
                type = "cpu",
                status = "critical",
                value = cpu_val,
                threshold = cpu_threshold,
                message = string_format("Высокая нагрузка на CPU: %.1f%%", cpu_val)
            })
        end
    else
        if cpu_val < (cpu_threshold * HYSTERESIS_FACTOR) then
            state.active_warnings.cpu = false
            ed:emit("sys:resource_warning", {
                type = "cpu",
                status = "ok",
                value = cpu_val,
                message = "Нагрузка на CPU нормализовалась"
            })
        end
    end

    -- 2. Проверка RAM (Lua)
    local ram_limit_mb = (MonitorConfig and MonitorConfig.MemoryLimitMb) or 50
    local ram_limit_kb = ram_limit_mb * 1024
    local ram_usage_pct = (report.memory.lua / ram_limit_kb) * 100

    if not state.active_warnings.ram then
        if ram_usage_pct > ram_threshold_pct then
            state.active_warnings.ram = true
            ed:emit("sys:resource_warning", {
                type = "ram",
                status = "critical",
                value = ram_usage_pct,
                threshold = ram_threshold_pct,
                current_kb = report.memory.lua,
                limit_kb = ram_limit_kb,
                message = string_format("Высокое потребление памяти Lua: %.1f%% (%d KB)", ram_usage_pct, report.memory.lua)
            })
        end
    else
        if ram_usage_pct < (ram_threshold_pct * HYSTERESIS_FACTOR) then
            state.active_warnings.ram = false
            ed:emit("sys:resource_warning", {
                type = "ram",
                status = "ok",
                value = ram_usage_pct,
                message = "Потребление памяти Lua нормализовалось"
            })
        end
    end
end

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- @class ResourceMonitor
local ResourceMonitor = {}

--- Явное обновление конфигурации из MonitorConfig
function ResourceMonitor.refresh_config()
    if MonitorConfig then
        state.config_cache.cpu_threshold = MonitorConfig.CpuThreshold or DEFAULT_CPU_THRESHOLD
        state.config_cache.ram_threshold_pct = MonitorConfig.RamThresholdPct or DEFAULT_RAM_THRESHOLD_PCT
    end
    state.config_cache.last_refresh = os_time()
end

--- Собирает актуальные метрики системы
--- @return SystemReport|nil
function ResourceMonitor.check()
    local now_clock = os_clock()
    local now_time = os_time()
    local utime, stime = _parse_stat()
    --- @type SysStatusTemp
    local status = _parse_status() or {}
    local current_lua_mem = collectgarbage("count")

    -- Освобождение старого отчета в пул
    if state.report and TablePool then
        TablePool.release(state.report, "report_sys", true)
    end

    -- Получение нового отчета из пула
    --- @type SystemReport
    local report = TablePool and TablePool.get("report_sys") or {}
    report.pid = state.pid
    report.uptime = now_time - state.start_time
    report.fd_size = status.fd_size or 0

    -- Метрики CPU
    report.cpu = report.cpu or (TablePool and TablePool.get("sys_cpu") or {})
    report.cpu.threads = status.threads or 0
    report.cpu.user = 0
    report.cpu.system = 0
    report.cpu.usage = state.last_cpu_usage

    if state.last_clock > 0 then
        local delta_clock = now_clock - state.last_clock
        if delta_clock > 0 then
            local u_usage = ((utime - state.last_utime) / TICK_RATE / delta_clock) * 100
            local s_usage = ((stime - state.last_stime) / TICK_RATE / delta_clock) * 100
            
            report.cpu.user = u_usage
            report.cpu.system = s_usage
            report.cpu.usage = _moving_average(u_usage + s_usage)
            state.last_cpu_usage = report.cpu.usage
        end
    end

    state.last_clock = now_clock
    state.last_utime = utime
    state.last_stime = stime

    -- Метрики памяти
    report.memory = report.memory or (TablePool and TablePool.get("sys_mem") or {})
    report.memory.lua = current_lua_mem
    report.memory.lua_delta = (state.last_lua_mem > 0) and (current_lua_mem - state.last_lua_mem) or 0
    
    if current_lua_mem < state.last_lua_mem then
        state.last_post_gc_mem = current_lua_mem
    end
    report.memory.lua_post_gc = state.last_post_gc_mem
    
    report.memory.resident = status.resident or 0
    report.memory.virtual = status.virtual or 0

    state.last_lua_mem = current_lua_mem

    -- Метрики сети (с кэшированием и переиспользованием таблиц)
    report.network = report.network or (TablePool and TablePool.get("sys_net") or {})
    
    if not state.cached_network or (now_time - state.last_network_check > NETWORK_CHECK_INTERVAL) then
        -- Вместо полной очистки, переиспользуем существующие таблицы в кэше
        local net_list = state.cached_network or (TablePool and TablePool.get("sys_net") or {})
        local idx = 1
        
        if utils_ifaddrs and type(utils_ifaddrs) == "function" then
            local interfaces = utils_ifaddrs()
            if type(interfaces) == "table" then
                for name, addrs in pairs(interfaces) do
                    if addrs.ipv4 and addrs.ipv4[1] then
                        local item = net_list[idx]
                        if not item then
                            item = TablePool and TablePool.get("sys_net_item") or {}
                            table_insert(net_list, item)
                        end
                        item.interface = name
                        item.ip = addrs.ipv4[1]
                        idx = idx + 1
                    end
                end
            end
        end
        
        -- Удаляем лишние элементы из кэша, если их стало меньше
        while #net_list >= idx do
            local old_item = table_remove(net_list)
            if TablePool then TablePool.release(old_item, "sys_net_item") end
        end
        
        state.cached_network = net_list
        state.last_network_check = now_time
    end

    -- Копируем из кэша в отчет
    for i = 1, #state.cached_network do
        local cached_item = state.cached_network[i]
        local item = TablePool and TablePool.get("sys_net_item") or {}
        item.interface = cached_item.interface
        item.ip = cached_item.ip
        table_insert(report.network, item)
    end

    -- Проверка порогов
    _check_thresholds(report)

    -- Освобождаем временную таблицу статуса
    if TablePool and status.__pool_type then
        TablePool.release(status, "sys_status_temp")
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
        if Logger then Logger.error(COMPONENT_NAME, "Scheduler not available") end
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

-- Инициализация PID
local f_pid = io_open(PROC_STAT, "r")
if f_pid then
    local content = f_pid:read(64)
    if content then
        state.pid = tonumber(string_match(content, "^(%d+)"))
    end
    f_pid:close()
end

-- Регистрация типов в TablePool
if TablePool then
    TablePool.register_type("report_sys", { "pid", "uptime", "cpu", "memory", "network", "fd_size" }, 10, 2)
    TablePool.register_type("sys_cpu", { "usage", "user", "system", "threads" }, 10, 2)
    TablePool.register_type("sys_mem", { "lua", "lua_delta", "lua_post_gc", "resident", "virtual" }, 10, 2)
    TablePool.register_type("sys_net", nil, 10, 2)
    TablePool.register_type("sys_net_item", { "interface", "ip" }, 20, 5)
    TablePool.register_type("sys_status_temp", { "resident", "virtual", "threads", "fd_size" }, 5, 1, true)
end

-- Автоматический запуск при загрузке
ResourceMonitor.start()

return ResourceMonitor
