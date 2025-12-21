-- ===========================================================================
-- ResourceMonitor Class
-- Менеджер для мониторинга системных ресурсов (CPU, RAM, Disk I/O, Network I/O).
-- ===========================================================================

local type      = type
local getpid    = getpid
local tonumber  = tonumber
local string_format = string.format
local os_execute = os.execute
local io_popen = io.popen
local table_insert = table.insert

local Logger = require "utils.logger"
local log_info = Logger.info
local log_error = Logger.error
local log_debug = Logger.debug

local COMPONENT_NAME = "ResourceMonitor"

local instance = nil
local ResourceMonitor = {}
ResourceMonitor.__index = ResourceMonitor

--- Создает новый экземпляр ResourceMonitor.
-- @param string name Уникальное имя монитора.
-- @param table config Конфигурация монитора.
-- @return ResourceMonitor Новый объект ResourceMonitor.
function ResourceMonitor:new()
    if not instance then
        local self = setmetatable({}, ResourceMonitor)
        self.last_net_stats = {} -- Для отслеживания изменений сетевой статистики
        self.pid = getpid() -- PID процесса для мониторинга
        self.last_system_cpu_total_time = 0 -- Для расчета общего использования CPU системы
        self.last_system_cpu_active_time = 0 -- Для расчета активного использования CPU системы
        self.last_current_process_cpu_time = 0 -- Для расчета использования CPU текущего процесса
        self.last_current_process_total_cpu_time_at_call = 0 -- Для расчета общего использования CPU системы на момент вызова process_cpu_usage для текущего процесса
        self.last_network_check_time = astra.date() -- Для расчета интервала сетевой активности
        log_info(COMPONENT_NAME, "ResourceMonitor initialized. PID: %s", tostring(self.pid))

        instance = self
    end
    
    return instance
end
--- Собирает данные о системных ресурсах.
function ResourceMonitor:collect_system_data()
    local data = {
        timestamp = astra.date(),
        system = {
            cpu = self:get_system_cpu_usage(),
            memory = self:get_system_memory_usage(),
            disk = self:get_disk_usage(),
            network = self:get_network_usage()
        }
    }
    log_debug(COMPONENT_NAME, "Collected system data for '%s': %s", self.name, json.encode(data))
    return data
end

--- Собирает данные о ресурсах конкретного процесса.
-- @return table Таблица с данными о ресурсах процесса.
function ResourceMonitor:collect_process_data()
    local data = {
        timestamp = astra.date(),
        process = {
            pid = self.pid, -- Используем self.pid
            cpu = self:get_process_cpu_usage(self.pid),
            memory = self:get_process_memory_usage(self.pid)
        }
    }
    log_debug(COMPONENT_NAME, "Collected process data for PID '%s': %s", tostring(self.pid), json.encode(data))
    return data
end

--- Получает использование CPU системы.
-- @return table Таблица с данными об использовании CPU системы.
function ResourceMonitor:get_system_cpu_usage()
    local cpu_data = {}
    local f = io_popen("grep 'cpu ' /proc/stat")
    if f then
        local line = f:read("*l")
        f:close()
        local user, nice, system, idle, iowait, irq, softirq, steal, guest, guest_nice = line:match("cpu%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s*(%d*)%s*(%d*)")
        
        local current_user = tonumber(user) or 0
        local current_nice = tonumber(nice) or 0
        local current_system = tonumber(system) or 0
        local current_idle = tonumber(idle) or 0
        local current_iowait = tonumber(iowait) or 0
        local current_irq = tonumber(irq) or 0
        local current_softirq = tonumber(softirq) or 0
        local current_steal = tonumber(steal) or 0

        local current_total_cpu_time = current_user + current_nice + current_system + current_idle + current_iowait + current_irq + current_softirq + current_steal
        local current_active_cpu_time = current_user + current_nice + current_system + current_irq + current_softirq + current_steal

        if self.last_system_cpu_total_time > 0 then
            local delta_total = current_total_cpu_time - self.last_system_cpu_total_time
            local delta_active = current_active_cpu_time - self.last_system_cpu_active_time

            if delta_total > 0 then
                cpu_data.usage_percent = (delta_active / delta_total) * 100
            else
                cpu_data.usage_percent = 0
            end
        else
            cpu_data.usage_percent = 0
        end

        self.last_system_cpu_total_time = current_total_cpu_time
        self.last_system_cpu_active_time = current_active_cpu_time
    else
        log_error(COMPONENT_NAME, "Failed to open /proc/stat for system CPU usage.")
    end
    return cpu_data
end

--- Получает использование памяти системы.
-- @return table Таблица с данными об использовании памяти системы.
function ResourceMonitor:get_system_memory_usage()
    local mem_data = {}
    local f = io_popen("free -m | awk 'NR==2{print $2,$3}'")
    if f then
        local total_mem_str, used_mem_str = f:read("*l"):match("(%d+)%s+(%d+)")
        f:close()
        local total_mem = tonumber(total_mem_str)
        local used_mem = tonumber(used_mem_str)
        if total_mem and used_mem and total_mem > 0 then
            mem_data.total_mb = total_mem
            mem_data.used_mb = used_mem
            mem_data.usage_percent = (used_mem / total_mem) * 100
        else
            log_error(COMPONENT_NAME, "Failed to parse system memory usage.")
        end
    else
        log_error(COMPONENT_NAME, "Failed to execute 'free -m' for system memory usage.")
    end
    return mem_data
end

