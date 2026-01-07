--- @class MonitorRoutes
local MonitorRoutes = {}

-- 1. Стандартные Lua функции
local pairs = pairs
local table_insert = table.insert
local pcall = pcall

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")
local ChannelRepository = ModuleManager.get_module("channel_repository")
local Channel = ModuleManager.get_module("channel")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local timer = ModuleManager.get_global_dependency("timer")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "MonitorRoutes"

--- Возвращает список активных мониторов
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function MonitorRoutes.get_monitors(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local monitors = {}
    local active_channels = ChannelRepository and ChannelRepository:get_all() or {}
    
    for name, ch_obj in pairs(active_channels) do
        table_insert(monitors, {
            name = name,
            display_name = ch_obj._display_name,
            type = ch_obj._config and ch_obj._config.monitor_type or "output"
        })
    end

    HttpHelpers.success(server, client, monitors)
    return true
end

--- Возвращает сводный статус по всем мониторам
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function MonitorRoutes.get_monitors_status(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local total = 0
    local ok_count = 0
    local error_count = 0
    local total_cc_errors = 0

    local active_channels = ChannelRepository and ChannelRepository:get_all() or {}
    
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
    return true
end

--- Возвращает текущие метрики конкретного монитора
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function MonitorRoutes.get_monitor_data(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, {
        name = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local ch_obj = ChannelRepository and ChannelRepository:find(params.name)
    if not ch_obj then
        return HttpHelpers.error(server, client, 404, "Monitor not found")
    end

    -- Используем _json_cache напрямую для максимальной производительности
    if ch_obj._json_cache then
        HttpHelpers.send_raw_json(server, client, 200, ch_obj._json_cache)
        return true
    end

    -- Если кэша нет, возвращаем полный статус
    HttpHelpers.success(server, client, ch_obj:get_full_status())
    return true
end

--- Создает новый монитор (без создания канала)
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function MonitorRoutes.create_monitor(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local data = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(data, {
        name = { type = "string", required = true },
        monitor = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_or_err = Channel.make_monitor(data)
    if success and result_or_err then
        HttpHelpers.success(server, client, { message = "Monitor created" })
        return true
    else
        return false, result_or_err or "Failed to create monitor"
    end
end

--- Удаляет монитор (без удаления канала)
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function MonitorRoutes.kill_monitor(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, {
        name = { type = "string", required = true },
        reboot = { type = "boolean", required = false }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local name = params.name
    local reboot = params.reboot == true

    local config = Channel.kill_monitor(name)
    if not config then 
        return HttpHelpers.error(server, client, 404, "Monitor not found")
    end
    
    if reboot then
        if timer then
            timer({
                interval = 1,
                callback = function(self)
                    self:close()
                    Channel.make_monitor(config)
                end
            })
        else
            Channel.make_monitor(config)
        end
    end

    HttpHelpers.success(server, client, { 
        message = reboot and "Monitor rebooting" or "Monitor killed",
        config = config
    })
    return true
end

--- Обновляет параметры монитора
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function MonitorRoutes.update_monitor(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, {
        name = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_err = Channel.update_monitor_parameters(params.name, params)
    if success then
        HttpHelpers.success(server, client, { message = "Monitor updated" })
        return true
    else
        return false, result_err or "Failed to update monitor"
    end
end

--- Приостановка мониторинга канала
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function MonitorRoutes.pause_monitor(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, {
        name = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_err = Channel.pause_monitor(params.name)
    if success then
        HttpHelpers.success(server, client, { message = "Monitoring paused" })
        return true
    else
        return false, result_err or "Failed to pause monitor"
    end
end

--- Возобновление мониторинга канала
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function MonitorRoutes.resume_monitor(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, {
        name = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_err = Channel.resume_monitor(params.name)
    if success then
        HttpHelpers.success(server, client, { message = "Monitoring resumed" })
        return true
    else
        return false, result_err or "Failed to resume monitor"
    end
end

--- Получение статистики по PID
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function MonitorRoutes.get_monitor_pids(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, {
        name = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local ch_obj = ChannelRepository and ChannelRepository:find(params.name)
    if not ch_obj then
        return HttpHelpers.error(server, client, 404, "Monitor not found")
    end

    HttpHelpers.success(server, client, ch_obj:get_stats())
    return true
end

--- Получение статистики по битрейту
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function MonitorRoutes.get_monitor_rate_stat(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, {
        name = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local ch_obj = ChannelRepository and ChannelRepository:find(params.name)
    if not ch_obj then
        return HttpHelpers.error(server, client, 404, "Monitor not found")
    end

    HttpHelpers.success(server, client, ch_obj:get_rate_stat() or {})
    return true
end

--- Очистка статистики по PID и битрейту
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function MonitorRoutes.clear_monitor_pids(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, {
        name = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local ch_obj = ChannelRepository and ChannelRepository:find(params.name)
    if not ch_obj then
        return HttpHelpers.error(server, client, 404, "Monitor not found")
    end

    ch_obj:clear_stats()
    HttpHelpers.success(server, client, { message = "PID and rate stats cleared" })
    return true
end

return MonitorRoutes
