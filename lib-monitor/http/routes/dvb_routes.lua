--- @class DvbRoutes
local DvbRoutes = {}

-- 1. Стандартные Lua функции
local pairs = pairs
local table_insert = table.insert
local type = type
local pcall = pcall
local tostring = tostring

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")
local DvbRepository = ModuleManager.get_module("dvb_repository")
local Adapter = ModuleManager.get_module("adapter")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local dvb_tune = ModuleManager.get_global_dependency("dvb_tune")
local dvb_input_instance_list = ModuleManager.get_global_dependency("dvb_input_instance_list")
local dvb_list = ModuleManager.get_global_dependency("dvb_list")
local dvbls = ModuleManager.get_global_dependency("dvbls")
local json_decode = ModuleManager.get_global_dependency("json.decode")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "DvbRoutes"

--- Возвращает список используемых DVB-адаптеров
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.get_adapters(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local adapters = {}
    -- Используем dvb_list как основной источник данных о тюнерах
    local list = dvb_list or {}
    
    for id, data in pairs(list) do
        table_insert(adapters, data)
    end

    -- Если dvb_list пуст, пробуем dvbls()
    if #adapters == 0 and dvbls then
        adapters = dvbls() or {}
    end

    HttpHelpers.success(server, client, adapters)
end

--- Возвращает список всех физических DVB-адаптеров, обнаруженных в системе
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.get_hardware_all(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local adapters = {}
    if dvbls then
        adapters = dvbls() or {}
    end

    HttpHelpers.success(server, client, adapters)
end

--- Возвращает список адаптеров с активным мониторингом
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.get_monitored_adapters(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local monitors = {}
    local active_adapters = DvbRepository and DvbRepository.get_all and DvbRepository:get_all() or {}
    
    for id, _ in pairs(active_adapters) do
        monitors[id] = id
    end

    HttpHelpers.success(server, client, monitors)
end

--- Запуск быстрого сканирования адаптера
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.scan_adapters(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    -- Логика сканирования зависит от возможностей Astra
    -- Обычно это вызов dvb_tune с последующим анализом
    HttpHelpers.error(server, client, 501, "Scan not implemented in this version")
end

--- Возвращает состояние тюнера (Signal, SNR, BER, Lock)
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.get_adapter_data(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local name = request.path:match("/api/dvb/adapters/([^/]+)/data")
    if not Adapter or not Adapter.get_full_status then
        return HttpHelpers.error(server, client, 500, "Adapter module not properly loaded")
    end
    local dvb_obj = DvbRepository and DvbRepository:find(name)
    if not dvb_obj then
        return HttpHelpers.error(server, client, 404, "Adapter not found")
    end

    -- Используем _json_cache напрямую для максимальной производительности
    if dvb_obj._json_cache then
        return HttpHelpers.send_raw_json(server, client, 200, dvb_obj._json_cache)
    end

    HttpHelpers.success(server, client, dvb_obj:get_full_status())
end

--- Возвращает таблицу PSI для адаптера
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.get_adapter_psi(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id, table_name = request.path:match("/api/dvb/adapters/([^/]+)/psi/([^/]+)$")
    if not id then
        id = request.path:match("/api/dvb/adapters/([^/]+)/psi")
    end

    local dvb_obj = DvbRepository and DvbRepository:find(id)
    if not dvb_obj then
        return HttpHelpers.error(server, client, 404, "Adapter not found")
    end

    local psi = dvb_obj:get_psi() or {}

    if table_name then
        local table_data = psi[table_name:upper()]
        if not table_data then
            return HttpHelpers.error(server, client, 404, "PSI table not found")
        end
        return HttpHelpers.success(server, client, table_data)
    end

    HttpHelpers.success(server, client, psi)
end

--- Настройка частоты (смена источника сигнала)
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.tune_adapter(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id = request.path:match("/api/dvb/adapters/([^/]+)/tune")
    if not id then
        return HttpHelpers.error(server, client, 400, "Adapter ID is required")
    end

    local data = request.query
    if request.content_type == "application/json" and request.content then
        local ok, decoded = pcall(json_decode, request.content)
        if ok then data = decoded end
    end

    if not data or not data.tp then
        return HttpHelpers.error(server, client, 400, "Tuning parameters (tp) required")
    end

    -- Убеждаемся, что имя адаптера соответствует ID из пути
    data.name_adapter = id

    -- Вызов функции настройки Astra
    if not Adapter or not Adapter.dvb_tuner_monitor then
        return HttpHelpers.error(server, client, 500, "Adapter module not properly loaded")
    end
    local success, err = Logger.with_error(Adapter.dvb_tuner_monitor, data)
    if success then
        HttpHelpers.success(server, client, { message = "Adapter tuning and monitoring started" })
    else
        HttpHelpers.error(server, client, 500, err or "Failed to tune adapter")
    end
end

--- Обновление параметров мониторинга адаптера
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.update_adapter(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id = request.path:match("/api/dvb/adapters/([^/]+)/update")
    if not id then return HttpHelpers.error(server, client, 400, "Adapter ID required") end

    local data = request.query
    if request.content_type == "application/json" and request.content then
        local ok, decoded = pcall(json_decode, request.content)
        if ok then data = decoded end
    end

    local success, err = Logger.with_error(Adapter.update_dvb_monitor_parameters, id, data)
    if success then
        HttpHelpers.success(server, client, { message = "Adapter monitor updated" })
    else
        HttpHelpers.error(server, client, 500, err or "Failed to update adapter monitor")
    end
end

--- Запуск обновления PSI таблиц
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.update_adapter_psi(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id = request.path:match("/api/dvb/adapters/([^/]+)/psi/update")
    if not id then
        return HttpHelpers.error(server, client, 400, "Adapter ID is required")
    end

    local success, err = Logger.with_error(Adapter.update_dvb_psi, id)
    if success then
        HttpHelpers.success(server, client, { message = "PSI update started" })
    else
        HttpHelpers.error(server, client, 500, err or "Failed to start PSI update")
    end
end

--- Переключение транспондера
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.switch_transponder(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id = request.path:match("/api/dvb/adapters/([^/]+)/switch%-transponder")
    local data = request.query
    if request.content_type == "application/json" and request.content then
        local ok, decoded = pcall(json_decode, request.content)
        if ok then data = decoded end
    end

    if not data or not data.tp then
        return HttpHelpers.error(server, client, 400, "New tuner parameters (tp) required")
    end

    local success, result_or_err = Logger.with_error(Adapter.switch_transponder, id, data, data.reserve_input)
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

    local id = request.path:match("/api/dvb/adapters/([^/]+)/pause")
    if not id then
        return HttpHelpers.error(server, client, 400, "Adapter ID is required")
    end

    local success, err = Logger.with_error(Adapter.pause_dvb_monitor, id)
    if success then
        HttpHelpers.success(server, client, { message = "Adapter monitoring paused" })
    else
        HttpHelpers.error(server, client, 500, err or "Failed to pause adapter")
    end
end

--- Возобновление мониторинга адаптера
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.resume_adapter(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id = request.path:match("/api/dvb/adapters/([^/]+)/resume")
    if not id then
        return HttpHelpers.error(server, client, 400, "Adapter ID is required")
    end

    local success, err = Logger.with_error(Adapter.resume_dvb_monitor, id)
    if success then
        HttpHelpers.success(server, client, { message = "Adapter monitoring resumed" })
    else
        HttpHelpers.error(server, client, 500, err or "Failed to resume adapter")
    end
end

--- Перезапуск мониторинга адаптера
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.restart_adapter(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id = request.path:match("/api/dvb/adapters/([^/]+)/restart")
    if not id then
        return HttpHelpers.error(server, client, 400, "Adapter ID is required")
    end

    local data = request.query
    if request.content_type == "application/json" and request.content then
        local ok, decoded = pcall(json_decode, request.content)
        if ok then data = decoded end
    end

    local force = data and (data.force == "true" or data.force == true)
    local success, err = Logger.with_error(Adapter.restart_dvb_monitor, id, data, force)
    if success then
        HttpHelpers.success(server, client, { message = "Adapter restarted successfully" })
    else
        HttpHelpers.error(server, client, 500, err or "Failed to restart adapter")
    end
end

--- Остановка мониторинга адаптера
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function DvbRoutes.stop_adapter(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id = request.path:match("/api/dvb/adapters/([^/]+)/kill")
    if not id then
        return HttpHelpers.error(server, client, 400, "Adapter ID is required")
    end

    local data = request.query
    local force = data and (data.force == "true" or data.force == true)
    
    local success, result_or_err = Logger.with_error(Adapter.stop_dvb_monitor, id, force)
    if success and result_or_err then
        HttpHelpers.success(server, client, { 
            message = "Adapter stopped successfully",
            config = result_or_err
        })
    else
        HttpHelpers.error(server, client, 500, result_or_err or "Failed to stop adapter")
    end
end

return DvbRoutes
