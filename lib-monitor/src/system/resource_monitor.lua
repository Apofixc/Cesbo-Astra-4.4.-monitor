-- ===========================================================================
-- Класс `ResourceMonitor` (Singleton)
--
-- Менеджер для мониторинга системных ресурсов (CPU, RAM, Disk I/O, Network I/O).
-- Обеспечивает сбор, кэширование и предоставление данных о состоянии системы
-- и текущего процесса Astra.
-- ===========================================================================

-- 1. Стандартные Lua функции
local type, tostring, tonumber = type, tostring, tonumber
local string_format = string.format
local io_open, io_popen = io.open, io.popen
local table_insert = table.insert
local os_time, os_date = os.time, os.date
local math_max = math.max

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local log_info = Logger.info
local log_error = Logger.error
local log_debug = Logger.debug

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Нет глобальных зависимостей Astra в этом модуле

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ResourceMonitor"

-- 5. Инициализация объектов из загруженных модулей
--- @class ResourceMonitor
--- @field name string Имя монитора
--- @field pid number PID процесса
--- @field last_net_stats table Статистика сети
--- @field last_system_cpu_total_time number
--- @field last_system_cpu_active_time number
--- @field last_process_cpu_time number
--- @field last_system_cpu_time_at_process_check number
--- @field last_network_check_time number
--- @field cache table Кэш данных
--- @field cache_interval number Интервал кэширования
--- @field stats table Статистика использования
local ResourceMonitor = {}
ResourceMonitor.__index = ResourceMonitor
--- @type ResourceMonitor|nil
local instance = nil

--- @return boolean success Статус выполнения
--- @return number|nil result PID или nil
local function get_current_pid()
    local file = io_open("/proc/self/stat", "r")
    if file then
        local data = file:read("*a")
        file:close()
        local pid = data:match("^(%d+)")
        return true, tonumber(pid)
    end
    return false, nil
end

--- Создает или возвращает единственный экземпляр ResourceMonitor.
--- @param [name] string|nil Уникальное имя монитора (используется только при первом создании).
--- @return ResourceMonitor result Единственный объект ResourceMonitor.
function ResourceMonitor:new(name)
    if not instance then
        local self = setmetatable({}, ResourceMonitor)
        
        -- Сохраняем имя монитора (только при первом создании)
        self.name = name or "ResourceMonitor"
        
        -- Получаем PID текущего процесса
        local success_pid, pid = get_current_pid()
        self.pid = success_pid and pid or 0
        
        -- Инициализация состояния
        self.last_net_stats = {} -- Для отслеживания изменений сетевой статистики
        
        -- Для расчета CPU системы
        self.last_system_cpu_total_time = 0
        self.last_system_cpu_active_time = 0
        
        -- Для расчета CPU текущего процесса
        self.last_process_cpu_time = 0
        self.last_system_cpu_time_at_process_check = 0
        
        -- Время последней проверки сети
        self.last_network_check_time = os_time()
        
        -- Кэш для уменьшения нагрузки
        self.cache = {
            system = nil,
            process = nil,
            last_update = 0
        }
        
        -- Интервал кэширования в секундах
        self.cache_interval = 2
        
        -- Статистика использования
        self.stats = {
            collections = 0,
            last_reset = os_time()
        }
        
        log_info(COMPONENT_NAME, "ResourceMonitor '%s' инициализирован. PID: %s", 
                 self.name, tostring(self.pid))
        
        self:get_system_cpu_usage()
        self:get_process_cpu_usage()
        
        instance = self
    end
    
    return instance
end

--- Возвращает единственный экземпляр ResourceMonitor, создавая его при необходимости.
--- @param [name] string|nil Имя монитора (используется только при первом вызове).
--- @return ResourceMonitor result Единственный экземпляр.
function ResourceMonitor.getInstance(name)
    return ResourceMonitor:new(name)
end

--- Вспомогательная функция для безопасного выполнения команд.
--- @param cmd string Команда для выполнения.
--- @param default any Значение по умолчанию при ошибке.
--- @return boolean success Статус выполнения
--- @return string result Результат выполнения команды или значение по умолчанию.
local function safe_command(cmd, default)
    local f = io_popen(cmd .. " 2>/dev/null", "r")
    if not f then
        log_error(COMPONENT_NAME, "Не удалось выполнить команду: %s.", cmd)
        return false, default
    end
    
    local result = f:read("*a")
    f:close()
    
    return true, result and result:gsub("%s+$", "") or default
end

--- Получает текущее время в миллисекундах.
--- @return number result Время в мс.
local function get_current_time_ms()
    return os_time() * 1000
