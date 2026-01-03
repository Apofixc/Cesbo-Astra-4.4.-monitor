--- @class MonitorRoutes
local MonitorRoutes = {}

-- 1. Стандартные Lua функции
local pairs = pairs
local table_insert = table.insert

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")
local ChannelStorage = ModuleManager.get_module("channel_storage")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- (Добавьте зависимости если нужны)

-- 4. Константы и конфигурации
local COMPONENT_NAME = "MonitorRoutes"

--- Возвращает список активных мониторов
--- @param server table
--- @param client table
--- @param request table
function MonitorRoutes.get_monitors(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local monitors = {}
    local active_channels = ChannelStorage and ChannelStorage.get_all and ChannelStorage.get_all() or {}
    
    for id, ch_obj in pairs(active_channels) do
        if ch_obj.monitor then
            table_insert(monitors, {
                id = id,
                name = ch_obj.monitor.name or id,
                type = ch_obj.monitor.monitor_type
            })
        end
    end

    HttpHelpers.success(server, client, { monitors = monitors })
end

--- Возвращает сводный статус по всем мониторам
--- @param server table
--- @param client table
--- @param request table
function MonitorRoutes.get_monitors_status(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local total = 0
    local ok_count = 0
    local error_count = 0
    local total_cc_errors = 0

    local active_channels = ChannelStorage and ChannelStorage.get_all and ChannelStorage.get_all() or {}
    
    for _, ch_obj in pairs(active_channels) do
        if ch_obj.monitor then
            total = total + 1
            if ch_obj.last_status == "OK" then
                ok_count = ok_count + 1
            else
                error_count = error_count + 1
            end
            total_cc_errors = total_cc_errors + (ch_obj.cc_errors or 0)
        end
    end

    HttpHelpers.success(server, client, {
        total = total,
        ok = ok_count,
        error = error_count,
        total_cc_errors = total_cc_errors
    })
end

--- Возвращает текущие метрики конкретного монитора
--- @param server table
--- @param client table
--- @param request table
function MonitorRoutes.get_monitor_data(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id = request.path:match("/api/monitors/([^/]+)/data")
    local ch_obj = ChannelStorage and ChannelStorage.get(id)
    if not ch_obj or not ch_obj.monitor then
        return HttpHelpers.error(server, client, 404, "Monitor not found")
    end

    HttpHelpers.success(server, client, {
        monitor_data = {
            id = id,
            status = ch_obj.last_status or "UNKNOWN",
            bitrate = ch_obj.bitrate or 0,
            cc_errors = ch_obj.cc_errors or 0,
            pes_errors = ch_obj.pes_errors or 0,
            scrambled = ch_obj.scrambled or false,
            ready = ch_obj.ready or false
        }
    })
end

--- Обновляет параметры монитора
--- @param server table
--- @param client table
--- @param request table
function MonitorRoutes.update_monitor(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id = request.path:match("/api/monitors/([^/]+)/update")
    local ch_obj = ChannelStorage and ChannelStorage.get(id)
    if not ch_obj or not ch_obj.monitor then
        return HttpHelpers.error(server, client, 404, "Monitor not found")
    end

    local data = request.query
    if request.content_type == "application/json" and request.content then
        local json_decode = ModuleManager.get_global_dependency("json.decode")
        local ok, decoded = pcall(json_decode, request.content)
        if ok then data = decoded end
    end

    if not data then
        return HttpHelpers.error(server, client, 400, "Update parameters required")
    end

    -- Вызов метода обновления в объекте монитора
    if ch_obj.monitor.update_parameters then
        local success, err = Logger.with_error(ch_obj.monitor.update_parameters, ch_obj.monitor, data)
        if success then
            HttpHelpers.success(server, client, { message = "Monitor updated" })
        else
            HttpHelpers.error(server, client, 500, err or "Failed to update monitor")
        end
    else
        HttpHelpers.error(server, client, 501, "Update method not implemented for this monitor")
    end
end

return MonitorRoutes
