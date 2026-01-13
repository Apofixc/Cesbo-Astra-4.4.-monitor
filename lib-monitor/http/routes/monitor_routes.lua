--- @class MonitorRoutes
local MonitorRoutes = {}

-- 1. Стандартные Lua функции
local pairs = pairs
local table_insert = table.insert

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")
local ChannelRepository = ModuleManager.get_module("channel_repository")
local Channel = ModuleManager.get_module("channel")
local RoutesUtils = ModuleManager.get_module("routes_utils")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local timer = ModuleManager.get_global_dependency("timer")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "MonitorRoutes"

--- Возвращает список активных мониторов
function MonitorRoutes.get_monitors(server, client, request)
    local monitors = {}
    local active_channels = ChannelRepository and ChannelRepository:get_all() or {}

    for name, ch_obj in pairs(active_channels) do
        table_insert(monitors, {
            name = name,
            display_name = ch_obj._display_name,
            type = ch_obj._config and ch_obj._config.monitor_type or "output"
        })
    end

    return HttpHelpers.success(server, client, monitors)
end

--- Возвращает сводный статус по всем мониторам
function MonitorRoutes.get_monitors_status(server, client, request)
    local total, ok_count, error_count, total_cc_errors = 0, 0, 0, 0
    local active_channels = ChannelRepository and ChannelRepository:get_all() or {}

    for _, ch_obj in pairs(active_channels) do
        total = total + 1
        local status = ch_obj._status or {}
        if status.ready then ok_count = ok_count + 1 else error_count = error_count + 1 end
        total_cc_errors = total_cc_errors + (status.cc_errors or 0)
    end

    return HttpHelpers.success(server, client, {
        total = total, ok = ok_count, error = error_count, total_cc_errors = total_cc_errors
    })
end

--- Возвращает текущие метрики конкретного монитора
function MonitorRoutes.get_monitor_data(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local ch_obj = ChannelRepository and ChannelRepository:find(params.name)
    if not ch_obj then return HttpHelpers.error(server, client, 404, "Монитор не найден") end

    -- Оптимизация: используем горячий JSON-кэш монитора для мгновенного ответа
    local json_data = ch_obj:get_status_json()
    if json_data then
        return HttpHelpers.send_raw_json(server, client, 200, json_data)
    end

    return HttpHelpers.success(server, client, ch_obj:get_status_table())
end

--- Создает новый монитор (без создания канала)
function MonitorRoutes.create_monitor(server, client, request)
    local data = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(data, {
        name = { type = "string", required = true },
        monitor = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_or_err = Channel.make_monitor(data)
    if not success then return false, result_or_err or "Не удалось создать" end

    return HttpHelpers.success(server, client, { message = "Монитор создан" })
end

--- Удаляет монитор (без удаления канала)
function MonitorRoutes.kill_monitor(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, {
        name = { type = "string", required = true },
        reboot = { type = "boolean", required = false }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local config = Channel.kill_monitor(params.name)
    if not config then return HttpHelpers.error(server, client, 404, "Монитор не найден") end

    if params.reboot then
        if timer then
            timer({ interval = 1, callback = function(self) self:close(); Channel.make_monitor(config) end })
        else
            Channel.make_monitor(config)
        end
    end

    return HttpHelpers.success(server, client, {
        message = params.reboot and "Перезагрузка монитора" or "Монитор удален",
        config = config
    })
end

--- Обновляет параметры монитора
function MonitorRoutes.update_monitor(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_err = Channel.update_monitor_parameters(params.name, params)
    if not success then
        return HttpHelpers.error(server, client, 500, result_err or "Не удалось обновить")
    end

    return HttpHelpers.success(server, client, { message = "Монитор обновлен" })
end

--- Приостановка мониторинга канала
function MonitorRoutes.pause_monitor(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_err = Channel.pause_monitor(params.name)
    if not success then return false, result_err or "Не удалось приостановить" end

    return HttpHelpers.success(server, client, { message = "Мониторинг приостановлен" })
end

--- Возобновление мониторинга канала
function MonitorRoutes.resume_monitor(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_err = Channel.resume_monitor(params.name)
    if not success then return false, result_err or "Не удалось возобновить" end

    return HttpHelpers.success(server, client, { message = "Мониторинг возобновлен" })
end

--- Получение статистики по PID
function MonitorRoutes.get_monitor_pids(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local ch_obj = ChannelRepository and ChannelRepository:find(params.name)
    if not ch_obj then return HttpHelpers.error(server, client, 404, "Монитор не найден") end

    return HttpHelpers.success(server, client, ch_obj:get_stats())
end

--- Очистка статистики по PID и битрейту
function MonitorRoutes.clear_monitor_pids(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local ch_obj = ChannelRepository and ChannelRepository:find(params.name)
    if not ch_obj then return HttpHelpers.error(server, client, 404, "Монитор не найден") end

    ch_obj:clear_stats()
    return HttpHelpers.success(server, client, { message = "Статистика очищена" })
end

return MonitorRoutes
