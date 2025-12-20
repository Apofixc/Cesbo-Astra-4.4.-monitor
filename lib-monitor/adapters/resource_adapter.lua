-- ===========================================================================
-- ResourceAdapter Class
-- Адаптер для сбора данных о системных ресурсах (CPU, RAM, Disk I/O, Network I/O).
-- Использует системные команды для получения информации.
-- ===========================================================================

local type      = type
local tonumber  = tonumber
local string_format = string.format
local os_execute = os.execute
local io_popen = io.popen
local table_insert = table.insert

local Logger = require "utils.logger"
local log_info = Logger.info
local log_error = Logger.error
local log_debug = Logger.debug

local COMPONENT_NAME = "ResourceAdapter"

local ResourceAdapter = {}
ResourceAdapter.__index = ResourceAdapter

--- Создает новый экземпляр ResourceAdapter.
-- @param string name Уникальное имя монитора.
-- @param table config Конфигурация монитора.
-- @return ResourceAdapter Новый объект ResourceAdapter.
function ResourceAdapter:new(name, config)
    local self = setmetatable({}, ResourceAdapter)
    self.name = name
    self.config = config or {}
    self.interval = self.config.interval or 5000 -- Интервал мониторинга в миллисекундах
    self.timer = nil
    self.last_net_stats = {} -- Для отслеживания изменений сетевой статистики
    log_info(COMPONENT_NAME, "ResourceAdapter '%s' initialized with interval %dms.", self.name, self.interval)
    self:start()
    return self
end

--- Запускает мониторинг ресурсов.
function ResourceAdapter:start()
    if self.timer then
        self:stop()
    end
    self.timer = astra.timer.start(self.interval, function() self:collect_data() end)
    log_info(COMPONENT_NAME, "ResourceAdapter '%s' started monitoring.", self.name)
end

--- Останавливает мониторинг ресурсов.
function ResourceAdapter:stop()
    if self.timer then
        astra.timer.stop(self.timer)
        self.timer = nil
        log_info(COMPONENT_NAME, "ResourceAdapter '%s' stopped monitoring.", self.name)
    end
end

--- Обновляет параметры монитора.
-- @param table params Новые параметры.
-- @return boolean true, если параметры успешно обновлены; `nil` и сообщение об ошибке в случае ошибки.
function ResourceAdapter:update_parameters(params)
    if not params or type(params) ~= "table" then
        return nil, "Invalid parameters: expected table."
    end
    self.config = params
    self.interval = self.config.interval or self.interval
    self:start() -- Перезапускаем таймер с новым интервалом
    log_info(COMPONENT_NAME, "ResourceAdapter '%s' parameters updated. New interval: %dms.", self.name, self.interval)
    return true
end

--- Собирает данные о системных ресурсах.
function ResourceAdapter:collect_data()
    local data = {
        timestamp = astra.date(),
        cpu = self:get_cpu_usage(),
        memory = self:get_memory_usage(),
        disk = self:get_disk_usage(),
        network = self:get_network_usage()
    }
    log_debug(COMPONENT_NAME, "Collected data for '%s': %s", self.name, json.encode(data))
    -- Здесь можно добавить логику для отправки данных, например, в InfluxDB или через HTTP
    -- astra.event.send("resource_monitor_data", { name = self.name, data = data })
end

--- Получает использование CPU.
-- @return table Таблица с данными об использовании CPU.
function ResourceAdapter:get_cpu_usage()
    local cpu_data = {}
    local f = io_popen("grep 'cpu ' /proc/stat | awk '{usage=($2+$3+$4+$6+$7+$8)*100/($2+$3+$4+$5+$6+$7+$8+$9)} END {print usage}'")
    if f then
        local usage = tonumber(f:read("*l"))
        f:close()
        if usage then
            cpu_data.usage_percent = usage
        else
            log_error(COMPONENT_NAME, "Failed to parse CPU usage.")
        end
    else
        log_error(COMPONENT_NAME, "Failed to open /proc/stat for CPU usage.")
    end
    return cpu_data
end

--- Получает использование памяти.
-- @return table Таблица с данными об использовании памяти.
function ResourceAdapter:get_memory_usage()
    local mem_data = {}
    local f = io_popen("free -m | awk 'NR==2{printf \"%.2f\", $3*100/$2 }'")
    if f then
        local usage = tonumber(f:read("*l"))
        f:close()
        if usage then
            mem_data.usage_percent = usage
        else
            log_error(COMPONENT_NAME, "Failed to parse memory usage.")
        end
    else
        log_error(COMPONENT_NAME, "Failed to execute 'free -m' for memory usage.")
    end
    return mem_data
end

--- Получает использование диска.
-- @return table Таблица с данными об использовании диска.
function ResourceAdapter:get_disk_usage()
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
function ResourceAdapter:get_network_usage()
    local net_data = {
        interfaces = {}
    }
    local f = io_popen("cat /proc/net/dev")
    if f then
        for line in f:lines() do
            local interface, rx_bytes, rx_packets, rx_errs, rx_drop, rx_fifo, rx_frame, rx_compressed, rx_multicast, tx_bytes, tx_packets, tx_errs, tx_drop, tx_fifo, tx_colls, tx_carrier, tx_compressed = line:match("%s*(%S+):%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)%s*(%d+)")
            if interface and interface ~= "lo" then
                local current_rx_bytes = tonumber(rx_bytes)
                local current_tx_bytes = tonumber(tx_bytes)

                local last_rx_bytes = self.last_net_stats[interface .. "_rx"] or 0
                local last_tx_bytes = self.last_net_stats[interface .. "_tx"] or 0

                local rx_speed = (current_rx_bytes - last_rx_bytes) / (self.interval / 1000) -- bytes/sec
                local tx_speed = (current_tx_bytes - last_tx_bytes) / (self.interval / 1000) -- bytes/sec

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
    return net_data
end

return ResourceAdapter
