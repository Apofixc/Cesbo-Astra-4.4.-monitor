--- @class ChannelRoutes
local ChannelRoutes = {}

-- 1. Стандартные Lua функции
local pairs = pairs
local ipairs = ipairs
local type = type
local tonumber = tonumber
local table_insert = table.insert
local pcall = pcall

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")
local Channel = ModuleManager.get_module("channel")
local ChannelRepository = ModuleManager.get_module("channel_repository")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local find_channel = ModuleManager.get_global_dependency("find_channel")
local make_channel = ModuleManager.get_global_dependency("make_channel")
local kill_channel = ModuleManager.get_global_dependency("kill_channel")
local channel_list = ModuleManager.get_global_dependency("channel_list")
local timer = ModuleManager.get_global_dependency("timer")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ChannelRoutes"

--- Возвращает список всех каналов с их адресами вещания
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function ChannelRoutes.get_channels(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

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

    HttpHelpers.success(server, client, channels)
    return true
end

--- Возвращает агрегированную статистику по каналам
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function ChannelRoutes.get_channels_stats(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local total_astra_channels = 0
    if channel_list then
        for _ in pairs(channel_list) do
            total_astra_channels = total_astra_channels + 1
        end
    end

    local total_monitored = 0
    local online = 0
    local offline = 0
    local with_errors = 0

    local active_channels = ChannelRepository and ChannelRepository:get_all() or {}
    
    for _, ch_obj in pairs(active_channels) do
        total_monitored = total_monitored + 1
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
        total_astra_channels = total_astra_channels,
        total_monitored = total_monitored,
        online = online,
        offline = offline,
        with_errors = with_errors
    })
    return true
end

--- Возвращает детальную информацию о канале
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function ChannelRoutes.get_channel_info(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, {
        name = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local ch_data = find_channel(params.name)
    if not ch_data or not ch_data.config then
        return HttpHelpers.error(server, client, 404, "Channel not found")
    end

    HttpHelpers.success(server, client, ch_data.config)
    return true
end

--- Возвращает список входов канала и активный вход
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function ChannelRoutes.get_channel_inputs(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, {
        name = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local name = params.name
    local ch_data = find_channel(name)
    if not ch_data or not ch_data.config then
        return HttpHelpers.error(server, client, 404, "Channel not found")
    end

    local ch_obj = ChannelRepository and ChannelRepository:find(name)
    local active_input = ch_obj and ch_obj._last_active_id or 1
    
    HttpHelpers.success(server, client, {
        name = name,
        inputs = ch_data.config.input or {},
        active_input = active_input,
        display_name = ch_obj and ch_obj._display_name or name
    })
    return true
end

--- Возвращает данные PSI/SI канала
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function ChannelRoutes.get_channel_psi(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, {
        name = { type = "string", required = true },
        table = { type = "string", required = false }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local name = params.name
    local table_name = params.table

    local ch_obj = ChannelRepository and ChannelRepository:find(name)
    if not ch_obj then
        return HttpHelpers.error(server, client, 404, "Channel not found")
    end

    local psi = ch_obj:get_psi() or {}
    
    if table_name then
        local table_data = psi[table_name:upper()]
        if not table_data then
            return HttpHelpers.error(server, client, 404, "PSI table not found")
        end
        HttpHelpers.success(server, client, table_data)
        return true
    end

    psi.name = name
    psi.display_name = ch_obj and ch_obj._display_name or name
    HttpHelpers.success(server, client, psi)
    return true
end

--- Создает новый канал (Raw Astra Channel)
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function ChannelRoutes.create_channel_raw(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local data = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(data, {
        name = { type = "string", required = true },
        input = { type = "table", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local ch = make_channel(data)
    if not ch then
        Logger.error(COMPONENT_NAME, "Failed to create channel '%s'", tostring(data.name))
        return false, "Failed to create channel in Astra core"
    end

    HttpHelpers.success(server, client, { message = "Channel created" })
    return true
end

--- Удаляет или перезапускает канал (Raw Astra Channel)
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function ChannelRoutes.kill_channel_raw(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, {
        name = { type = "string", required = true },
        reboot = { type = "boolean", required = false }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local name = params.name
    local ch_data = find_channel(name)
    if not ch_data then
        return HttpHelpers.error(server, client, 404, "Channel not found in Astra")
    end

    local reboot = params.reboot == true
    local config = ch_data.config
    
    kill_channel(ch_data)
    if reboot and config then
        if timer then
            timer({
                interval = 1,
                callback = function(self)
                    self:close()
                    make_channel(config)
                end
            })
        else
            make_channel(config)
        end
    end

    HttpHelpers.success(server, client, { 
        message = reboot and "Channel rebooting" or "Channel killed",
        config = config
    })
    return true
end

--- Создает поток с мониторингом
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function ChannelRoutes.create_stream(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local data = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(data, {
        name = { type = "string", required = true },
        input = { type = "table", required = true },
        monitor = { type = "table", required = false }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result = Channel.make_stream(data)
    if success and result then
        HttpHelpers.success(server, client, { message = "Stream and monitor created" })
        return true
    else
        return false, result or "Failed to create stream"
    end
end

--- Удаляет поток и монитор
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function ChannelRoutes.kill_stream(server, client, request)
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

    local config = Channel.kill_stream(name)
    if not config then 
        return HttpHelpers.error(server, client, 404, "Stream not found")
    end
    
    if reboot then
        if timer then
            timer({
                interval = 1,
                callback = function(self)
                    self:close()
                    Channel.make_stream(config)
                end
            })
        else
            Channel.make_stream(config)
        end
    end

    HttpHelpers.success(server, client, { 
        message = reboot and "Stream rebooting" or "Stream and monitor killed",
        config = config
    })
    return true
end

return ChannelRoutes
