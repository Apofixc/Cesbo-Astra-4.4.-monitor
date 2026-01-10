--- @class ChannelRoutes
local ChannelRoutes = {}

-- 1. Стандартные Lua функции
local pairs = pairs
local table_insert = table.insert

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")
local Channel = ModuleManager.get_module("channel")
local ChannelRepository = ModuleManager.get_module("channel_repository")
local RoutesUtils = ModuleManager.get_module("routes_utils")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local find_channel = ModuleManager.get_global_dependency("find_channel")
local make_channel = ModuleManager.get_global_dependency("make_channel")
local kill_channel = ModuleManager.get_global_dependency("kill_channel")
local channel_list = ModuleManager.get_global_dependency("channel_list")
local timer = ModuleManager.get_global_dependency("timer")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ChannelRoutes"

--- Возвращает список всех каналов с их адресами вещания
function ChannelRoutes.get_channels(server, client, request)
    local channels = {}
    local list = channel_list or {}

    for _, ch_data in pairs(list) do
        local cfg = ch_data.config or {}
        local name = cfg.name
        if name then
            local ch_obj = ChannelRepository and ChannelRepository:find(name)
            table_insert(channels, {
                name = name,
                display_name = ch_obj and ch_obj._display_name or name,
                output = cfg.output or {}
            })
        end
    end

    return HttpHelpers.success(server, client, channels)
end

--- Возвращает агрегированную статистику по каналам
function ChannelRoutes.get_channels_stats(server, client, request)
    local total_astra_channels = 0
    if channel_list then
        for _ in pairs(channel_list) do total_astra_channels = total_astra_channels + 1 end
    end

    local total_monitored = ChannelRepository and ChannelRepository:count() or 0
    local online = 0
    local offline = 0
    local with_errors = 0

    local active_channels = ChannelRepository and ChannelRepository:get_all() or {}
    
    for _, ch_obj in pairs(active_channels) do
        local status = ch_obj._status or {}
        if status.ready then online = online + 1 else offline = offline + 1 end
        if (status.cc_errors or 0) > 0 then with_errors = with_errors + 1 end
    end

    return HttpHelpers.success(server, client, {
        total_astra_channels = total_astra_channels,
        total_monitored = total_monitored,
        online = online,
        offline = offline,
        with_errors = with_errors
    })
end

--- Возвращает детальную информацию о канале
function ChannelRoutes.get_channel_info(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local ch_data = find_channel(params.name)
    if not ch_data or not ch_data.config then
        return HttpHelpers.error(server, client, 404, "Channel not found")
    end

    return HttpHelpers.success(server, client, ch_data.config)
end

--- Возвращает список входов канала и активный вход
function ChannelRoutes.get_channel_inputs(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local ch_data = find_channel(params.name)
    if not ch_data or not ch_data.config then
        return HttpHelpers.error(server, client, 404, "Channel not found")
    end

    local ch_obj = ChannelRepository and ChannelRepository:find(params.name)
    
    return HttpHelpers.success(server, client, {
        name = params.name,
        inputs = ch_data.config.input or {},
        active_input = ch_obj and ch_obj._last_active_id or 1,
        display_name = ch_obj and ch_obj._display_name or params.name
    })
end

--- Возвращает данные PSI/SI канала
function ChannelRoutes.get_channel_psi(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, {
        name = { type = "string", required = true },
        table = { type = "string", required = false }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local ch_obj = ChannelRepository and ChannelRepository:find(params.name)
    if not ch_obj then return HttpHelpers.error(server, client, 404, "Channel not found") end

    local psi = ch_obj:get_psi() or {}
    if params.table then
        local table_data = psi[params.table:upper()]
        if not table_data then return HttpHelpers.error(server, client, 404, "PSI table not found") end
        return HttpHelpers.success(server, client, table_data)
    end

    psi.name = params.name
    psi.display_name = ch_obj._display_name or params.name
    return HttpHelpers.success(server, client, psi)
end

--- Создает новый канал (Raw Astra Channel)
function ChannelRoutes.create_channel_raw(server, client, request)
    local data = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(data, {
        name = { type = "string", required = true },
        input = { type = "table", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    if not make_channel(data) then
        return false, "Failed to create channel in Astra core"
    end

    return HttpHelpers.success(server, client, { message = "Channel created" })
end

--- Удаляет или перезапускает канал (Raw Astra Channel)
function ChannelRoutes.kill_channel_raw(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, {
        name = { type = "string", required = true },
        reboot = { type = "boolean", required = false }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local ch_data = find_channel(params.name)
    if not ch_data then return HttpHelpers.error(server, client, 404, "Channel not found") end

    local config = ch_data.config
    kill_channel(ch_data)
    
    if params.reboot and config then
        if timer then
            timer({ interval = 1, callback = function(self) self:close(); make_channel(config) end })
        else
            make_channel(config)
        end
    end

    return HttpHelpers.success(server, client, { 
        message = params.reboot and "Channel rebooting" or "Channel killed",
        config = config
    })
end

--- Создает поток с мониторингом
function ChannelRoutes.create_stream(server, client, request)
    local data = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(data, {
        name = { type = "string", required = true },
        input = { type = "table", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result = Channel.make_stream(data)
    if not success then return false, result or "Failed to create stream" end

    return HttpHelpers.success(server, client, { message = "Stream and monitor created" })
end

--- Удаляет поток и монитор
function ChannelRoutes.kill_stream(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, {
        name = { type = "string", required = true },
        reboot = { type = "boolean", required = false }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local config = Channel.kill_stream(params.name)
    if not config then return HttpHelpers.error(server, client, 404, "Stream not found") end
    
    if params.reboot then
        if timer then
            timer({ interval = 1, callback = function(self) self:close(); Channel.make_stream(config) end })
        else
            Channel.make_stream(config)
        end
    end

    return HttpHelpers.success(server, client, { 
        message = params.reboot and "Stream rebooting" or "Stream and monitor killed",
        config = config
    })
end

return ChannelRoutes
