--- @class MonitorRoutes
local MonitorRoutes = {}

-- 1. Стандартные Lua функции
local pairs = pairs
local table_insert = table.insert

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")
local ChannelStorage = ModuleManager.get_module("channel_storage")
local Channel = ModuleManager.get_module("channel")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local json_decode = ModuleManager.get_global_dependency("json.decode")
local timer = ModuleManager.get_global_dependency("timer")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "MonitorRoutes"

--- Возвращает список активных мониторов
--- @param server table
--- @param client table
--- @param request table
function MonitorRoutes.get_monitors(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local monitors = {}
    local active_channels = ChannelStorage and ChannelStorage.get_all and ChannelStorage.get_all() or {}
    
    for name, ch_obj in pairs(active_channels) do
        table_insert(monitors, {
            name = name,
            display_name = ch_obj.display_name,
            type = ch_obj._config and ch_obj._config.monitor_type or "output"
        })
    end

    HttpHelpers.success(server, client, monitors)
end

--- Возвращает сводный статус по всем мониторам
--- @param server table
--- @param client table
--- @param request table
function MonitorRoutes.get_monitors_status(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local total = 0
    local ok_count = 0
    local error_count = 0
    local total_cc_errors = 0

    local active_channels = ChannelStorage and ChannelStorage.get_all and ChannelStorage.get_all() or {}
    
    for _, ch_obj in pairs(active_channels) do
        total = total + 1
        local status = ch_obj._status or {}
        if status.ready then
            ok_count = ok_count + 1
        else
            error_count = error_count + 1
        end
        total_cc_errors = total_cc_errors + (status.cc_errors or 0)
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
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local name = request.path:match("/api/monitors/([^/]+)/data")
    if not name then
        return HttpHelpers.error(server, client, 400, "Monitor name is required")
    end

    local ch_obj = ChannelStorage and ChannelStorage.find(name)
    if not ch_obj then
        return HttpHelpers.error(server, client, 404, "Monitor not found")
    end

    -- Используем _json_cache напрямую для максимальной производительности
    if ch_obj._json_cache then
        return HttpHelpers.send_raw_json(server, client, 200, ch_obj._json_cache)
    end

    -- Если кэша нет, возвращаем полный статус
    HttpHelpers.success(server, client, ch_obj:get_full_status())
end

--- Создает новый монитор (без создания канала)
--- @param server table
--- @param client table
--- @param request table
function MonitorRoutes.create_monitor(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local data = request.query
    if request.content_type == "application/json" and request.content then
        local ok, decoded = pcall(json_decode, request.content)
        if ok then data = decoded end
    end

    if not data or not data.monitor or not data.name then
        return HttpHelpers.error(server, client, 400, "Name and monitor address are required")
    end

    local success, result_or_err = Logger.with_error(Channel.make_monitor, data, data.channel_data or data.name)
    if success and result_or_err then
        HttpHelpers.success(server, client, { message = "Monitor created" })
    else
        HttpHelpers.error(server, client, 500, result_or_err or "Failed to create monitor")
    end
end

--- Удаляет монитор (без удаления канала)
--- @param server table
--- @param client table
--- @param request table
function MonitorRoutes.kill_monitor(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local name = request.path:match("/api/monitors/([^/]+)/kill")
    if not name then return HttpHelpers.error(server, client, 400, "Monitor name is required") end

    local reboot = request.query and (request.query.reboot == "true" or request.query.reboot == true)

    local success, result_or_err = Logger.with_error(function()
        local config = Channel.kill_monitor(name)
        if not config then return false, "Failed to kill monitor" end
        
        if reboot then
            if timer then
                timer({
                    interval = 1,
                    count = 1,
                    callback = function()
                        Channel.make_monitor(config, config.channel_data or config.name)
                    end
                })
            else
                Channel.make_monitor(config, config.channel_data or config.name)
            end
        end
        return config
    end)

    if success and result_or_err then
        HttpHelpers.success(server, client, { 
            message = reboot and "Monitor rebooting" or "Monitor killed",
            config = result_or_err
        })
    else
        HttpHelpers.error(server, client, 500, result_or_err or "Failed to kill monitor")
    end
end

--- Обновляет параметры монитора
--- @param server table
--- @param client table
--- @param request table
function MonitorRoutes.update_monitor(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local name = request.path:match("/api/monitors/([^/]+)/update")
    if not name then return HttpHelpers.error(server, client, 400, "Monitor name required") end

    local data = request.query
    if request.content_type == "application/json" and request.content then
        local ok, decoded = pcall(json_decode, request.content)
        if ok then data = decoded end
    end

    local success, err = Logger.with_error(Channel.update_monitor_parameters, name, data)
    if success then
        HttpHelpers.success(server, client, { message = "Monitor updated" })
    else
        HttpHelpers.error(server, client, 500, err or "Failed to update monitor")
    end
end

--- Приостановка мониторинга канала
--- @param server table
--- @param client table
--- @param request table
function MonitorRoutes.pause_monitor(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local name = request.path:match("/api/monitors/([^/]+)/pause")
    if not name then
        return HttpHelpers.error(server, client, 400, "Monitor name is required")
    end

    local success, err = Logger.with_error(Channel.pause_monitor, name)
    if success then
        HttpHelpers.success(server, client, { message = "Monitoring paused" })
    else
        HttpHelpers.error(server, client, 500, err or "Failed to pause monitor")
    end
end

--- Возобновление мониторинга канала
--- @param server table
--- @param client table
--- @param request table
function MonitorRoutes.resume_monitor(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local name = request.path:match("/api/monitors/([^/]+)/resume")
    if not name then
        return HttpHelpers.error(server, client, 400, "Monitor name is required")
    end

    local success, err = Logger.with_error(Channel.resume_monitor, name)
    if success then
        HttpHelpers.success(server, client, { message = "Monitoring resumed" })
    else
        HttpHelpers.error(server, client, 500, err or "Failed to resume monitor")
    end
end

--- Получение статистики по PID
--- @param server table
--- @param client table
--- @param request table
function MonitorRoutes.get_monitor_pids(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local name = request.path:match("/api/monitors/([^/]+)/pids")
    if not name then
        return HttpHelpers.error(server, client, 400, "Monitor name is required")
    end

    local ch_obj = ChannelStorage and ChannelStorage.find(name)
    if not ch_obj then
        return HttpHelpers.error(server, client, 404, "Monitor not found")
    end

    HttpHelpers.success(server, client, ch_obj:get_stats())
end

--- Получение статистики по битрейту
--- @param server table
--- @param client table
--- @param request table
function MonitorRoutes.get_monitor_rate_stat(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local name = request.path:match("/api/monitors/([^/]+)/rate_stat")
    if not name then
        return HttpHelpers.error(server, client, 400, "Monitor name is required")
    end

    local ch_obj = ChannelStorage and ChannelStorage.find(name)
    if not ch_obj then
        return HttpHelpers.error(server, client, 404, "Monitor not found")
    end

    HttpHelpers.success(server, client, ch_obj:get_rate_stat() or {})
end

--- Очистка статистики по PID и битрейту
--- @param server table
--- @param client table
--- @param request table
function MonitorRoutes.clear_monitor_pids(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local name = request.path:match("/api/monitors/([^/]+)/pids/clear")
    if not name then
        return HttpHelpers.error(server, client, 400, "Monitor name is required")
    end

    local ch_obj = ChannelStorage and ChannelStorage.find(name)
    if not ch_obj then
        return HttpHelpers.error(server, client, 404, "Monitor not found")
    end

    ch_obj:clear_stats()
    HttpHelpers.success(server, client, { message = "PID and rate stats cleared" })
end

return MonitorRoutes
