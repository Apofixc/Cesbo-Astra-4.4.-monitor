--- @class CasRoutes
local CasRoutes = {}

-- 1. Стандартные Lua функции
local pairs = pairs
local table_insert = table.insert
local type = type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local softcam_list = ModuleManager.get_global_dependency("softcam_list")
local find_channel = ModuleManager.get_global_dependency("find_channel")
local json_decode = ModuleManager.get_global_dependency("json.decode")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "CasRoutes"

--- Возвращает список всех активных Softcam-клиентов
--- @param server table
--- @param client table
--- @param request table
function CasRoutes.get_softcams(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local list = {}
    if softcam_list then
        for id, cam in pairs(softcam_list) do
            table_insert(list, {
                id = id,
                config = cam.config or {}
            })
        end
    end

    HttpHelpers.success(server, client, list)
end

--- Создает нового Softcam-клиента
--- @param server table
--- @param client table
--- @param request table
function CasRoutes.create_softcam(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local data = request.query
    if request.content_type == "application/json" and request.content then
        local ok, decoded = pcall(json_decode, request.content)
        if ok then data = decoded end
    end

    if not data or not data.type then
        return HttpHelpers.error(server, client, 400, "Softcam type is required")
    end

    -- В Astra создание softcam обычно делается через глобальные функции или напрямую
    -- Здесь должна быть логика инициализации softcam
    HttpHelpers.error(server, client, 501, "Softcam creation not implemented via API yet")
end

--- Останавливает работу Softcam-клиента
--- @param server table
--- @param client table
--- @param request table
function CasRoutes.stop_softcam(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id = request.path:match("/api/cas/softcam/([^/]+)/stop")
    if not id then return HttpHelpers.error(server, client, 400, "Softcam ID required") end

    if softcam_list and softcam_list[id] then
        local cam = softcam_list[id]
        if cam.close then
            cam:close()
            return HttpHelpers.success(server, client, { message = "Softcam stopped" })
        end
    end

    HttpHelpers.error(server, client, 404, "Softcam not found or cannot be closed")
end

--- Перезагружает Softcam-клиента
--- @param server table
--- @param client table
--- @param request table
function CasRoutes.restart_softcam(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id = request.path:match("/api/cas/softcam/([^/]+)/restart")
    if not id then return HttpHelpers.error(server, client, 400, "Softcam ID required") end

    -- Логика перезапуска: закрыть и открыть заново с тем же конфигом
    HttpHelpers.error(server, client, 501, "Softcam restart not implemented")
end

--- Динамическое обновление BISS-ключа для канала
--- @param server table
--- @param client table
--- @param request table
function CasRoutes.update_biss(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local data = request.query
    if request.content_type == "application/json" and request.content then
        local ok, decoded = pcall(json_decode, request.content)
        if ok then data = decoded end
    end

    if not data or not data.name or not data.biss then
        return HttpHelpers.error(server, client, 400, "Channel name and BISS key are required")
    end

    local ch_data = find_channel(data.name)
    if not ch_data then
        return HttpHelpers.error(server, client, 404, "Channel not found")
    end

    -- Логика обновления BISS ключа в модуле decrypt
    -- Обычно это поиск модуля decrypt в цепочке ch_data и вызов метода обновления
    HttpHelpers.error(server, client, 501, "BISS update not implemented")
end

return CasRoutes
