--- @class SystemRoutes
local SystemRoutes = {}

-- 1. Стандартные Lua функции
local os_time = os.time
local os_date = os.date
local tostring = tostring

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")
local ResourceMonitor = ModuleManager.get_module("resource_monitor")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local astra_version = ModuleManager.get_global_dependency("astra.version")
local astra_reload = ModuleManager.get_global_dependency("astra.reload")
local astra_exit = ModuleManager.get_global_dependency("astra.exit")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "SystemRoutes"

--- Возвращает информацию о версии Astra и аптайме
--- @param server table
--- @param client table
--- @param request table
function SystemRoutes.get_env_astra(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local report = ResourceMonitor and ResourceMonitor.get_report and ResourceMonitor.get_report() or {}
    HttpHelpers.success(server, client, {
        astra = {
            version = astra_version or "unknown",
            uptime = report.timestamp and (os_time() - report.timestamp) or 0
        }
    })
end

--- Возвращает метрики CPU, RAM, Disk, Network
--- @param server table
--- @param client table
--- @param request table
function SystemRoutes.get_resources(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local report = ResourceMonitor and ResourceMonitor.get_report and ResourceMonitor.get_report() or {}
    HttpHelpers.success(server, client, { resources = report })
end

--- Возвращает статистику работы ResourceMonitor
--- @param server table
--- @param client table
--- @param request table
function SystemRoutes.get_monitor_stats(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    HttpHelpers.success(server, client, {
        stats = {
            is_running = ResourceMonitor and ResourceMonitor.is_running and ResourceMonitor.is_running() or false,
            pid = ResourceMonitor and ResourceMonitor._pid
        }
    })
end

--- Проверяет состояние сервера
--- @param server table
--- @param client table
--- @param request table
function SystemRoutes.get_health(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    HttpHelpers.success(server, client, {
        status = "healthy",
        pid = ResourceMonitor and ResourceMonitor._pid,
        astra_version = astra_version or "unknown",
        server_time = os_date("%Y-%m-%d %H:%M:%S")
    })
end

--- Перезагружает Astra
--- @param server table
--- @param client table
--- @param request table
function SystemRoutes.reload(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local delay = request.query and tonumber(request.query.delay) or 1
    
    -- Используем таймер для отложенной перезагрузки, чтобы успеть отправить ответ
    local timer = ModuleManager.get_global_dependency("timer")
    if timer then
        timer({
            interval = delay,
            count = 1,
            callback = function()
                if astra_reload then astra_reload() end
            end
        })
        HttpHelpers.success(server, client, { message = "Astra reload scheduled in " .. delay .. "s" })
    else
        if astra_reload then astra_reload() end
        HttpHelpers.success(server, client, { message = "Astra reloading" })
    end
end

--- Останавливает Astra
--- @param server table
--- @param client table
--- @param request table
function SystemRoutes.exit(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local delay = request.query and tonumber(request.query.delay) or 1
    
    local timer = ModuleManager.get_global_dependency("timer")
    if timer then
        timer({
            interval = delay,
            count = 1,
            callback = function()
                if astra_exit then astra_exit() end
            end
        })
        HttpHelpers.success(server, client, { message = "Astra exit scheduled in " .. delay .. "s" })
    else
        if astra_exit then astra_exit() end
        HttpHelpers.success(server, client, { message = "Astra exiting" })
    end
end

--- Очищает кэш системных метрик
--- @param server table
--- @param client table
--- @param request table
function SystemRoutes.clear_cache(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    if ResourceMonitor and ResourceMonitor.clear_cache then
        ResourceMonitor.clear_cache()
        HttpHelpers.success(server, client, { message = "Cache cleared" })
    else
        HttpHelpers.error(server, client, 501, "Clear cache not implemented")
    end
end

return SystemRoutes
