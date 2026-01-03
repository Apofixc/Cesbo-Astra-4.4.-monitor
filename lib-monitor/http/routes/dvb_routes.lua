--- @class DvbRoutes
local DvbRoutes = {}

-- 1. Стандартные Lua функции
local pairs = pairs
local table_insert = table.insert
local type = type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")
local DvbStorage = ModuleManager.get_module("dvb_storage")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local dvb_tune = ModuleManager.get_global_dependency("dvb_tune")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "DvbRoutes"

--- Возвращает список используемых DVB-адаптеров
--- @param server table
--- @param client table
--- @param request table
function DvbRoutes.get_adapters(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local adapters = {}
    local active_adapters = DvbStorage and DvbStorage.get_all and DvbStorage.get_all() or {}
    
    for id, dvb_obj in pairs(active_adapters) do
        table_insert(adapters, {
            id = id,
            name = dvb_obj.name or id,
            type = dvb_obj.type
        })
    end

    HttpHelpers.success(server, client, { adapters = adapters })
end

--- Запуск быстрого сканирования адаптера
--- @param server table
--- @param client table
--- @param request table
function DvbRoutes.scan_adapters(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    -- Логика сканирования зависит от возможностей Astra
    -- Обычно это вызов dvb_tune с последующим анализом
    HttpHelpers.success(server, client, { message = "Scan started" })
end

--- Возвращает состояние тюнера (Signal, SNR, BER, Lock)
--- @param server table
--- @param client table
--- @param request table
function DvbRoutes.get_adapter_data(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id = request.path:match("/api/dvb/adapters/([^/]+)/data")
    local dvb_obj = DvbStorage and DvbStorage.get(id)
    if not dvb_obj then
        return HttpHelpers.error(server, client, 404, "Adapter not found")
    end

    HttpHelpers.success(server, client, {
        adapter_data = {
            id = id,
            status = dvb_obj.status or 0,
            signal = dvb_obj.signal or 0,
            snr = dvb_obj.snr or 0,
            ber = dvb_obj.ber or 0,
            unc = dvb_obj.unc or 0,
            lock = dvb_obj.lock or false
        }
    })
end

--- Возвращает таблицу PSI для адаптера
--- @param server table
--- @param client table
--- @param request table
function DvbRoutes.get_adapter_psi(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id = request.path:match("/api/dvb/adapters/([^/]+)/psi")
    local dvb_obj = DvbStorage and DvbStorage.get(id)
    if not dvb_obj then
        return HttpHelpers.error(server, client, 404, "Adapter not found")
    end

    HttpHelpers.success(server, client, {
        psi = dvb_obj.psi_data or {}
    })
end

--- Настройка частоты (смена источника сигнала)
--- @param server table
--- @param client table
--- @param request table
function DvbRoutes.tune_adapter(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id = request.path:match("/api/dvb/adapters/([^/]+)/tune")
    local dvb_obj = DvbStorage and DvbStorage.get(id)
    if not dvb_obj then
        return HttpHelpers.error(server, client, 404, "Adapter not found")
    end

    local data = request.query
    if request.content_type == "application/json" and request.content then
        local json_decode = ModuleManager.get_global_dependency("json.decode")
        local ok, decoded = pcall(json_decode, request.content)
        if ok then data = decoded end
    end

    if not data or not data.tp then
        return HttpHelpers.error(server, client, 400, "Tuning parameters (tp) required")
    end

    -- Вызов функции настройки Astra
    local success, err = Logger.with_error(dvb_tune, data)
    if success then
        HttpHelpers.success(server, client, { message = "Adapter tuning started" })
    else
        HttpHelpers.error(server, client, 500, err or "Failed to tune adapter")
    end
end

--- Обновление параметров мониторинга адаптера
--- @param server table
--- @param client table
--- @param request table
function DvbRoutes.update_adapter(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id = request.path:match("/api/dvb/adapters/([^/]+)/update")
    local dvb_obj = DvbStorage and DvbStorage.get(id)
    if not dvb_obj then
        return HttpHelpers.error(server, client, 404, "Adapter not found")
    end

    local data = request.query
    if request.content_type == "application/json" and request.content then
        local json_decode = ModuleManager.get_global_dependency("json.decode")
        local ok, decoded = pcall(json_decode, request.content)
        if ok then data = decoded end
    end

    if dvb_obj.update_parameters then
        local success, err = Logger.with_error(dvb_obj.update_parameters, dvb_obj, data)
        if success then
            HttpHelpers.success(server, client, { message = "Adapter monitor updated" })
        else
            HttpHelpers.error(server, client, 500, err or "Failed to update adapter monitor")
        end
    else
        HttpHelpers.error(server, client, 501, "Update method not implemented for this adapter")
    end
end

return DvbRoutes
