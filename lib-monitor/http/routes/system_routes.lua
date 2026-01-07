--- @class SystemRoutes
local SystemRoutes = {}

-- 1. Стандартные Lua функции
local os_time = os.time
local os_date = os_date
local tonumber = tonumber

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")
local ResourceMonitor = ModuleManager.get_module("resource_monitor")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local astra_version = ModuleManager.get_global_dependency("astra.version")
local astra_reload = ModuleManager.get_global_dependency("astra.reload")
local astra_exit = ModuleManager.get_global_dependency("astra.exit")
local utils_ifaddrs = ModuleManager.get_global_dependency("utils.ifaddrs")
local utils_hostname = ModuleManager.get_global_dependency("utils.hostname")
local timer_obj = ModuleManager.get_global_dependency("timer")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "SystemRoutes"

--- Проверяет состояние сервера и возвращает метрики ресурсов процесса
function SystemRoutes.get_health(server, client, request)
    local report = ResourceMonitor and ResourceMonitor.get_report and ResourceMonitor.get_report() or {}
    
    -- Добавляем мониторинг памяти Lua
    report.lua_mem_kb = collectgarbage("count")
    
    local response = {
        status = "healthy",
        astra_version = astra_version or "unknown",
        server_time = os_date("%Y-%m-%d %H:%M:%S"),
        timestamp = os_time(),
        resources = report
    }
    return HttpHelpers.success(server, client, response)
end

--- Перезагружает Astra
function SystemRoutes.reload(server, client, request)
    local params = HttpHelpers.get_params(request)
    local delay = tonumber(params.delay) or 1
    
    if timer_obj then
        timer_obj({ interval = delay, callback = function(self) self:close(); if astra_reload then astra_reload() end end })
        return HttpHelpers.success(server, client, { message = "Astra reload scheduled in " .. delay .. "s" })
    end
    
    if astra_reload then astra_reload() end
    return HttpHelpers.success(server, client, { message = "Astra reloading" })
end

--- Останавливает Astra
function SystemRoutes.exit(server, client, request)
    local params = HttpHelpers.get_params(request)
    local delay = tonumber(params.delay) or 1
    
    if timer_obj then
        timer_obj({ interval = delay, callback = function(self) self:close(); if astra_exit then astra_exit() end end })
        return HttpHelpers.success(server, client, { message = "Astra exit scheduled in " .. delay .. "s" })
    end
    
    if astra_exit then astra_exit() end
    return HttpHelpers.success(server, client, { message = "Astra exiting" })
end

--- Очищает кэш системных метрик
function SystemRoutes.clear_cache(server, client, request)
    if ResourceMonitor and ResourceMonitor.check then
        ResourceMonitor.check()
        return HttpHelpers.success(server, client, { message = "Metrics updated" })
    end
    return HttpHelpers.error(server, client, 501, "Not available")
end

--- Возвращает список всех сетевых интерфейсов сервера
function SystemRoutes.get_network_interfaces(server, client, request)
    local interfaces = utils_ifaddrs and utils_ifaddrs() or {}
    return HttpHelpers.success(server, client, interfaces)
end

--- Возвращает имя хоста сервера
function SystemRoutes.get_hostname(server, client, request)
    return HttpHelpers.success(server, client, {
        hostname = utils_hostname and utils_hostname() or "unknown"
    })
end

return SystemRoutes
