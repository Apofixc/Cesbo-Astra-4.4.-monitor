--- @class DvbRoutes
local DvbRoutes = {}

-- 1. Стандартные Lua функции
local pairs = pairs
local ipairs = ipairs
local type = type
local table_insert = table.insert
local pcall = pcall

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
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.get_adapters(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local list = dvbls and dvbls() or {}
    local adapters = {}
    for id, data in pairs(list) do
        table_insert(adapters, data)
    end

    HttpHelpers.success(server, client, adapters)
end

--- Возвращает список адаптеров, находящихся под мониторингом
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.get_monitored_adapters(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local active_adapters = DvbRepository and DvbRepository.get_all and DvbRepository:get_all() or {}
    local list = {}
    for name in pairs(active_adapters) do
        list[name] = name
    end

    HttpHelpers.success(server, client, list)
end

--- Запуск сканирования адаптеров (заглушка)
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.scan_adapters(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    HttpHelpers.error(server, client, 501, "Scan not implemented in this version")
end

--- Возвращает текущие метрики конкретного DVB адаптера
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.get_adapter_data(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local name = params.name
    if not name then
        return HttpHelpers.error(server, client, 400, "Adapter name is required")
    end

    local dvb_obj = DvbRepository and DvbRepository:find(name)
    if not dvb_obj then
        return HttpHelpers.error(server, client, 404, "Adapter monitor not found")
    end

    if dvb_obj._json_cache then
        return HttpHelpers.send_raw_json(server, client, 200, dvb_obj._json_cache)
    end

    HttpHelpers.success(server, client, dvb_obj:get_full_status())
end

--- Обновляет параметры мониторинга DVB адаптера
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.update_adapter(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local name = params.name
    if not name then return HttpHelpers.error(server, client, 400, "Adapter name required") end

    local success, err = Logger.with_error(Adapter.update_dvb_monitor_parameters, name, params)
    if success then
        HttpHelpers.success(server, client, { message = "Adapter monitor updated" })
    else
        HttpHelpers.error(server, client, 500, err or "Failed to update adapter monitor")
    end
end

--- Останавливает мониторинг DVB адаптера
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.stop_adapter(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local name = params.name
    if not name then return HttpHelpers.error(server, client, 400, "Adapter name required") end

    local force = params.force == "true" or params.force == true

    local success, result_or_err = Logger.with_error(Adapter.stop_dvb_monitor, name, force)
    if success and result_or_err then
        HttpHelpers.success(server, client, { 
            message = "Adapter stopped successfully",
            config = result_or_err
        })
    else
        HttpHelpers.error(server, client, 500, result_or_err or "Failed to stop adapter monitor")
    end
end

--- Возвращает PSI данные DVB адаптера
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.get_adapter_psi(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local name = params.name
    local table_name = params.table

    if not name then
        return HttpHelpers.error(server, client, 400, "Adapter name is required")
    end

    local dvb_obj = DvbRepository and DvbRepository:find(name)
    if not dvb_obj then
        return HttpHelpers.error(server, client, 404, "Adapter monitor not found")
    end

    local psi = dvb_obj:get_psi() or {}
    if table_name then
        local table_data = psi[table_name:upper()]
        if not table_data then
            return HttpHelpers.error(server, client, 404, "PSI table not found")
        end
        return HttpHelpers.success(server, client, table_data)
    end

    psi.adapter_name = name
    HttpHelpers.success(server, client, psi)
end

--- Запускает обновление PSI данных на адаптере
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.update_adapter_psi(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local name = params.name
    if not name then return HttpHelpers.error(server, client, 400, "Adapter name required") end

    local dvb_obj = DvbRepository and DvbRepository:find(name)
    if not dvb_obj then
        return HttpHelpers.error(server, client, 404, "Adapter monitor not found")
    end

    dvb_obj:psi_update()
    HttpHelpers.success(server, client, { message = "PSI update started" })
end

--- Настройка адаптера на частоту и запуск мониторинга
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.tune_adapter(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local data = HttpHelpers.get_params(request)

    local success, result_or_err = Logger.with_error(Adapter.dvb_tuner_monitor, data)
    if success and result_or_err then
        HttpHelpers.success(server, client, { message = "Adapter tuning and monitoring started" })
    else
        HttpHelpers.error(server, client, 500, result_or_err or "Failed to tune adapter")
    end
end

--- Переключение транспондера
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.switch_transponder(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local data = HttpHelpers.get_params(request)
    local name = data.name
    if not name then return HttpHelpers.error(server, client, 400, "Adapter name required") end

    local success, result_or_err = Logger.with_error(Adapter.switch_transponder, name, data, data.reserve_input)
    if success and result_or_err then
        HttpHelpers.success(server, client, { 
            message = "Transponder switched successfully",
            backup = result_or_err
        })
    else
        HttpHelpers.error(server, client, 500, result_or_err or "Failed to switch transponder")
    end
end

--- Приостановка мониторинга адаптера
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.pause_adapter(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local name = params.name
    if not name then return HttpHelpers.error(server, client, 400, "Adapter name required") end

    local success, err = Logger.with_error(Adapter.pause_dvb_monitor, name)
    if success then
        HttpHelpers.success(server, client, { message = "Adapter monitoring paused" })
    else
        HttpHelpers.error(server, client, 500, err or "Failed to pause adapter monitor")
    end
end

--- Возобновление мониторинга адаптера
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.resume_adapter(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local name = params.name
    if not name then return HttpHelpers.error(server, client, 400, "Adapter name required") end

    local success, err = Logger.with_error(Adapter.resume_dvb_monitor, name)
    if success then
        HttpHelpers.success(server, client, { message = "Adapter monitoring resumed" })
    else
        HttpHelpers.error(server, client, 500, err or "Failed to resume adapter monitor")
    end
end

--- Перезапуск мониторинга адаптера
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.restart_adapter(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local name = params.name
    if not name then return HttpHelpers.error(server, client, 400, "Adapter name required") end

    local force = params.force == "true" or params.force == true

    local success, err = Logger.with_error(Adapter.restart_dvb_monitor, name, force, params)
    if success then
        HttpHelpers.success(server, client, { message = "Adapter restarted successfully" })
    else
        HttpHelpers.error(server, client, 500, err or "Failed to restart adapter monitor")
    end
end

--- Возвращает список всех физических адаптеров
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.get_hardware_all(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local list = dvbls and dvbls() or {}
    HttpHelpers.success(server, client, list)
end

return DvbRoutes
