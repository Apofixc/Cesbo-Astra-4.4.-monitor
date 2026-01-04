--- @class ChannelRoutes
local ChannelRoutes = {}

-- 1. Стандартные Lua функции
local pairs = pairs
local ipairs = ipairs
local type = type
local tonumber = tonumber

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")
local Channel = ModuleManager.get_module("channel")
local ChannelStorage = ModuleManager.get_module("channel_storage")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local find_channel = ModuleManager.get_global_dependency("find_channel")
local make_channel = ModuleManager.get_global_dependency("make_channel")
local kill_channel = ModuleManager.get_global_dependency("kill_channel")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ChannelRoutes"

--- Возвращает список всех каналов с их адресами вещания
--- @param server table
--- @param client table
--- @param request table
function ChannelRoutes.get_channels(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local channels = {}
    local active_channels = ChannelStorage and ChannelStorage.get_all and ChannelStorage.get_all() or {}
    
    for id, ch_obj in pairs(active_channels) do
        local ch_data = ch_obj._channel_data or {}
        table.insert(channels, {
            id = id,
            name = ch_data.name or id,
            display_name = ch_obj.display_name,
            output = ch_data.output or {}
        })
    end

    HttpHelpers.success(server, client, { channels = channels })
end

--- Возвращает агрегированную статистику по каналам
--- @param server table
--- @param client table
--- @param request table
function ChannelRoutes.get_channels_stats(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local total = 0
    local online = 0
    local offline = 0
    local with_errors = 0

    local active_channels = ChannelStorage and ChannelStorage.get_all and ChannelStorage.get_all() or {}
    
    for _, ch_obj in pairs(active_channels) do
        total = total + 1
        local status = ch_obj._status or {}
        if status.ready then
            online = online + 1
        else
            offline = offline + 1
        end
        if status.cc_errors and status.cc_errors > 0 then
            with_errors = with_errors + 1
        end
    end

    HttpHelpers.success(server, client, {
        total = total,
        online = online,
        offline = offline,
        with_errors = with_errors
    })
end

--- Возвращает детальную информацию о канале
--- @param server table
--- @param client table
--- @param request table
function ChannelRoutes.get_channel_info(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id = request.path:match("/api/channels/([^/]+)")
    if not id then
        return HttpHelpers.error(server, client, 400, "Channel ID is required")
    end

    local ch_obj = ChannelStorage and ChannelStorage.find and ChannelStorage.find(id)
    if not ch_obj or not ch_obj._channel_data then
        return HttpHelpers.error(server, client, 404, "Channel not found")
    end

    HttpHelpers.success(server, client, {
        channel = {
            id = id,
            name = ch_obj._channel_data.name,
            display_name = ch_obj.display_name,
            input = ch_obj._channel_data.input,
            output = ch_obj._channel_data.output,
            map = ch_obj._channel_data.map
        }
    })
end

--- Возвращает список входов канала и активный вход
--- @param server table
--- @param client table
--- @param request table
function ChannelRoutes.get_channel_inputs(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id = request.path:match("/api/channels/([^/]+)/inputs")
    local ch_obj = ChannelStorage and ChannelStorage.find(id)
    if not ch_obj or not ch_obj._channel_data then
        return HttpHelpers.error(server, client, 404, "Channel not found")
    end

    local active_input = ch_obj._last_active_id or 1
    
    HttpHelpers.success(server, client, {
        inputs = ch_obj._channel_data.input or {},
        active_input = active_input
    })
end

--- Возвращает данные PSI/SI канала
--- @param server table
--- @param client table
--- @param request table
function ChannelRoutes.get_channel_psi(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id = request.path:match("/api/channels/([^/]+)/psi")
    local ch_obj = ChannelStorage and ChannelStorage.find(id)
    if not ch_obj then
        return HttpHelpers.error(server, client, 404, "Channel not found")
    end

    HttpHelpers.success(server, client, {
        psi = ch_obj:get_psi() or {}
    })
end

--- Создает новый канал (Raw Astra Channel)
--- @param server table
--- @param client table
--- @param request table
function ChannelRoutes.create_channel_raw(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local data = request.query
    if request.content_type == "application/json" and request.content then
        local ok, decoded = pcall(json_decode, request.content)
        if ok then data = decoded end
    end

    if not data or not data.name or not data.input then
        return HttpHelpers.error(server, client, 400, "Name and input are required")
    end

    local success, err = Logger.with_error(make_channel, data)
    if success then
        HttpHelpers.success(server, client, { message = "Channel created" })
    else
        HttpHelpers.error(server, client, 500, err or "Failed to create channel")
    end
end

--- Удаляет или перезапускает канал (Raw Astra Channel)
--- @param server table
--- @param client table
--- @param request table
function ChannelRoutes.kill_channel_raw(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id = request.path:match("/api/channels/([^/]+)/kill")
    if not id then return HttpHelpers.error(server, client, 400, "Channel ID is required") end

    local reboot = request.query and (request.query.reboot == "true" or request.query.reboot == true)
    
    local success, err = Logger.with_error(kill_channel, { name = id, reboot = reboot })
    if success then
        HttpHelpers.success(server, client, { message = reboot and "Channel rebooting" or "Channel killed" })
    else
        HttpHelpers.error(server, client, 500, err or "Operation failed")
    end
end

--- Создает поток с мониторингом
--- @param server table
--- @param client table
--- @param request table
function ChannelRoutes.create_stream(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local data = request.query
    if request.content_type == "application/json" and request.content then
        local ok, decoded = pcall(json_decode, request.content)
        if ok then data = decoded end
    end

    if not data or not data.name or not data.input then
        return HttpHelpers.error(server, client, 400, "Name and input are required")
    end

    local success, result_or_err = Logger.with_error(Channel.make_stream, data)
    if success and result_or_err then
        HttpHelpers.success(server, client, { message = "Stream and monitor created" })
    else
        HttpHelpers.error(server, client, 500, result_or_err or "Failed to create stream")
    end
end

--- Удаляет поток и монитор
--- @param server table
--- @param client table
--- @param request table
function ChannelRoutes.kill_stream(server, client, request)
    if not HttpHelpers.check_auth(server, client, request) then return end

    local id = request.path:match("/api/streams/([^/]+)/kill")
    if not id then return HttpHelpers.error(server, client, 400, "Stream ID is required") end

    local success, result_or_err = Logger.with_error(Channel.kill_stream, id)
    if success and result_or_err then
        HttpHelpers.success(server, client, { 
            message = "Stream and monitor killed",
            config = result_or_err
        })
    else
        HttpHelpers.error(server, client, 500, result_or_err or "Failed to kill stream")
    end
end

return ChannelRoutes