end

--- Собирает данные о системных ресурсах.
--- @return boolean success Статус выполнения
--- @return table result Таблица с данными о системных ресурсах.
function ResourceMonitor:collect_system_data()
    -- Проверяем кэш
    local now = os_time()
    if self.cache.system and (now - self.cache.last_update) < self.cache_interval then
        return true, self.cache.system
    end
    
    local _, cpu = self:get_system_cpu_usage()
    local _, memory = self:get_system_memory_usage()
    local _, disk = self:get_disk_usage()
    local _, network = self:get_network_usage()

    local data = {
        timestamp = os_date("%Y-%m-%d %H:%M:%S"),
        system = {
            cpu = cpu,
            memory = memory,
            disk = disk,
            network = network
        }
    }
    
    -- Кэшируем результат
    self.cache.system = data
    self.cache.last_update = now
    self.stats.collections = self.stats.collections + 1
    
    log_debug(COMPONENT_NAME, "Собраны системные данные для '%s'.", self.name)
    return true, data
end

--- Собирает данные о ресурсах текущего процесса.
--- @return boolean success Статус выполнения
--- @return table result Таблица с данными о ресурсах процесса.
function ResourceMonitor:collect_process_data()
    -- Проверяем кэш
    local now = os_time()
    if self.cache.process and (now - self.cache.last_update) < self.cache_interval then
        return true, self.cache.process
    end
    
    local _, cpu = self:get_process_cpu_usage()
    local _, memory = self:get_process_memory_usage()

    local data = {
        timestamp = os_date("%Y-%m-%d %H:%M:%S"),
        process = {
            pid = self.pid,
            cpu = cpu,
            memory = memory
        }
    }
    
    -- Кэшируем результат
    self.cache.process = data
    self.cache.last_update = now
    self.stats.collections = self.stats.collections + 1
    
    log_debug(COMPONENT_NAME, "Собраны данные процесса для PID '%s'.", tostring(self.pid))
    return true, data
end

