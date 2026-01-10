--- @class SystemRoutes
local SystemRoutes = {}

-- 1. Стандартные Lua функции
local os_time = os.time
local os_date = os.date
local tonumber = tonumber
local collectgarbage = collectgarbage

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")
local ResourceMonitor = ModuleManager.get_module("resource_monitor")
local ChannelRepository = ModuleManager.get_module("repository.channel_repository")
local DvbRepository = ModuleManager.get_module("repository.dvb_repository")
-- local TablePool = ModuleManager.get_module("table_pool") -- Загружается динамически

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local astra_version = ModuleManager.get_global_dependency("astra.version")
local astra_reload = ModuleManager.get_global_dependency("astra.reload")
local astra_exit = ModuleManager.get_global_dependency("astra.exit")
local utils_ifaddrs = ModuleManager.get_global_dependency("utils.ifaddrs")
local utils_hostname = ModuleManager.get_global_dependency("utils.hostname")
local timer_obj = ModuleManager.get_global_dependency("timer")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "SystemRoutes"

--- Форматирует время в человекочитаемый вид
--- @param seconds number
--- @return string
local function format_uptime(seconds)
    local days = math.floor(seconds / 86400)
    local hours = math.floor((seconds % 86400) / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    return string.format("%dd %02dh %02dm", days, hours, minutes)
end

--- Проверяет состояние сервера и возвращает метрики ресурсов процесса
function SystemRoutes.get_health(server, client, request)
    local report = ResourceMonitor and ResourceMonitor.get_report and ResourceMonitor.get_report() or {}
    local HttpServer = ModuleManager.get_module("http_server")

    -- Добавляем мониторинг памяти Lua
    report.lua_mem_kb = collectgarbage("count")

    local status = "healthy"
    if report.cpu and report.cpu.usage and report.cpu.usage > 80 then
        status = "warning"
    end

    local response = {
        status = status,
        bind_address = HttpServer and HttpServer._bind_addr or "unknown",
        bind_port = HttpServer and HttpServer._bind_port or 0,
        astra_version = astra_version or "unknown",
        server_time = os_date("%Y-%m-%d %H:%M:%S"),
        timestamp = os_time(),
        uptime_human = format_uptime(report.uptime or 0),
        stats = {
            active_channels = ChannelRepository and ChannelRepository:count() or 0,
            active_adapters = DvbRepository and DvbRepository:count() or 0,
        },
        resources = report
    }
    return HttpHelpers.success(server, client, response)
end

--- Перезагружает Astra
function SystemRoutes.reload(server, client, request)
    local params = HttpHelpers.get_params(request)
    local delay = tonumber(params.delay) or 1

    if timer_obj then
        timer_obj({
            interval = delay,
            callback = function(self) self:close(); if astra_reload then astra_reload() end end
        })
        return HttpHelpers.success(server, client, { message = "Перезагрузка Astra запланирована через " .. delay .. " сек" })
    end

    if astra_reload then astra_reload() end
    return HttpHelpers.success(server, client, { message = "Перезагрузка Astra" })
end

--- Останавливает Astra
function SystemRoutes.exit(server, client, request)
    local params = HttpHelpers.get_params(request)
    local delay = tonumber(params.delay) or 1

    if timer_obj then
        timer_obj({ interval = delay, callback = function(self) self:close(); if astra_exit then astra_exit() end end })
        return HttpHelpers.success(server, client, { message = "Выход из Astra запланирован через " .. delay .. " сек" })
    end

    if astra_exit then astra_exit() end
    return HttpHelpers.success(server, client, { message = "Выход из Astra" })
end

--- Очищает кэш системных метрик
function SystemRoutes.clear_cache(server, client, request)
    if ResourceMonitor and ResourceMonitor.check then
        ResourceMonitor.check()
        return HttpHelpers.success(server, client, { message = "Метрики обновлены" })
    end
    return HttpHelpers.error(server, client, 501, "Недоступно")
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

--- Возвращает статистику использования пулов таблиц
function SystemRoutes.get_pool_stats(server, client, request)
    local TablePool = ModuleManager.get_module("table_pool")
    if not TablePool or not TablePool.get_stats then
        return HttpHelpers.error(server, client, 501, "TablePool недоступен")
    end
    return HttpHelpers.success(server, client, TablePool.get_stats())
end

return SystemRoutes
