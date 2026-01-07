--- @class DvbRoutes
local DvbRoutes = {}

-- 1. Стандартные Lua функции
local pairs = pairs
local table_insert = table.insert

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")
local Adapter = ModuleManager.get_module("adapter")
local DvbRepository = ModuleManager.get_module("dvb_repository")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local dvbls = ModuleManager.get_global_dependency("dvbls")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "DvbRoutes"

--- Возвращает список всех DVB адаптеров в системе
function DvbRoutes.get_adapters(server, client, request)
    local list = dvbls and dvbls() or {}
    local adapters = {}
    for _, data in pairs(list) do table_insert(adapters, data) end
    return HttpHelpers.success(server, client, adapters)
end

--- Возвращает список адаптеров, находящихся под мониторингом
function DvbRoutes.get_monitored_adapters(server, client, request)
    local active_adapters = DvbRepository and DvbRepository:get_all() or {}
    local list = {}
    for name in pairs(active_adapters) do list[name] = name end
    return HttpHelpers.success(server, client, list)
end

--- Запуск сканирования адаптеров (заглушка)
function DvbRoutes.scan_adapters(server, client, request)
    return HttpHelpers.error(server, client, 501, "Scan not implemented")
end

--- Возвращает текущие метрики конкретного DVB адаптера
function DvbRoutes.get_adapter_data(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local dvb_obj = DvbRepository and DvbRepository:find(params.name)
    if not dvb_obj then return HttpHelpers.error(server, client, 404, "Adapter not found") end

    if dvb_obj._json_cache then return HttpHelpers.send_raw_json(server, client, 200, dvb_obj._json_cache) end
    return HttpHelpers.success(server, client, dvb_obj:get_full_status())
end

--- Обновляет параметры мониторинга DVB адаптера
function DvbRoutes.update_adapter(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_err = Adapter.update_dvb_monitor_parameters(params.name, params)
    if not success then return false, result_err or "Failed to update" end

    return HttpHelpers.success(server, client, { message = "Adapter monitor updated" })
end

--- Останавливает мониторинг DVB адаптера
function DvbRoutes.stop_adapter(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, {
        name = { type = "string", required = true },
        force = { type = "boolean", required = false }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_or_err = Adapter.stop_dvb_monitor(params.name, params.force == true)
    if not success then return false, result_or_err or "Failed to stop" end

    return HttpHelpers.success(server, client, { message = "Adapter stopped", config = result_or_err })
end

--- Возвращает PSI данные DVB адаптера
function DvbRoutes.get_adapter_psi(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, {
        name = { type = "string", required = true },
        table = { type = "string", required = false }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local dvb_obj = DvbRepository and DvbRepository:find(params.name)
    if not dvb_obj then return HttpHelpers.error(server, client, 404, "Adapter not found") end

    local psi = dvb_obj:get_psi() or {}
    if params.table then
        local table_data = psi[params.table:upper()]
        if not table_data then return HttpHelpers.error(server, client, 404, "PSI table not found") end
        return HttpHelpers.success(server, client, table_data)
    end

    psi.adapter_name = params.name
    return HttpHelpers.success(server, client, psi)
end

--- Запускает обновление PSI данных на адаптере
function DvbRoutes.update_adapter_psi(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local dvb_obj = DvbRepository and DvbRepository:find(params.name)
    if not dvb_obj then return HttpHelpers.error(server, client, 404, "Adapter not found") end

    dvb_obj:psi_update()
    return HttpHelpers.success(server, client, { message = "PSI update started" })
end

--- Настройка адаптера на частоту и запуск мониторинга
function DvbRoutes.tune_adapter(server, client, request)
    local data = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(data, {
        name_adapter = { type = "string", required = true },
        tp = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_or_err = Adapter.dvb_tuner_monitor(data)
    if not success then return false, result_or_err or "Failed to tune" end

    return HttpHelpers.success(server, client, { message = "Adapter tuning started" })
end

--- Переключение транспондера
function DvbRoutes.switch_transponder(server, client, request)
    local data = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(data, {
        name = { type = "string", required = true },
        tp = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_or_err = Adapter.switch_transponder(data.name, data, data.reserve_input)
    if not success then return false, result_or_err or "Failed to switch" end

    return HttpHelpers.success(server, client, { message = "Transponder switched", backup = result_or_err })
end

--- Приостановка мониторинга адаптера
function DvbRoutes.pause_adapter(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_err = Adapter.pause_dvb_monitor(params.name)
    if not success then return false, result_err or "Failed to pause" end

    return HttpHelpers.success(server, client, { message = "Adapter paused" })
end

--- Возобновление мониторинга адаптера
function DvbRoutes.resume_adapter(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_err = Adapter.resume_dvb_monitor(params.name)
    if not success then return false, result_err or "Failed to resume" end

    return HttpHelpers.success(server, client, { message = "Adapter resumed" })
end

--- Перезапуск мониторинга адаптера
function DvbRoutes.restart_adapter(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, {
        name = { type = "string", required = true },
        force = { type = "boolean", required = false }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_err = Adapter.restart_dvb_monitor(params.name, params.force == true, params)
    if not success then return false, result_err or "Failed to restart" end

    return HttpHelpers.success(server, client, { message = "Adapter restarted" })
end

--- Возвращает список всех физических адаптеров
function DvbRoutes.get_hardware_all(server, client, request)
    local list = dvbls and dvbls() or {}
    return HttpHelpers.success(server, client, list)
end

return DvbRoutes