--- Получает использование CPU системы.
--- @return boolean success Статус выполнения
--- @return table result Таблица с данными об использовании CPU системы.
function ResourceMonitor:get_system_cpu_usage()
    local cpu_data = {usage_percent = 0, cores = 1}
    
    -- Получаем количество ядер
    local _, nproc_res = safe_command("nproc", "1")
    local cores = tonumber(nproc_res) or 1
    cpu_data.cores = cores
    
    -- Чтение /proc/stat
    local _, stat_content = safe_command("grep '^cpu ' /proc/stat", "")
    if stat_content == "" then
        return true, cpu_data
    end
    
    local user, nice, system, idle, iowait, irq, softirq, steal = 
        stat_content:match("cpu%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
    
    if not user then
        return cpu_data
    end
    
    local current_user = tonumber(user) or 0
    local current_nice = tonumber(nice) or 0
    local current_system = tonumber(system) or 0
    local current_idle = tonumber(idle) or 0
    local current_iowait = tonumber(iowait) or 0
    local current_irq = tonumber(irq) or 0
    local current_softirq = tonumber(softirq) or 0
    local current_steal = tonumber(steal) or 0
    
    local current_total = current_user + current_nice + current_system + current_idle + 
                         current_iowait + current_irq + current_softirq + current_steal
    local current_active = current_total - current_idle - current_iowait
    
    if self.last_system_cpu_total_time > 0 then
        local delta_total = current_total - self.last_system_cpu_total_time
        local delta_active = current_active - self.last_system_cpu_active_time
        
        if delta_total > 0 then
            cpu_data.usage_percent = (delta_active / delta_total) * 100
        end
    end
    
    -- Сохраняем текущие значения для следующего вызова
    self.last_system_cpu_total_time = current_total
    self.last_system_cpu_active_time = current_active
    
    return true, cpu_data
end

--- Получает использование памяти системы.
--- @return boolean success Статус выполнения
--- @return table result Таблица с данными об использовании памяти системы.
function ResourceMonitor:get_system_memory_usage()
    local mem_data = {total_mb = 0, used_mb = 0, usage_percent = 0}
    
    local _, meminfo = safe_command("free -m | awk 'NR==2{print $2,$3,$4}'", "")
    if meminfo == "" then
        return true, mem_data
    end
    
    local total_str, used_str, free_str = meminfo:match("(%d+)%s+(%d+)%s+(%d+)")
    local total = tonumber(total_str)
    local used = tonumber(used_str)
    
    if total and used and total > 0 then
        mem_data.total_mb = total
        mem_data.used_mb = used
        mem_data.free_mb = tonumber(free_str) or 0
        mem_data.usage_percent = (used / total) * 100
    end
    
    return true, mem_data
end

--- Получает использование CPU текущего процесса.
--- @return boolean success Статус выполнения
--- @return table result Таблица с данными об использовании CPU процесса.
function ResourceMonitor:get_process_cpu_usage()
    local cpu_data = {usage_percent = 0}
    if self.pid <= 0 then 
        return true, cpu_data 
    end

    -- Чтение /proc/pid/stat без внешних команд
    local f = io_open(string_format("/proc/%d/stat", self.pid), "r")
    if not f then 
        return true, cpu_data 
    end

    local stat_content = f:read("*all")
    f:close()

    local fields = {}
    for field in stat_content:gmatch("%S+") do
        table.insert(fields, field)
    end

    -- Нам нужны utime (14) и stime (15)
    -- Проверяем наличие полей перед доступом
    local utime = (fields[14] and tonumber(fields[14])) or 0
    local stime = (fields[15] and tonumber(fields[15])) or 0
    local current_process_time = utime + stime

    -- Чтение общей статистики системы
    local sf = io.open("/proc/stat", "r")
    if not sf then 
        return cpu_data 
    end

    local system_stat = sf:read("*line") -- Первая строка всегда 'cpu '
    sf:close()

    local user, nice, system, idle, iowait, irq, softirq, steal = 
        system_stat:match("cpu%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
    
    local current_system_time = 0
    if user then
        current_system_time = tonumber(user) + tonumber(nice) + tonumber(system) + 
                              tonumber(idle) + tonumber(iowait) + tonumber(irq) + 
                              tonumber(softirq) + tonumber(steal)
    end

    if self.last_process_cpu_time > 0 and self.last_system_cpu_time_at_process_check > 0 then
        local delta_process = current_process_time - self.last_process_cpu_time
        local delta_system = current_system_time - self.last_system_cpu_time_at_process_check
        
        if delta_system > 0 then
            local usage = (delta_process / delta_system) * 100
            cpu_data.usage_percent = math.max(0, usage)
        else
            log_debug(COMPONENT_NAME, "Время дельты системы равно нулю, невозможно рассчитать использование ЦП процесса.")
        end
    end

    self.last_process_cpu_time = current_process_time
    self.last_system_cpu_time_at_process_check = current_system_time
    
    return true, cpu_data
end

--- Получает использование памяти текущего процесса.
--- @return boolean success Статус выполнения
--- @return table result Таблица с данными об использовании памяти процесса.
function ResourceMonitor:get_process_memory_usage()
    local mem_data = {rss_mb = 0, rss_kb = 0}
    
    if self.pid <= 0 then
        return true, mem_data
    end
    
    local _, status_content = safe_command(string_format("cat /proc/%d/status 2>/dev/null", self.pid), "")
    if status_content == "" then
        return true, mem_data
    end
    
    -- Ищем VmRSS
    for line in status_content:gmatch("[^\r\n]+") do
        if line:match("VmRSS:") then
            local vmrss_kb = line:match("VmRSS:%s*(%d+)%s*kB")
            if vmrss_kb then
                local kb = tonumber(vmrss_kb)
                mem_data.rss_kb = kb
                mem_data.rss_mb = kb / 1024
            end
            break
        end
    end
    
    return true, mem_data
end

--- Получает использование диска.
--- @return boolean success Статус выполнения
--- @return table result Таблица с данными об использовании диска.
function ResourceMonitor:get_disk_usage()
    local disk_data = {usage_percent = 0, total_gb = 0, used_gb = 0, free_gb = 0}
    
    local _, df_output = safe_command("df -B1 / | awk 'NR==2{print $2,$3,$4,$5}'", "")
    if df_output == "" then
        return true, disk_data
    end
    
    local total_bytes_str, used_bytes_str, free_bytes_str, percent_str = 
        df_output:match("(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%%")
    
    if total_bytes_str then
        local total_bytes = tonumber(total_bytes_str) or 0
        local used_bytes = tonumber(used_bytes_str) or 0
        local free_bytes = tonumber(free_bytes_str) or 0
        local percent = tonumber(percent_str) or 0
        
        disk_data.usage_percent = percent
        disk_data.total_gb = total_bytes / (1024^3)
        disk_data.used_gb = used_bytes / (1024^3)
        disk_data.free_gb = free_bytes / (1024^3)
    end
    
    return true, disk_data
end

--- Получает сетевую активность.
--- @return boolean success Статус выполнения
--- @return table result Таблица с данными о сетевой активности.
function ResourceMonitor:get_network_usage()
    local net_data = {
        interfaces = {},
        total_rx_bytes_per_sec = 0,
        total_tx_bytes_per_sec = 0
    }
    
    local current_time = os_time()
    local delta_time = current_time - self.last_network_check_time
    
    -- Минимальный интервал 1 секунда для адекватных расчетов скорости
    if delta_time < 1 then
        delta_time = 1
    end
    
    local _, netdev_content = safe_command("cat /proc/net/dev", "")
    if netdev_content == "" then
        self.last_network_check_time = current_time
        return true, net_data
    end
    
    for line in netdev_content:gmatch("[^\r\n]+") do
        local interface, stats = line:match("^%s*(%S+):%s*(.+)$")
        if interface and interface ~= "lo" then
            local fields = {}
            for field in stats:gmatch("%S+") do
                table_insert(fields, field)
            end
            
            if #fields >= 16 then
                local current_rx_bytes = tonumber(fields[1]) or 0
                local current_tx_bytes = tonumber(fields[9]) or 0
                
                local last_rx_key = interface .. "_rx"
                local last_tx_key = interface .. "_tx"
                
                local last_rx_bytes = self.last_net_stats[last_rx_key] or 0
                local last_tx_bytes = self.last_net_stats[last_tx_key] or 0
                
                local rx_speed = 0
                local tx_speed = 0
                
                log_debug(COMPONENT_NAME, "Интерфейс %s: current_rx_bytes: %s, last_rx_bytes: %s", interface, tostring(current_rx_bytes), tostring(last_rx_bytes))
                if current_rx_bytes >= last_rx_bytes then
                    rx_speed = (current_rx_bytes - last_rx_bytes) / delta_time
                end
                
                if current_tx_bytes >= last_tx_bytes then
                    tx_speed = (current_tx_bytes - last_tx_bytes) / delta_time
                end
                
                -- Сохраняем текущие значения
                self.last_net_stats[last_rx_key] = current_rx_bytes
                self.last_net_stats[last_tx_key] = current_tx_bytes
                
                -- Добавляем интерфейс
                table_insert(net_data.interfaces, {
                    name = interface,
                    rx_bytes_per_sec = rx_speed,
                    tx_bytes_per_sec = tx_speed,
                    rx_bytes_total = current_rx_bytes,
                    tx_bytes_total = current_tx_bytes
                })
                
                net_data.total_rx_bytes_per_sec = net_data.total_rx_bytes_per_sec + rx_speed
                net_data.total_tx_bytes_per_sec = net_data.total_tx_bytes_per_sec + tx_speed
            end
        end
    end
    
    -- Очистка устаревших статистик
    local active_interfaces = {}
    for _, iface in ipairs(net_data.interfaces) do
        active_interfaces[iface.name .. "_rx"] = true
        active_interfaces[iface.name .. "_tx"] = true
    end
    
    for key in pairs(self.last_net_stats) do
        if not active_interfaces[key] then
            self.last_net_stats[key] = nil
        end
    end
    
    self.last_network_check_time = current_time
    
    return true, net_data
end

--- Сбрасывает кэш (принудительное обновление данных при следующем вызове).
--- @return boolean success Статус выполнения
function ResourceMonitor:clear_cache()
    self.cache.system = nil
    self.cache.process = nil
    self.cache.last_update = 0
    log_debug(COMPONENT_NAME, "Кэш очищен для '%s'", self.name)
    return true
end

--- Устанавливает интервал кэширования.
--- @param seconds number Интервал в секундах.
--- @return boolean success Статус выполнения
function ResourceMonitor:set_cache_interval(seconds)
    if type(seconds) == "number" and seconds >= 0 then
        self.cache_interval = seconds
        log_debug(COMPONENT_NAME, "Интервал кэширования установлен на %d секунд для '%s'", seconds, self.name)
        return true
    end
    return false
end

--- Возвращает статистику использования монитора.
--- @return table result Статистика.
function ResourceMonitor:get_stats()
    return {
        name = self.name,
        pid = self.pid,
        collections = self.stats.collections,
        last_reset = self.stats.last_reset,
        cache_hits = self.stats.collections - (self.cache.system and 1 or 0) - (self.cache.process and 1 or 0),
        cache_interval = self.cache_interval
    }
end

--- Сбрасывает статистику монитора.
--- @return boolean success Статус выполнения
function ResourceMonitor:reset_stats()
    self.stats.collections = 0
    self.stats.last_reset = os_time()
    log_debug(COMPONENT_NAME, "Статистика сброшена для '%s'", self.name)
    return true
end

return ResourceMonitor