--- Получает использование CPU конкретного процесса.
-- @param number pid PID процесса.
-- @return table Таблица с данными об использовании CPU процесса.
function ResourceMonitor:get_process_cpu_usage(pid)
    local cpu_data = {}
    local f = io_popen(string_format("cat /proc/%d/stat", pid))
    if f then
        local stat_line = f:read("*l")
        f:close()
        if stat_line then
            local _, _, _, _, _, _, _, _, _, _, _, _, utime, stime, cutime, cstime = stat_line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
            local current_cpu_time = (tonumber(utime) or 0) + (tonumber(stime) or 0) + (tonumber(cutime) or 0) + (tonumber(cstime) or 0)

            local total_cpu_time_f = io_popen("grep 'cpu ' /proc/stat")
            local total_cpu_line = total_cpu_time_f:read("*l")
            total_cpu_time_f:close()
            local user, nice, system, idle, iowait, irq, softirq, steal = total_cpu_line:match("cpu%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
            local current_total_cpu_time = (tonumber(user) or 0) + (tonumber(nice) or 0) + (tonumber(system) or 0) + (tonumber(idle) or 0) + (tonumber(iowait) or 0) + (tonumber(irq) or 0) + (tonumber(softirq) or 0) + (tonumber(steal) or 0)

            if self.last_current_process_cpu_time > 0 and self.last_current_process_total_cpu_time_at_call > 0 then
                local delta_cpu_time = current_cpu_time - self.last_current_process_cpu_time
                local delta_total_cpu_time = current_total_cpu_time - self.last_current_process_total_cpu_time_at_call
                
                if delta_total_cpu_time > 0 then
                    cpu_data.usage_percent = (delta_cpu_time / delta_total_cpu_time) * 100
                else
                    cpu_data.usage_percent = 0
                end
            else
                cpu_data.usage_percent = 0
            end
            self.last_current_process_cpu_time = current_cpu_time
            self.last_current_process_total_cpu_time_at_call = current_total_cpu_time
        else
            log_error(COMPONENT_NAME, "Failed to read /proc/%d/stat for process CPU usage.", pid)
        end
    else
        log_error(COMPONENT_NAME, "Failed to open /proc/%d/stat for process CPU usage.", pid)
    end
    return cpu_data
end

--- Получает использование памяти конкретного процесса.
-- @param number pid PID процесса.
-- @return table Таблица с данными об использовании памяти процесса.
function ResourceMonitor:get_process_memory_usage(pid)
    local mem_data = {}
    local f = io_popen(string_format("cat /proc/%d/status | grep VmRSS", pid))
    if f then
        local line = f:read("*l")
        f:close()
        local vmrss_kb = line:match("VmRSS:%s*(%d+)")
        if vmrss_kb then
            mem_data.rss_mb = tonumber(vmrss_kb) / 1024
        else
            log_error(COMPONENT_NAME, "Failed to parse VmRSS for process memory usage.")
        end
    else
        log_error(COMPONENT_NAME, "Failed to open /proc/%d/status for process memory usage.", pid)
    end
    return mem_data
end

--- Получает использование диска.
-- @return table Таблица с данными об использовании диска.
function ResourceMonitor:get_disk_usage()
    local disk_data = {}
    local f = io_popen("df -h / | awk 'NR==2{print $5}' | sed 's/%//'")
    if f then
        local usage = tonumber(f:read("*l"))
        f:close()
        if usage then
            disk_data.usage_percent = usage
        else
            log_error(COMPONENT_NAME, "Failed to parse disk usage.")
        end
    else
        log_error(COMPONENT_NAME, "Failed to execute 'df -h /' for disk usage.")
    end
    return disk_data
end

--- Получает сетевую активность.
-- @return table Таблица с данными о сетевой активности.
function ResourceMonitor:get_network_usage()
    local net_data = {
        interfaces = {}
    }
    local current_time = astra.date()
    local delta_time = (current_time - self.last_network_check_time) / 1000 -- в секундах

    if delta_time <= 0 then
        delta_time = 1 -- Избегаем деления на ноль или отрицательных значений
    end

    local f = io_popen("cat /proc/net/dev")
    if f then
        for line in f:lines() do
            local interface, rx_bytes, rx_packets, rx_errs, rx_drop, rx_fifo, rx_frame, rx_compressed, rx_multicast, tx_bytes, tx_packets, tx_errs, tx_drop, tx_fifo, tx_colls, tx_carrier, tx_compressed = line:match("%s*(%S+):%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)")
            if interface and interface ~= "lo" then
                local current_rx_bytes = tonumber(rx_bytes)
                local current_tx_bytes = tonumber(tx_bytes)

                local last_rx_bytes = self.last_net_stats[interface .. "_rx"] or 0
                local last_tx_bytes = self.last_net_stats[interface .. "_tx"] or 0

                local rx_speed = (current_rx_bytes - last_rx_bytes) / delta_time -- bytes/sec
                local tx_speed = (current_tx_bytes - last_tx_bytes) / delta_time -- bytes/sec

                self.last_net_stats[interface .. "_rx"] = current_rx_bytes
                self.last_net_stats[interface .. "_tx"] = current_tx_bytes

                table_insert(net_data.interfaces, {
                    name = interface,
                    rx_bytes_per_sec = rx_speed,
                    tx_bytes_per_sec = tx_speed
                })
            end
        end
        f:close()
    else
        log_error(COMPONENT_NAME, "Failed to open /proc/net/dev for network usage.")
    end
    self.last_network_check_time = current_time
    return net_data
end

return ResourceMonitor
