-- 1. Стандартные Lua функции
local collectgarbage = collectgarbage
local io = io
local os = os
local tonumber = tonumber

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpSubscriber = ModuleManager.get_module("http_subscriber")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local json_encode = ModuleManager.get_global_dependency("json.encode")
local timer = ModuleManager.get_global_dependency("timer")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ResourceMonitor"
local UPDATE_INTERVAL = 10 -- секунд

-- 5. Инициализация объектов из загруженных модулей
--- @class ResourceMonitor
local ResourceMonitor = {}

local last_utime = 0
local last_stime = 0
local last_time = 0

--- Читает статистику процесса из /proc/self/stat
--- @return table|nil Данные о потреблении ресурсов
local function get_proc_stats()
    local f = io.open("/proc/self/stat", "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()

    -- Формат /proc/[pid]/stat:
    -- 14: utime (user mode jiffies)
    -- 15: stime (kernel mode jiffies)
    -- 24: rss (resident set size in pages)
    local parts = {}
    for part in content:gmatch("%S+") do
        parts[#parts + 1] = part
    end

    return {
        utime = tonumber(parts[14]),
        stime = tonumber(parts[15]),
        rss = tonumber(parts[24])
    }
end

--- Вычисляет загрузку CPU и RAM и отправляет отчет
function ResourceMonitor.check()
    local stats = get_proc_stats()
    if not stats then return end

    local current_time = os.time()
    local cpu_usage = 0

    if last_time > 0 then
        local delta_time = current_time - last_time
        if delta_time > 0 then
            -- Упрощенный расчет: (delta_utime + delta_stime) / delta_time
            -- В Linux jiffies обычно 100 в секунду (USER_HZ)
            local delta_cpu = (stats.utime - last_utime) + (stats.stime - last_stime)
            cpu_usage = (delta_cpu / 100) / delta_time * 100
        end
    end

    last_utime = stats.utime
    last_stime = stats.stime
    last_time = current_time

    local report = {
        type = "sys",
        cpu = cpu_usage,
        -- collectgarbage("count") возвращает КБ
        lua_mem = collectgarbage("count"),
        -- rss в страницах (обычно 4КБ)
        rss = stats.rss * 4
    }

    local json_data = json_encode(report)
    if HttpSubscriber then
        HttpSubscriber.publish("sys", json_data)
    end
    
    Logger.debug(COMPONENT_NAME, "Resources: CPU: %.2f%%, Lua Mem: %.2f KB, RSS: %d KB", 
        cpu_usage, report.lua_mem, report.rss)
end

--- Инициализирует мониторинг системных ресурсов
function ResourceMonitor.init()
    if ResourceMonitor._timer then return end

    ResourceMonitor._timer = timer({
        interval = UPDATE_INTERVAL,
        callback = function()
            ResourceMonitor.check()
        end
    })

    Logger.info(COMPONENT_NAME, "ResourceMonitor initialized (interval: %d s)", UPDATE_INTERVAL)
end

--- Останавливает мониторинг
function ResourceMonitor.stop()
    if ResourceMonitor._timer then
        ResourceMonitor._timer:close()
        ResourceMonitor._timer = nil
    end
end

return ResourceMonitor
